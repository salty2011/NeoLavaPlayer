extends RefCounted
## Scene-specific adapter for the recovered Triple Trance fixed-function path.
const VertexShader = preload("res://legacy_vertex_lighting.gdshader")
static func create(record: Dictionary, control: StandardMaterial3D, scene: Dictionary) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	if str(record.material.get("culling", "back")).to_lower() == "none":
		var shader := Shader.new()
		shader.code = VertexShader.code.replace("cull_back", "cull_disabled")
		material.shader = shader
	else: material.shader = VertexShader
	var ambient := _rgb(record.material.get("color_bytes", [255,255,255,255]))
	material.set_shader_parameter("material_ambient", ambient)
	# Lava3 display mesh0x10022d2e sets format0x1f: vertex color drives
	# GL_AMBIENT_AND_DIFFUSE, not diffuse alone.
	material.set_shader_parameter("vertex_ambient", true)
	material.set_shader_parameter("material_specular", _rgb(record.material.get("specular_bytes", [0,0,0,255])))
	material.set_shader_parameter("shininess", clampf(float(record.material.get("gloss",0)),0,128))
	material.set_shader_parameter("lighting_enabled", int(record.get("EnableLighting","1")) != 0)
	material.set_shader_parameter("has_texture", control.albedo_texture != null)
	if control.albedo_texture != null: material.set_shader_parameter("scene_texture",control.albedo_texture)
	for command in scene.lighting:
		if int(command.index) != 0: continue
		var values: Array = command.value
		if command.property == "Position": material.set_shader_parameter("light_position",Vector4(values[0],values[1],values[2],values[3]))
		elif command.property == "Diffuse":
			var color := Vector3(values[0],values[1],values[2])
			material.set_shader_parameter("light_diffuse", color)
			material.set_shader_parameter("light_specular", color)
			material.set_shader_parameter("light_ambient", color * float(scene.header.get("Brightness",1.0)))
	sync(material, control)
	return material

static func sync(material: ShaderMaterial, control: StandardMaterial3D):
	var color := control.albedo_color
	material.set_shader_parameter("material_diffuse", Vector4(color.r,color.g,color.b,color.a))

## Live light terms (Brightness, Strobe, Colored Lighting; legacy_light_fx.gd).
static func set_light(material: ShaderMaterial, diffuse: Color, ambient: Color):
	material.set_shader_parameter("light_diffuse", Vector3(diffuse.r, diffuse.g, diffuse.b))
	material.set_shader_parameter("light_specular", Vector3(diffuse.r, diffuse.g, diffuse.b))
	material.set_shader_parameter("light_ambient", Vector3(ambient.r, ambient.g, ambient.b))

static func _rgb(values: Array) -> Vector3:
	return Vector3(values[0],values[1],values[2]) / 255.0
