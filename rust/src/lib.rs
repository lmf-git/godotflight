mod chunk;
mod math;
mod meshing;
mod terrain;
mod uber_noise;

use chunk::{ChunkKey, ChunkResult, ChunkState, CubeFace, MeshData, CHUNK_SIZE};
use meshing::polygonize_chunk;
use terrain::{PlanetParams, TerrainSampler};

use godot::classes::mesh::PrimitiveType;
use godot::classes::{
    ArrayMesh, BoxMesh, BoxShape3D, ConcavePolygonShape3D, CollisionShape3D, INode3D,
    MeshInstance3D, Node3D, ResourceLoader, Shader, ShaderMaterial, SphereMesh,
    StandardMaterial3D, StaticBody3D, Texture2D,
};
use godot::global::godot_print;
use godot::prelude::*;

// Godot Mesh array slot indices (Mesh::ArrayType enum ordinals)
const ARRAY_VERTEX: usize = 0;
const ARRAY_NORMAL: usize = 1;
const ARRAY_INDEX: usize = 12;
const ARRAY_MAX: usize = 13;

use std::collections::{HashMap, HashSet};
use std::sync::{mpsc, Arc, Condvar, Mutex};
use std::thread;

// Priority work queue: workers always pull the lowest-priority-value request.
type WorkQueue = Arc<(Mutex<Vec<(f32, WorkRequest)>>, Condvar)>;

struct VoxelTerrainExtension;

#[gdextension]
unsafe impl ExtensionLibrary for VoxelTerrainExtension {}

// ---------------------------------------------------------------------------
// Worker message types
// ---------------------------------------------------------------------------

struct WorkRequest {
    key: ChunkKey,
    sampler: Arc<TerrainSampler>,
}

// ---------------------------------------------------------------------------
// LOD constants
// ---------------------------------------------------------------------------

const NUM_LODS: u8 = 9;
const VIEW_RADIUS_CHUNKS: i32 = 3;
const FADE_SPEED: f32 = 1.5;

fn lod_chunk_world_size(lod: u8) -> f32 {
    CHUNK_SIZE as f32 * (1u32 << lod) as f32
}

// ---------------------------------------------------------------------------
// Planet GDExtension node
// ---------------------------------------------------------------------------

#[derive(GodotClass)]
#[class(base=Node3D)]
pub struct Planet {
    base: Base<Node3D>,

    #[export]
    radius: f64,

    #[export]
    seed: i32,

    #[export]
    elevation_range: f64,

    /// 0 = Earth-like planet (terrain shader, water, cities)
    /// 1 = Moon (crater terrain, grey shader, no water/cities)
    #[export]
    terrain_style: i32,

    // Threading
    result_rx: Option<mpsc::Receiver<ChunkResult>>,
    work_queue: Option<WorkQueue>,

    // Chunk state tracking
    chunk_states: HashMap<ChunkKey, ChunkState>,
    mesh_instances: HashMap<ChunkKey, Gd<MeshInstance3D>>,

    // Fade-in: newly loaded chunks dissolve from 0→1 (fading_material).
    fade_in: HashMap<ChunkKey, f32>,
    // Held: chunks that left the load_set but have no replacement yet.
    held: HashMap<ChunkKey, (Gd<MeshInstance3D>, f32)>,

    // Shared terrain sampler
    sampler: Option<Arc<TerrainSampler>>,

    // Opaque material — const fade=1.0 (no instance variable slot).
    material: Option<Gd<ShaderMaterial>>,
    // Fading material — instance uniform float fade.
    fading_material: Option<Gd<ShaderMaterial>>,
}

#[godot_api]
impl INode3D for Planet {
    fn init(base: Base<Node3D>) -> Self {
        Planet {
            base,
            radius: 100_000.0,
            seed: 42,
            elevation_range: 5000.0,
            terrain_style: 0,
            result_rx: None,
            work_queue: None,
            chunk_states: HashMap::new(),
            mesh_instances: HashMap::new(),
            fade_in: HashMap::new(),
            held: HashMap::new(),
            sampler: None,
            material: None,
            fading_material: None,
        }
    }

