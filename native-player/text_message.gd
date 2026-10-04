extends Node3D
## 3D text message ("Message" in the original Tray; M toggles it).
##
## Evidence (static; full notes in docs/ENGINE_API.md, "3D text message"):
## - ASHEX header text block = 8 properties in LavaFile reader order
##   (0x1001b651..0x1001b933): Enable 0x94, Message 0x133, Size 0xdd,
##   Weight 0xe2, Italics 0xf3, Color 0x1e5 (RGBA bytes), Extrusion 0xdc,
##   Font 0xe1. SetTextInfo 0x10017000 writes the same set.
## - Glyphs: LAVARndr 0x10006fa0 builds LOGFONT(height -10, weight, italic,
##   DEFAULT_CHARSET, face or "Times") and wglUseFontOutlinesA(format
##   WGL_FONT_POLYGONS, extrusion) per glyph -> extruded polygon glyphs in em
##   units, extruded toward -Z.
## - Layout: text draw 0x10027ce0..0x1002818c (fields from the TextDeform
##   preset: TextMode +0x2f0, TextRadius +0x2f4, Offset +0x2f8, SizeXYZ +0x314,
##   header Size +0x320, ViewFromInsideText +0x324, colour +0x304):
##     W = sum of glyph advances (gmfCellIncX, em units)
##     mode 0: T(offX, offY, offZ + 0.5*SY*S*W*SX*S) * Rz(90) * Scale(S*SXYZ) * string
##     mode 1/2, per glyph i (rotation accumulates outside push/pop):
##       a_i = SX*S*adv_{i-1}*57.2958/R + extra   (adv_{-1} = 0; negated if inside)
##       M = M * Ry(a_i)
##       glyph = M * T(R,0,0) * T(offset) * Scale(S*SXYZ) * Ry(inside ? -84 : 96)
##     mode 2: extra = 360*(1 - W*SX*S/(2*pi*R))/n, mode 1: extra = 0.
## - Animation: DefMsgRot is the DefRotate class (factory branch 0x1001c381,
##   ctor 0x1000e530); DefMsgAlpha is the DefAlpha class (0x1001c3b2).
## - Material (0x10027cf7..0x10027d91): diffuse = text colour, specular via
##   (1,1,1,1), shininess 10, ambient from a renderer default (assumed GL
##   default 0.2 here, inferred).
## Best-evidence, labelled inferred: the rotation axis (DoX/DoY/DoZ), the
## RotateX/Y/Z read as a start angle about the spin axis only (no tilt), the
## glyph baseline placement of Godot TextMesh, and Parent following only the
## parent's position/rotation.
const LegacyEffect = preload("res://legacy_effect.gd")
const AlphaCenterEffects = preload("res://alpha_center_effects.gd")
const VertexShader = preload("res://legacy_vertex_lighting.gdshader")
const FONT_PX := 64
const EM_SCALE := 1.0 / FONT_PX

var enabled := false
var message := ""
var size := 1.0
var weight := 400
var italic := false
var color := Color(1, 1, 1, 1)
var extrusion := 0.1
var font_name := "Arial"
var layout := {"TextMode": 1.0, "TextRadius": 2.0, "ViewFromInsideText": 0.0, "OffsetX": 0.0, "OffsetY": 0.0, "OffsetZ": 0.0, "SizeX": 1.0, "SizeY": 1.0, "SizeZ": 1.0, "RotateX": 0.0, "RotateY": 0.0, "RotateZ": 0.0}
var deforms: Array = []   # {kind, preset, file, state}
var parent_name := ""
var alpha := 1.0
var source := "none"
var _runtime
var _ring: Node3D
var _material: ShaderMaterial
var _font: SystemFont
var _previous := Transform3D.IDENTITY
var _current := Transform3D.IDENTITY
var _style := 0

