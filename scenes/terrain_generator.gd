extends Node3D

## Procedural terrain with a flat zone around the runway.
## Generates chunked terrain that follows the camera and works with floating origin.
## Mesh generation runs on WorkerThreadPool to avoid main-thread hitches.

# Terrain config
@export var chunk_size := 500.0        # meters per chunk edge
@export var grid_resolution := 25      # vertices per chunk edge (25 = 20m spacing at 500m chunks) — LOD 0 only
@export var view_range := 12           # chunks visible in each direction from center
@export var max_height := 120.0        # peak terrain height in meters
@export var terrain_seed := 42

# LOD system — Manhattan distance thresholds and per-LOD vertex counts.
# LOD 0 (≤3 chunks out): full detail, 20 m vertex spacing
# LOD 1 (≤7 chunks out): half detail, 40 m vertex spacing
# LOD 2 (≤12 chunks out): quarter detail, 80 m vertex spacing
const LOD_THRESHOLDS   := [3, 7]          # max Manhattan dist for LOD 0, 1 (else LOD 2)
const LOD_RESOLUTIONS  := [25, 13, 7]     # vertices per chunk edge per LOD level
const SKIRT_DEPTH      := 150.0           # metres — fills cracks between adjacent LOD levels

const PLANET_RADIUS := 100_000.0  # metres — large enough to keep runway (<750 m) essentially flat (~0.5 m drop)

# Runway flat zone (world-space, matching runway at X:-15..15, Z:-750..750)
@export var flat_rect := Rect2(-80, -900, 160, 1800)  # x, z, w, h
@export var blend_margin := 150.0      # meters to blend from flat to full height

var _noise: FastNoiseLite           # primary elevation (FRACTAL_NONE — manual FBM below)
var _warp_noise: FastNoiseLite      # domain-warp field (independent seed)
var _continent_noise: FastNoiseLite # very-low-frequency mask that creates ocean basins vs land masses
var _chunks := {}             # Vector2i -> MeshInstance3D (active, visible)
var _chunk_lods := {}         # Vector2i -> int  (LOD level of the visible chunk)
var _pending_builds := {}     # Vector2i -> int  (LOD level being built on worker thread)
var _pending_replace := {}    # Vector2i -> MeshInstance3D (old chunk kept visible during LOD rebuild)
var _world_offset := Vector3.ZERO  # accumulated floating-origin shift
var _material: ShaderMaterial
var _last_center := Vector2i(999999, 999999)

# LOD debug visualisation
var _lod_debug: bool = false
var _lod_materials: Array[StandardMaterial3D] = []  # [LOD0, LOD1, LOD2]
var _debug_btn: Button


func _ready() -> void:
	# Primary elevation noise — FRACTAL_NONE so _uber_sample() controls all octaves.
	_noise = FastNoiseLite.new()
	_noise.seed = terrain_seed
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = 0.0008
	_noise.fractal_type = FastNoiseLite.FRACTAL_NONE

	# Domain-warp noise — slightly lower frequency for large-scale distortion.
	_warp_noise = FastNoiseLite.new()
	_warp_noise.seed = terrain_seed + 1000
	_warp_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_warp_noise.frequency = 0.00045
	_warp_noise.fractal_type = FastNoiseLite.FRACTAL_NONE

	# Continent noise — very low frequency (~40 km wavelength) to create ocean basins
	# and land masses.  Negative values → below sea level (ocean); positive → land.
	_continent_noise = FastNoiseLite.new()
	_continent_noise.seed = terrain_seed + 5000
	_continent_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_continent_noise.frequency = 0.000024   # 1/0.000024 ≈ 41 600 m wavelength
	_continent_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_continent_noise.fractal_octaves = 3

	var shader := load("res://shaders/terrain.gdshader") as Shader
	_material = ShaderMaterial.new()
	_material.shader = shader
	_material.set_shader_parameter(&"planet_radius", PLANET_RADIUS)
	_material.set_shader_parameter(&"max_height", max_height)
	_material.set_shader_parameter(&"world_offset", _world_offset)
	# _update_chunks() is NOT called here: _last_center is (999999,999999) at this
	# point, which would queue 169 tasks at ~500,000 km — all immediately discarded.
	# _process() triggers the first correct update once terrain_anchor nodes are ready.

	# LOD debug materials — one flat unshaded colour per LOD level.
	# LOD 0 (nearest, most detail) = green; LOD 1 = orange; LOD 2 = red.
	var lod_colors := [Color(0.15, 0.85, 0.25), Color(0.95, 0.65, 0.05), Color(0.90, 0.15, 0.15)]
	for col in lod_colors:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = col
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.cull_mode = BaseMaterial3D.CULL_BACK
		_lod_materials.append(mat)

	# Small toggle button — bottom-left corner, always on top.
	var canvas := CanvasLayer.new()
	canvas.layer = 10
	add_child(canvas)
	_debug_btn = Button.new()
	_debug_btn.text = "[ LOD Debug: OFF ]"
	_debug_btn.anchor_left   = 0.0
	_debug_btn.anchor_right  = 0.0
	_debug_btn.anchor_top    = 1.0
	_debug_btn.anchor_bottom = 1.0
	_debug_btn.offset_left   = 12
	_debug_btn.offset_right  = 220
	_debug_btn.offset_top    = -52
	_debug_btn.offset_bottom = -12
	_debug_btn.add_theme_font_size_override("font_size", 15)
	_debug_btn.pressed.connect(_toggle_lod_debug)
	canvas.add_child(_debug_btn)