    fn ready(&mut self) {
        godot_print!("Planet ready — radius={} seed={}", self.radius, self.seed);

        let params = PlanetParams {
            radius: self.radius as f32,
            elevation_range: self.elevation_range as f32,
            seed: self.seed as u32,
            terrain_style: self.terrain_style,
        };
        let sampler = Arc::new(TerrainSampler::new(params));
        self.sampler = Some(sampler.clone());

        // terrain shader uses "// FADE_PLACEHOLDER" comment as a replacement target:
        // - Fading variant:  `instance uniform float fade` (per-chunk instance slot)
        // - Opaque variant:  `const float fade = 1.0`     (zero instance slots)
        let fade_line_fading = "instance uniform float fade : hint_range(0.0, 1.0) = 1.0;";
        let fade_line_opaque = "const float fade = 1.0;";

        if self.terrain_style == 1 {
            // Moon: simple grey shader, two variants.
            let moon_body =
                "void fragment() {\n\
                 \tFADE_DISCARD\n\
                 \tALBEDO = vec3(0.52, 0.50, 0.48);\n\
                 \tROUGHNESS = 0.92;\n\
                 \tMETALLIC = 0.0;\n\
                 }";
            let fade_discard =
                "if (fade < 1.0) {\n\
                 \t\tfloat hash = fract(sin(dot(floor(FRAGCOORD.xy), vec2(127.1, 311.7))) * 43758.5453);\n\
                 \t\tif (hash > fade) { discard; }\n\
                 \t}";

            let fading_code = format!(
                "shader_type spatial;\n{}\n{}",
                fade_line_fading,
                moon_body.replace("FADE_DISCARD", fade_discard)
            );
            let opaque_code = format!(
                "shader_type spatial;\n{}\n{}",
                fade_line_opaque,
                moon_body.replace("FADE_DISCARD", "")
            );

            let mut sh_f = Shader::new_gd();
            sh_f.set_code(&fading_code);
            let mut mat_f = ShaderMaterial::new_gd();
            mat_f.set_shader(&sh_f);
            self.fading_material = Some(mat_f);

            let mut sh_o = Shader::new_gd();
            sh_o.set_code(&opaque_code);
            let mut mat_o = ShaderMaterial::new_gd();
            mat_o.set_shader(&sh_o);
            self.material = Some(mat_o);
        } else {
            // Earth-like planet: full triplanar terrain shader from project shaders/.
            // Path is relative to this source file (rust/src/lib.rs → ../../shaders/).
            let base_code = include_str!("../../shaders/planet_terrain.gdshader");
            let fading_code = base_code.replace("// FADE_PLACEHOLDER", fade_line_fading);
            let opaque_code = base_code.replace("// FADE_PLACEHOLDER", fade_line_opaque);

            let r = self.radius as f32;
            let elev = self.elevation_range as f32;
            let snow_h = elev * 0.20;
            let rock_t = 0.10_f32;

            // Load textures; apply to both material variants.
            let terrain_textures: &[(&str, &str)] = &[
                ("tex_grass",   "res://assets/textures/terrain/rass-green.jpg"),
                ("tex_rock",    "res://assets/textures/terrain/estern-barren.jpg"),
                ("tex_snow",    "res://assets/textures/terrain/mntn-snow-greys.jpg"),
                ("tex_sand",    "res://assets/textures/terrain/andy-ground.jpg"),
                ("tex_tundra",  "res://assets/textures/terrain/ange-herbacious-tundra.jpg"),
                ("tex_desert",  "res://assets/textures/terrain/rand-canyon-red.jpg"),
                ("tex_dry",     "res://assets/textures/terrain/rass-yellow.jpg"),
            ];
            let mut textures: Vec<(&str, Gd<Texture2D>)> = Vec::new();
            {
                let mut rl = ResourceLoader::singleton();
                for (param, path) in terrain_textures {
                    let gpath = GString::from(*path);
                    if let Some(res) = rl.load(&gpath) {
                        if let Ok(tex) = res.try_cast::<Texture2D>() {
                            textures.push((param, tex));
                        }
                    }
                }
            }

            let setup_mat = |code: &str| -> Gd<ShaderMaterial> {
                let mut shader = Shader::new_gd();
                shader.set_code(code);
                let mut mat = ShaderMaterial::new_gd();
                mat.set_shader(&shader);
                for (param, val) in [("planet_radius", r), ("snow_height", snow_h), ("rock_threshold", rock_t)] {
                    mat.set_shader_parameter(&StringName::from(param), &val.to_variant());
                }
                for (param, tex) in &textures {
                    mat.set_shader_parameter(&StringName::from(*param), &tex.to_variant());
                }
                mat
            };

            self.fading_material = Some(setup_mat(&fading_code));
            self.material = Some(setup_mat(&opaque_code));

            // Water sphere at sea level
            let water_r = self.radius as f32;
            let mut water_mesh = SphereMesh::new_gd();
            water_mesh.set_radius(water_r);
            water_mesh.set_height(water_r * 2.0);
            water_mesh.set_radial_segments(64);
            water_mesh.set_rings(32);
            let mut water_mat = StandardMaterial3D::new_gd();
            water_mat.set_albedo(Color::from_rgb(0.08, 0.25, 0.55));
            let mut water_mi = MeshInstance3D::new_alloc();
            water_mi.set_mesh(&water_mesh);
            water_mi.set_surface_override_material(0, &water_mat);
            self.base_mut().add_child(&water_mi);
        }

        // Priority work queue + worker thread pool.
        let work_queue: WorkQueue = Arc::new((Mutex::new(Vec::with_capacity(512)), Condvar::new()));
        let (result_tx, result_rx) = mpsc::channel::<ChunkResult>();

        let num_workers = std::thread::available_parallelism()
            .map(|n| n.get().min(8).max(2))
            .unwrap_or(4);
        godot_print!("Starting {} worker threads", num_workers);

        for _ in 0..num_workers {
            let wq = work_queue.clone();
            let tx = result_tx.clone();
            thread::spawn(move || {
                let (lock, cvar) = &*wq;
                loop {
                    let req: WorkRequest = {
                        let mut items = lock.lock().unwrap();
                        loop {
                            if let Some(min_pos) = items
                                .iter()
                                .enumerate()
                                .min_by(|(_, a), (_, b)| {
                                    a.0.partial_cmp(&b.0)
                                        .unwrap_or(std::cmp::Ordering::Equal)
                                })
                                .map(|(i, _)| i)
                            {
                                break items.swap_remove(min_pos).1;
                            }
                            items = cvar.wait(items).unwrap();
                        }
                    };
                    let densities = req.sampler.fill_chunk(
                        req.key.face, req.key.lod, req.key.cx, req.key.cy,
                    );
                    let mesh_data = polygonize_chunk(&req.key, &densities, &req.sampler);
                    if tx.send(ChunkResult { key: req.key, mesh_data }).is_err() {
                        break;
                    }
                }
            });
        }

        self.work_queue = Some(work_queue);
        self.result_rx = Some(result_rx);

        if self.terrain_style != 1 {
            self.place_city_buildings();
        }
    }

