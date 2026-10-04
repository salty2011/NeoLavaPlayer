extends RefCounted
## Lossless schema adapter for recovered ASHEX v2 and LVC v3 scene data.
## Values remain in original units/axes; parent links only come from explicit commands.
var _lines: PackedStringArray
var _cursor := 0
var _result: Dictionary

func read_scene(folder: String) -> Dictionary:
	# Keep virtual res:// addresses inside exported PCKs. Parent traversal used
	# by repository research fixtures alone must resolve to the host filesystem.
	if folder.begins_with("res://") and not folder.trim_prefix("res://").simplify_path().begins_with(".."):
		folder = "res://" + folder.trim_prefix("res://").simplify_path()
	else:
		folder = ProjectSettings.globalize_path(folder).simplify_path()
	_result = {"folder": folder, "objects": [], "camera": {}, "bands": [], "header": {}, "effect_presets": [], "text_deforms": [],
		"lighting": [], "links": [], "commands": [], "unsupported": [], "warnings": [], "errors": [], "files": []}
	var directory := DirAccess.open(folder)
	if directory == null:
		_result.errors.append("Cannot open scene folder")
		return _result
	for filename in directory.get_files(): _result.files.append(filename)
	var composition := _find_file("lava.ashex")
	if composition.is_empty(): composition = _find_file("lava.lvc")
	if composition.is_empty():
		_result.errors.append("Missing ASHEX/LVC composition")
		return _result
	_result.composition_file = composition
	var source := FileAccess.get_file_as_string(folder.path_join(composition))
	_result.raw_source = source
	_lines = source.replace("\\r", "").replace("\\n", "\n").replace("\r", "").split("\n")
	_cursor = 0
	if composition.get_extension().to_lower() == "ashex": _read_ashex()
	else: _read_lvc()
	for object in _result.objects:
		object.engine_position = object.get("engine_position", object.position)
		object.engine_rotation_degrees = object.get("engine_rotation_degrees", object.rotation_degrees)
		object.filelist = []
		for file in object.morphs + [object.material.get("texture", "")]:
			if not file.is_empty(): object.filelist.append(file)
		for effect in object.effects:
			object.filelist.append(effect.file)
			effect.definition = _read_effect(effect.file)
		for file in object.filelist:
			if _find_file(file).is_empty() and file.to_lower() != "hydra.lvo":
				_result.warnings.append("Missing resource: " + object.name + " / " + file)
		if object.morphs.has("hydra.lvo"):
			object.procedural_kind = "HYDRA"
			_result.unsupported.append({"system": "procedural_hydra", "object": object.name, "note": "Engine-created mesh; hydra.lvo intentionally absent"})
		for file in object.morphs:
			var resolved := _find_file(file)
			if not resolved.is_empty():
				var bytes := FileAccess.get_file_as_bytes(folder.path_join(resolved))
				var offset := bytes.decode_u32(2) if bytes.size() >= 6 and bytes[0] == 66 and bytes[1] == 77 else 0
				if offset < bytes.size() and bytes.slice(offset, mini(offset + 4, bytes.size())).get_string_from_ascii().begins_with("BLOB"):
					_result.unsupported.append({"system": "procedural_blob", "object": object.name, "file": file})
	return _result

func _take() -> String:
	if _cursor >= _lines.size():
		_result.errors.append("Unexpected end of composition at line " + str(_cursor + 1))
		return ""
	var value := _lines[_cursor].strip_edges()
	_cursor += 1
	return value

func _numbers(value: String) -> Array:
	var values := []
	for word in value.replace("\t", " ").split(" ", false):
		if word.is_valid_float(): values.append(float(word))
	return values

func _vector(value: String) -> Vector3:
	var values := _numbers(value)
	if values.size() != 3:
		_result.errors.append("Expected vector at line " + str(_cursor) + ": " + value)
		return Vector3.ZERO
	return Vector3(values[0], values[1], values[2])

func _new_object(name: String) -> Dictionary:
	return {"name": name, "morphs": [], "effects": [], "position": Vector3.ZERO,
		"rotation_degrees": Vector3.ZERO, "scale": Vector3.ONE, "material": {}, "raw_fields": [], "parent": ""}

