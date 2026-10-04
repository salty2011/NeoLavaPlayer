extends Node3D
## Modern ("Lava-25") render layer. Attaches to a loaded SceneRuntime and
## changes only how it looks: per-object PBR materials, the Environment, extra
## lights, optional effects. Geometry, deformation, texture-effect UVs, event
## colours, camera and every random draw stay in the runtime, which keeps
## running exactly as in Classic. detach() restores the Classic materials,
## environment, light masks and viewport settings, so F9 can flip back and
## forth mid-song without a reset. See docs/MODERN_RENDERING.md.

const ReactivityServiceScript = preload("res://analysis/reactivity_service.gd")
const SurfaceShader = preload("res://modern/modern_surface.gdshader")
const ModernProfiles = preload("res://modern/modern_profiles.gd")
const ModernQuality = preload("res://modern/modern_quality.gd")
const ModernEnvironment = preload("res://modern/modern_environment.gd")
const ModernEffects = preload("res://modern/modern_effects.gd")
const ModernSurfaceVariants = preload("res://modern/modern_surface_variants.gd")
const ModernAtmosphere = preload("res://modern/modern_atmosphere.gd")
const StyleFlags = preload("res://style_flags.gd")
const VirtualDirector = preload("res://modern/director/virtual_director.gd")
const CharacterAnimator = preload("res://modern/animation/character_animator.gd")

const EFFECT_DEFAULTS := {"particles": true, "trails": true, "dof": true, "post": true}

var runtime
var profile: Dictionary = {}
var quality := "high"
var effects := EFFECT_DEFAULTS.duplicate()
var attached := false
## "director" | "original" | "locked" (Phase 4d; AppSettings.camera_mode).
var camera_mode := "director"
var director = null
var animator = null
## Hand-over (Phase 4d): take_motion() from a layer that ran this same runtime
## (the scene-transition stage, or this layer before rebuild()) so the edit and
## the characters carry on instead of restarting with a new opening shot.
var handoff: Dictionary = {}

var _row: Dictionary = {}
var _entries: Array = []           # {entry, material, config, saved_override, saved_shadow, drift}
var _world_environment: WorldEnvironment
var _saved_environment: Environment
var _saved_attributes: CameraAttributes
var _saved_light_masks: Array = []
var _saved_viewport: Dictionary = {}
var _environment: Environment
var _key: Light3D
var _atmosphere: Node3D
var _fx_clock := 0.0
var _fill: DirectionalLight3D
var _rim: DirectionalLight3D
var _fx: Node3D
var _base: Dictionary = {}
var _cull_shader: Shader
var _texture_cache := {}
var _hue := 0.0
var _impact_connected := false
var _camera_base := Transform3D.IDENTITY
var _camera_written = null
var _saved_fov := 45.0
var _dof := {}
var _last_delta := 0.0

func _init():
	name = "ModernLayer"

## True if the scene has a Modern profile and the layer took over its look.
func attach(target) -> bool:
	if attached: detach()
	runtime = target
	if runtime == null or runtime.camera == null or runtime.data.is_empty(): return false
	profile = ModernProfiles.for_folder(str(runtime.data.get("folder", "")))
	if profile.is_empty(): return false
	_row = ModernQuality.preset(quality)
	_saved_viewport = ModernQuality.apply_viewport(get_viewport(), _row)
	_build_materials()
	_build_environment()
	_build_lights()
	_atmosphere = ModernAtmosphere.new()
	add_child(_atmosphere)
	_atmosphere.build(profile, _row, effects, _environment, _key)
	_fx = ModernEffects.new()
	_fx.name = "ModernEffects"
	add_child(_fx)
	_fx.build(runtime, profile, _row, effects)
	var mapper = ReactivityServiceScript.instance().mapper
	_build_director_and_animation(mapper)
	if not _impact_connected:
		mapper.impact_fired.connect(_on_impact)
		_impact_connected = true
	attached = true
	update(0.0)
	return true

