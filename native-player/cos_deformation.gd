extends RefCounted
## Original DefCos (0x10002280) and DefTexCos (0x1000b870).
## Angular parameters are engine pairs (phi, theta) in radians, not UV coordinates.
## Supplied A/S/dt are engine inputs. Random seed/whole-scene consumption unresolved.
const EventColors = preload("res://legacy_event_colors.gd")
var _cos: Dictionary
var _tex: Dictionary
var _waves: Array[Dictionary] = []
var _selected: int = 0
var _since_creation: float = 0.0
var _random_state: int = 1
var _tex_wave: Dictionary = {}

func reset(cos_preset: Dictionary, texture_preset: Dictionary = {}, instance_count: int = 2, seed: int = 1) -> void:
	_cos = {"AmpScale":1.0,"DoAmp":1,"DoColor":0,"DecayMin":0.75,"DecayMax":0.75,"BumpDir":0.0,"BumpDirMult":1.0,"CosDepthMin":1.0,"CosDepthMax":2.0,"WMin":360.0,"WMax":540.0,"MMin":1.0,"Mmax":3.0,"NMin":2.0,"NMax":6.0,"DefType":0.0,"DefTypeMult":1.0,"CreationLevel":0.0,"InteruptLevel":0.0,"MinBetweenTime":0.1}
	_cos.merge(cos_preset, true)
	_tex = {"AmpScale":45.0,"DoTexture":1,"DecayMin":0.6,"DecayMax":0.8,"CosDepthMin":1.0,"CosDepthMax":1.0,"WMin":360.0,"WMax":540.0,"MMin":2.0,"Mmax":4.0,"Direction":0.0,"DirectionMultiply":1.0,"Orientation":0.0,"OrientationMultiply":1.0,"CreationLevel":0.0,"InteruptLevel":0.0}
	_tex.merge(texture_preset, true)
	_tex["Enabled"] = not texture_preset.is_empty()
	_random_state = seed
	_selected = 0
	_since_creation = 0.0
	_waves.clear()
	for i in range(maxi(instance_count, 1)):
		_waves.append({"active":false,"envelope":0.0})
	_tex_wave = {"active":false}

func deform(mesh_arrays: Array, angular_parameters: PackedVector2Array, amplitude: float, scale: float, engine_delta: float, repeat_x: float = 1.0, repeat_y: float = 1.0, offset: Vector2 = Vector2.ZERO, texture_input: Dictionary = {}, material_color: Color = Color.WHITE) -> Array:
	var result := mesh_arrays.duplicate(true)
	var vertices: PackedVector3Array = mesh_arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = mesh_arrays[Mesh.ARRAY_NORMAL]
	if angular_parameters.size() != vertices.size() or normals.size() != vertices.size():
		push_error("Original cosine deformation requires one angular pair and source normal per vertex.")
		return result
	_advance_cos(amplitude, engine_delta, material_color)
	var output := vertices.duplicate()
	if int(_cos["DoAmp"]) == 1:
		for i in range(vertices.size()):
			var displacement := 0.0
			for wave in _waves:
				if bool(wave["active"]):
					displacement += _cos_weight(wave, angular_parameters[i]) * float(wave["sign"]) * float(wave["envelope"]) * float(_cos["AmpScale"]) * scale
			output[i] += normals[i] * displacement
	result[Mesh.ARRAY_VERTEX] = output
	if int(_cos["DoColor"]) == 1:
		var source: PackedColorArray = mesh_arrays[Mesh.ARRAY_COLOR] if mesh_arrays[Mesh.ARRAY_COLOR] != null else PackedColorArray()
		var colors := PackedColorArray()
		for i in range(vertices.size()):
			var color := source[i] if source.size() == vertices.size() else material_color
			for wave in _waves:
				if bool(wave["active"]):
					var target: Color = EventColors.event_color(wave.color0, wave.color1, wave.color2, wave.elapsed, wave.duration)
					color = EventColors.blend(color, target, _cos_weight(wave, angular_parameters[i]))
			colors.append(color)
		result[Mesh.ARRAY_COLOR] = colors
	if bool(_tex["Enabled"]):
		var texture_amplitude := float(texture_input.get("a", amplitude))
		var texture_scale := float(texture_input.get("s", scale))
		_advance_tex(texture_amplitude, engine_delta)
		if bool(_tex_wave["active"]) and int(_tex["DoTexture"]) == 1:
			var uvs := PackedVector2Array()
			for param in angular_parameters:
				var orientation := float(_tex_wave["orientation"])
				var coordinate := param.x if orientation == -1.0 else param.y
				var weight := cos(coordinate * float(_tex_wave["m"]) + float(_tex_wave["phase_time"]) * float(_tex_wave["w"])) * float(_tex_wave["depth"]) + 1.0 - float(_tex_wave["depth"])
				var rate := repeat_x * 0.0027777778450399637 if orientation == -1.0 else repeat_y * 0.0055555556900799274
				var movement := weight * float(_tex["AmpScale"]) * texture_scale * float(_tex_wave["envelope"]) * rate * float(_tex_wave["direction"])
				var uv := Vector2(param.y * repeat_x * 0.15915493667125702 + offset.x, (3.1415927410125732-param.x) * repeat_y * 0.31830987334251404 + offset.y)
				uv.x += movement
				if orientation != -1.0:
					uv.y -= movement
				uvs.append(uv)
			result[Mesh.ARRAY_TEX_UV] = uvs
	return result

