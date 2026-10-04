extends SceneTree
## Renders the app icon (res://icon.png, 1024x1024) from a shader: the
## player's lava-drop mark as merged glowing blobs on a dark macOS-style
## rounded square. Needs a window (not --headless):
##   Godot --path native-player --script res://tools/make_icon.gd

const SIZE := 1024
const SHADER := """
shader_type canvas_item;

// Superellipse distance-ish value: < 1 inside the macOS icon shape.
float squircle(vec2 p, float n) {
	return pow(abs(p.x), n) + pow(abs(p.y), n);
}

float blob(vec2 p, vec2 c, float r) {
	vec2 d = p - c;
	return r * r / max(dot(d, d), 1e-5);
}

float field(vec2 p) {
	return blob(p, vec2(-0.10, 0.26), 0.24)
		+ blob(p, vec2(0.10, 0.06), 0.13)
		+ blob(p, vec2(0.20, -0.30), 0.14)
		+ blob(p, vec2(-0.30, -0.14), 0.065)
		+ blob(p, vec2(0.32, 0.30), 0.05);
}

void fragment() {
	// Icon grid: 824 px body centred in 1024, shadow below.
	vec2 p = (UV - 0.5) * (1024.0 / 824.0) * 2.0;
	float s = squircle(p, 5.0);
	float inside = 1.0 - smoothstep(0.985, 1.015, s);
	float shadow = (1.0 - smoothstep(0.7, 1.5, squircle(p - vec2(0.0, 0.035), 5.0))) * 0.45;

	// Body: deep warm-black with a faint top sheen and darker rim.
	vec3 body = mix(vec3(0.16, 0.07, 0.05), vec3(0.035, 0.02, 0.03), smoothstep(-1.0, 1.0, p.y));
	body *= 1.0 - 0.35 * smoothstep(0.55, 1.0, s);
	body += vec3(0.10, 0.06, 0.05) * (1.0 - smoothstep(0.0, 0.25, abs(s - 0.93))) * (1.0 - smoothstep(-0.4, 0.2, p.y));

	// Lava: thresholded metaball field with hot core and soft glow.
	vec2 q = p * 0.82;
	float f = field(q);
	float edge = smoothstep(0.96, 1.04, f);
	float core = smoothstep(1.3, 4.0, f);
	vec3 lava = mix(vec3(0.85, 0.16, 0.03), vec3(1.0, 0.52, 0.10), core);
	lava = mix(lava, vec3(1.0, 0.86, 0.45), smoothstep(4.5, 10.0, f));
	// Fake lighting from the top-left using the field gradient.
	vec2 e = vec2(0.004, 0.0);
	vec2 grad = vec2(field(q + e.xy) - field(q - e.xy), field(q + e.yx) - field(q - e.yx));
	vec3 n = normalize(vec3(-grad * 0.06, 1.0));
	float spec = pow(max(dot(n, normalize(vec3(-0.45, -0.55, 0.7))), 0.0), 40.0);
	lava += vec3(1.0, 0.95, 0.85) * spec * 0.9 * edge;
	float glow = smoothstep(0.25, 1.0, f) * (1.0 - edge);
	vec3 col = body + vec3(1.0, 0.35, 0.06) * glow * 0.55;
	col = mix(col, lava, edge);

	// Glossy upper highlight across the body.
	float gloss = (1.0 - smoothstep(-0.95, -0.15, p.y)) * (1.0 - smoothstep(0.6, 1.0, s)) * 0.06;
	col += vec3(gloss);

	float alpha = max(inside, shadow);
	vec3 rgb = mix(vec3(0.0), col, inside / max(alpha, 1e-4));
	COLOR = vec4(rgb, alpha);
}
"""

func _initialize():
	var viewport := SubViewport.new()
	viewport.size = Vector2i(SIZE, SIZE)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var rect := ColorRect.new()
	rect.size = Vector2(SIZE, SIZE)
	var material := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = SHADER
	material.shader = shader
	rect.material = material
	viewport.add_child(rect)
	for i in 3: await process_frame
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	var out := ProjectSettings.globalize_path("res://icon.png")
	print("ICON ", image.save_png(out) == OK, " ", out)
	quit(0)