func _read_ashex():
	_result.format = "ASHEX"
	_result.header.version = int(_take())
	_result.header.FramesPerSecond = float(_take())
	_result.header.Brightness = float(_take())
	_result.header.Responsivness = float(_take())
	_result.header.render_mode_raw = _take()
	_result.header.render_flags_raw = _take()
	var object_count := int(_take())
	_result.header.NumObjects = object_count
	_result.header.scene_character_raw = _take()
	var band_count := int(_take())
	if object_count < 0 or object_count > 10000 or band_count < 0 or band_count > 128:
		_result.errors.append("Invalid composition counts")
		return
	for i in range(band_count): _result.bands.append({"min": float(_take()), "max": float(_take())})
	_result.header.message_raw = []
	for i in range(9): _result.header.message_raw.append(_take())
	for i in range(object_count):
		var start := _cursor
		var object := _new_object(_take())
		object.num_morphs = int(_take())
		object.object_type = int(_take())
		object.position = _vector(_take())
		object.rotation_degrees = _vector(_take())
		object.scale = _vector(_take())
		object.engine_position = object.position
		object.engine_rotation_degrees = object.rotation_degrees
		if object.object_type == 1:
			object.engine_position.z = 0.0
			object.engine_rotation_degrees = Vector3(object.rotation_degrees.y, object.rotation_degrees.z, object.rotation_degrees.x)
		object.deformation_scale = float(_take())
		object.material.texture = _take()
		object.material.color_bytes = _numbers(_take())
		object.material.specular_bytes = _numbers(_take())
		object.material.gloss = float(_take())
		var effect_count := int(_take())
		if object.num_morphs < 0 or object.num_morphs > 10000 or effect_count < 0 or effect_count > 10000:
			_result.errors.append("Invalid object morph/effect count: " + object.name)
			return
		for j in range(object.num_morphs): object.morphs.append(_take())
		for j in range(effect_count):
			var controls := []
			for k in range(4): controls.append(int(_take()))
			var effect := {"band": controls[0], "Input1Band": controls[0], "Input1Type": controls[1], "Input2Band": controls[2], "Input2Type": controls[3], "controls_raw": controls, "file": _take(), "name": _take(), "preset": int(_take())}
			object.effects.append(effect)
		object.raw_fields = Array(_lines.slice(start, _cursor))
		_result.objects.append(object)
	while _cursor < _lines.size(): _command(_take())
	_result.unsupported.append({"system": "ashex_header_flags", "note": "Style (render_flags_raw) is the effects mask (style_flags.gd); render mode and scene_character_raw retained without guessed semantics"})

func _read_lvc():
	_result.format = "LVC"
	var current: Dictionary = {}
	var effect: Dictionary = {}
	while _cursor < _lines.size():
		var line := _take()
		if line.is_empty(): continue
		if _is_command(line):
			_command(line)
			continue
		var split := line.find("\t")
		if split < 0: split = line.find(" ")
		if split < 0:
			_result.unsupported.append({"system": "lvc_line", "raw": line})
			continue
		var key := line.left(split)
		var value := line.substr(split + 1).strip_edges()
		if key == "OName":
			current = _new_object(value)
			_result.objects.append(current)
			effect = {}
		elif current.is_empty(): _result.header[key] = value
		else:
			current.raw_fields.append({"key": key, "value": value})
			match key:
				"OPos": current.position = _vector(value)
				"OAng": current.rotation_degrees = _vector(value)
				"OSize": current.scale = _vector(value)
				"NumMorphs": current.num_morphs = int(value)
				"LvoFile": current.morphs.append(value)
				"TName": current.material.texture = value
				"TColor": current.material.color_bytes = _numbers(value)
				"SpecCol": current.material.specular_bytes = _numbers(value)
				"Gloss": current.material.gloss = float(value)
				"Culling": current.material.culling = value
				"DefScale": current.deformation_scale = float(value)
				"DefName":
					effect = {"name": value, "file": "", "preset": 0, "band": 0, "Input1Band": 0, "Input1Type": 0, "Input2Band": 0, "Input2Type": 1}
					current.effects.append(effect)
				"DefBand":
					effect.band = int(value)
					effect.Input1Band = int(value)
				"Input1Band", "Input1Type", "Input2Band", "Input2Type": effect[key] = int(value)
				"DefLvd": effect.file = value
				"DefPreset": effect.preset = int(value)
				"Visible", "EnableLighting", "NumDefs": current[key] = value
				"OType": current.object_type = int(value)
				"Olink", "ObjSite", "ObjPodIni", "NextPod":
					current[key] = value
					_result.unsupported.append({"system": "pod_interaction", "object": current.name, "key": key, "value": value})
				_: _result.unsupported.append({"system": "lvc_object_field", "object": current.name, "key": key, "value": value})
	var band_count := int(_result.header.get("Nbands", "0"))
	for i in range(band_count): _result.bands.append({"min": float(_result.header.get("B" + str(i) + "Min", "0")), "max": float(_result.header.get("B" + str(i) + "Max", "0"))})
	for object in _result.objects:
		if object.morphs.size() != object.get("num_morphs", 0): _result.errors.append("LVC morph count mismatch: " + object.name)
		if object.effects.size() != int(object.get("NumDefs", "0")): _result.errors.append("LVC effect count mismatch: " + object.name)
	if _result.objects.size() != int(_result.header.get("NumObjects", "0")): _result.errors.append("LVC object count mismatch")

