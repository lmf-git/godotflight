extends Node3D

## Ocean surface: a chunked curved grid sitting at sea level (y=0 world-space).
## Uses the same floating-origin system as the terrain.
## Chunks are regenerated as the camera moves, matching the terrain's chunk grid.

const PLANET_RADIUS := 100_000.0

@export var chunk_size  := 500.0
@export var view_range  := 5       # slightly less than terrain to reduce overdraw at edges

var _chunks        := {}             # Vector2i -> MeshInstance3D
var _pending       := {}             # Vector2i -> true
var _world_offset  := Vector3.ZERO
var _last_center   := Vector2i(999999, 999999)
var _material:     ShaderMaterial


func _ready() -> void:
	_material = ShaderMaterial.new()
	_material.shader = _water_shader()
	# _update_chunks() intentionally NOT called here — same reason as terrain_generator:
	# _last_center starts at (999999,999999) and would queue chunks at 500,000 km.
	# _process() triggers the first correct update.


func _get_anchor_pos() -> Vector3:
	var anchors := get_tree().get_nodes_in_group("terrain_anchor")
	if not anchors.is_empty():
		return (anchors[0] as Node3D).global_position
	var cam := get_viewport().get_camera_3d()
	return cam.global_position if cam else Vector3.ZERO


func _process(_delta: float) -> void:
	var pos := _get_anchor_pos()
	var center := Vector2i(
		floori((pos.x + _world_offset.x) / chunk_size),
		floori((pos.z + _world_offset.z) / chunk_size)
	)
	if center != _last_center:
		_last_center = center
		_update_chunks()


func notify_origin_shift(offset: Vector3) -> void:
	_world_offset += offset


func _update_chunks() -> void:
	var needed := {}
	for cx in range(_last_center.x - view_range, _last_center.x + view_range + 1):
		for cz in range(_last_center.y - view_range, _last_center.y + view_range + 1):
			needed[Vector2i(cx, cz)] = true

	var to_remove := []
	for key in _chunks:
		if not needed.has(key):
			to_remove.append(key)
	for key in to_remove:
		_chunks[key].queue_free()
		_chunks.erase(key)

	for key in needed:
		if not _chunks.has(key) and not _pending.has(key):
			_pending[key] = true
			WorkerThreadPool.add_task(_build_chunk_threaded.bind(key))


func _build_chunk_threaded(coord: Vector2i) -> void:
	var world_x := coord.x * chunk_size
	var world_z := coord.y * chunk_size
	var res     := 6     # low resolution — ocean surface needs few verts
	var step    := chunk_size / float(res - 1)

	# Chunk centre on the sphere surface (sea level, h = 0)
	var center_u := world_x + chunk_size * 0.5
	var center_v := world_z + chunk_size * 0.5
	var center_dir := Vector3(center_u, PLANET_RADIUS, center_v).normalized()
	var chunk_center_world := center_dir * PLANET_RADIUS + Vector3(0.0, -PLANET_RADIUS, 0.0)

	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var tri_count := (res - 1) * (res - 1) * 6
	verts.resize(tri_count)
	norms.resize(tri_count)
	var vi := 0

	for gz in range(res - 1):
		for gx in range(res - 1):
			var wx0 := world_x + gx * step
			var wz0 := world_z + gz * step
			var wx1 := wx0 + step
			var wz1 := wz0 + step

			# Map each corner onto the sphere surface at sea level (h = 0)
			var d00 := Vector3(wx0, PLANET_RADIUS, wz0).normalized()
			var d10 := Vector3(wx1, PLANET_RADIUS, wz0).normalized()
			var d01 := Vector3(wx0, PLANET_RADIUS, wz1).normalized()
			var d11 := Vector3(wx1, PLANET_RADIUS, wz1).normalized()
			var p00 := d00 * PLANET_RADIUS + Vector3(0.0, -PLANET_RADIUS, 0.0) - chunk_center_world
			var p10 := d10 * PLANET_RADIUS + Vector3(0.0, -PLANET_RADIUS, 0.0) - chunk_center_world
			var p01 := d01 * PLANET_RADIUS + Vector3(0.0, -PLANET_RADIUS, 0.0) - chunk_center_world
			var p11 := d11 * PLANET_RADIUS + Vector3(0.0, -PLANET_RADIUS, 0.0) - chunk_center_world

			# Triangle 1
			verts[vi] = p00; norms[vi] = d00; vi += 1
			verts[vi] = p10; norms[vi] = d10; vi += 1
			verts[vi] = p01; norms[vi] = d01; vi += 1
			# Triangle 2
			verts[vi] = p10; norms[vi] = d10; vi += 1
			verts[vi] = p11; norms[vi] = d11; vi += 1
			verts[vi] = p01; norms[vi] = d01; vi += 1

	_integrate_chunk.call_deferred(coord, verts, norms, chunk_center_world)