func build(scene: Dictionary, runtime) -> void:
	_runtime = runtime
	_read_header(scene)
	for line in scene.get("text_deforms", []):
		var words: PackedStringArray = str(line).replace("\t", " ").split(" ", false)
		if words.size() >= 4 and words[1] == "Load": _load_deform(scene, words[2], int(words[3]))
		elif words.size() >= 3 and words[1] == "Parent": parent_name = words[2]
	for deform in deforms:
		for key in layout:
			if deform.preset.has(key): layout[key] = float(deform.preset[key])
	_material = ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = VertexShader.code.replace("cull_back", "cull_disabled").replace("ALBEDO = lit.rgb * texel.rgb;", "ALBEDO = lit.rgb * texel.rgb;\n ALPHA = lit.a;")
	_material.shader = shader
	_material.set_shader_parameter("vertex_ambient", false)
	_material.set_shader_parameter("material_ambient", Vector3(0.2, 0.2, 0.2))
	_material.set_shader_parameter("material_specular", Vector3.ONE)
	_material.set_shader_parameter("shininess", 10.0)
	_material.set_shader_parameter("has_texture", false)
	for command in scene.get("lighting", []):
		if int(command.index) == 0 and command.property == "Position":
			var v: Array = command.value
			_material.set_shader_parameter("light_position", Vector4(v[0], v[1], v[2], v[3]))
	_font = SystemFont.new()
	_font.font_names = PackedStringArray([font_name, "Arial", "Helvetica", "sans-serif"])
	_font.font_weight = clampi(weight, 100, 999)
	_font.font_italic = italic
	_ring = Node3D.new()
	_ring.name = "Ring"
	add_child(_ring)
	_rebuild_glyphs()
	_update_material()
	visible = enabled

func _read_header(scene: Dictionary) -> void:
	var header: Dictionary = scene.get("header", {})
	if header.has("message_raw") and header.message_raw is Array and header.message_raw.size() >= 8:
		var raw: Array = header.message_raw
		enabled = int(str(raw[0]).to_float()) != 0
		message = str(raw[1])
		size = str(raw[2]).to_float()
		weight = int(str(raw[3]).to_float())
		italic = int(str(raw[4]).to_float()) != 0
		var rgba := str(raw[5]).split(" ", false)
		if rgba.size() >= 4: color = Color(rgba[0].to_float() / 255.0, rgba[1].to_float() / 255.0, rgba[2].to_float() / 255.0, rgba[3].to_float() / 255.0)
		extrusion = str(raw[6]).to_float()
		font_name = str(raw[7]) if not str(raw[7]).is_empty() else "Times"
		source = "ASHEX header"
	elif header.has("MsgOn") or header.has("MsgIni"):
		enabled = int(str(header.get("MsgOn", "0")).to_float()) != 0
		_read_text_ini(scene, str(header.get("MsgIni", "Text.ini")))

## Oozic 3 Text.ini: [Message] 0=<text>, [Data] 0=Font;Italic;R;G;B;A;Weight;Size;Extrusion;...
## Field meaning inferred from the ASHEX property set (values line up).
func _read_text_ini(scene: Dictionary, filename: String) -> void:
	var path := ""
	for file in scene.get("files", []):
		if str(file).to_lower() == filename.to_lower(): path = str(scene.folder).path_join(str(file))
	if path.is_empty(): return
	var section := ""
	for raw_line in FileAccess.get_file_as_string(path).replace("\r", "").split("\n"):
		var line := raw_line.strip_edges()
		if line.begins_with("["): section = line; continue
		if not line.begins_with("0="): continue
		var value := line.substr(2)
		if section == "[Message]": message = value.strip_edges()
		elif section == "[Data]":
			var fields := value.split(";")
			if fields.size() >= 9:
				font_name = fields[0]
				italic = fields[1].to_int() != 0
				color = Color(fields[2].to_float() / 255.0, fields[3].to_float() / 255.0, fields[4].to_float() / 255.0, fields[5].to_float() / 255.0)
				weight = fields[6].to_int()
				size = fields[7].to_float()
				extrusion = fields[8].to_float()
	source = "Oozic 3 " + filename

func _load_deform(scene: Dictionary, filename: String, preset_index: int) -> void:
	var path := ""
	for file in scene.get("files", []):
		if str(file).to_lower() == filename.to_lower(): path = str(scene.folder).path_join(str(file))
	if path.is_empty(): return
	var kind := ""
	var presets := {}
	var current := -1
	for raw_line in FileAccess.get_file_as_string(path).replace("\r", "").split("\n"):
		var line := raw_line.strip_edges()
		if line.is_empty() or line.begins_with("#"): continue
		var split := line.find("\t")
		if split < 0: split = line.find(" ")
		if split < 0: continue
		var key := line.left(split)
		var value := line.substr(split + 1).strip_edges()
		if key == "DefType": kind = value
		elif key == "Preset": current = value.to_int(); presets[current] = {}
		elif current >= 0: presets[current][key] = value.to_float()
	var preset: Dictionary = presets.get(preset_index, {})
	if preset.has("Interruptlevel"): preset["InteruptLevel"] = preset["Interruptlevel"]
	deforms.append({"kind": kind, "file": filename, "preset": preset, "state": null})

