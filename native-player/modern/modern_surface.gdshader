shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;
// Modern (Lava-25) surface. The colour inputs are exactly the Classic ones:
// material diffuse (event HSI colours via entry.material.albedo_color), mesh
// vertex colours (DoColor) and the mesh UVs the texture effects animate
// (TexScroll/Wave/Translate/Zoom). Only the shading changes: derived 4x
// albedo, normal and roughness maps, GGX + clearcoat, per-pixel lights,
// music-driven emission. The Translucent variant (see modern_surface_variants.gd)
// also writes ALPHA from material x vertex alpha, as Classic does. Original colours are display (sRGB) values, so they
// are linearised here; Classic keeps writing them raw.

uniform vec4 material_diffuse = vec4(1.0);
uniform bool has_texture = true;
uniform bool lighting_enabled = true;
uniform bool flat_shading = false;
uniform sampler2D albedo_map : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_map : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D roughness_map : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool has_normal_map = false;
uniform bool has_roughness_map = false;
uniform float normal_strength = 1.0;
uniform float roughness_scale = 1.0;
uniform float roughness_bias = 0.0;
uniform float metallic = 0.0;
uniform float specular_level = 0.5;
uniform float clearcoat_amount = 0.0;
uniform float clearcoat_gloss = 0.9;
uniform float albedo_gain = 1.0;
uniform float saturation = 1.0;
// Emission = albedo * emission_base (+ music) and a fresnel rim in rim_color.
uniform float emission_base = 0.0;
uniform float emission_music = 0.0;
uniform vec3 rim_color : source_color = vec3(0.6, 0.3, 1.0);
uniform float rim_strength = 0.0;
uniform float rim_power = 3.0;
// Modern-only drift (background motion); never touches the simulation UVs.
uniform vec2 uv_drift = vec2(0.0);
uniform float ao_strength = 0.0;
uniform sampler2D height_map : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform bool has_height_map = false;

// Phase 4f. Colour tint toward a palette colour (display space).
uniform vec3 tint_to = vec3(1.0);
uniform float tint_amount = 0.0;
// Modern-only animation time (integrated by the layer from frame deltas).
uniform float fx_time = 0.0;
// Breeze: a slow travelling UV warp (flowers, grass, water edge).
uniform float wave_amp = 0.0;
uniform float wave_freq = 6.0;
uniform float wave_speed = 0.35;
// Water glints: animated micro-normals plus rare bright sparkles.
uniform float glint_normal = 0.0;
uniform float glint_scale = 18.0;
uniform float glint_speed = 0.4;
uniform float glint_strength = 0.0;
uniform float glint_threshold = 0.5;
uniform vec3 glint_color = vec3(1.0, 0.97, 0.9);
// Translucent variant only: alpha scale on top of material/vertex alpha.
uniform float alpha_gain = 1.0;
// Emission from the albedo texture's own luminance (glowing signs, windows).
uniform float emissive_luma = 0.0;
uniform float emissive_luma_curve = 2.0;

// Procedural albedo for textures the original package never shipped (and for
// profile-chosen replacements). Colours are display-space; see procedural().
uniform int proc_mode = 0;          // 0 off, 1 plasma, 2 planet, 3 rock/moon, 4 river terrain, 5 sun
uniform float proc_textured = 1.0;  // follows the Classic TEXTURE style flag
uniform vec3 proc_a = vec3(0.1, 0.2, 0.6);
uniform vec3 proc_b = vec3(0.3, 0.6, 0.3);
uniform vec3 proc_c = vec3(1.0);
uniform float proc_scale = 3.0;
uniform float proc_speed = 0.05;

varying vec3 local_normal;
varying vec3 local_pos;

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

void vertex() {
	local_normal = NORMAL;
	local_pos = VERTEX;
}

float hash31(vec3 p) {
	p = fract(p * 0.3183099 + vec3(0.1, 0.2, 0.3));
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float vnoise3(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash31(i), hash31(i + vec3(1.0, 0.0, 0.0)), f.x), mix(hash31(i + vec3(0.0, 1.0, 0.0)), hash31(i + vec3(1.0, 1.0, 0.0)), f.x), f.y),
		mix(mix(hash31(i + vec3(0.0, 0.0, 1.0)), hash31(i + vec3(1.0, 0.0, 1.0)), f.x), mix(hash31(i + vec3(0.0, 1.0, 1.0)), hash31(i + vec3(1.0, 1.0, 1.0)), f.x), f.y), f.z);
}