func _toggle_lod_debug() -> void:
	_lod_debug = not _lod_debug
	_debug_btn.text = "[ LOD Debug: ON ]" if _lod_debug else "[ LOD Debug: OFF ]"
	# Swap materials on all currently visible chunks.
	for key in _chunks:
		var mi: MeshInstance3D = _chunks[key]
		var lod: int = _chunk_lods.get(key, 0)
		mi.material_override = _lod_materials[lod] if _lod_debug else _material
	# Also apply to chunks being held during LOD transitions.
	for key in _pending_replace:
		var mi: MeshInstance3D = _pending_replace[key]
		var lod: int = _chunk_lods.get(key, 0)
		mi.material_override = _lod_materials[lod] if _lod_debug else _material


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F3:
			_toggle_lod_debug()


func _process(_delta: float) -> void:
	var pos := _get_anchor_pos()
	var center := Vector2i(
		floori((pos.x + _world_offset.x) / chunk_size),
		floori((pos.z + _world_offset.z) / chunk_size)
	)
	if center != _last_center:
		_last_center = center
		_update_chunks()


func _get_anchor_pos() -> Vector3:
	# In map mode, load chunks at the orbit camera's surface focus.
	var map_anchors := get_tree().get_nodes_in_group("map_terrain_anchor")
	if not map_anchors.is_empty():
		return (map_anchors[0] as Node3D).global_position
	# Normal flight: load around the player/occupied vehicle.
	var anchors := get_tree().get_nodes_in_group("terrain_anchor")
	if not anchors.is_empty():
		return (anchors[0] as Node3D).global_position
	var cam := get_viewport().get_camera_3d()
	return cam.global_position if cam else Vector3.ZERO


func notify_origin_shift(offset: Vector3) -> void:
	_world_offset += offset
	_material.set_shader_parameter(&"world_offset", _world_offset)


func _lod_for_dist(dist: int) -> int:
	if dist <= LOD_THRESHOLDS[0]: return 0
	if dist <= LOD_THRESHOLDS[1]: return 1
	return 2


func _update_chunks() -> void:
	# Build needed map: coord -> target LOD level
	var needed := {}
	for cx in range(_last_center.x - view_range, _last_center.x + view_range + 1):
		for cz in range(_last_center.y - view_range, _last_center.y + view_range + 1):
			var key := Vector2i(cx, cz)
			var dist := absi(cx - _last_center.x) + absi(cz - _last_center.y)
			needed[key] = _lod_for_dist(dist)

	# Remove out-of-range chunks
	var to_remove := []
	for key in _chunks:
		if not needed.has(key):
			to_remove.append(key)
	for key in to_remove:
		_chunks[key].queue_free()
		_chunks.erase(key)
		_chunk_lods.erase(key)

	# Identify chunks whose LOD has changed — keep the old mesh visible (_pending_replace)
	# until the new LOD mesh is ready, to prevent flickering holes during LOD transitions.
	var to_rebuild := []
	for key in needed:
		var target_lod: int = needed[key]
		if _chunks.has(key) and _chunk_lods.get(key, -1) != target_lod and not _pending_builds.has(key):
			# Move to pending-replace so it stays visible during rebuild.
			_pending_replace[key] = _chunks[key]
			_chunks.erase(key)
			_chunk_lods.erase(key)
		if not _chunks.has(key) and not _pending_builds.has(key):
			var dist := absi(key.x - _last_center.x) + absi(key.y - _last_center.y)
			to_rebuild.append([dist, key, target_lod])

	to_rebuild.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	for item in to_rebuild:
		var key: Vector2i = item[1]
		var lod: int = item[2]
		_pending_builds[key] = lod
		WorkerThreadPool.add_task(_build_chunk_threaded.bind(key, lod))