func _integrate_chunk(coord: Vector2i, verts: PackedVector3Array, norms: PackedVector3Array, chunk_center_world: Vector3) -> void:
	_pending.erase(coord)
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
	mesh_inst.material_override = _material
	mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	mesh_inst.position = chunk_center_world

	add_child(mesh_inst)
	_chunks[coord] = mesh_inst


func _water_shader() -> Shader:
	var s := Shader.new()
	s.code = """
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// ── Noise helpers ─────────────────────────────────────────────────────────────

float hash21(vec2 p) {
	p = fract(p * vec2(234.34, 435.345));
	p += dot(p, p + 34.23);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = smoothstep(vec2(0.0), vec2(1.0), fract(p));
	return mix(
		mix(hash21(i),              hash21(i + vec2(1.0, 0.0)), f.x),
		mix(hash21(i + vec2(0.0,1.0)), hash21(i + vec2(1.0,1.0)), f.x),
		f.y);
}

float fbm(vec2 p) {
	float v = 0.0, a = 0.55;
	for (int i = 0; i < 4; i++) {
		v += a * vnoise(p);
		p  = p * 2.1 + vec2(1.731, 9.213);
		a *= 0.5;
	}
	return v;
}

// ── Fragment ──────────────────────────────────────────────────────────────────

void fragment() {
	// World-space XZ for stable, non-floating noise tile.
	vec3 world_pos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 wuv = world_pos.xz * 0.00025;

	float t = TIME * 0.35;

	// Two FBM samples at different speeds and directions for anisotropic waves.
	vec2 uv1 = wuv + vec2(t * 0.5,  t * 0.3);
	vec2 uv2 = wuv * 1.5 + vec2(-t * 0.4, t * 0.55) + vec2(4.7, 8.3);
	float n1 = fbm(uv1);
	float n2 = fbm(uv2);

	// Normal perturbation from FBM gradients (screen-space tangent basis).
	float eps = 0.008;
	float dn1x = fbm(uv1 + vec2(eps, 0.0)) - n1;
	float dn1z = fbm(uv1 + vec2(0.0, eps)) - n1;
	float dn2x = fbm(uv2 + vec2(eps, 0.0)) - n2;
	float dn2z = fbm(uv2 + vec2(0.0, eps)) - n2;

	// Tangent vectors in view space (from screen-space derivatives of position).
	vec3 tangent   = normalize(dFdx(VERTEX));
	vec3 bitangent = normalize(dFdy(VERTEX));

	float wave_strength = 0.35;
	vec2  grad = vec2(dn1x * 0.65 + dn2x * 0.35, dn1z * 0.65 + dn2z * 0.35);
	NORMAL = normalize(NORMAL + (tangent * grad.x + bitangent * grad.y) * wave_strength);

	// Fresnel: near-zero alpha looking straight down, fully opaque at glancing angles.
	float ndotv   = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float fresnel = pow(1.0 - ndotv, 3.5);

	// Color: deep navy → mid blue based on wave height.
	float n_blend = n1 * 0.6 + n2 * 0.4;
	vec3 deep_col    = vec3(0.02, 0.07, 0.24);
	vec3 shallow_col = vec3(0.06, 0.26, 0.56);
	vec3 highlight   = vec3(0.30, 0.55, 0.80);
	vec3 water_col   = mix(deep_col, shallow_col, clamp(n_blend * 1.8, 0.0, 1.0));
	water_col = mix(water_col, highlight, fresnel * 0.25);

	ALBEDO    = water_col;
	ROUGHNESS = mix(0.06, 0.18, fresnel);
	METALLIC  = 0.0;
	SPECULAR  = 0.9;
	// Opacity: semi-transparent straight down, near-opaque at glancing angles.
	ALPHA     = clamp(0.72 + fresnel * 0.24, 0.0, 1.0);
}
"""
	return s