func reset() -> void:
	alpha = 1.0
	for deform in deforms:
		match deform.kind:
			"DefMsgRot":
				deform.state = LegacyEffect.new()
				deform.state.configure(deform.preset)
			"DefMsgAlpha":
				deform.state = AlphaCenterEffects.new()
				deform.state.random_source = Callable(_runtime, "_texture_random") if _runtime != null else Callable()
				deform.state.configure("DefAlpha", deform.preset)
	_current = _compute_transform()
	_previous = _current
	present(1.0)

func _band_a(deform: Dictionary, band_a: Array) -> float:
	var index := int(deform.preset.get("Input1Band", 0))
	if band_a.is_empty(): return 0.0
	if index < 0 or index >= band_a.size(): index = 0
	var value = band_a[index]
	return float(value.get("a", 0.0)) if value is Dictionary else float(value)

## One engine update (dt already scaled by Responsivness).
func step(dt: float, band_a: Array, global_s: float) -> void:
	if dt <= 0.0: return
	for deform in deforms:
		if deform.state == null: continue
		var a := _band_a(deform, band_a)
		match deform.kind:
			"DefMsgRot": deform.state.rotate(dt, a, global_s)
			"DefMsgAlpha": alpha = float(deform.state.update(dt, a, global_s).alpha)
	_previous = _current
	_current = _compute_transform()

func _compute_transform() -> Transform3D:
	var basis := Basis.IDENTITY
	for deform in deforms:
		if deform.kind != "DefMsgRot" or deform.state == null: continue
		var axis := Vector3(float(deform.preset.get("DoX", 0.0)), float(deform.preset.get("DoY", 1.0)), float(deform.preset.get("DoZ", 0.0)))
		if axis.is_zero_approx(): axis = Vector3.UP
		basis = basis * Basis(axis.normalized(), deg_to_rad(float(deform.state.angle)))
	# RotateX/Y/Z do not tilt the ring: scenes whose text clearly circles an
	# upright subject (LVT2's well, Music Metropolis, Lost Road Rave) carry
	# RotateX = +-270, which as a tilt would stand the ring on end. Only the
	# component about the spin axis is kept, as a starting angle. Inferred.
	var fixed := Basis.IDENTITY
	for deform in deforms:
		if deform.kind != "DefMsgRot": continue
		var spin := Vector3(float(deform.preset.get("DoX", 0.0)), float(deform.preset.get("DoY", 1.0)), float(deform.preset.get("DoZ", 0.0)))
		if spin.is_zero_approx(): spin = Vector3.UP
		spin = spin.normalized()
		var start := spin.dot(Vector3(layout.RotateX, layout.RotateY, layout.RotateZ))
		fixed = Basis(spin, deg_to_rad(start))
		break
	return Transform3D(basis * fixed, Vector3.ZERO)

func present(weight_alpha: float) -> void:
	if _ring == null: return
	var local := Transform3D(Basis(_previous.basis.get_rotation_quaternion().slerp(_current.basis.get_rotation_quaternion(), weight_alpha)), Vector3.ZERO)
	var parent_transform := Transform3D.IDENTITY
	if not parent_name.is_empty() and _runtime != null:
		var parent: Dictionary = _runtime.object_named(parent_name)
		if not parent.is_empty() and parent.node != null:
			var g: Transform3D = parent.node.transform
			parent_transform = Transform3D(g.basis.orthonormalized(), g.origin)
	_ring.transform = parent_transform * local
	if alpha != float(_material.get_meta("alpha", -1.0)):
		_material.set_meta("alpha", alpha)
		_update_material()

func set_enabled(value: bool) -> void:
	enabled = value
	visible = value

func set_text(value: String) -> void:
	message = value
	_rebuild_glyphs()