# --- Worker thread: heavy mesh computation ---

func _build_chunk_threaded(coord: Vector2i, lod: int) -> void:
	var res: int = LOD_RESOLUTIONS[lod]
	var world_x := coord.x * chunk_size
	var world_z := coord.y * chunk_size
	var step := chunk_size / float(res - 1)

	# Compute the chunk centre's true sphere-surface position.
	# Tangent-plane coords (wu, wv) are fed into normalize(wu, R, wv) to get
	# a direction on the sphere surface, matching the cube-sphere approach.
	var center_u := world_x + chunk_size * 0.5
	var center_v := world_z + chunk_size * 0.5
	var center_dir := Vector3(center_u, PLANET_RADIUS, center_v).normalized()
	var chunk_center_world := center_dir * PLANET_RADIUS + Vector3(0.0, -PLANET_RADIUS, 0.0)

	# Mesh-local positions for each grid vertex (relative to chunk_center_world).
	var positions: Array[Vector3] = []
	positions.resize(res * res)

	for gz in range(res):
		for gx in range(res):
			var wu := world_x + gx * step
			var wv := world_z + gz * step
			var blend := _runway_blend(wu, wv)
			var h := _uber_sample(wu, wv) * max_height * blend

			# Map flat tangent coords onto the sphere surface.
			# dir = normalize(wu, R, wv)  →  vertex sits on sphere at radius R+h
			var dir := Vector3(wu, PLANET_RADIUS, wv).normalized()
			var vertex_world := dir * (PLANET_RADIUS + h) + Vector3(0.0, -PLANET_RADIUS, 0.0)

			# Sphere curvature lowers y by ~2.8 m at the runway endpoints (750 m out).
			# Cancel that sag inside the flat zone so terrain stays flush at y≈0.
			var sphere_y_at_sea := dir.y * PLANET_RADIUS - PLANET_RADIUS
			vertex_world.y -= sphere_y_at_sea * (1.0 - blend)

			positions[gz * res + gx] = vertex_world - chunk_center_world

	# Compute smooth normals via 3-D cross products on the sphere-surface positions.
	var normals_grid: Array[Vector3] = []
	normals_grid.resize(res * res)

	for gz in range(res):
		for gx in range(res):
			var idx: int = gz * res + gx
			var il: int = max(0, gx - 1)
			var ir: int = min(res - 1, gx + 1)
			var id_z: int = max(0, gz - 1)
			var iu_z: int = min(res - 1, gz + 1)
			var pL := positions[gz * res + il]
			var pR := positions[gz * res + ir]
			var pD := positions[id_z * res + gx]
			var pU := positions[iu_z * res + gx]
			normals_grid[idx] = (pU - pD).cross(pR - pL).normalized()

	# Main grid + skirt triangles.  Skirts hang below each chunk edge to fill
	# the cracks that appear between neighbours at different LOD levels.
	var tri_count: int = (res - 1) * (res - 1) * 6 + (res - 1) * 6 * 4  # grid + 4 edge skirts
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	verts.resize(tri_count)
	norms.resize(tri_count)
	var vi := 0

	for gz in range(res - 1):
		for gx in range(res - 1):
			var i00: int = gz * res + gx
			var i10: int = i00 + 1
			var i01: int = (gz + 1) * res + gx
			var i11: int = i01 + 1

			# Triangle 1
			verts[vi] = positions[i00]; norms[vi] = normals_grid[i00]; vi += 1
			verts[vi] = positions[i10]; norms[vi] = normals_grid[i10]; vi += 1
			verts[vi] = positions[i01]; norms[vi] = normals_grid[i01]; vi += 1
			# Triangle 2
			verts[vi] = positions[i10]; norms[vi] = normals_grid[i10]; vi += 1
			verts[vi] = positions[i11]; norms[vi] = normals_grid[i11]; vi += 1
			verts[vi] = positions[i01]; norms[vi] = normals_grid[i01]; vi += 1

	# Skirts — one quad strip per edge, 6 verts × (res-1) segments.
	# Winding follows the same convention as the terrain grid above.
	var dn := Vector3(0.0, -SKIRT_DEPTH, 0.0)

	# Bottom edge (gz = 0), facing –Z
	for gx in range(res - 1):
		var p0 := positions[gx];           var n0 := normals_grid[gx]
		var p1 := positions[gx + 1];       var n1 := normals_grid[gx + 1]
		verts[vi] = p0;       norms[vi] = n0; vi += 1
		verts[vi] = p1;       norms[vi] = n1; vi += 1
		verts[vi] = p0 + dn;  norms[vi] = n0; vi += 1
		verts[vi] = p1;       norms[vi] = n1; vi += 1
		verts[vi] = p1 + dn;  norms[vi] = n1; vi += 1
		verts[vi] = p0 + dn;  norms[vi] = n0; vi += 1

	# Top edge (gz = res-1), facing +Z — flipped winding
	for gx in range(res - 1):
		var row: int = (res - 1) * res
		var p0 := positions[row + gx];     var n0 := normals_grid[row + gx]
		var p1 := positions[row + gx + 1]; var n1 := normals_grid[row + gx + 1]
		verts[vi] = p1;       norms[vi] = n1; vi += 1
		verts[vi] = p0;       norms[vi] = n0; vi += 1
		verts[vi] = p0 + dn;  norms[vi] = n0; vi += 1
		verts[vi] = p0 + dn;  norms[vi] = n0; vi += 1
		verts[vi] = p1 + dn;  norms[vi] = n1; vi += 1
		verts[vi] = p1;       norms[vi] = n1; vi += 1

	# Left edge (gx = 0), facing –X — flipped winding
	for gz in range(res - 1):
		var p0 := positions[gz * res];       var n0 := normals_grid[gz * res]
		var p1 := positions[(gz + 1) * res]; var n1 := normals_grid[(gz + 1) * res]
		verts[vi] = p1;       norms[vi] = n1; vi += 1
		verts[vi] = p0;       norms[vi] = n0; vi += 1
		verts[vi] = p0 + dn;  norms[vi] = n0; vi += 1
		verts[vi] = p0 + dn;  norms[vi] = n0; vi += 1
		verts[vi] = p1 + dn;  norms[vi] = n1; vi += 1
		verts[vi] = p1;       norms[vi] = n1; vi += 1

	# Right edge (gx = res-1), facing +X
	for gz in range(res - 1):
		var p0 := positions[gz * res + (res - 1)];       var n0 := normals_grid[gz * res + (res - 1)]
		var p1 := positions[(gz + 1) * res + (res - 1)]; var n1 := normals_grid[(gz + 1) * res + (res - 1)]
		verts[vi] = p0;       norms[vi] = n0; vi += 1
		verts[vi] = p1;       norms[vi] = n1; vi += 1
		verts[vi] = p0 + dn;  norms[vi] = n0; vi += 1
		verts[vi] = p1;       norms[vi] = n1; vi += 1
		verts[vi] = p1 + dn;  norms[vi] = n1; vi += 1
		verts[vi] = p0 + dn;  norms[vi] = n0; vi += 1

	_integrate_chunk.call_deferred(coord, lod, verts, norms, chunk_center_world)


