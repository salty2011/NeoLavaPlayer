extends Node3D
## Optional Modern effects (each toggleable): audio-driven motes around the
## heads (rate from sparkle/pulse, burst on impact), light trails behind moving
## heads, and the impact-only lens pass (chromatic aberration + radial blur).
## Particles are world-space and only follow the head nodes' positions; they
## never read or write simulation state.

const PostShader = preload("res://modern/modern_post.gdshader")

var _emitters: Array = []   # {node: Node3D, motes, burst, trail, last: Vector3}
var _post: MeshInstance3D
var _post_material: ShaderMaterial
var _config: Dictionary = {}
var particles_on := true
var trails_on := true
var post_on := true
var scale_amount := 1.0

func build(runtime, profile: Dictionary, row: Dictionary, toggles: Dictionary) -> void:
	_config = profile.get("effects", {})
	particles_on = bool(toggles.get("particles", true))
	trails_on = bool(toggles.get("trails", true)) and bool(row.get("trails", true))
	post_on = bool(toggles.get("post", true))
	scale_amount = float(row.get("particles", 1.0))
	var particles: Dictionary = _config.get("particles", {})
	var colors: Dictionary = particles.get("colors", {})
	for object_name in particles.get("emitters", []):
		var entry: Dictionary = runtime.object_named(object_name)
		if entry.is_empty() or entry.node == null: continue
		var color := Color(1, 1, 1)
		var c = colors.get(object_name)
		if c is Array and c.size() >= 3: color = Color(c[0], c[1], c[2])
		var item := {"node": entry.node, "last": entry.node.global_position, "speed": 0.0}
		item.motes = _system(int(float(particles.get("amount", 96)) * scale_amount), 2.2, color, float(particles.get("radius", 0.7)), 0.0, 0.035, 2.5)
		item.burst = _system(int(float(particles.get("burst", 160)) * scale_amount), 1.4, color, 0.35, 1.0, 0.05, 6.0)
		item.burst.one_shot = true
		item.burst.emitting = false
		var trail_config: Dictionary = _config.get("trails", {})
		item.trail = _system(int(trail_config.get("amount", 64)), float(trail_config.get("lifetime", 0.7)), color.lerp(Color.WHITE, 0.3), 0.15, 0.0, 0.03, 0.0)
		item.motes.visible = particles_on
		item.burst.visible = particles_on
		item.trail.visible = trails_on
		_emitters.append(item)
	_post = MeshInstance3D.new()
	_post.name = "ModernPost"
	var quad := QuadMesh.new()
	quad.size = Vector2(1, 1)
	_post.mesh = quad
	_post_material = ShaderMaterial.new()
	_post_material.shader = PostShader
	_post_material.render_priority = -128
	var post: Dictionary = _config.get("post", {})
	_post_material.set_shader_parameter("chromatic", float(post.get("chromatic", 0.0045)))
	_post_material.set_shader_parameter("motion_blur", float(post.get("motion_blur", 0.035)))
	_post.material_override = _post_material
	_post.extra_cull_margin = 16384.0
	_post.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_post.visible = false
	add_child(_post)

func _system(amount: int, lifetime: float, color: Color, radius: float, explosiveness: float, size: float, speed: float) -> GPUParticles3D:
	var system := GPUParticles3D.new()
	system.amount = maxi(amount, 1)
	system.lifetime = lifetime
	system.explosiveness = explosiveness
	system.local_coords = false
	system.fixed_fps = 0
	system.interpolate = true
	system.visibility_aabb = AABB(Vector3(-6, -6, -6), Vector3(12, 12, 12))
	system.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE_SURFACE if explosiveness == 0.0 and speed > 0.0 else ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = radius
	process.direction = Vector3(0, 1, 0)
	process.spread = 180.0 if explosiveness > 0.0 else 35.0
	process.initial_velocity_min = speed * 0.4
	process.initial_velocity_max = speed
	process.gravity = Vector3(0, 0.25 if explosiveness == 0.0 else -0.6, 0)
	process.damping_min = 1.0
	process.damping_max = 2.5
	var curve := Curve.new()
	curve.add_point(Vector2(0, 0))
	curve.add_point(Vector2(0.15, 1))
	curve.add_point(Vector2(1, 0))
	var curve_texture := CurveTexture.new()
	curve_texture.curve = curve
	process.scale_curve = curve_texture
	process.scale_min = 0.6
	process.scale_max = 1.4
	system.process_material = process
	var mesh := QuadMesh.new()
	mesh.size = Vector2(size, size)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	material.vertex_color_use_as_albedo = true
	material.albedo_color = Color(color.r * 3.0, color.g * 3.0, color.b * 3.0, 1.0)
	material.albedo_texture = _soft_dot()
	material.disable_receive_shadows = true
	material.no_depth_test = false
	mesh.material = material
	system.draw_pass_1 = mesh
	add_child(system)
	return system

static var _dot: Texture2D
static func _soft_dot() -> Texture2D:
	if _dot != null: return _dot
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1, 1, 1, 1))
	gradient.set_color(1, Color(1, 1, 1, 0))
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(0.5, 0.0)
	texture.width = 64
	texture.height = 64
	_dot = texture
	return _dot

## Per render frame; channels are already effects-intensity scaled.
func update(delta: float, sparkle: float, pulse: float, impact: float) -> void:
	for item in _emitters:
		var node: Node3D = item.node
		if not is_instance_valid(node): continue
		var position: Vector3 = node.global_position
		var moved: float = position.distance_to(item.last)
		item.speed = lerpf(item.speed, moved / maxf(delta, 1e-4), 1.0 - exp(-delta / 0.15))
		item.last = position
		for key in ["motes", "burst", "trail"]: item[key].global_position = position
		item.motes.amount_ratio = clampf(0.15 + 0.55 * sparkle + 0.45 * pulse, 0.0, 1.0)
		item.motes.emitting = particles_on
		item.trail.amount_ratio = clampf(item.speed / 2.5, 0.0, 1.0)
		item.trail.emitting = trails_on and item.speed > 0.05
	_post.visible = post_on and impact > 0.01
	_post_material.set_shader_parameter("strength", impact)

func burst(strength: float) -> void:
	if not particles_on: return
	for item in _emitters:
		item.burst.amount_ratio = clampf(strength, 0.2, 1.0)
		item.burst.restart()
		item.burst.emitting = true