    fn process(&mut self, delta: f64) {
        let cam_world = match self.get_camera_world_pos() {
            Some(p) => p,
            None => return,
        };
        let cam_pos = cam_world - self.base().get_global_position();

        let r = self.radius as f32;
        let load_list = Self::compute_desired_chunks(r, cam_pos, 1.0);
        let load_set: HashSet<ChunkKey> = load_list.iter().map(|(k, _)| *k).collect();
        let keep_set: HashSet<ChunkKey> = Self::compute_desired_chunks(r, cam_pos, 1.5)
            .into_iter()
            .map(|(k, _)| k)
            .collect();

        self.process_results(&load_set);
        self.update_chunks(load_list, &load_set, &keep_set);
        self.update_fades(delta as f32);
    }
}

impl Planet {
    // ── City building placement ───────────────────────────────────────────────

    fn place_city_buildings(&mut self) {
        let sampler = match self.sampler.clone() {
            Some(s) => s,
            None => return,
        };

        let r = self.radius as f32;

        let mut building_mat = StandardMaterial3D::new_gd();
        building_mat.set_albedo(Color::from_rgb(0.58, 0.58, 0.62));

        let mut dark_mat = StandardMaterial3D::new_gd();
        dark_mat.set_albedo(Color::from_rgb(0.25, 0.25, 0.28));

        let mut instances: Vec<Gd<MeshInstance3D>> = Vec::new();

        for city in sampler.cities().iter() {
            let up = Vector3::new(city.dir[0], city.dir[1], city.dir[2]).normalized();
            let ground_r = r + city.base_elev_m;
            let (right, fwd) = tangent_frame(up);

            let buildings: &[(f32, f32, f32, f32, f32, &Gd<StandardMaterial3D>)] = match city.kind {
                0 => &[
                    (-25.0,  0.0,  18.0, 18.0, 12.0, &building_mat),
                    ( 25.0,-15.0,  14.0, 14.0,  9.0, &building_mat),
                    (  5.0, 30.0,  12.0, 20.0, 10.0, &building_mat),
                    (-30.0, 25.0,   9.0,  9.0,  7.0, &building_mat),
                ],
                1 => &[
                    (  0.0,  0.0, 22.0, 22.0, 55.0, &building_mat),
                    (-45.0,-20.0, 16.0, 16.0, 32.0, &building_mat),
                    ( 45.0, 10.0, 18.0, 18.0, 28.0, &building_mat),
                    (-20.0, 45.0, 20.0, 20.0, 22.0, &building_mat),
                    ( 35.0,-45.0, 14.0, 14.0, 38.0, &building_mat),
                    (-55.0, 20.0, 12.0, 25.0, 18.0, &building_mat),
                    ( 12.0,-55.0, 15.0, 15.0, 20.0, &building_mat),
                    ( 55.0, 45.0, 18.0, 18.0, 42.0, &building_mat),
                    (-35.0,-55.0, 20.0, 20.0, 26.0, &building_mat),
                    ( 22.0, 55.0, 14.0, 14.0, 30.0, &building_mat),
                ],
                2 => &[
                    (-90.0,  0.0, 130.0, 38.0,  8.0, &building_mat),
                    ( 90.0,  0.0, 100.0, 30.0,  6.0, &building_mat),
                    (  0.0,  0.0,  28.0,380.0,  1.5, &dark_mat),
                    ( 65.0, 90.0,   9.0,  9.0, 32.0, &building_mat),
                ],
                _ => &[],
            };

            for &(or_, of_, w, d, h, mat) in buildings {
                instances.push(make_building(up, right, fwd, ground_r, or_, of_, w, d, h, mat));
            }
        }

        for mi in instances {
            self.base_mut().add_child(&mi);
        }
    }

