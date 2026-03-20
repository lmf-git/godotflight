extends Node3D

## Volumetric cloud system — three stacked dome layers at different altitudes.
## Each layer uses an animated procedural FBM noise shader for patchy cloud coverage.
## Layers scroll at independent speeds, giving a depth-parallax illusion.
##
## Vertex positions are placed on the true sphere surface (cube-sphere formula)
## so clouds match the spherical terrain geometry.

const PLANET_RADIUS := 100_000.0

@export var dome_radius := 40_000.0  # horizontal extent of the cloud dome
@export var dome_res    := 48        # ring subdivisions (higher = smoother horizon fade)

# [altitude_m, base_alpha, scroll_x, scroll_z, cloud_scale]
# Stratus (low/thick), Altostratus (mid), Cirrus (high/thin/fast)
const LAYERS: Array = [
	[1600.0, 0.55, 0.007,  0.003, 4.5],
	[2600.0, 0.38, 0.013,  0.006, 7.5],
	[4500.0, 0.20, 0.022, -0.005, 12.0],
]


func _ready() -> void:
	for layer in LAYERS:
		_build_layer(layer[0], layer[1], layer[2], layer[3], layer[4])


func _process(_delta: float) -> void:
	# Follow the player (terrain_anchor group), never the map orbit camera.
	var anchors := get_tree().get_nodes_in_group("terrain_anchor")
	if not anchors.is_empty():
		var ap := (anchors[0] as Node3D).global_position
		global_position = Vector3(ap.x, 0.0, ap.z)
	else:
		var cam := get_viewport().get_camera_3d()
		if cam:
			global_position = Vector3(cam.global_position.x, 0.0, cam.global_position.z)


# ---------------------------------------------------------------------------
# Layer construction
# ---------------------------------------------------------------------------

func _build_layer(altitude: float, base_alpha: float, sx: float, sz: float, cscale: float) -> void:
	var shader := Shader.new()
	shader.code = _cloud_shader()

	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter(&"base_alpha", base_alpha)
	mat.set_shader_parameter(&"scroll", Vector2(sx, sz))
	mat.set_shader_parameter(&"cloud_scale", cscale)

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh_inst.material_override = mat
	mesh_inst.mesh = _build_dome_mesh(altitude)
	add_child(mesh_inst)


func _build_dome_mesh(altitude: float) -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var lat_rings: int = dome_res >> 1
	var lon_segs := dome_res

	for i_lat in range(lat_rings):
		var t0 := float(i_lat)     / lat_rings
		var t1 := float(i_lat + 1) / lat_rings
		var theta0 := t0 * (PI / 2.2)
		var theta1 := t1 * (PI / 2.2)

		# Edge-fade via vertex alpha: zero at horizon and top, peak mid-dome.
		var a0: float = sin(t0 * PI) * 0.90
		var a1: float = sin(t1 * PI) * 0.90

		for i_lon in range(lon_segs):
			var phi0 := float(i_lon)     / lon_segs * TAU
			var phi1 := float(i_lon + 1) / lon_segs * TAU

			var v00 := _dome_vert(theta0, phi0, altitude)
			var v10 := _dome_vert(theta1, phi0, altitude)
			var v01 := _dome_vert(theta0, phi1, altitude)
			var v11 := _dome_vert(theta1, phi1, altitude)

			_add_quad(st, v00, v10, v01, v11, a0, a1)

	return st.commit()


func _dome_vert(theta: float, phi: float, altitude: float) -> Vector3:
	# XZ spread from dome-radius polar coords.
	var x: float = dome_radius * sin(theta) * cos(phi)
	var z: float = dome_radius * sin(theta) * sin(phi)
	# Sphere-surface Y: project local offset direction onto sphere at cloud altitude.
	# Using cube-sphere formula: dir = normalize(x, R, z) from planet centre.
	var dir := Vector3(x, PLANET_RADIUS, z).normalized()
	var y: float = dir.y * (PLANET_RADIUS + altitude) - PLANET_RADIUS
	return Vector3(x, y, z)


func _add_quad(st: SurfaceTool, v00: Vector3, v10: Vector3, v01: Vector3, v11: Vector3, a0: float, a1: float) -> void:
	# Normals point inward (we cull the front face, so we see the back).
	st.set_color(Color(0.97, 0.97, 0.99, a0)); st.set_normal(-v00.normalized()); st.add_vertex(v00)
	st.set_color(Color(0.97, 0.97, 0.99, a1)); st.set_normal(-v10.normalized()); st.add_vertex(v10)
	st.set_color(Color(0.97, 0.97, 0.99, a0)); st.set_normal(-v01.normalized()); st.add_vertex(v01)
	st.set_color(Color(0.97, 0.97, 0.99, a1)); st.set_normal(-v10.normalized()); st.add_vertex(v10)
	st.set_color(Color(0.97, 0.97, 0.99, a1)); st.set_normal(-v11.normalized()); st.add_vertex(v11)
	st.set_color(Color(0.97, 0.97, 0.99, a0)); st.set_normal(-v01.normalized()); st.add_vertex(v01)


# ---------------------------------------------------------------------------
# Cloud shader — procedural animated FBM noise
# ---------------------------------------------------------------------------

func _cloud_shader() -> String:
	return """
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_front, unshaded, shadows_disabled;

uniform float base_alpha : hint_range(0.0, 1.0) = 0.5;
uniform vec2  scroll     = vec2(0.008, 0.003);
uniform float cloud_scale = 5.0;

// ── Noise helpers ─────────────────────────────────────────────────────────

float hash21(vec2 p) {
	p = fract(p * vec2(234.34, 435.345));
	p += dot(p, p + 34.23);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = smoothstep(0.0, 1.0, fract(p));
	return mix(
		mix(hash21(i),              hash21(i + vec2(1.0, 0.0)), f.x),
		mix(hash21(i + vec2(0.0,1.0)), hash21(i + vec2(1.0,1.0)), f.x),
		f.y
	);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.55;
	for (int i = 0; i < 5; i++) {
		v += a * vnoise(p);
		p  = p * 2.07 + vec2(1.731, 9.213);
		a *= 0.48;
	}
	return v;
}

// ── Fragment ──────────────────────────────────────────────────────────────

void fragment() {
	// Sample noise in dome-local XZ scaled by cloud_scale, animated with TIME.
	// VERTEX is in object space; since the node follows the camera XZ, this
	// effectively tiles clouds in world space and scrolls them over time.
	vec2 uv = VERTEX.xz / 10000.0 * cloud_scale + TIME * scroll;

	float n = fbm(uv);

	// Soft coverage threshold — adjust 0.40/0.62 to change cloud density.
	float coverage = smoothstep(0.40, 0.62, n);

	// COLOR.a carries the per-vertex edge-fade baked into the mesh.
	ALBEDO = COLOR.rgb;
	ALPHA  = COLOR.a * base_alpha * coverage;
}
"""
