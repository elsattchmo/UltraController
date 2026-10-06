shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, blend_mix;
// One health bar per MultiMesh instance, billboarded in the vertex stage (so it faces every camera,
// split-screen included). Per-instance custom data: x = fill 0..1, y = opacity, z = kind (0 enemy,
// 1 friendly), w unused. The instance transform carries the position and the size (x, y scale).

varying vec4 bar;

void vertex() {
	bar = INSTANCE_CUSTOM;
	vec3 sc = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), 1.0);
	mat4 face = mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = VIEW_MATRIX * face * mat4(vec4(sc.x, 0.0, 0.0, 0.0), vec4(0.0, sc.y, 0.0, 0.0), vec4(0.0, 0.0, 1.0, 0.0), vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	float fill = bar.x;
	float opacity = bar.y;
	vec2 uv = UV;
	float edge = 0.09;
	// Border (dark), back (darker red), fill (green -> yellow -> red by amount).
	float in_x = step(edge * 0.35, uv.x) * step(uv.x, 1.0 - edge * 0.35);
	float in_y = step(0.18, uv.y) * step(uv.y, 0.82);
	vec3 low = vec3(0.85, 0.12, 0.1);
	vec3 mid = vec3(0.95, 0.75, 0.15);
	vec3 high = vec3(0.35, 0.8, 0.25);
	vec3 col = fill > 0.5 ? mix(mid, high, (fill - 0.5) * 2.0) : mix(low, mid, fill * 2.0);
	vec3 base = vec3(0.04, 0.03, 0.03);
	float inside = in_x * in_y;
	float filled = step(uv.x, mix(edge * 0.35, 1.0 - edge * 0.35, fill)) * inside;
	vec3 c = mix(base, vec3(0.16, 0.05, 0.05), inside);
	c = mix(c, col, filled);
	ALBEDO = c;
	ALPHA = opacity * (0.92 * step(0.05, uv.y) * step(uv.y, 0.95));
}