func detach() -> void:
	if not attached: return
	attached = false
	if animator != null: animator.restore()
	animator = null
	if runtime != null and is_instance_valid(runtime.camera):
		if _camera_written != null and runtime.camera.transform == _camera_written: runtime.camera.transform = _camera_base
		runtime.camera.fov = _saved_fov
	_camera_written = null
	director = null
	for item in _entries:
		var node: MeshInstance3D = item.entry.get("node")
		if is_instance_valid(node):
			node.material_override = item.saved_override
			node.cast_shadow = item.saved_shadow
			node.gi_mode = item.saved_gi
			node.visible = item.saved_visible
	_entries.clear()
	if is_instance_valid(_world_environment): _world_environment.environment = _saved_environment
	if runtime != null and is_instance_valid(runtime.camera): runtime.camera.attributes = _saved_attributes
	for saved in _saved_light_masks:
		if is_instance_valid(saved.node): saved.node.light_cull_mask = saved.mask
	_saved_light_masks.clear()
	ModernQuality.restore_viewport(get_viewport(), _saved_viewport)
	for child in get_children(): child.queue_free()
	_key = null
	_fill = null
	_rim = null
	_fx = null
	_atmosphere = null
	if _impact_connected:
		var mapper = ReactivityServiceScript.instance().mapper
		if mapper.impact_fired.is_connected(_on_impact): mapper.impact_fired.disconnect(_on_impact)
		_impact_connected = false

## Re-apply after a quality or effects change (keeps the simulation).
func rebuild() -> void:
	if not attached: return
	var target = runtime
	handoff = take_motion()
	detach()
	attach(target)

# --- Materials ---------------------------------------------------------------

func _build_materials() -> void:
	var configs: Dictionary = profile.get("materials", {})
	var defaults: Dictionary = configs.get("default", {})
	for entry in runtime.objects:
		var node: MeshInstance3D = entry.get("node")
		if node == null: continue
		var config: Dictionary = defaults.duplicate()
		config.merge(configs.get("objects", {}).get(str(entry.record.name), {}), true)
		var translucent := ModernSurfaceVariants.is_translucent(entry, config)
		var material := ShaderMaterial.new()
		material.shader = ModernSurfaceVariants.shader_for(entry, config)
		var texture: Texture2D = entry.get("texture")
		var maps := ModernProfiles.derived_maps(texture.resource_path) if texture != null else {}
		material.set_shader_parameter("albedo_map", _mipmapped(maps.get("albedo", ""), texture))
		if maps.has("normal"):
			material.set_shader_parameter("normal_map", _mipmapped(maps.normal, null))
			material.set_shader_parameter("has_normal_map", true)
		if maps.has("roughness"):
			material.set_shader_parameter("roughness_map", _mipmapped(maps.roughness, null))
			material.set_shader_parameter("has_roughness_map", true)
		if maps.has("height"):
			material.set_shader_parameter("height_map", _mipmapped(maps.height, null))
			material.set_shader_parameter("has_height_map", true)
			material.set_shader_parameter("ao_strength", float(config.get("ao", 0.0)))
		material.set_shader_parameter("normal_strength", float(config.get("normal_strength", 1.0)))
		material.set_shader_parameter("roughness_scale", float(config.get("roughness_scale", 1.0)))
		material.set_shader_parameter("roughness_bias", float(config.get("roughness_bias", 0.0)))
		material.set_shader_parameter("specular_level", float(config.get("specular", 0.5)))
		material.set_shader_parameter("clearcoat_amount", float(config.get("clearcoat", 0.0)))
		material.set_shader_parameter("clearcoat_gloss", float(config.get("clearcoat_gloss", 0.9)))
		material.set_shader_parameter("albedo_gain", float(config.get("albedo_gain", 1.0)))
		material.set_shader_parameter("saturation", float(config.get("saturation", 1.0)))
		material.set_shader_parameter("emission_base", float(config.get("emission_base", 0.0)))
		material.set_shader_parameter("rim_strength", float(config.get("rim_strength", 0.0)))
		var rim = config.get("rim_color")
		if rim is Array: material.set_shader_parameter("rim_color", Color(rim[0], rim[1], rim[2]))
		ModernSurfaceVariants.apply_config(material, config, translucent, texture != null)
		var item := {"entry": entry, "material": material, "config": config, "saved_override": node.material_override,
			"saved_shadow": node.cast_shadow, "saved_gi": node.gi_mode, "saved_visible": node.visible, "drift": Vector2.ZERO}
		node.material_override = material
		# Profile may retire a Classic backdrop that Modern replaces (e.g. the sky sphere).
		if config.get("hidden", false): node.visible = false
		var shadows: bool = bool(config.get("shadows", true)) and int(_row.shadows) > 0
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# SDFGI only sees static geometry: the enclosing background (and other
		# gi_static objects) contribute their bounce from the current pose.
		node.gi_mode = GeometryInstance3D.GI_MODE_STATIC if config.get("gi_static", false) else GeometryInstance3D.GI_MODE_DYNAMIC
		_entries.append(item)
	_sync_materials(0.0, {})