float fbm3(vec3 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		v += a * vnoise3(p);
		p = p * 2.02 + vec3(5.2, 1.3, 3.7);
		a *= 0.5;
	}
	return v;
}

vec3 ramp3(float f, vec3 a, vec3 b, vec3 c) {
	return f < 0.5 ? mix(a, b, f * 2.0) : mix(b, c, (f - 0.5) * 2.0);
}

vec3 procedural(vec2 uv, vec3 lp) {
	float t = fx_time * proc_speed;
	if (proc_mode == 1) {
		vec2 p = uv * proc_scale;
		vec2 w = vec2(fbm3(vec3(p + vec2(0.0, t), 1.7)), fbm3(vec3(p + vec2(5.2, 1.3) - vec2(t, 0.0), 3.1)));
		return ramp3(clamp(fbm3(vec3(p + 2.0 * w, t * 0.5)) * 1.5 - 0.2, 0.0, 1.0), proc_a, proc_b, proc_c);
	}
	if (proc_mode == 2) {
		vec3 n = normalize(lp);
		vec3 p = n * proc_scale;
		float h = fbm3(p);
		vec3 col = h < 0.5 ? proc_a * (0.7 + 0.6 * h) : mix(proc_b, proc_b * 0.65, (h - 0.5) * 2.0);
		col = mix(col, proc_c, smoothstep(0.55, 0.8, fbm3(p * 1.7 + vec3(t, 0.0, 0.0))) * 0.75);
		return mix(col, proc_c, smoothstep(0.82, 0.95, abs(n.y)));
	}
	if (proc_mode == 3) {
		vec3 p = normalize(lp) * proc_scale;
		float c = smoothstep(0.5, 0.58, fbm3(p * 2.3 + 9.0));
		return mix(proc_a, proc_b, fbm3(p)) * mix(0.5, 1.0, c);
	}
	if (proc_mode == 4) {
		vec2 p = uv * proc_scale;
		float h = fbm3(vec3(p * 0.6, 2.0));
		float river = 1.0 - smoothstep(0.0, 0.32, abs(sin(p.x * 0.8 + fbm3(vec3(p, 4.0)) * 3.0)));
		vec3 land = mix(proc_b, proc_c, smoothstep(0.35, 0.7, h));
		return mix(land, proc_a, river) * (0.85 + 0.3 * fbm3(vec3(p * 6.0, 1.0)));
	}
	if (proc_mode == 5) {
		vec3 p = normalize(lp) * proc_scale;
		float f = clamp(fbm3(p * 2.0 + vec3(0.0, 0.0, t)) * 1.2 + fbm3(p * 6.0 - vec3(t, 0.0, 0.0)) * 0.4 - 0.1, 0.0, 1.0);
		return ramp3(f, proc_a, proc_b, proc_c);
	}
	return vec3(1.0);
}

vec3 perturb(vec3 n, vec3 view_pos, vec2 uv, vec3 map_normal) {
	// Cotangent frame from screen derivatives: the runtime meshes carry no
	// tangents (they are rebuilt from the original deformers every tick).
	vec3 dp1 = dFdx(view_pos);
	vec3 dp2 = dFdy(view_pos);
	vec2 duv1 = dFdx(uv);
	vec2 duv2 = dFdy(uv);
	vec3 dp2perp = cross(dp2, n);
	vec3 dp1perp = cross(n, dp1);
	vec3 t = dp2perp * duv1.x + dp1perp * duv2.x;
	vec3 b = dp2perp * duv1.y + dp1perp * duv2.y;
	float invmax = inversesqrt(max(dot(t, t), dot(b, b)) + 1e-12);
	mat3 tbn = mat3(t * invmax, b * invmax, n);
	return normalize(tbn * map_normal);
}

