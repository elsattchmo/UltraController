shader_type spatial;
// Prototype grid in world space: 1 m lines, 0.25 m sub-lines, triplanar so every face reads.

uniform vec4 base_color : source_color = vec4(0.55, 0.57, 0.6, 1.0);
uniform vec4 line_color : source_color = vec4(0.25, 0.27, 0.3, 1.0);
uniform float line_width = 0.03;
uniform float roughness_value = 0.85;

varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

float grid(vec2 p, float spacing, float w) {
	vec2 g = abs(fract(p / spacing - 0.5) - 0.5) * spacing;
	vec2 fw = fwidth(p) * 1.2;
	vec2 l = 1.0 - smoothstep(vec2(w) - fw, vec2(w) + fw, g);
	return max(l.x, l.y);
}

void fragment() {
	vec3 n = abs(world_normal);
	vec2 uv = n.y > 0.5 ? world_pos.xz : (n.x > n.z ? world_pos.zy : world_pos.xy);
	float major = grid(uv, 1.0, line_width);
	float minor = grid(uv, 0.25, line_width * 0.4) * 0.35;
	float l = max(major, minor);
	ALBEDO = mix(base_color.rgb, line_color.rgb, l);
	ROUGHNESS = roughness_value;
}