func _shader_for(entry: Dictionary) -> Shader:
	if str(entry.record.material.get("culling", "back")).to_lower() != "none": return SurfaceShader
	if _cull_shader == null:
		_cull_shader = Shader.new()
		_cull_shader.code = SurfaceShader.code.replace("cull_back", "cull_disabled")
	return _cull_shader

## Derived maps are imported without mipmaps; the 4x maps shimmer without
## them, so build a mipmapped copy once per file.
func _mipmapped(path: String, fallback: Texture2D) -> Texture2D:
	var key := path if not path.is_empty() else (fallback.resource_path if fallback != null else "")
	if key.is_empty(): return null
	if _texture_cache.has(key): return _texture_cache[key]
	var source: Texture2D = load(path) as Texture2D if not path.is_empty() else fallback
	if source == null: return fallback
	var image := source.get_image()
	if image == null: return source
	if image.is_compressed(): image.decompress()
	image.generate_mipmaps()
	var texture := ImageTexture.create_from_image(image)
	_texture_cache[key] = texture
	return texture

func _sync_materials(delta: float, levels: Dictionary) -> void:
	var flags: int = runtime.get_style_flags()
	var textured := (flags & StyleFlags.TEXTURE) != 0
	var lights_on := (flags & StyleFlags.LIGHTS) != 0
	var flat := (flags & StyleFlags.FLAT_SHADING) != 0
	var reactions: Dictionary = profile.get("reactions", {})
	var music := float(levels.get("pulse", 0.0)) * float(reactions.get("emission_pulse", 1.0)) + float(levels.get("accent", 0.0)) * float(reactions.get("emission_accent", 0.5))
	var rim_gain := 1.0 + float(levels.get("swell", 0.0)) * float(reactions.get("rim_swell", 0.0))
	var drift_gain := (1.0 + float(levels.get("swell", 0.0)) * float(reactions.get("background_drift_swell", 0.0))) * maxf(0.0, 1.0 - float(levels.get("calm", 0.0)) * float(reactions.get("background_drift_calm", 0.0)))
	_fx_clock += maxf(delta, 0.0)
	for item in _entries:
		var entry: Dictionary = item.entry
		var material: ShaderMaterial = item.material
		var color: Color = entry.material.albedo_color
		material.set_shader_parameter("material_diffuse", Vector4(color.r, color.g, color.b, color.a))
		material.set_shader_parameter("has_texture", textured and entry.get("texture") != null)
		material.set_shader_parameter("lighting_enabled", bool(entry.get("lit", true)) and lights_on and not bool(item.config.get("unlit", false)))
		material.set_shader_parameter("flat_shading", flat)
		material.set_shader_parameter("emission_music", float(item.config.get("emission_music", 0.0)) * music)
		ModernSurfaceVariants.sync(material, _fx_clock, textured)
		material.set_shader_parameter("rim_strength", float(item.config.get("rim_strength", 0.0)) * rim_gain)
		var drift = item.config.get("drift")
		if drift is Array and delta > 0.0:
			item.drift = (item.drift + Vector2(drift[0], drift[1]) * drift_gain * delta).posmod(1.0)
			material.set_shader_parameter("uv_drift", item.drift)