    fn get_camera_world_pos(&self) -> Option<Vector3> {
        let viewport = self.base().get_viewport()?;
        let camera = viewport.get_camera_3d()?;
        Some(camera.get_global_position())
    }

    // ── Fade helpers ─────────────────────────────────────────────────────────

    fn set_chunk_fade(mi: &mut Gd<MeshInstance3D>, alpha: f32) {
        let name = StringName::from("fade");
        let value = alpha.to_variant();
        mi.set_instance_shader_parameter(&name, &value);
    }

    fn update_fades(&mut self, dt: f32) {
        let mut done_in: Vec<ChunkKey> = Vec::new();
        for (key, alpha) in self.fade_in.iter_mut() {
            *alpha = (*alpha + dt * FADE_SPEED).min(1.0);
            if let Some(mi) = self.mesh_instances.get_mut(key) {
                Self::set_chunk_fade(mi, *alpha);
            }
            if *alpha >= 1.0 {
                done_in.push(*key);
            }
        }
        for k in done_in {
            self.fade_in.remove(&k);
            if let Some(mi) = self.mesh_instances.get_mut(&k) {
                if let Some(opaque) = &self.material {
                    mi.set_surface_override_material(0, opaque);
                }
            }
        }

        const HELD_TIMEOUT: f32 = 15.0;
        let mut timed_out: Vec<ChunkKey> = Vec::new();
        for (key, (_, age)) in self.held.iter_mut() {
            *age += dt;
            if *age >= HELD_TIMEOUT {
                timed_out.push(*key);
            }
        }
        for k in timed_out {
            if let Some((mut mi, _)) = self.held.remove(&k) {
                mi.queue_free();
            }
        }
    }

    // ── Chunk management ─────────────────────────────────────────────────────

