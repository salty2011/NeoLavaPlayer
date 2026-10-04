extends Node3D
## Scene atmosphere for Modern profiles (Phase 4f): the procedural sky's sun
## and cloud drift, low height-limited fog volumes, and ambient particles
## (pollen, bubbles, dust, embers). Everything is display-only and driven by
## ReactivityService channels or delta integrators; nothing here reads or
## writes simulation state.
##
## Profile keys (all optional):
##   environment.sky            - see modern_sky.gdshader; "cloud_speed": [u, v] units/s
##   lights.key.type            - "directional" makes the key a sun; sky.sun_dir then follows it
##   atmosphere.fog_volumes[]   - {center, size, density, albedo, emission, falloff, edge}
##   atmosphere.particles[]     - {name, center, extents, amount, lifetime, size, color,
##                                 energy, velocity, spread, turbulence, gravity, blend,
##                                 base, sparkle, pulse, impact}

const ModernEffects = preload("res://modern/modern_effects.gd")

var _sky: ShaderMaterial
var _sky_config: Dictionary = {}
var _cloud := Vector2.ZERO
var _sun_base := 1.0
var _systems: Array = []     # {node, config}
var _fog: Array = []         # {node: FogVolume, base: float}
var _particles_on := true
var _scale := 1.0

func build(profile: Dictionary, row: Dictionary, toggles: Dictionary, environment: Environment, key: Light3D) -> void:
	name = "ModernAtmosphere"
	_particles_on = bool(toggles.get("particles", true))
	_scale = float(row.get("particles", 1.0))
	_sky_config = profile.get("environment", {}).get("sky", {})
	if environment != null and environment.sky != null and environment.sky.sky_material is ShaderMaterial:
		_sky = environment.sky.sky_material
		_sun_base = float(_sky_config.get("sun_energy", 6.0))
		if key is DirectionalLight3D and bool(_sky_config.get("sun_from_key", true)):
			_sky.set_shader_parameter("sun_dir", -key.global_transform.basis.z)
	var atmosphere: Dictionary = profile.get("atmosphere", {})
	if str(row.get("fog", "")) == "volumetric":
		for config in atmosphere.get("fog_volumes", []): _add_fog(config)
	for config in atmosphere.get("particles", []): _add_particles(config)

func _color(values, fallback := Color.WHITE) -> Color:
	if values is Array and values.size() >= 3: return Color(float(values[0]), float(values[1]), float(values[2]))
	return fallback

func _vec(values, fallback := Vector3.ZERO) -> Vector3:
	if values is Array and values.size() >= 3: return Vector3(float(values[0]), float(values[1]), float(values[2]))
	return fallback

func _add_fog(config: Dictionary) -> void:
	var volume := FogVolume.new()
	volume.shape = RenderingServer.FOG_VOLUME_SHAPE_BOX
	volume.size = _vec(config.get("size"), Vector3(30, 2, 30))
	volume.position = _vec(config.get("center"), Vector3.ZERO)
	var material := FogMaterial.new()
	material.density = float(config.get("density", 0.05))
	material.albedo = _color(config.get("albedo"), Color(0.9, 0.95, 1.0))
	material.emission = _color(config.get("emission"), Color.BLACK)
	material.height_falloff = float(config.get("falloff", 0.5))
	material.edge_fade = float(config.get("edge", 0.3))
	volume.material = material
	add_child(volume)
	_fog.append({"node": volume, "base": material.density, "swell": float(config.get("swell", 0.0)), "anticipation": float(config.get("anticipation", 0.0))})