# --- Environment & lights ----------------------------------------------------

func _build_environment() -> void:
	_world_environment = null
	for child in runtime._world.get_children():
		if child is WorldEnvironment: _world_environment = child
	_environment = ModernEnvironment.build(profile, _row)
	_base = {"exposure": _environment.tonemap_exposure, "glow": _environment.glow_intensity,
		"fog": _environment.volumetric_fog_density if _environment.volumetric_fog_enabled else _environment.fog_density}
	if _world_environment != null:
		_saved_environment = _world_environment.environment
		_world_environment.environment = _environment
	_saved_attributes = runtime.camera.attributes
	runtime.camera.attributes = ModernEnvironment.camera_attributes(profile, _row, bool(effects.get("dof", true)))

func _build_lights() -> void:
	# Classic omni lights stay in the tree (the runtime keeps animating them for
	# Strobe/Coloured Lighting) but light nothing while Modern is attached.
	for light in runtime._lights:
		_saved_light_masks.append({"node": light.node, "mask": light.node.light_cull_mask})
		light.node.light_cull_mask = 0
	var config: Dictionary = profile.get("lights", {})
	var key: Dictionary = config.get("key", {})
	var position := Vector3(0, 2, 0)
	for command in runtime.data.get("lighting", []):
		if int(command.index) == int(key.get("from_scene_light", 0)) and command.property == "Position":
			position = Vector3(command.value[0], command.value[1], command.value[2])
	if str(key.get("type", "omni")) == "directional":
		# Outdoor profiles: the key is a sun (colour and energy still follow the
		# original light 0 terms in update()).
		var sun := DirectionalLight3D.new()
		var toward: Array = key.get("direction", [-0.4, -0.7, -0.5])
		sun.basis = Basis.looking_at(Vector3(toward[0], toward[1], toward[2]).normalized(), Vector3.UP)
		sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
		sun.directional_shadow_max_distance = float(key.get("shadow_distance", 40.0))
		sun.light_angular_distance = float(key.get("size", 1.2)) if _row.get("soft_shadows", false) else 0.0
		sun.shadow_enabled = bool(key.get("shadow", true)) and int(_row.shadows) > 0
		sun.shadow_bias = 0.03
		sun.shadow_normal_bias = 1.2
		sun.light_volumetric_fog_energy = float(key.get("volumetric", 1.0))
		sun.light_specular = float(key.get("specular", 1.0))
		_key = sun
	else:
		var omni := OmniLight3D.new()
		omni.position = position
		omni.omni_range = float(key.get("range", 60.0))
		omni.omni_attenuation = float(key.get("attenuation", 0.5))
		omni.light_size = float(key.get("size", 0.3)) if _row.get("soft_shadows", false) else 0.0
		omni.shadow_enabled = bool(key.get("shadow", true)) and int(_row.shadows) > 0
		omni.omni_shadow_mode = OmniLight3D.SHADOW_CUBE
		omni.shadow_bias = 0.05
		omni.shadow_normal_bias = 1.5
		omni.light_volumetric_fog_energy = float(key.get("volumetric", 1.0))
		omni.light_specular = float(key.get("specular", 1.0))
		_key = omni
	_key.name = "ModernKey"
	add_child(_key)
	var fill: Dictionary = config.get("fill", {})
	_fill = DirectionalLight3D.new()
	_fill.name = "ModernFill"
	_fill.light_color = ModernEnvironment._color(fill.get("color"), Color(0.5, 0.6, 1.0))
	_fill.light_energy = float(fill.get("energy", 0.3))
	var direction: Array = fill.get("direction", [-0.6, -0.4, 0.7])
	_fill.basis = Basis.looking_at(Vector3(direction[0], direction[1], direction[2]).normalized(), Vector3.UP)
	_fill.light_volumetric_fog_energy = 0.0
	add_child(_fill)
	var rim: Dictionary = config.get("rim", {})
	_rim = DirectionalLight3D.new()
	_rim.name = "ModernRim"
	_rim.light_color = ModernEnvironment._color(rim.get("color"), Color(1, 0.4, 0.9))
	_rim.light_energy = float(rim.get("energy", 0.8))
	_rim.light_volumetric_fog_energy = 0.0
	add_child(_rim)
	_base.key_energy = float(key.get("energy", 2.0))
	_base.rim_energy = _rim.light_energy

