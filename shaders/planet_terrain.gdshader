shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

// Set at runtime by Planet node to match actual planet params
uniform float rock_threshold : hint_range(0.0, 1.0) = 0.25;
uniform float snow_height    : hint_range(0.0, 500.0) = 120.0;
uniform float planet_radius  : hint_range(100.0, 200000.0) = 100000.0;
uniform float tex_scale      : hint_range(0.001, 0.2) = 0.012;

// 7 biome textures — all assigned from Rust in Planet.ready()
uniform sampler2D tex_grass  : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_dry    : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_desert : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_sand   : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_tundra : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_snow   : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_rock   : hint_default_white, filter_linear_mipmap, repeat_enable;

// FADE_PLACEHOLDER

// ── helpers ───────────────────────────────────────────────────────────────────

vec3 triplanar_blend(vec3 n) {
	vec3 b = abs(n);
	b = max(b - 0.2, vec3(0.0));
	b = pow(b, vec3(6.0));
	return b / (b.x + b.y + b.z + 0.001);
}

vec3 triplanar(sampler2D tex, vec3 pos, vec3 blend, float scale) {
	vec3 cx = texture(tex, pos.yz * scale).rgb;
	vec3 cy = texture(tex, pos.xz * scale).rgb;
	vec3 cz = texture(tex, pos.xy * scale).rgb;
	return cx * blend.x + cy * blend.y + cz * blend.z;
}

void fragment() {
	// ── Ordered dither fade-in ─────────────────────────────────────────────
	if (fade < 1.0) {
		float hash = fract(sin(dot(floor(FRAGCOORD.xy), vec2(127.1, 311.7))) * 43758.5453);
		if (hash > fade) { discard; }
	}

	vec3 world_pos    = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;

	float dist        = length(world_pos);
	vec3  world_up    = (dist > 0.001) ? world_pos / dist : vec3(0.0, 1.0, 0.0);

	// Screen-space position derivatives — correct slope regardless of mesh LOD
	vec3 sp_dx     = dFdx(world_pos);
	vec3 sp_dy     = dFdy(world_pos);
	vec3 sp_normal = normalize(cross(sp_dy, sp_dx));
	float slope    = abs(dot(sp_normal, world_up));       // 1=flat, 0=vertical

	float height      = dist - planet_radius;             // metres above sea level
	float latitude    = abs(world_up.y);                  // 0=equator  1=pole

	// ── Rock on steep slopes (overrides everything) ────────────────────────
	float rock_blend = smoothstep(rock_threshold + 0.1, rock_threshold - 0.1, slope);

	// ── Geographic variation: longitude-based climate bands ───────────────
	float geo_x = sin(world_pos.x * 0.0031 + world_pos.z * 0.0019) * 0.5 + 0.5;
	float geo_z = sin(world_pos.z * 0.0027 - world_pos.y * 0.0023) * 0.5 + 0.5;
	float geo_vary = (geo_x * 0.6 + geo_z * 0.4) * 0.22 - 0.11;

	// ── Latitude zones ─────────────────────────────────────────────────────
	float lat_varied = clamp(latitude + geo_vary, 0.0, 1.0);
	float tropical   = smoothstep(0.30, 0.20, lat_varied);
	float sub_polar  = smoothstep(0.55, 0.68, lat_varied);
	float polar_zone = smoothstep(0.68, 0.80, lat_varied);

	// ── Height zones (metres above sea level) ─────────────────────────────
	float beach     = smoothstep(35.0, -5.0,  height) * smoothstep(0.3, 0.6, slope);
	float highland  = smoothstep(50.0, 100.0, height);
	float mountain_snow = smoothstep(snow_height - 30.0, snow_height + 30.0, height)
	                    * (1.0 - rock_blend) * smoothstep(0.5, 0.8, slope);

	// ── Polar snow ────────────────────────────────────────────────────────
	float polar_snow = polar_zone * smoothstep(0.25, 0.55, slope);
	float snow_blend = max(mountain_snow, polar_snow);

	// ── Biome colours via triplanar ────────────────────────────────────────
	vec3 tblend   = triplanar_blend(sp_normal);
	vec3 c_grass  = triplanar(tex_grass,  world_pos, tblend, tex_scale);
	vec3 c_dry    = triplanar(tex_dry,    world_pos, tblend, tex_scale);
	vec3 c_desert = triplanar(tex_desert, world_pos, tblend, tex_scale);
	vec3 c_sand   = triplanar(tex_sand,   world_pos, tblend, tex_scale);
	vec3 c_tundra = triplanar(tex_tundra, world_pos, tblend, tex_scale);
	vec3 c_snow   = triplanar(tex_snow,   world_pos, tblend, tex_scale);
	vec3 c_rock   = triplanar(tex_rock,   world_pos, tblend, tex_scale);

	vec3 base = c_grass;
	base = mix(base, c_dry,    tropical * highland);
	base = mix(base, c_desert, tropical * (1.0 - highland) * (1.0 - beach));
	base = mix(base, c_tundra, sub_polar * (1.0 - polar_zone));
	base = mix(base, c_sand, beach * (1.0 - rock_blend));
	base = mix(base, c_rock, rock_blend);
	base = mix(base, c_snow, snow_blend);

	ALBEDO    = base;
	ROUGHNESS = mix(0.82, 0.96, rock_blend);
	METALLIC  = 0.0;
}
