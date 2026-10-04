shader_type spatial;
// Stylised Forward+ water: depth-faded colour, fresnel sky tint, two scrolling normal layers,
// shoreline foam from the depth difference. Visible from below (cull_disabled).
render_mode blend_mix, depth_draw_always, cull_disabled, specular_schlick_ggx;

uniform vec4 shallow_color : source_color = vec4(0.22, 0.62, 0.68, 0.55);
uniform vec4 deep_color : source_color = vec4(0.03, 0.17, 0.30, 0.92);
uniform float depth_fade = 3.0;
uniform float foam_width = 0.1;
uniform vec4 foam_color : source_color = vec4(0.9, 0.96, 1.0, 1.0);
uniform sampler2D normal_a : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_b : hint_normal, filter_linear_mipmap, repeat_enable;
instance uniform vec2 flow = vec2(0.0, 0.0);
instance uniform float wave_height = 0.05;
instance uniform float wave_length = 3.2;
instance uniform float wave_speed = 1.1;
global uniform float ultra_wave_time;
uniform float normal_scale = 0.35;
uniform float tiling = 0.18;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

varying vec3 world_pos;

// Same wave as UltraWater.wave(), so floating props ride the surface you see.
float wave(vec3 p) {
	float k = 6.2831853 / wave_length;
	float w = wave_speed * k;
	float t = ultra_wave_time;
	return wave_height * (0.6 * sin(k * p.x + w * t) + 0.4 * sin(k * 0.73 * p.z - w * 1.27 * t + 1.3));
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float h = wave(world_pos);
	VERTEX.y += h;
	world_pos.y += h;
	float e = 0.1;
	float hx = wave(world_pos + vec3(e, 0.0, 0.0)) - h;
	float hz = wave(world_pos + vec3(0.0, 0.0, e)) - h;
	NORMAL = normalize(vec3(-hx / e, 1.0, -hz / e));
}

void fragment() {
	vec2 uv = world_pos.xz * tiling;
	vec3 na = texture(normal_a, uv + TIME * (vec2(0.02, 0.013) + flow * 0.25)).rgb;
	vec3 nb = texture(normal_b, uv * 1.7 - TIME * (vec2(0.011, -0.017) - flow * 0.25)).rgb;
	NORMAL_MAP = normalize(mix(na, nb, 0.5));
	NORMAL_MAP_DEPTH = normal_scale;

	float scene_depth = texture(depth_tex, SCREEN_UV).r;
	vec4 sp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, scene_depth, 1.0);
	sp.xyz /= sp.w;
	float water_depth = max(-sp.z + VERTEX.z, 0.0);     // view-space distance behind the surface
	float t = clamp(water_depth / depth_fade, 0.0, 1.0);
	vec4 col = mix(shallow_color, deep_color, t);
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0);
	float foam = (1.0 - smoothstep(0.0, foam_width, water_depth)) * (FRONT_FACING ? 1.0 : 0.0);
	ALBEDO = mix(col.rgb, vec3(0.62, 0.78, 0.9), fres * 0.5);
	ALBEDO = mix(ALBEDO, foam_color.rgb, foam * 0.6);
	ALPHA = clamp(mix(col.a, 1.0, fres * 0.6) + foam * 0.35, 0.0, 1.0);
	if (!FRONT_FACING) {
		// The surface seen from below: bright sky light through the water (lit or not).
		ALPHA = 0.8;
		ALBEDO = vec3(0.2, 0.45, 0.55);
		EMISSION = vec3(0.35, 0.65, 0.75);
	}
	ROUGHNESS = 0.06;
	SPECULAR = 0.6;
}
