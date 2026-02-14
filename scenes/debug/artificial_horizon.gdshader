shader_type spatial;
render_mode unshaded, cull_disabled;

uniform float pitch : hint_range(-1.5708, 1.5708) = 0.0;  // radians
uniform float roll : hint_range(-3.14159, 3.14159) = 0.0;  // radians
uniform float fpv_x : hint_range(-1.0, 1.0) = 0.0;         // normalized offset
uniform float fpv_y : hint_range(-1.0, 1.0) = 0.0;         // normalized offset

const vec3 SKY_COLOR = vec3(0.2, 0.4, 0.8);
const vec3 GROUND_COLOR = vec3(0.55, 0.35, 0.15);
const vec3 LINE_COLOR = vec3(1.0, 1.0, 1.0);
const vec3 FPV_COLOR = vec3(0.0, 1.0, 0.0);
const vec3 WINGS_COLOR = vec3(1.0, 1.0, 0.0);
const float LINE_WIDTH = 0.008;
const float PITCH_SCALE = 0.3;  // UV units per radian of pitch

void fragment() {
	// Center UV to -0.5..0.5, flip Y so +Y = up on screen
	vec2 uv = vec2(UV.x - 0.5, 0.5 - UV.y);

	// Apply roll rotation
	float c = cos(-roll);
	float s = sin(-roll);
	vec2 rotated = vec2(uv.x * c - uv.y * s, uv.x * s + uv.y * c);

	// Apply pitch offset (positive pitch = nose up = horizon moves down)
	float horizon_y = rotated.y + pitch * PITCH_SCALE;

	// Sky/ground split
	vec3 color = horizon_y > 0.0 ? SKY_COLOR : GROUND_COLOR;

	// Horizon line
	if (abs(horizon_y) < LINE_WIDTH) {
		color = LINE_COLOR;
	}

	// Pitch ladder lines at 5-degree intervals
	for (int i = -6; i <= 6; i++) {
		if (i == 0) continue;
		float line_pitch_rad = float(i) * 0.0872665;  // 5 degrees in radians
		float line_y = horizon_y - line_pitch_rad * PITCH_SCALE;
		float half_width = abs(i) % 2 == 0 ? 0.15 : 0.08;  // Longer lines at 10-degree marks
		if (abs(line_y) < LINE_WIDTH * 0.7 && abs(rotated.x) < half_width) {
			color = LINE_COLOR * 0.7;
		}
	}

	// Center aircraft reference (fixed wings symbol)
	// Left wing dash
	if (abs(uv.y) < LINE_WIDTH && uv.x > -0.18 && uv.x < -0.04) {
		color = WINGS_COLOR;
	}
	// Right wing dash
	if (abs(uv.y) < LINE_WIDTH && uv.x > 0.04 && uv.x < 0.18) {
		color = WINGS_COLOR;
	}
	// Center dot
	if (length(uv) < 0.015) {
		color = WINGS_COLOR;
	}

	// Flight Path Vector (FPV) - small circle
	vec2 fpv_pos = vec2(fpv_x * 0.3, fpv_y * 0.3);
	float fpv_dist = length(uv - fpv_pos);
	if (fpv_dist > 0.02 && fpv_dist < 0.035) {
		color = FPV_COLOR;
	}
	// FPV center dot
	if (fpv_dist < 0.008) {
		color = FPV_COLOR;
	}

	// Circular mask - fade edges to black for instrument bezel look
	float dist_from_center = length(uv);
	float bezel_inner = 0.44;
	float bezel_outer = 0.48;
	if (dist_from_center > bezel_outer) {
		color = vec3(0.1, 0.1, 0.1);
	} else if (dist_from_center > bezel_inner) {
		float t = (dist_from_center - bezel_inner) / (bezel_outer - bezel_inner);
		color = mix(color, vec3(0.1, 0.1, 0.1), t);
	}

	ALBEDO = color;
}