void fragment() {
	vec2 uv = UV + uv_drift;
	if (wave_amp > 0.0) {
		float w = fx_time * wave_speed * 6.2831853;
		uv += wave_amp * vec2(sin(UV.y * wave_freq + w + sin(UV.x * wave_freq * 0.7 + w * 0.6) * 1.3), cos(UV.x * wave_freq * 1.3 + w * 0.8 + sin(UV.y * wave_freq * 0.5) * 1.1));
	}
	vec3 base = material_diffuse.rgb * COLOR.rgb;
	base = mix(base, tint_to, tint_amount);
	vec3 tex = has_texture ? texture(albedo_map, uv).rgb : vec3(1.0);
	if (proc_mode > 0 && proc_textured > 0.5) tex = pow(max(procedural(uv, local_pos), vec3(0.0)), vec3(2.2));
	// Display-space product (as Classic GL_MODULATE), then linearised.
	vec3 albedo = pow(clamp(base, 0.0, 1.0), vec3(2.2)) * tex * albedo_gain;
	float luma = dot(albedo, vec3(0.2126, 0.7152, 0.0722));
	albedo = max(mix(vec3(luma), albedo, saturation), vec3(0.0));
	vec3 n = NORMAL;
	if (flat_shading) n = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
	if (!FRONT_FACING) n = -n;
	if (has_normal_map && has_texture && normal_strength > 0.0) {
		vec3 m = texture(normal_map, uv).xyz * 2.0 - 1.0;
		m.xy *= normal_strength;
		n = perturb(n, VERTEX, uv, normalize(m));
	}
	float sparkle = 0.0;
	if (glint_normal > 0.0 || glint_strength > 0.0) {
		vec2 gp = uv * glint_scale;
		vec2 t = fx_time * glint_speed * vec2(1.0, 0.7);
		vec2 q = gp + t;
		float g1 = vnoise(q);
		float g2 = vnoise(gp * 1.73 - t.yx * 1.4 + 7.3);
		vec2 grad = vec2(vnoise(q + vec2(0.35, 0.0)) - vnoise(q - vec2(0.35, 0.0)), vnoise(q + vec2(0.0, 0.35)) - vnoise(q - vec2(0.0, 0.35)));
		grad += 0.6 * vec2(vnoise(gp * 2.3 + t.yx * 2.0 + 3.1) - 0.5, vnoise(gp * 2.3 - t * 1.7 + 9.7) - 0.5);
		if (glint_normal > 0.0) n = perturb(n, VERTEX, uv, normalize(vec3(grad * glint_normal, 1.0)));
		sparkle = smoothstep(glint_threshold, glint_threshold + 0.2, g1 * g2 * 2.4);
	}
	NORMAL = n;
	float rough = has_roughness_map ? texture(roughness_map, uv).r : 0.5;
	ROUGHNESS = clamp(rough * roughness_scale + roughness_bias, 0.03, 1.0);
	METALLIC = metallic;
	SPECULAR = specular_level;
	CLEARCOAT = clearcoat_amount;
	CLEARCOAT_ROUGHNESS = 1.0 - clearcoat_gloss;
	if (has_height_map && ao_strength > 0.0) AO = mix(1.0, texture(height_map, uv).r, ao_strength);
	float fresnel = pow(1.0 - clamp(dot(n, VIEW), 0.0, 1.0), rim_power);
	vec3 emission = albedo * (emission_base + emission_music) + rim_color * rim_strength * fresnel;
	if (emissive_luma > 0.0) emission += albedo * emissive_luma * pow(clamp(dot(tex, vec3(0.2126, 0.7152, 0.0722)) * 1.6, 0.0, 1.0), emissive_luma_curve) * 4.0;
	emission += glint_color * glint_strength * sparkle * (0.35 + 0.65 * fresnel);
	if (lighting_enabled) {
		ALBEDO = albedo;
		EMISSION = emission;
	} else {
		// Unlit (Classic EnableLighting 0 / lights off): a flat colour with no
		// specular or reflections from the Modern key.
		ALBEDO = vec3(0.0);
		SPECULAR = 0.0;
		CLEARCOAT = 0.0;
		EMISSION = albedo + emission;
	}
//@translucent
}