# --- Main thread: scene tree integration ---

func _integrate_chunk(coord: Vector2i, lod: int, verts: PackedVector3Array, norms: PackedVector3Array, chunk_center_world: Vector3) -> void:
	_pending_builds.erase(coord)

	# Discard if chunk is no longer in view range or was already built at same LOD
	if _chunks.has(coord):
		return
	if abs(coord.x - _last_center.x) > view_range or abs(coord.y - _last_center.y) > view_range:
		return

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(verts.size()):
		st.set_normal(norms[i])
		st.add_vertex(verts[i])
	var mesh := st.commit()

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = mesh
	mesh_inst.material_override = _lod_materials[lod] if _lod_debug else _material
	mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	# True sphere-surface position for the chunk centre
	mesh_inst.position = chunk_center_world

	# Collision only for LOD 0 and 1 — LOD 2 chunks are 3.5 km+ away, no physics needed.
	if lod <= 1:
		var body := StaticBody3D.new()
		body.collision_layer = 1  # world layer
		body.collision_mask = 0
		var col_shape := CollisionShape3D.new()
		col_shape.shape = mesh.create_trimesh_shape()
		body.add_child(col_shape)
		mesh_inst.add_child(body)

	add_child(mesh_inst)
	_chunks[coord] = mesh_inst
	_chunk_lods[coord] = lod

	# Free the old lower-quality chunk now that the replacement is in the scene.
	if _pending_replace.has(coord):
		_pending_replace[coord].queue_free()
		_pending_replace.erase(coord)


