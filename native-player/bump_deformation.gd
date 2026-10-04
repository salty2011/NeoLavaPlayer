extends RefCounted
## DefBump Lava3.dll ctor 0x100030b0, update 0x100037d0.
## Angular pairs are original (phi,theta) radians; source normals set displacement axis.
## Shared CRT seed and whole-scene random order remain caller concerns.
const RAD := 0.01745329238474369
const PI32 := 3.1415927410125732
const TAU32 := 6.2831854820251465
const Colors = preload("res://legacy_event_colors.gd")
var _p: Dictionary = {}
var _waves: Array[Dictionary] = []
var _seed := 1
var _selected := 0
var _spacing := 0.0

func reset(preset: Dictionary, instance_count: int = 3, seed: int = 1) -> void:
	_p = {"AmpScale":1.0,"DoAmp":1,"DoColor":1,"DecayMin":1.0,"DecayMax":2.0,"BumpDir":0.0,"BumpDirMult":1.0,"CosDepthMin":1.0,"CosDepthMax":1.0,"WMin":540.0,"WMax":720.0,"MMin":3.0,"Mmax":6.0,"CHSigma":60.0,"CHOffset":0.0,"CSSigma":0.0,"CSOffset":0.0,"CISigma":0.3,"CIOffset":0.15,"VMin":60.0,"VMax":140.0,"VDirMin":0.0,"VDirMax":360.0,"SigmaMin":60.0,"SigmaMax":90.0,"ThetaMin":0.0,"ThetaMax":360.0,"PhiMin":0.0,"PhiMax":180.0,"CreationLevel":0.0,"InteruptLevel":0.0,"MinBetweenTime":0.1,"WrapTheta":1,"WrapPhi":1}
	_p.merge(preset,true)
	# Setter 0x100035f9 misroutes CSOffset to the sigma slot; CSSigma is ignored.
	_p["CSSigma"] = float(preset.get("CSOffset",0.0))
	_p["CSOffset"] = 0.0
	if preset.has("Interruptlevel"): _p["InteruptLevel"] = preset["Interruptlevel"]
	_seed = seed
	_selected = 0
	_spacing = 0.0
	_waves.clear()
	for i in range(maxi(instance_count,1)): _waves.append({"active":false,"envelope":0.0})

func deform(mesh_arrays: Array, angular_parameters: PackedVector2Array, amplitude: float, scale: float, dt: float, def_scale: float = 1.0, material_color: Color = Color.WHITE) -> Array:
	var result := mesh_arrays.duplicate(true)
	var vertices: PackedVector3Array = mesh_arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = mesh_arrays[Mesh.ARRAY_NORMAL]
	if vertices.size()!=angular_parameters.size() or normals.size()!=vertices.size():
		push_error("Original Bump requires one angular pair and source normal per vertex.")
		return result
	_advance(amplitude,dt,material_color)
	var output := vertices.duplicate()
	var colors := PackedColorArray()
	var source_colors: PackedColorArray = mesh_arrays[Mesh.ARRAY_COLOR] if mesh_arrays[Mesh.ARRAY_COLOR]!=null else PackedColorArray()
	for i in range(vertices.size()):
		var displacement := 0.0
		var color := source_colors[i] if source_colors.size()==vertices.size() else material_color
		for wave in _waves:
			if not bool(wave["active"]): continue
			var weight := bump_weight(wave,angular_parameters[i])
			if int(_p["DoAmp"])==1: displacement += weight*float(wave["sign"])*float(wave["envelope"])*float(_p["AmpScale"])*scale
			if int(_p["DoColor"])==1:
				var target := _event_color(wave)
				color = Colors.blend(color,target,weight,true)
		output[i] += normals[i]*displacement*def_scale
		colors.append(color)
	result[Mesh.ARRAY_VERTEX] = output
	if int(_p["DoColor"])==1: result[Mesh.ARRAY_COLOR] = colors
	return result

## State-only tick (no vertex output) for fixed-timestep catch-up ticks.
func advance(amplitude: float, dt: float, material_color: Color = Color.WHITE) -> void:
	_advance(amplitude,dt,material_color)

func state_snapshot() -> Dictionary:
	return {"waves":_waves.duplicate(true),"seed":_seed,"selected":_selected,"spacing":_spacing}

func _unit() -> float:
	_seed = (_seed*214013+2531011)&0xffffffff
	return float((_seed>>16)&32767)*0.000030518509447574615
func _uniform(low: float, high: float) -> float:
	return low+_unit()*(high-low)
func _integer(low: float, high: float) -> float:
	return float(int(low+_unit()*(high+1.0-low)))
func _range(low_key: String, high_key: String) -> float:
	return _uniform(float(_p[low_key]),float(_p[high_key]))

func _color(base: Color) -> Color:
	var draws := Vector3(_unit(),_unit(),_unit())
	return Colors.random_color(base,_p,draws)