# --- Per frame ------------------------------------------------------------------

## Called once per render frame after runtime.advance(). Everything is a
## function of reaction channels (already smoothed, frame-rate independent)
## and delta-scaled integrators.
func update(delta: float) -> void:
	if not attached or runtime == null or runtime.camera == null: return
	var mapper = ReactivityServiceScript.instance().mapper
	var levels := {}
	for channel in ["pulse", "accent", "impact", "anticipation", "swell", "calm", "sparkle"]:
		levels[channel] = clampf(mapper.effect(channel), 0.0, 2.0)
	var reactions: Dictionary = profile.get("reactions", {})
	_last_delta = delta
	# Phase 4d: characters first (display-only offsets on top of the sim), then
	# the camera, so the rim light and particles below follow both.
	if animator != null: animator.update(ReactivityServiceScript.instance().hub.frame, mapper)
	if director != null: _direct(mapper)
	_sync_materials(delta, levels)
	# Key light: the original light0 colour after Brightness/Strobe/Coloured Lighting.
	var terms: Dictionary = runtime.current_light_terms()
	var color: Color = terms.get("diffuse", Color.WHITE)
	_hue = lerpf(_hue, levels.accent * float(reactions.get("key_hue_accent", 0.0)), 1.0 - exp(-delta / 0.25)) if delta > 0.0 else _hue
	if _hue > 0.001: color = Color.from_hsv(fposmod(color.h + _hue, 1.0), color.s, color.v) if color.s > 0.05 else color.lerp(Color(1.0, 0.75, 1.0), _hue * 4.0)
	var lights_on: bool = (int(runtime.get_style_flags()) & StyleFlags.LIGHTS) != 0
	_key.visible = lights_on
	_key.light_color = Color(minf(color.r, 1.0), minf(color.g, 1.0), minf(color.b, 1.0))
	_key.light_energy = float(_base.key_energy) * maxf(color.get_luminance(), 0.2) / maxf(Color(_key.light_color).get_luminance(), 0.2) * (1.0 + levels.swell * float(reactions.get("key_energy_swell", 0.0)) + levels.pulse * float(reactions.get("key_energy_pulse", 0.0)))
	# Rim light stays behind the subject relative to the orbiting camera.
	var rim_config: Dictionary = profile.get("lights", {}).get("rim", {})
	var relative: Array = rim_config.get("camera_relative", [0.0, 0.25, -1.0])
	var camera_basis: Basis = runtime.camera.global_transform.basis
	var toward_camera: Vector3 = camera_basis * Vector3(relative[0], relative[1], -float(relative[2]))
	# A DirectionalLight shines along its -Z: point it from behind the subject
	# toward the camera so it only grazes silhouettes.
	if toward_camera.length_squared() > 1e-6: _rim.basis = Basis.looking_at(toward_camera.normalized(), Vector3.UP if absf(toward_camera.normalized().y) < 0.99 else Vector3.BACK)
	_rim.light_energy = float(_base.rim_energy) * (1.0 + levels.swell * float(reactions.get("rim_swell", 0.0)))
	# Fog breathes with calm passages and thickens into a drop.
	var fog: float = float(_base.fog) * (1.0 + levels.calm * float(reactions.get("fog_calm", 0.0)) + levels.anticipation * float(reactions.get("fog_anticipation", 0.0)) - 0.5 * levels.impact)
	if _environment.volumetric_fog_enabled: _environment.volumetric_fog_density = maxf(fog, 0.0)
	else: _environment.fog_density = maxf(fog, 0.0)
	# Big reactions only on impact (drops).
	_environment.glow_intensity = float(_base.glow) * (1.0 + levels.impact * float(reactions.get("glow_impact", 0.0)))
	_environment.tonemap_exposure = float(_base.exposure) * (1.0 + levels.impact * float(reactions.get("exposure_impact", 0.0)))
	if _atmosphere != null: _atmosphere.update(delta, levels, reactions)
	if _fx != null: _fx.update(maxf(delta, 1e-4), levels.sparkle, levels.pulse, levels.impact if bool(effects.get("post", true)) else 0.0)