    fn update_chunks(
        &mut self,
        load_list: Vec<(ChunkKey, f32)>,
        load_set: &HashSet<ChunkKey>,
        keep_set: &HashSet<ChunkKey>,
    ) {
        // Restore held chunks that came back into the load set
        let to_restore: Vec<ChunkKey> =
            self.held.keys().filter(|k| load_set.contains(k)).copied().collect();
        for key in to_restore {
            if let Some((mi, _)) = self.held.remove(&key) {
                self.fade_in.remove(&key);
                self.mesh_instances.insert(key, mi);
            }
        }

        // Move chunks that left the load set into "held"
        let to_hold: Vec<ChunkKey> = self
            .mesh_instances
            .keys()
            .filter(|k| !load_set.contains(k) && !self.held.contains_key(k))
            .copied()
            .collect();
        for key in to_hold {
            self.fade_in.remove(&key);
            if let Some(mut mi) = self.mesh_instances.remove(&key) {
                if let Some(opaque) = &self.material {
                    mi.set_surface_override_material(0, opaque);
                }
                Self::set_chunk_fade(&mut mi, 1.0);
                self.held.insert(key, (mi, 0.0));
            }
        }

        // Free held chunks whose replacement is visible
        let held_keys: Vec<ChunkKey> = self.held.keys().copied().collect();
        for key in held_keys {
            let replaced = {
                let parent_loaded = key.lod + 1 < NUM_LODS && {
                    let pk = ChunkKey { face: key.face, lod: key.lod + 1, cx: key.cx >> 1, cy: key.cy >> 1 };
                    (self.mesh_instances.contains_key(&pk) && !self.fade_in.contains_key(&pk))
                        || matches!(self.chunk_states.get(&pk), Some(ChunkState::Empty))
                };
                let child_loaded = key.lod > 0 && (0..4).all(|i| {
                    let ck = ChunkKey {
                        face: key.face,
                        lod: key.lod - 1,
                        cx: key.cx * 2 + (i & 1),
                        cy: key.cy * 2 + (i >> 1),
                    };
                    (self.mesh_instances.contains_key(&ck) && !self.fade_in.contains_key(&ck))
                        || matches!(self.chunk_states.get(&ck), Some(ChunkState::Empty))
                });
                parent_loaded || child_loaded
            };
            if replaced {
                if let Some((mut mi, _)) = self.held.remove(&key) {
                    mi.queue_free();
                }
            }
        }

        // Preserve in-flight requests within the wider keep_set
        self.chunk_states.retain(|k, v| match v {
            ChunkState::Requested => keep_set.contains(k),
            ChunkState::Empty => true,
        });

        // Prune work queue entries for cancelled requests
        if let Some(wq) = &self.work_queue {
            let (lock, _) = &**wq;
            if let Ok(mut items) = lock.try_lock() {
                items.retain(|(_, req)| self.chunk_states.contains_key(&req.key));
            }
        }

        // Request new chunks in priority order
        for (key, priority) in &load_list {
            let key = *key;
            if !self.chunk_states.contains_key(&key)
                && !self.mesh_instances.contains_key(&key)
                && !self.held.contains_key(&key)
            {
                self.request_chunk(key, *priority);
            }
        }
    }

    fn request_chunk(&mut self, key: ChunkKey, priority: f32) {
        let sampler = match &self.sampler {
            Some(s) => s.clone(),
            None => return,
        };
        let wq = match &self.work_queue {
            Some(q) => q.clone(),
            None => return,
        };
        let (lock, cvar) = &*wq;
        let mut items = lock.lock().unwrap();
        items.push((priority, WorkRequest { key, sampler }));
        cvar.notify_one();
        drop(items);
        self.chunk_states.insert(key, ChunkState::Requested);
    }

    fn process_results(&mut self, load_set: &HashSet<ChunkKey>) {
        let mut completed: Vec<ChunkResult> = Vec::new();
        if let Some(rx) = &self.result_rx {
            while let Ok(result) = rx.try_recv() {
                completed.push(result);
            }
        }

        for result in completed {
            if self.chunk_states.remove(&result.key).is_none() {
                continue; // cancelled while in-flight
            }
            if !load_set.contains(&result.key) {
                continue; // drifted out of load_set
            }
            if self.mesh_instances.contains_key(&result.key) {
                continue; // duplicate result
            }
            match result.mesh_data {
                Some(mesh_data) => self.create_mesh_for_chunk(result.key, mesh_data),
                None => {
                    self.chunk_states.insert(result.key, ChunkState::Empty);
                }
            }
        }
    }