func _sample_height(world_x: float, world_z: float) -> float:
	var h := _uber_sample(world_x, world_z) * max_height
	h *= _runway_blend(world_x, world_z)
	var dir := Vector3(world_x, PLANET_RADIUS, world_z).normalized()
	return (dir * (PLANET_RADIUS + h)).y - PLANET_RADIUS


## Über-noise sampler — combines continent mask + detail FBM.
##
##   1. Continent mask (~40 km wavelength) — drives ocean basin vs land mass.
##      Negative values → below sea level (oceans); positive → above sea level (land).
##   2. Domain warping  — distorts detail coords for flowing coastlines.
##   3. Slope-responsive FBM (IQ's erosion) — smooth slopes, detailed flats.
##   4. Sharpness blend — billow (0) → perlin (0.5) → ridge (1).
##   5. Altitude damping — flatten extreme peaks/basins.
##
## Returns approximately [-1, 1].  Thread-safe (read-only noise objects).
const _UBER_OCTAVES    := 5
const _UBER_LACUNARITY := 2.0
const _UBER_GAIN       := 0.5
const _UBER_SHARPNESS  := 0.40  # 0=billow, 0.5=perlin, 1.0=ridge
const _UBER_EROSION    := 1.20  # slope erosion strength
const _UBER_ALT_DAMP   := 0.18  # altitude damping (flatten peaks + basins)
const _UBER_WARP_STR   := 180.0 # domain warp in metres
# Continent mask weights: 0.55 continent + 0.45 detail.
# ~0.05 negative bias on continent gives ≈45% ocean coverage.
const _CONTINENT_WEIGHT := 0.55
const _OCEAN_BIAS       := 0.05

func _uber_sample(wu: float, wv: float) -> float:
	# ── Continent mask (very low frequency — creates ocean basins / land masses) ──
	# Sampled BEFORE domain warping so large-scale shapes are clean.
	var continent: float = _continent_noise.get_noise_2d(wu, wv) - _OCEAN_BIAS

	# ── Domain warping: distort detail coords with a secondary noise field ──
	var warp_u := _warp_noise.get_noise_2d(wu, wv)                     * _UBER_WARP_STR
	var warp_v := _warp_noise.get_noise_2d(wu + 9271.3, wv + 6554.7)  * _UBER_WARP_STR
	wu += warp_u
	wv += warp_v

	# ── Slope-responsive FBM with sharpness blend ───────────────────────────
	var value     := 0.0
	var amplitude := 1.0
	var freq      := 1.0
	var slope_acc := 1e-4

	for _i in range(_UBER_OCTAVES):
		var raw: float = _noise.get_noise_2d(wu * freq, wv * freq)

		# Sharpness: blend between billow (abs), perlin (raw), ridge (1-abs)
		var shaped: float
		if _UBER_SHARPNESS < 0.5:
			shaped = lerpf(absf(raw), raw, _UBER_SHARPNESS * 2.0)
		else:
			shaped = lerpf(raw, 1.0 - absf(raw), (_UBER_SHARPNESS - 0.5) * 2.0)

		var erosion := 1.0 / (1.0 + slope_acc * _UBER_EROSION)
		value     += shaped * amplitude * erosion
		slope_acc += amplitude * absf(shaped)

		amplitude *= _UBER_GAIN
		freq      *= _UBER_LACUNARITY

	var max_amp: float = (1.0 - pow(_UBER_GAIN, _UBER_OCTAVES)) / (1.0 - _UBER_GAIN)
	var detail := value / max_amp

	# ── Combine: continent mask controls large-scale land/ocean, detail adds relief ──
	var combined: float = continent * _CONTINENT_WEIGHT + detail * (1.0 - _CONTINENT_WEIGHT)

	# ── Altitude damping: flatten extreme peaks/basins ───────────────────────
	var extreme := absf(combined)
	return combined * maxf(1.0 - _UBER_ALT_DAMP * extreme * extreme, 0.0)


func _runway_blend(world_x: float, world_z: float) -> float:
	var dx := 0.0
	if world_x < flat_rect.position.x:
		dx = flat_rect.position.x - world_x
	elif world_x > flat_rect.end.x:
		dx = world_x - flat_rect.end.x

	var dz := 0.0
	if world_z < flat_rect.position.y:
		dz = flat_rect.position.y - world_z
	elif world_z > flat_rect.end.y:
		dz = world_z - flat_rect.end.y

	var dist := sqrt(dx * dx + dz * dz)
	if dist <= 0.0:
		return 0.0
	if dist >= blend_margin:
		return 1.0
	var t := dist / blend_margin
	return t * t * (3.0 - 2.0 * t)
