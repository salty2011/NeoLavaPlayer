shader_type canvas_item;
// Scene transition overlay (Phase 4e). `incoming` is the next scene's viewport;
// whatever the window already shows (the outgoing scene, still simulating) is
// underneath, so every style is plain alpha: no copy of the outgoing frame.
// Texture values are sampled and written raw (no sRGB conversion), so a
// finished blend matches the scene drawn directly by the window.
uniform sampler2D incoming : filter_linear, repeat_disable;
uniform float progress = 0.0;  // 0..1
uniform int style = 1;         // 1 crossfade, 2 dip to black, 3 iris
uniform float aspect = 1.6;    // width / height of the window

void fragment() {
	vec3 rgb = textureLod(incoming, UV, 0.0).rgb;
	float alpha = 1.0;
	float p = clamp(progress, 0.0, 1.0);
	if (style == 1) {
		alpha = smoothstep(0.0, 1.0, p);
	} else if (style == 2) {
		float k = smoothstep(0.0, 1.0, p < 0.5 ? p * 2.0 : (p - 0.5) * 2.0);
		if (p < 0.5) { rgb = vec3(0.0); alpha = k; }
		else { rgb *= k; alpha = 1.0; }
	} else {
		// Radial iris opening from the centre with a soft edge.
		float corner = 0.5 * length(vec2(aspect, 1.0));
		float radius = p * (corner + 0.12);
		float distance_from_centre = length((UV - vec2(0.5)) * vec2(aspect, 1.0));
		alpha = 1.0 - smoothstep(radius - 0.12, radius, distance_from_centre);
		if (p >= 1.0) alpha = 1.0;
	}
	COLOR = vec4(rgb, alpha);
}
