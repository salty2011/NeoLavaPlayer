shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;
// Impact-only lens response: chromatic aberration and a short radial (zoom)
// blur, both scaled by `strength` (impact channel x effects intensity). At
// strength 0 the pass is hidden by modern_layer.gd, so it costs nothing.
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap, repeat_disable;
uniform float strength = 0.0;
uniform float chromatic = 0.0045;
uniform float motion_blur = 0.035;

void vertex() {
	POSITION = vec4(VERTEX.xy * 2.0, 1.0, 1.0);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 dir = uv - vec2(0.5);
	float ca = chromatic * strength;
	float mb = motion_blur * strength;
	vec3 sum = vec3(0.0);
	for (int i = 0; i < 6; i++) {
		float k = 1.0 - mb * float(i) / 5.0;
		vec2 p = vec2(0.5) + dir * k;
		sum.r += texture(screen_texture, vec2(0.5) + (p - vec2(0.5)) * (1.0 + ca)).r;
		sum.g += texture(screen_texture, p).g;
		sum.b += texture(screen_texture, vec2(0.5) + (p - vec2(0.5)) * (1.0 - ca)).b;
	}
	ALBEDO = sum / 6.0;
}