func _on_impact(strength: float, _kind: String) -> void:
	if _fx != null: _fx.burst(strength * float(ReactivityServiceScript.instance().mapper.effects_intensity))

## For offline captures: pre-warm particles; returns frames to render before
## the image is stable (TAA, temporal volumetric fog, SDFGI convergence).
func settle() -> int:
	if _fx != null:
		for child in _fx.get_children():
			if child is GPUParticles3D and not child.one_shot:
				child.preprocess = child.lifetime
				child.restart()
	return 45 if _row.get("gi", "") == "sdfgi" else 20

func describe() -> Dictionary:
	return {"attached": attached, "profile": str(profile.get("name", "")), "quality": quality, "effects": effects.duplicate(),
		"camera_mode": camera_mode, "director": director.describe() if director != null else {}}

# --- Director and character animation (Phase 4d) ---------------------------------
# docs/DIRECTOR_AND_ANIMATION.md. Both only write display transforms after the
# runtime's present(); the runtime re-presents its own sim transforms every
# frame and never reads node transforms back.

## Give up the director and animator (and the camera bookkeeping) without
## restoring anything; the next layer on the same runtime continues them.
func take_motion() -> Dictionary:
	if not attached: return {}
	var out := {"runtime": runtime, "director": director, "animator": animator, "camera_base": _camera_base,
		"camera_written": _camera_written, "saved_fov": _saved_fov, "dof": _dof.duplicate()}
	if animator != null: animator.disconnect_mapper()
	director = null
	animator = null
	_camera_written = null
	return out

func _build_director_and_animation(mapper) -> void:
	if not handoff.is_empty() and handoff.get("runtime") == runtime:
		director = handoff.director
		animator = handoff.animator
		_camera_base = handoff.camera_base
		_camera_written = handoff.camera_written
		_saved_fov = float(handoff.saved_fov)
		_dof = handoff.dof
		if animator != null: animator.connect_mapper(mapper)
		handoff = {}
		return
	handoff = {}
	var config: Dictionary = profile.get("director", {})
	var center_array: Array = config.get("center", [0.0, 0.0, 0.0])
	var world: Transform3D = runtime.camera.get_parent().global_transform
	var center: Vector3 = world * Vector3(center_array[0], center_array[1], center_array[2])
	_saved_fov = runtime.camera.fov
	_camera_base = runtime.camera.transform
	_camera_written = null
	var dof: Dictionary = profile.get("effects", {}).get("dof", {})
	_dof = {"far": float(dof.get("far_distance", 14.0)), "transition": float(dof.get("far_transition", 10.0)), "amount": float(dof.get("amount", 0.06)),
		"default_far": float(dof.get("far_distance", 14.0)), "default_transition": float(dof.get("far_transition", 10.0)), "default_amount": float(dof.get("amount", 0.06)),
		"closeup_amount": float(dof.get("closeup_amount", 0.09))}
	if profile.has("animation"):
		animator = CharacterAnimator.new()
		if animator.setup(runtime, profile.animation, center): animator.connect_mapper(mapper)
		else: animator = null
	if config.is_empty(): return
	director = VirtualDirector.new()
	director.configure(config)
	director.mode = camera_mode
	director.comfort.guard = _build_guard(config.get("guard", {}), center)