func apply_style(mask: int) -> void:
	_style = mask
	if _material == null: return
	_material.set_shader_parameter("flat_shading", (mask & 0x80) != 0)
	_material.set_shader_parameter("lighting_enabled", (mask & 0x20) != 0)

func set_light(diffuse: Color, ambient: Color) -> void:
	if _material == null: return
	_material.set_shader_parameter("light_diffuse", Vector3(diffuse.r, diffuse.g, diffuse.b))
	_material.set_shader_parameter("light_specular", Vector3(diffuse.r, diffuse.g, diffuse.b))
	_material.set_shader_parameter("light_ambient", Vector3(ambient.r, ambient.g, ambient.b))

func _update_material() -> void:
	_material.set_shader_parameter("material_diffuse", Vector4(color.r, color.g, color.b, color.a * alpha))

func advance_em(character: String) -> float:
	return _font.get_string_size(character, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_PX).x / FONT_PX

## Rebuilds per-glyph meshes in the original layout (see header).
func _rebuild_glyphs() -> void:
	if _ring == null: return
	for child in _ring.get_children():
		_ring.remove_child(child)
		child.free()
	var count := message.length()
	if count == 0: return
	var sx: float = layout.SizeX * size
	var sy: float = layout.SizeY * size
	var sz: float = layout.SizeZ * size
	var scaling := Basis.from_scale(Vector3(sx, sy, sz))
	var offset := Vector3(layout.OffsetX, layout.OffsetY, layout.OffsetZ)
	var advances := PackedFloat32Array()
	var total := 0.0
	for i in count:
		advances.append(advance_em(message[i]))
		total += advances[i]
	var mode := int(layout.TextMode)
	var inside := float(layout.ViewFromInsideText) != 0.0
	if mode == 0:
		var base := Transform3D(Basis.IDENTITY, Vector3(offset.x, offset.y, offset.z + 0.5 * sy * total * sx)) * Transform3D(Basis(Vector3.BACK, PI / 2.0), Vector3.ZERO) * Transform3D(scaling, Vector3.ZERO)
		var pen := 0.0
		for i in count:
			_add_glyph(message[i], base * Transform3D(Basis.IDENTITY, Vector3(pen, 0, 0)))
			pen += advances[i]
		return
	var radius: float = maxf(float(layout.TextRadius), 0.0001)
	var extra := 0.0
	if mode == 2: extra = (1.0 - total * sx * 0.15915494 / radius) * 360.0 / count
	var accumulated := Transform3D.IDENTITY
	var previous_advance := 0.0
	var turn := deg_to_rad(-84.0 if inside else 96.0)
	for i in count:
		var angle := sx * previous_advance * 57.29578 / radius + extra
		if inside: angle = -angle
		accumulated = accumulated * Transform3D(Basis(Vector3.UP, deg_to_rad(angle)), Vector3.ZERO)
		previous_advance = advances[i]
		var glyph := accumulated * Transform3D(Basis.IDENTITY, Vector3(radius, 0, 0)) * Transform3D(Basis.IDENTITY, offset) * Transform3D(scaling, Vector3.ZERO) * Transform3D(Basis(Vector3.UP, turn), Vector3.ZERO)
		_add_glyph(message[i], glyph)

func _add_glyph(character: String, placement: Transform3D) -> void:
	if character.strip_edges().is_empty(): return
	var mesh := TextMesh.new()
	mesh.text = character
	mesh.font = _font
	mesh.font_size = FONT_PX
	mesh.pixel_size = EM_SCALE
	mesh.depth = maxf(extrusion, 0.0)
	mesh.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	mesh.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = _material
	# wglUseFontOutlines: front face at z=0, extrusion toward -Z.
	node.transform = placement * Transform3D(Basis.IDENTITY, Vector3(0, 0, -extrusion * 0.5))
	_ring.add_child(node)

func summary() -> Dictionary:
	var kinds := []
	for deform in deforms: kinds.append(deform.kind)
	return {"enabled": enabled, "message": message, "source": source, "size": size, "weight": weight, "italic": italic, "color": [color.r8, color.g8, color.b8, color.a8], "extrusion": extrusion, "font": font_name, "deforms": kinds, "layout": layout.duplicate(), "parent": parent_name, "glyphs": _ring.get_child_count() if _ring != null else 0}