func _add_particles(config: Dictionary) -> void:
	var system := GPUParticles3D.new()
	system.name = str(config.get("name", "ambient"))
	var amount := maxi(int(float(config.get("amount", 100)) * _scale), 1)
	system.amount = amount
	system.lifetime = float(config.get("lifetime", 6.0))
	system.preprocess = system.lifetime
	system.local_coords = false
	system.fixed_fps = 0
	system.interpolate = true
	var extents := _vec(config.get("extents"), Vector3(8, 2, 8))
	system.position = _vec(config.get("center"), Vector3.ZERO)
	system.visibility_aabb = AABB(-extents - Vector3.ONE * 4.0, (extents + Vector3.ONE * 4.0) * 2.0)
	system.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.emission_box_extents = extents
	var velocity := _vec(config.get("velocity"), Vector3(0, 0.2, 0))
	process.direction = velocity.normalized() if velocity.length() > 1e-4 else Vector3.UP
	process.spread = float(config.get("spread", 40.0))
	process.initial_velocity_min = velocity.length() * 0.5
	process.initial_velocity_max = velocity.length()
	process.gravity = _vec(config.get("gravity"), Vector3.ZERO)
	var turbulence := float(config.get("turbulence", 0.0))
	if turbulence > 0.0:
		process.turbulence_enabled = true
		process.turbulence_noise_strength = turbulence
		process.turbulence_noise_scale = float(config.get("turbulence_scale", 2.5))
		process.turbulence_influence_min = 0.05
		process.turbulence_influence_max = 0.25
	var curve := Curve.new()
	curve.add_point(Vector2(0, 0))
	curve.add_point(Vector2(0.2, 1))
	curve.add_point(Vector2(0.8, 1))
	curve.add_point(Vector2(1, 0))
	var curve_texture := CurveTexture.new()
	curve_texture.curve = curve
	process.scale_curve = curve_texture
	process.scale_min = float(config.get("scale_min", 0.5))
	process.scale_max = float(config.get("scale_max", 1.5))
	system.process_material = process
	var size := float(config.get("size", 0.05))
	var mesh := QuadMesh.new()
	mesh.size = Vector2(size, size)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var blend := str(config.get("blend", "add"))
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if blend == "add" else BaseMaterial3D.BLEND_MODE_MIX
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	material.vertex_color_use_as_albedo = true
	var color := _color(config.get("color"))
	var energy := float(config.get("energy", 2.0))
	material.albedo_color = Color(color.r * energy, color.g * energy, color.b * energy, float(config.get("alpha", 1.0)))
	material.albedo_texture = ModernEffects._soft_dot()
	material.disable_receive_shadows = true
	mesh.material = material
	system.draw_pass_1 = mesh
	add_child(system)
	system.visible = _particles_on
	_systems.append({"node": system, "config": config})

## Per render frame. `levels` are the layer's channel levels (effects-intensity scaled).
func update(delta: float, levels: Dictionary, reactions: Dictionary) -> void:
	if _sky != null and delta > 0.0:
		var speed = _sky_config.get("cloud_speed", [0.004, 0.0015])
		var swell := 1.0 + float(levels.get("swell", 0.0)) * float(reactions.get("cloud_speed_swell", 0.0))
		_cloud += Vector2(float(speed[0]), float(speed[1])) * delta * swell
		_sky.set_shader_parameter("cloud_offset", _cloud)
		var sun := _sun_base * (1.0 + float(levels.get("swell", 0.0)) * float(reactions.get("sun_swell", 0.0)) + float(levels.get("impact", 0.0)) * float(reactions.get("sun_impact", 0.0)))
		_sky.set_shader_parameter("sun_energy", sun)
	for item in _fog:
		var material: FogMaterial = item.node.material
		material.density = float(item.base) * (1.0 + float(levels.get("anticipation", 0.0)) * float(item.anticipation) + float(levels.get("swell", 0.0)) * float(item.swell) - 0.5 * float(levels.get("impact", 0.0)))
	for item in _systems:
		var config: Dictionary = item.config
		var ratio := float(config.get("base", 0.6)) + float(levels.get("sparkle", 0.0)) * float(config.get("sparkle", 0.4)) + float(levels.get("pulse", 0.0)) * float(config.get("pulse", 0.0)) + float(levels.get("impact", 0.0)) * float(config.get("impact", 0.0))
		item.node.amount_ratio = clampf(ratio, 0.05, 1.0)
		item.node.emitting = _particles_on