    fn create_mesh_for_chunk(&mut self, key: ChunkKey, data: MeshData) {
        if data.vertices.is_empty() {
            return;
        }

        let mut array_mesh = ArrayMesh::new_gd();

        let verts: PackedVector3Array =
            data.vertices.iter().map(|v| Vector3::new(v[0], v[1], v[2])).collect();
        let normals: PackedVector3Array =
            data.normals.iter().map(|n| Vector3::new(n[0], n[1], n[2])).collect();
        let idxs: PackedInt32Array = data.indices.iter().map(|&i| i).collect();

        let mut arrays = VarArray::new();
        let nil_var = Variant::nil();
        arrays.resize(ARRAY_MAX, &nil_var);
        let verts_var = verts.to_variant();
        let norms_var = normals.to_variant();
        let idxs_var = idxs.to_variant();
        arrays.set(ARRAY_VERTEX, &verts_var);
        arrays.set(ARRAY_NORMAL, &norms_var);
        arrays.set(ARRAY_INDEX, &idxs_var);

        array_mesh.add_surface_from_arrays(PrimitiveType::TRIANGLES, &arrays);

        let mut mi = MeshInstance3D::new_alloc();
        mi.set_mesh(&array_mesh);
        if let Some(mat) = &self.fading_material {
            mi.set_surface_override_material(0, mat);
        }
        Self::set_chunk_fade(&mut mi, 0.0);

        // Trimesh collision only for LOD0 (player walking surface)
        if key.lod == 0 {
            let mut faces = PackedVector3Array::new();
            for tri in data.indices.chunks(3) {
                if tri.len() < 3 { continue; }
                for &idx in tri {
                    let v = &data.vertices[idx as usize];
                    faces.push(Vector3::new(v[0], v[1], v[2]));
                }
            }
            let mut trimesh = ConcavePolygonShape3D::new_gd();
            trimesh.set_faces(&faces);
            let mut col = CollisionShape3D::new_alloc();
            col.set_shape(&trimesh);
            let mut body = StaticBody3D::new_alloc();
            body.add_child(&col);
            mi.add_child(&body);
        }

        if let Some(mut old) = self.mesh_instances.remove(&key) {
            old.queue_free();
        }
        if let Some((mut old, _)) = self.held.remove(&key) {
            old.queue_free();
        }
        self.fade_in.remove(&key);

        self.base_mut().add_child(&mi);
        self.fade_in.insert(key, 0.0);
        self.mesh_instances.insert(key, mi);
    }

    // ── Desired-chunk computation ─────────────────────────────────────────────

