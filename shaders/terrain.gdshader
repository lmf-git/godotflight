// Procedural terrain shader — adapted from ref/godot/shaders/terrain.gdshader
// Uses screen-space derivatives for slope detection (accurate at any mesh LOD)
// and shader-computed biome blending based on height, slope, and latitude.
// No textures required; add tex_* uniforms + triplanar sampling when available.

shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform float planet_radius : hint_range(1000.0, 1000000.0) = 100000.0;
uniform float max_height    : hint_range(10.0, 10000.0)     = 120.0;
// Accumulated floating-origin shift (set by terrain_generator, updated each shift).
// Required so climate latitude is computed from true world position, not scene position.
uniform vec3  world_offset  = vec3(0.0);

void fragment() {
	// ── Scene-space world position ──────────────────────────────────────────
	// Planet centre is fixed at (0, -planet_radius, 0) in scene space.
	vec3 world_pos   = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 from_local  = world_pos + vec3(0.0, planet_radius, 0.0);
	float dist       = length(from_local);
	vec3 world_up    = dist > 0.001 ? from_local / dist : vec3(0.0, 1.0, 0.0);

	// ── Screen-space slope (uses scene-space position — always correct) ────
	vec3  sp_dx  = dFdx(world_pos);
	vec3  sp_dy  = dFdy(world_pos);
	vec3  sp_n   = normalize(cross(sp_dy, sp_dx));
	float slope  = abs(dot(sp_n, world_up));  // 1=flat, 0=cliff

	float height = dist - planet_radius;

	// ── True world position for climate (corrected for floating origin) ────
	// Without this, scene-space world_pos ≈ (0,0,0) always → lat ≈ 1 (pole) everywhere.
	vec3  true_world    = world_pos + world_offset;
	vec3  from_centre   = true_world + vec3(0.0, planet_radius, 0.0);
	float dist_climate  = length(from_centre);
	vec3  climate_up    = dist_climate > 0.001 ? from_centre / dist_climate : vec3(0.0, 1.0, 0.0);

	// ── Geographic variation ────────────────────────────────────────────────
	float geo_vary = (sin(true_world.x * 0.0031 + true_world.z * 0.0019) * 0.6
	               + sin(true_world.z * 0.0027 - true_world.y * 0.0023) * 0.4) * 0.12;
	// latitude: 1.0 at pole (spawn), 0.0 at equator (~157 km away on a 100 km sphere)
	float latitude = abs(climate_up.y);
	float lat_v    = clamp(latitude + geo_vary, 0.0, 1.0);

	// ── Climate zones ───────────────────────────────────────────────────────
	// lat_v = 1 → pole (polar biome)
	// lat_v = 0 → equator (tropical)
	// Meaningful variation requires traveling 100–300 km from spawn.
	float tropical   = smoothstep(0.30, 0.20, lat_v);
	float sub_polar  = smoothstep(0.55, 0.68, lat_v);
	float polar_zone = smoothstep(0.68, 0.80, lat_v);

	// ── Height/slope zones ──────────────────────────────────────────────────
	float highland   = smoothstep(40.0, 90.0, height);
	float beach      = smoothstep(35.0, -5.0, height) * smoothstep(0.3, 0.6, slope);
	float rock_blend = smoothstep(0.52, 0.30, slope);
	float mtn_snow   = smoothstep(max_height * 0.55, max_height * 0.80, height)
	                 * (1.0 - rock_blend) * smoothstep(0.5, 0.8, slope);
	float snow_blend = max(mtn_snow, polar_zone * smoothstep(0.20, 0.50, slope));

	// ── Colour selection ────────────────────────────────────────────────────
	vec3 c_grass  = vec3(0.22, 0.44, 0.16);
	vec3 c_dry    = vec3(0.55, 0.52, 0.24);
	vec3 c_desert = vec3(0.74, 0.60, 0.28);
	vec3 c_sand   = vec3(0.82, 0.76, 0.50);
	vec3 c_tundra = vec3(0.58, 0.60, 0.44);
	vec3 c_rock   = vec3(0.46, 0.40, 0.32);
	vec3 c_snow   = vec3(0.93, 0.94, 0.97);
	vec3 c_water  = mix(vec3(0.04, 0.12, 0.40), vec3(0.10, 0.30, 0.58),
	                    clamp(-height / (max_height * 0.35), 0.0, 1.0));

	vec3 base = c_grass;
	base = mix(base, c_dry,    tropical * highland);
	base = mix(base, c_desert, tropical * (1.0 - highland) * (1.0 - beach));
	base = mix(base, c_tundra, sub_polar * (1.0 - polar_zone));
	base = mix(base, c_sand,   beach * (1.0 - rock_blend));
	base = mix(base, c_rock,   rock_blend);
	base = mix(base, c_snow,   snow_blend);

	// Below sea level: blend to water colour
	float underwater = step(height, 0.0);
	base      = mix(base, c_water, underwater);
	rock_blend = mix(rock_blend, 0.0, underwater);

	ALBEDO    = base;
	ROUGHNESS = mix(0.80, 0.96, rock_blend);
	METALLIC  = 0.0;
}