## State-only tick (no vertex output) for fixed-timestep catch-up ticks.
func advance(amplitude: float, engine_delta: float, texture_input: Dictionary = {}, material_color: Color = Color.WHITE) -> void:
	_advance_cos(amplitude, engine_delta, material_color)
	if bool(_tex["Enabled"]): _advance_tex(float(texture_input.get("a", amplitude)), engine_delta)

func state_snapshot() -> Dictionary:
	return {"waves":_waves.duplicate(true),"texture":_tex_wave.duplicate(true),"seed":_random_state}

func _unit() -> float:
	_random_state = (_random_state * 214013 + 2531011) & 0xffffffff
	return float((_random_state >> 16) & 32767) * 0.000030518509447574615

func _uniform(low: float, high: float) -> float:
	return low + _unit() * (high-low)

func _integer(low: float, high: float) -> float:
	return float(int(low + _unit() * (high+1.0-low)))

func _sign() -> float:
	return (float(int(_unit()+0.5))-0.5)*2.0

func _cos_weight(wave: Dictionary, param: Vector2) -> float:
	var phase := float(wave["phase_time"]) * float(wave["w"])
	var depth := float(wave["depth"])
	var first := 2.0 * param.x * float(wave["m"])
	var second := param.y * float(wave["n"])
	if float(wave["type"]) == 1.0:
		return (cos(phase+first)*depth+1.0-depth)*(cos(phase+second)*depth+1.0-depth)
	return cos(phase+first+second)*depth+1.0-depth

func _advance_cos(amplitude: float, dt: float, material_color: Color = Color.WHITE) -> void:
	for wave in _waves:
		if not bool(wave["active"]):
			continue
		if float(wave["elapsed"]) >= float(wave["duration"]):
			wave["active"] = false
		else:
			wave["elapsed"] = float(wave["elapsed"]) + dt
			wave["phase_time"] = float(wave["phase_time"]) + dt
			wave["envelope"] = (cos(float(wave["elapsed"]) * 3.1415927410125732 / float(wave["duration"]))+1.0)*0.5*float(wave["peak"])
	if _since_creation >= float(_cos["MinBetweenTime"]):
		_selected = -1
		for i in range(_waves.size()):
			if not bool(_waves[i]["active"]):
				_selected = i # Original chooses the LAST inactive slot.
		if _selected == -1:
			var smallest := 2.0
			for i in range(_waves.size()):
				if float(_waves[i]["envelope"]) < smallest:
					smallest = float(_waves[i]["envelope"])
					_selected = i
	else:
		_since_creation += dt
	if _selected < 0 or amplitude <= float(_cos["CreationLevel"]):
		return
	var wave := _waves[_selected]
	if not bool(wave["active"]):
		wave["active"] = true
		wave["elapsed"] = 0.0
		wave["peak"] = amplitude
		wave["envelope"] = amplitude
		wave["duration"] = (1.0-amplitude)*float(_cos["DecayMin"])+amplitude*float(_cos["DecayMax"])
		_since_creation = 0.0
		wave["sign"] = -1.0 if _uniform(-1.0,1.0) > float(_cos["BumpDir"]) else 1.0
		_cos["BumpDir"] = float(_cos["BumpDir"])*float(_cos["BumpDirMult"])
		wave["depth"] = _uniform(float(_cos["CosDepthMin"]),float(_cos["CosDepthMax"]))*0.5
		wave["w"] = _uniform(float(_cos["WMin"]),float(_cos["WMax"]))*_sign()*0.01745329238474369
		wave["phase_time"] = 0.0
		wave["m"] = _integer(float(_cos["MMin"]),float(_cos["Mmax"]))*_sign()
		wave["n"] = _integer(float(_cos["NMin"]),float(_cos["NMax"]))*_sign()
		wave["type"] = -1.0 if _uniform(-1.0,1.0) > float(_cos["DefType"]) else 1.0
		_cos["DefType"] = float(_cos["DefType"])*float(_cos["DefTypeMult"])
		# Original computes three random H/S/I colors even with DoColor=0.
		_create_colors(wave, material_color)
	elif amplitude > float(wave["envelope"]) and amplitude > float(_cos["InteruptLevel"]):
		wave["peak"] = amplitude
		wave["envelope"] = amplitude
		wave["duration"] = (1.0-amplitude)*float(_cos["DecayMin"])+amplitude*float(_cos["DecayMax"])
		wave["elapsed"] = 0.0
		var w := float(wave["w"])
		wave["phase_time"] = (float(wave["phase_time"])*w - float(int(float(wave["phase_time"])*w*0.15915493667125702))*6.2831854820251465)/w if w != 0.0 else 0.0
		if _since_creation >= float(_cos["MinBetweenTime"]):
			_create_colors(wave, material_color)
		_since_creation = 0.0