    /// Compute which chunks should be loaded. Uses angular chord distance from
    /// camera direction to handle all 6 cube-sphere faces correctly.
    ///
    /// `outer_mult` scales LOD rings outward; use 1.0 for loading, 1.5 for
    /// hysteresis keep-set (prevents boundary flicker).
    fn compute_desired_chunks(r: f32, cam_pos: Vector3, outer_mult: f32) -> Vec<(ChunkKey, f32)> {
        let cam_h = (cam_pos.x * cam_pos.x + cam_pos.y * cam_pos.y + cam_pos.z * cam_pos.z)
            .sqrt()
            .max(r * 1.001);
        let cam_dir = [cam_pos.x / cam_h, cam_pos.y / cam_h, cam_pos.z / cam_h];

        // Altitude-based minimum LOD — fine LOD is wasted from high altitude.
        let altitude = (cam_h - r).max(0.0);
        let lod_start: u8 = if altitude < 100.0 { 0 }
            else if altitude < 500.0   { 1 }
            else if altitude < 2_000.0  { 2 }
            else if altitude < 8_000.0  { 3 }
            else if altitude < 20_000.0 { 4 }
            else if altitude < 80_000.0 { 5 }
            else if altitude < 250_000.0 { 7 }
            else { 8 };

        // Max visible distance (geometric horizon × 2)
        let max_visible_m = (2.0 * r * cam_h).sqrt() * 2.0;

        let mut out: Vec<(ChunkKey, f32)> = Vec::new();

        for face in CubeFace::all() {
            let (face_normal, tan_u, tan_v) = face.tangent_frame();
            let dot = cam_dir[0] * face_normal[0]
                + cam_dir[1] * face_normal[1]
                + cam_dir[2] * face_normal[2];

            if dot < -0.17 {
                continue; // back of planet — skip
            }

            let dominant = dot.max(0.06);
            let u = cam_dir[0] * tan_u[0] + cam_dir[1] * tan_u[1] + cam_dir[2] * tan_u[2];
            let v = cam_dir[0] * tan_v[0] + cam_dir[1] * tan_v[1] + cam_dir[2] * tan_v[2];
            let cam_cu = (u / dominant * r).clamp(-r * 1.5, r * 1.5);
            let cam_cv = (v / dominant * r).clamp(-r * 1.5, r * 1.5);

            for lod in lod_start..NUM_LODS {
                let chunk_m = lod_chunk_world_size(lod);

                let inner_m: f32 = if lod == lod_start {
                    0.0
                } else {
                    VIEW_RADIUS_CHUNKS as f32 * lod_chunk_world_size(lod - 1)
                };
                let outer_m: f32 = if lod == NUM_LODS - 1 {
                    max_visible_m
                } else {
                    (VIEW_RADIUS_CHUNKS as f32 * chunk_m * outer_mult).min(max_visible_m)
                };
                if outer_m <= inner_m {
                    break;
                }

                let inner_sq = inner_m * inner_m;
                let outer_sq = outer_m * outer_m;

                let max_r = ((outer_m / chunk_m).ceil() as i32) + 1;
                let cx0 = (cam_cu / chunk_m).floor() as i32;
                let cy0 = (cam_cv / chunk_m).floor() as i32;

                for dy in -max_r..=max_r {
                    for dx in -max_r..=max_r {
                        let cx = cx0 + dx;
                        let cy = cy0 + dy;

                        let cu_c = cx as f32 * chunk_m + chunk_m * 0.5;
                        let cv_c = cy as f32 * chunk_m + chunk_m * 0.5;
                        let px = face_normal[0] * r + tan_u[0] * cu_c + tan_v[0] * cv_c;
                        let py = face_normal[1] * r + tan_u[1] * cu_c + tan_v[1] * cv_c;
                        let pz = face_normal[2] * r + tan_u[2] * cu_c + tan_v[2] * cv_c;
                        let plen = (px * px + py * py + pz * pz).sqrt();

                        let cdot =
                            (cam_dir[0] * px + cam_dir[1] * py + cam_dir[2] * pz) / plen;
                        if cdot <= 0.0 {
                            continue;
                        }

                        let dist_sq = 2.0 * (1.0 - cdot) * r * r;

                        if dist_sq >= inner_sq && dist_sq < outer_sq {
                            let dist = dist_sq.sqrt();
                            let priority = dist + lod as f32 * chunk_m * 0.05;
                            out.push((ChunkKey { face, lod, cx, cy }, priority));
                        }
                    }
                }
            }
        }

        out.sort_unstable_by(|a, b| {
            a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal)
        });
        out
    }
}

// ---------------------------------------------------------------------------
// City building helpers
// ---------------------------------------------------------------------------

fn tangent_frame(up: Vector3) -> (Vector3, Vector3) {
    let ref_axis = if up.dot(Vector3::UP).abs() < 0.9 { Vector3::UP } else { Vector3::RIGHT };
    let right = ref_axis.cross(up).normalized();
    let fwd = up.cross(right).normalized();
    (right, fwd)
}

fn make_building(
    up: Vector3,
    right: Vector3,
    fwd: Vector3,
    ground_r: f32,
    offset_r: f32,
    offset_f: f32,
    width: f32,
    depth: f32,
    height: f32,
    mat: &Gd<StandardMaterial3D>,
) -> Gd<MeshInstance3D> {
    let centre = up * (ground_r + height * 0.5) + right * offset_r + fwd * offset_f;

    let basis = Basis {
        rows: [
            Vector3::new(right.x, up.x, fwd.x),
            Vector3::new(right.y, up.y, fwd.y),
            Vector3::new(right.z, up.z, fwd.z),
        ],
    };

    let mut box_mesh = BoxMesh::new_gd();
    box_mesh.set_size(Vector3::new(width, height, depth));

    let mut mi = MeshInstance3D::new_alloc();
    mi.set_mesh(&box_mesh);
    mi.set_surface_override_material(0, mat);
    mi.set_transform(Transform3D { basis, origin: centre });

    let mut box_shape = BoxShape3D::new_gd();
    box_shape.set_size(Vector3::new(width, height, depth));
    let mut col = CollisionShape3D::new_alloc();
    col.set_shape(&box_shape);
    let mut body = StaticBody3D::new_alloc();
    body.add_child(&col);
    mi.add_child(&body);

    mi
}
