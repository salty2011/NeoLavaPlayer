shader_type sky;
// Modern procedural sky (Phase 4f): vertical gradient, drifting fbm cloud deck,
// sun disc and glow. Used by outdoor profiles in place of the Classic sky
// sphere; also lights and reflects (ambient / reflections from the sky).
// cloud_offset is advanced by the layer from frame deltas.

uniform vec3 sky_top : source_color = vec3(0.16, 0.38, 0.85);
uniform vec3 sky_horizon : source_color = vec3(0.62, 0.78, 0.95);
uniform vec3 ground_color : source_color = vec3(0.25, 0.32, 0.2);
uniform vec3 sun_dir = vec3(0.35, 0.55, -0.75);
uniform vec3 sun_color : source_color = vec3(1.0, 0.92, 0.75);
uniform float sun_energy = 6.0;
uniform float sun_size = 0.0008;
uniform float sun_glow = 0.35;
uniform float cloud_cover = 0.5;
uniform float cloud_scale = 1.6;
uniform float cloud_sharp = 0.22;
uniform vec3 cloud_color : source_color = vec3(1.0, 0.98, 0.95);
uniform vec3 cloud_shade : source_color = vec3(0.62, 0.68, 0.8);
uniform vec2 cloud_offset = vec2(0.0);
uniform float haze = 0.35;
uniform float energy = 1.0;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), f.x), mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		v += a * vnoise(p);
		p = p * 2.03 + vec2(17.1, 9.2);
		a *= 0.5;
	}
	return v;
}

void sky() {
	vec3 d = normalize(EYEDIR);
	float h = d.y;
	vec3 sun = normalize(sun_dir);
	float sd = max(dot(d, sun), 0.0);
	vec3 col = mix(sky_horizon, sky_top, pow(clamp(h, 0.0, 1.0), 0.5));
	// Warm haze toward the sun, whitening at the horizon.
	col = mix(col, sun_color * 0.9, pow(sd, 6.0) * haze);
	if (h < 0.0) col = mix(sky_horizon, ground_color, smoothstep(0.0, -0.18, h));
	if (h > 0.0) {
		vec2 p = d.xz / (h + 0.18) * cloud_scale + cloud_offset;
		float c = fbm(p);
		float lit = fbm(p + sun.xz * 0.25);
		float m = smoothstep(1.0 - cloud_cover, 1.0 - cloud_cover + cloud_sharp, c) * smoothstep(0.0, 0.16, h);
		vec3 cc = mix(cloud_shade, cloud_color, clamp(1.15 - (lit - c) * 3.0 - c * 0.3, 0.0, 1.0));
		cc += sun_color * pow(sd, 5.0) * 0.3;
		col = mix(col, cc, m);
	}
	col += sun_color * sun_energy * smoothstep(1.0 - sun_size, 1.0 - sun_size * 0.55, sd);
	col += sun_color * (pow(sd, 90.0) * sun_glow * 2.0 + pow(sd, 10.0) * sun_glow * 0.25);
	COLOR = col * energy;
}
