extends RefCounted
## Builds the Modern Environment (and CameraAttributes) for a scene profile at
## a quality preset. Classic's own Environment is never modified; the layer
## swaps WorldEnvironment.environment and swaps it back on detach.

static func _color(values, fallback := Color.BLACK) -> Color:
	if values is Array and values.size() >= 3: return Color(float(values[0]), float(values[1]), float(values[2]))
	return fallback

static func build(profile: Dictionary, row: Dictionary) -> Environment:
	var p: Dictionary = profile.get("environment", {})
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = _color(p.get("background"), Color.BLACK)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = _color(p.get("ambient_color"), Color(0.4, 0.4, 0.8))
	env.ambient_light_energy = float(p.get("ambient_energy", 0.5))
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	var sky_config = p.get("sky")
	if sky_config is Dictionary: _apply_sky(env, p, sky_config, row)
	match str(p.get("tonemap", "agx")):
		"aces": env.tonemap_mode = Environment.TONE_MAPPER_ACES
		"filmic": env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
		"linear": env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
		_: env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = float(p.get("exposure", 1.0))
	env.tonemap_white = float(p.get("white", 6.0))
	env.adjustment_enabled = true
	env.adjustment_brightness = float(p.get("adjust_brightness", 1.0))
	env.adjustment_contrast = float(p.get("adjust_contrast", 1.0))
	env.adjustment_saturation = float(p.get("adjust_saturation", 1.0))
	# Glow (HDR bloom): additive-soft, tuned so only emissive highlights bloom.
	env.glow_enabled = true
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	env.glow_intensity = float(p.get("glow_intensity", 0.6))
	env.glow_strength = float(p.get("glow_strength", 1.0))
	env.glow_bloom = float(p.get("glow_bloom", 0.0))
	env.glow_hdr_threshold = float(p.get("glow_hdr_threshold", 1.0))
	var levels: Array = p.get("glow_levels", [0, 0.5, 1, 1, 0.5, 0.2, 0])
	for i in mini(levels.size(), 7): env.set_glow_level(i, float(levels[i]))
	# Fog: cheap depth fog on Low, froxel volumetric fog (light shafts) above.
	if row.fog == "volumetric":
		env.volumetric_fog_enabled = true
		env.volumetric_fog_density = float(p.get("volumetric_fog_density", 0.01))
		env.volumetric_fog_albedo = _color(p.get("volumetric_fog_albedo"), Color.WHITE)
		env.volumetric_fog_emission = _color(p.get("volumetric_fog_emission"), Color.BLACK)
		env.volumetric_fog_anisotropy = float(p.get("volumetric_fog_anisotropy", 0.3))
		env.volumetric_fog_length = float(p.get("volumetric_fog_length", 48.0))
		env.volumetric_fog_temporal_reprojection_enabled = true
		env.volumetric_fog_ambient_inject = 0.15
	else:
		env.fog_enabled = true
		env.fog_light_color = _color(p.get("fog_color"), Color(0.3, 0.25, 0.7))
		env.fog_density = float(p.get("fog_density", 0.005))
		env.fog_sky_affect = float(p.get("fog_sky_affect", 0.0))
		if p.has("fog_height_density"):
			env.fog_height = float(p.get("fog_height", 0.0))
			env.fog_height_density = float(p.get("fog_height_density", 0.0))
		env.fog_aerial_perspective = float(p.get("fog_aerial_perspective", 0.0))
		env.fog_sun_scatter = float(p.get("fog_sun_scatter", 0.0))
	if row.get("ssao", false):
		env.ssao_enabled = true
		env.ssao_radius = float(p.get("ssao_radius", 0.6))
		env.ssao_intensity = float(p.get("ssao_intensity", 1.5))
		env.ssao_light_affect = 0.15
	if row.get("ssr", false):
		env.ssr_enabled = true
		env.ssr_max_steps = int(row.get("ssr_steps", 48))
		env.ssr_fade_in = 0.12
		env.ssr_fade_out = 2.5
		env.ssr_depth_tolerance = 0.25
	if row.gi == "ssil" or row.get("ssil", false):
		env.ssil_enabled = true
		env.ssil_intensity = float(p.get("ssil_intensity", 0.8))
		env.ssil_radius = 3.0
	if row.gi == "sdfgi":
		env.sdfgi_enabled = true
		env.sdfgi_cascades = int(p.get("sdfgi_cascades", 4))
		env.sdfgi_min_cell_size = float(p.get("sdfgi_min_cell", 0.15))
		env.sdfgi_energy = float(p.get("sdfgi_energy", 1.0))
		env.sdfgi_use_occlusion = true
		env.sdfgi_read_sky_light = false
	return env

static func camera_attributes(profile: Dictionary, row: Dictionary, enabled: bool) -> CameraAttributesPractical:
	var attributes := CameraAttributesPractical.new()
	var dof: Dictionary = profile.get("effects", {}).get("dof", {})
	attributes.dof_blur_far_enabled = enabled and row.get("dof", false) and not dof.is_empty()
	attributes.dof_blur_far_distance = float(dof.get("far_distance", 14.0))
	attributes.dof_blur_far_transition = float(dof.get("far_transition", 10.0))
	attributes.dof_blur_amount = float(dof.get("amount", 0.06))
	return attributes

## Procedural sky (modern_sky.gdshader) as background, ambient and reflection
## source. `sky` keys are the shader's uniforms (colours as [r,g,b]).
static func _apply_sky(env: Environment, p: Dictionary, config: Dictionary, row: Dictionary) -> void:
	var material := ShaderMaterial.new()
	material.shader = preload("res://modern/modern_sky.gdshader")
	for key in config:
		var value = config[key]
		if str(key).begins_with("_"): continue
		if value is Array and value.size() >= 3:
			material.set_shader_parameter(key, Vector3(float(value[0]), float(value[1]), float(value[2])) if key == "sun_dir" else Color(float(value[0]), float(value[1]), float(value[2])))
		elif value is Array and value.size() == 2: material.set_shader_parameter(key, Vector2(float(value[0]), float(value[1])))
		elif value is float or value is int: material.set_shader_parameter(key, float(value))
	var sky := Sky.new()
	sky.sky_material = material
	sky.radiance_size = Sky.RADIANCE_SIZE_64 if str(row.get("fog", "")) == "depth" else Sky.RADIANCE_SIZE_128
	sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	env.sky = sky
	env.background_mode = Environment.BG_SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = float(p.get("ambient_sky_contribution", 1.0))
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