func _build_guard(config: Dictionary, center: Vector3) -> Dictionary:
	var clearance := float(config.get("clearance", runtime.camera.near + 0.15))
	var guard := {"center": center, "max_radius": float(config.get("max_radius", INF)), "min_y": float(config.get("min_y", -INF)),
		"max_y": float(config.get("max_y", INF)), "boxes": [], "spheres": [], "sphere_objects": [], "clearance": clearance}
	for object_name in config.get("boxes", []):
		var entry: Dictionary = runtime.object_named(str(object_name))
		if entry.is_empty() or entry.node == null: continue
		guard.boxes.append((entry.node.global_transform * entry.node.mesh.get_aabb()).grow(clearance))
	for object_name in config.get("spheres", []):
		var entry: Dictionary = runtime.object_named(str(object_name))
		if entry.is_empty() or entry.node == null: continue
		var box: AABB = entry.node.global_transform * entry.node.mesh.get_aabb()
		var radius := maxf(box.size.x, maxf(box.size.y, box.size.z)) * 0.5 + clearance
		guard.spheres.append({"center": box.get_center(), "radius": radius, "name": str(object_name)})
	return guard

## Scene context for the director: centre, live (simulated) head centres, and the original camera.
func _director_context() -> Dictionary:
	var camera: Camera3D = runtime.camera
	var world: Transform3D = camera.get_parent().global_transform
	var look: Array = runtime.data.camera.get("LookAt", [0, 0, 0])
	var targets := {}
	if animator != null: targets = animator.sim_centers()
	for name in profile.get("director", {}).get("subjects", []):
		if targets.has(name): continue
		var entry: Dictionary = runtime.object_named(str(name))
		if not entry.is_empty() and entry.node != null: targets[name] = entry.node.global_transform * entry.node.mesh.get_aabb().get_center()
	var guard: Dictionary = director.comfort.guard
	for sphere in guard.get("spheres", []):
		if targets.has(sphere.name): sphere.center = targets[sphere.name]
	return {"center": guard.get("center", Vector3.ZERO), "targets": targets,
		"original": {"position": (world * _camera_base).origin, "target": world * Vector3(look[0], look[1], look[2]), "fov": _saved_fov}}

func _direct(mapper) -> void:
	var camera: Camera3D = runtime.camera
	# A camera still holding our last pose was not re-presented (paused): keep the base.
	if _camera_written == null or camera.transform != _camera_written: _camera_base = camera.transform
	if director.mode != camera_mode:
		director.mode = camera_mode
		director.reset()
	var pose: Dictionary = director.update(ReactivityServiceScript.instance().hub.frame, mapper, _director_context())
	if pose.is_empty():
		if _camera_written != null:
			camera.transform = _camera_base
			_camera_written = null
		camera.fov = _saved_fov
		_apply_focus(-1.0)
		return
	var position: Vector3 = pose.position
	var target: Vector3 = pose.target
	var direction := target - position
	if direction.length_squared() < 1e-6: target = position + Vector3.FORWARD
	elif absf(direction.normalized().y) > 0.995: target += Vector3(0.0, 0.0, 0.1 * direction.length())
	# World up keeps the horizon level: no roll.
	camera.global_transform = Transform3D(Basis.IDENTITY, position).looking_at(target, Vector3.UP)
	_camera_written = camera.transform
	camera.fov = clampf(float(pose.fov), 20.0, 80.0)
	_apply_focus(float(pose.get("focus", -1.0)))

## DoF follows the subject on close-ups (far blur just behind it); otherwise the profile's far DoF.
func _apply_focus(focus: float) -> void:
	var attributes := runtime.camera.attributes as CameraAttributesPractical
	if attributes == null or not attributes.dof_blur_far_enabled or _dof.is_empty(): return
	var far := focus + 0.9 if focus > 0.0 else float(_dof.default_far)
	var transition := 2.2 if focus > 0.0 else float(_dof.default_transition)
	var amount := float(_dof.closeup_amount) if focus > 0.0 else float(_dof.default_amount)
	var k := 1.0 - exp(-maxf(_last_delta, 0.0) / 0.35) if _last_delta > 0.0 else 1.0
	_dof.far = lerpf(float(_dof.far), far, k)
	_dof.transition = lerpf(float(_dof.transition), transition, k)
	_dof.amount = lerpf(float(_dof.amount), amount, k)
	attributes.dof_blur_far_distance = float(_dof.far)
	attributes.dof_blur_far_transition = float(_dof.transition)
	attributes.dof_blur_amount = float(_dof.amount)