func _create_colors(wave: Dictionary, material_color: Color) -> void:
	for index in range(3):
		# Preserve the original nine CRT draws even when coloring is disabled.
		var draws := Vector3(_unit(), _unit(), _unit())
		wave["color%d" % index] = EventColors.random_color(material_color, _cos, draws)

func _advance_tex(amplitude: float, dt: float) -> void:
	if bool(_tex_wave["active"]):
		if float(_tex_wave["elapsed"]) >= float(_tex_wave["duration"]):
			_tex_wave["active"] = false
		else:
			_tex_wave["elapsed"] = float(_tex_wave["elapsed"])+dt
			_tex_wave["phase_time"] = float(_tex_wave["phase_time"])+dt
			_tex_wave["envelope"] = (cos(float(_tex_wave["elapsed"])*3.1415927410125732/float(_tex_wave["duration"]))+1.0)*0.5*float(_tex_wave["peak"])
	if amplitude <= float(_tex["CreationLevel"]):
		return
	if not bool(_tex_wave["active"]):
		_tex_wave["active"] = true
		_tex_wave["peak"] = amplitude
		_tex_wave["envelope"] = amplitude
		_tex_wave["duration"] = (1.0-amplitude)*float(_tex["DecayMin"])+amplitude*float(_tex["DecayMax"])
		_tex_wave["elapsed"] = 0.0
		_tex_wave["direction"] = -1.0 if _uniform(-1.0,1.0)>float(_tex["Direction"]) else 1.0
		_tex["Direction"] = float(_tex["Direction"])*float(_tex["DirectionMultiply"])
		_tex_wave["orientation"] = -1.0 if _uniform(-1.0,1.0)>float(_tex["Orientation"]) else 1.0
		_tex["Orientation"] = float(_tex["Orientation"])*float(_tex["OrientationMultiply"])
		_tex_wave["m"] = _integer(float(_tex["MMin"]),float(_tex["Mmax"]))
		_tex_wave["depth"] = _integer(float(_tex["CosDepthMin"]),float(_tex["CosDepthMax"]))*0.5
		_tex_wave["w"] = _uniform(float(_tex["WMin"]),float(_tex["WMax"]))*_sign()*0.01745329238474369
		_tex_wave["phase_time"] = 0.0
	elif amplitude > float(_tex_wave["envelope"]) and amplitude > float(_tex["InteruptLevel"]):
		_tex_wave["peak"] = amplitude
		_tex_wave["envelope"] = amplitude
		_tex_wave["duration"] = (1.0-amplitude)*float(_tex["DecayMin"])+amplitude*float(_tex["DecayMax"])
		_tex_wave["elapsed"] = 0.0
		var w := float(_tex_wave["w"])
		_tex_wave["phase_time"] = (float(_tex_wave["phase_time"])*w-float(int(float(_tex_wave["phase_time"])*w*0.15915493667125702))*6.2831854820251465)/w if w != 0.0 else 0.0