func _event_color(wave: Dictionary) -> Color:
	return Colors.event_color(wave["color0"],wave["color1"],wave["color2"],float(wave["elapsed"]),float(wave["duration"]))

func _move_center(wave: Dictionary, dt: float) -> void:
	for axis: String in ["theta","phi"]:
		var velocity_key := "v"+axis
		var limit := TAU32 if axis=="theta" else PI32
		var wrap_key := "WrapTheta" if axis=="theta" else "WrapPhi"
		var min_key := "ThetaMin" if axis=="theta" else "PhiMin"
		var max_key := "ThetaMax" if axis=="theta" else "PhiMax"
		wave[axis] = float(wave[axis])+float(wave[velocity_key])*dt
		if int(_p[wrap_key])==1:
			if float(wave[axis])>limit: wave[axis] = float(wave[axis])-limit
			if float(wave[axis])<0.0: wave[axis] = float(wave[axis])+limit
		elif float(wave[axis])>float(_p[max_key])*RAD:
			wave[axis] = float(_p[max_key])*RAD
			wave[velocity_key] = -float(wave[velocity_key])
		elif float(wave[axis])<float(_p[min_key])*RAD:
			wave[axis] = float(_p[min_key])*RAD
			wave[velocity_key] = -float(wave[velocity_key])

func _advance(a: float, dt: float, base: Color) -> void:
	for wave in _waves:
		if not bool(wave["active"]): continue
		if float(wave["elapsed"])>=float(wave["duration"]):
			wave["active"] = false
			continue
		wave["elapsed"] = float(wave["elapsed"])+dt
		wave["phase_time"] = float(wave["phase_time"])+dt
		wave["envelope"] = float(wave["peak"])*0.5*(1.0+cos(float(wave["elapsed"])*PI32/float(wave["duration"])))
		_move_center(wave,dt)
	if _spacing>=float(_p["MinBetweenTime"]):
		_selected = -1
		for i in range(_waves.size()):
			if not bool(_waves[i]["active"]): _selected = i
		if _selected==-1:
			var smallest := 2.0
			for i in range(_waves.size()):
				if float(_waves[i]["envelope"])<smallest:
					smallest = float(_waves[i]["envelope"])
					_selected = i
	else: _spacing += dt
	if _selected<0 or a<=float(_p["CreationLevel"]): return
	var wave := _waves[_selected]
	if not bool(wave["active"]):
		wave["active"] = true
		wave["sign"] = -1.0 if _uniform(-1.0,1.0)>float(_p["BumpDir"]) else 1.0
		_p["BumpDir"] = float(_p["BumpDir"])*float(_p["BumpDirMult"])
		wave["theta"] = _range("ThetaMin","ThetaMax")*RAD
		wave["phi"] = _range("PhiMin","PhiMax")*RAD
		var velocity := _range("VMin","VMax")*RAD
		var direction := _range("VDirMin","VDirMax")*RAD
		wave["vtheta"] = velocity*cos(direction)
		wave["vphi"] = velocity*sin(direction)
		var sigma := _range("SigmaMin","SigmaMax")*RAD
		wave["inverse_sigma_squared"] = 1.0/(sigma*sigma)
		wave["depth"] = _range("CosDepthMin","CosDepthMax")*0.5
		wave["m"] = _integer(float(_p["MMin"]),float(_p["Mmax"]))
		wave["w"] = _range("WMin","WMax")*RAD
		wave["phase_time"] = 0.0
		wave["color0"] = _color(base)
		wave["color1"] = _color(base)
		wave["color2"] = _color(base)
	elif a<=float(wave["envelope"]) or a<=float(_p["InteruptLevel"]): return
	else:
		if _spacing>=float(_p["MinBetweenTime"]):
			wave["color0"] = _color(base)
			wave["color1"] = _color(base)
			wave["color2"] = _color(base)
		var w := float(wave["w"])
		wave["phase_time"] = (float(wave["phase_time"])*w-float(int(float(wave["phase_time"])*w*0.15915493667125702))*TAU32)/w if w!=0.0 else 0.0
	wave["peak"] = a
	wave["envelope"] = a
	wave["elapsed"] = 0.0
	wave["duration"] = lerpf(float(_p["DecayMin"]),float(_p["DecayMax"]),a)
	_spacing = 0.0

func bump_weight(wave: Dictionary, param: Vector2) -> float:
	var theta := absf(param.y-float(wave["theta"]))
	var phi := absf(param.x-float(wave["phi"]))
	if theta>PI32 and int(_p["WrapTheta"])==1: theta = TAU32-theta
	if phi>PI32*0.5 and int(_p["WrapPhi"])==1: phi = PI32-phi
	var radius := sqrt(theta*theta+phi*phi)
	var modulation := cos(radius*float(wave["m"])+float(wave["phase_time"])*float(wave["w"]))*float(wave["depth"])+1.0-float(wave["depth"])
	return exp(-radius*radius*float(wave["inverse_sigma_squared"]))*modulation
