extends RefCounted
## Shader variants and per-material profile parameters for the Modern surface
## (modern_surface.gdshader). Kept out of modern_layer.gd so the layer only has
## three call sites: shader_for(), apply_config() and sync().
##
## Variants are compile-time (a shader that writes ALPHA is sorted into the
## transparent pass), so each (cull, translucent, blend) combination is built
## once and cached:
##   cull   - Classic "Culling <obj> None" -> cull_disabled
##   translucent - the object has material alpha < 1 or a DefAlpha effect (the
##                 cases where Classic switches the StandardMaterial to
##                 TRANSPARENCY_ALPHA); ALPHA = material.a x vertex colour.a x alpha_gain
##   blend  - "mix" (Classic's blend), or the profile's Modern-only "add" /
##            "premul" for light beams and glow veils

const SurfaceShader = preload("res://modern/modern_surface.gdshader")

static var _cache := {}

## True when Classic would draw this object alpha-blended.
static func is_translucent(entry: Dictionary, config: Dictionary) -> bool:
	if config.has("translucent"): return bool(config.translucent)
	var material = entry.get("material")
	if material != null and material.albedo_color.a < 0.999: return true
	for descriptor in entry.get("effects", []):
		if str(descriptor.get("kind", "")) == "DefAlpha": return true
	return false

static func shader_for(entry: Dictionary, config: Dictionary) -> Shader:
	var cull_none := str(entry.record.material.get("culling", "back")).to_lower() == "none"
	var translucent := is_translucent(entry, config)
	var blend := str(config.get("blend", "mix")) if translucent else "mix"
	var key := "%s|%s|%s" % [cull_none, translucent, blend]
	if _cache.has(key): return _cache[key]
	var code := SurfaceShader.code
	if cull_none: code = code.replace("cull_back", "cull_disabled")
	if translucent:
		match blend:
			"add": code = code.replace("blend_mix", "blend_add")
			"premul": code = code.replace("blend_mix", "blend_premul_alpha")
		code = code.replace("//@translucent", "ALPHA = clamp(material_diffuse.a * COLOR.a * alpha_gain, 0.0, 1.0);")
	var shader := Shader.new()
	shader.code = code
	_cache[key] = shader
	return shader

static func _vec3(value, fallback: Vector3) -> Vector3:
	if value is Array and value.size() >= 3: return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return fallback

## Static per-material parameters from the profile's material config.
static func apply_config(material: ShaderMaterial, config: Dictionary, translucent: bool, has_source_texture := true) -> void:
	# Procedural albedo: replaces a missing texture (the package never shipped
	# it) or, with "procedural_force", a shipped one.
	var proc = config.get("procedural")
	if proc is Dictionary and (not has_source_texture or bool(config.get("procedural_force", false))):
		var modes := {"plasma": 1, "planet": 2, "rock": 3, "terrain": 4, "sun": 5}
		material.set_shader_parameter("proc_mode", int(modes.get(str(proc.get("mode", "plasma")), 1)))
		material.set_shader_parameter("proc_a", _vec3(proc.get("a"), Vector3(0.1, 0.2, 0.6)))
		material.set_shader_parameter("proc_b", _vec3(proc.get("b"), Vector3(0.3, 0.6, 0.3)))
		material.set_shader_parameter("proc_c", _vec3(proc.get("c"), Vector3.ONE))
		material.set_shader_parameter("proc_scale", float(proc.get("scale", 3.0)))
		material.set_shader_parameter("proc_speed", float(proc.get("speed", 0.05)))
	var tint = config.get("tint_to")
	if tint is Array:
		material.set_shader_parameter("tint_to", _vec3(tint, Vector3.ONE))
		material.set_shader_parameter("tint_amount", float(config.get("tint_amount", 1.0)))
	material.set_shader_parameter("metallic", float(config.get("metallic", 0.0)))
	material.set_shader_parameter("wave_amp", float(config.get("wave_amp", 0.0)))
	material.set_shader_parameter("wave_freq", float(config.get("wave_freq", 6.0)))
	material.set_shader_parameter("wave_speed", float(config.get("wave_speed", 0.35)))
	material.set_shader_parameter("glint_normal", float(config.get("glint_normal", 0.0)))
	material.set_shader_parameter("glint_scale", float(config.get("glint_scale", 18.0)))
	material.set_shader_parameter("glint_speed", float(config.get("glint_speed", 0.4)))
	material.set_shader_parameter("glint_strength", float(config.get("glint_strength", 0.0)))
	material.set_shader_parameter("glint_threshold", float(config.get("glint_threshold", 0.5)))
	if config.has("glint_color"): material.set_shader_parameter("glint_color", _vec3(config.glint_color, Vector3.ONE))
	material.set_shader_parameter("emissive_luma", float(config.get("emissive_luma", 0.0)))
	material.set_shader_parameter("emissive_luma_curve", float(config.get("emissive_luma_curve", 2.0)))
	if translucent:
		material.set_shader_parameter("alpha_gain", float(config.get("alpha_gain", 1.0)))
		material.render_priority = int(config.get("priority", 0))

## Per-frame parameters: the animation clock (integrated by the caller from
## frame deltas, so it is frame-rate independent and pauses with the scene).
static func sync(material: ShaderMaterial, clock: float, textured := true) -> void:
	material.set_shader_parameter("fx_time", clock)
	material.set_shader_parameter("proc_textured", 1.0 if textured else 0.0)