func _is_command(line: String) -> bool:
	for prefix in ["Camera ", "Lighting ", "Culling ", "ParentChildLink ", "TextDeform", "SceneDetail", "EffectPreset"]:
		if line.begins_with(prefix): return true
	return false

func _command(line: String):
	if line.is_empty(): return
	_result.commands.append(line)
	var words := line.replace("\t", " ").split(" ", false)
	if words.size() < 2:
		_result.unsupported.append({"system": "scene_command", "raw": line})
		return
	match words[0]:
		"Camera":
			if words.size() >= 4 and words[2] == "Set":
				var numbers := _numbers(" ".join(words.slice(3)))
				_result.camera[words[1]] = numbers[0] if numbers.size() == 1 else numbers
			else: _result.unsupported.append({"system": "camera_command", "raw": line})
		"Lighting":
			_result.lighting.append({"index": int(words[1]), "property": words[2] if words.size() > 2 else "", "value": _numbers(" ".join(words.slice(3))), "raw": line})
		"EffectPreset":
			if words.size() >= 3: _result.effect_presets.append({"file": words[1], "name": words[2], "raw": line})
			_result.unsupported.append({"system": "effect_preset_events", "raw": line})
		"TextDeform":
			_result.text_deforms.append(line)
			_result.unsupported.append({"system": "text_deformation", "raw": line})
		"Culling":
			if words.size() >= 3:
				for object in _result.objects:
					if object.name == words[1]: object.material.culling = words[2]
		"ParentChildLink":
			if words.size() == 3:
				_result.links.append({"parent": words[1], "child": words[2], "raw": line})
				for object in _result.objects:
					if object.name == words[2]: object.parent = words[1]
		_: _result.unsupported.append({"system": words[0], "raw": line})

func _find_file(filename: String) -> String:
	for file in _result.files:
		if file.to_lower() == filename.to_lower(): return file
	return ""

func _read_effect(filename: String) -> Dictionary:
	var resolved := _find_file(filename)
	if resolved.is_empty(): return {"error": "Missing LVD: " + filename}
	var raw := FileAccess.get_file_as_string(_result.folder.path_join(resolved))
	var definition := {"raw_source": raw, "type": "", "presets": [], "header": {}}
	var preset: Dictionary = {}
	for line in raw.replace("\\r", "").replace("\\n", "\n").replace("\r", "").split("\n"):
		var words := line.replace("\t", " ").split(" ", false)
		if words.size() < 2 or words[0].begins_with("#"): continue
		var value := " ".join(words.slice(1))
		if words[0] == "Preset":
			preset = {"index": int(value), "parameters": {}}
			definition.presets.append(preset)
		elif preset.is_empty():
			definition.header[words[0]] = value
			if words[0] == "DefType": definition.type = value
		else: preset.parameters[words[0]] = float(value) if value.is_valid_float() else value
	return definition
