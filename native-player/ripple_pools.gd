extends RefCounted
## Original Lava3 DefRipple 0x10004eb0 and DefPools 0x10006a00.
## Parameters are original Vector2(phi, theta) radians. A/S/dt are engine audio inputs.
## Shared original CRT seed and whole-scene random ordering remain caller concerns.
const RAD := 0.01745329238474369
const PI32 := 3.1415927410125732
const TAU32 := 6.2831854820251465
var _r: Dictionary
var _p: Dictionary
var _waves: Array[Dictionary] = []
var _centers: Array[Dictionary] = []
var _palette: Array[Dictionary] = []
var _seed := 1
var _selected := 0
var _spacing := 0.0
var _pool: Dictionary
var _palette_ready := false

func reset(ripple_preset: Dictionary, pools_preset: Dictionary, instance_count: int = 3, seed: int = 1) -> void:
	_r = {"AmpScale":1.0,"DoAmp":1,"DoColor":0,"DecayMin":0.75,"DecayMax":0.75,"BumpDir":1.0,"BumpDirMult":1.0,"CosDepthMin":1.0,"CosDepthMax":1.0,"VMin":135.0,"VMax":135.0,"WMin":360.0,"WMax":540.0,"MMin":0.0,"Mmax":4.0,"SigmaMin":30.0,"SigmaMax":30.0,"Orient":0.0,"OrientMultiply":1.0,"VDir":0.0,"VDirMultiply":1.0,"WrapTheta":1,"WrapPhi":1,"CreationLevel":0.0,"InteruptLevel":0.0,"MinBetweenTime":0.1}
	_r.merge(ripple_preset,true)
	_p = {"AmpScale":1.0,"DoAmp":0,"DoColor":1,"DecayMin":1.5,"DecayMax":1.5,"CHSigma":120.0,"CHOffset":0.0,"CSSigma":0.5,"CSOffset":0.0,"CISigma":0.5,"CIOffset":0.25,"VMin":30.0,"VMax":90.0,"MMin":0.0,"Mmax":0.0,"MVMin":0.0,"MVMax":0.5,"MVDir":1.0,"PhaseVMin":0.0,"PhaseVMax":360.0,"PhaseVDir":1.0,"PhaseMin":0.0,"PhaseMax":0.0,"WrapTheta":1,"WrapPhi":1,"ColorDistMin":25.0,"ColorDistMax":35.0,"ColorVMin":30.0,"ColorVMax":90.0,"SmoothnessMin":0.0,"SmoothnessMax":0.75,"CosDepthMin":0.0,"CosDepthMax":0.0,"CreationLevel":0.0,"InteruptLevel":0.0}
	_p.merge(pools_preset,true)
	_seed = seed
	_selected = 0
	_spacing = 0.0
	_waves.clear()
	_centers.clear()
	_palette.clear()
	_palette_ready = false
	_pool = {"elapsed":1.0,"duration":1.0,"envelope":0.0,"peak":0.0,"m":0.0,"phase":0.0}
	for i in range(maxi(instance_count,1)):
		_waves.append({"active":false,"envelope":0.0})
		var theta := _uniform(0.0,TAU32)
		var phi := _uniform(0.0,PI32)
		var direction := _uniform(0.0,TAU32)
		_centers.append({"theta":theta,"phi":phi,"dx":cos(direction),"dy":sin(direction)})

func deform(mesh_arrays: Array, angular_parameters: PackedVector2Array, ripple_a: float, ripple_s: float, pools_a: float, pools_s: float, dt: float, def_scale: float = 1.0, material_color: Color = Color.WHITE) -> Array:
	var result := mesh_arrays.duplicate(true)
	var vertices: PackedVector3Array = mesh_arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = mesh_arrays[Mesh.ARRAY_NORMAL]
	if vertices.size() != angular_parameters.size() or vertices.size() != normals.size():
		push_error("Ripple/Pools require original angular parameters and normals.")
		return result
	_advance_ripple(ripple_a,dt)
	_advance_pools(pools_a,pools_s,dt,material_color)
	var output := vertices.duplicate()
	var colors := PackedColorArray()
	var source_colors: PackedColorArray = mesh_arrays[Mesh.ARRAY_COLOR] if mesh_arrays[Mesh.ARRAY_COLOR] != null else PackedColorArray()
	for i in range(vertices.size()):
		var param := angular_parameters[i]
		var displacement := 0.0
		if int(_r["DoAmp"]) == 1:
			for wave in _waves:
				if bool(wave["active"]):
					displacement += ripple_weight(wave,param) * float(wave["sign"]) * float(wave["envelope"]) * float(_r["AmpScale"]) * ripple_s
		var distance := pools_distance(param)
		var depth := 0.5*lerpf(float(_p["CosDepthMin"]),float(_p["CosDepthMax"]),pools_s*float(_pool["envelope"]))
		var weight := cos(distance*float(_pool["m"])+float(_pool["phase"]))*depth+1.0-depth
		if int(_p["DoAmp"]) == 1:
			displacement += float(_p["AmpScale"])*float(_pool["envelope"])*pools_s*weight
		output[i] += normals[i]*displacement*def_scale
		var source := source_colors[i] if source_colors.size() == vertices.size() else material_color
		if int(_p["DoColor"]) == 1:
			var target := palette_color(distance)
			var blend := maxf(weight,0.0) # Original lower-clamps only.
			source = Color(lerpf(source.r,target.r,blend),lerpf(source.g,target.g,blend),lerpf(source.b,target.b,blend),source.a)
		colors.append(source)
	result[Mesh.ARRAY_VERTEX] = output
	if int(_p["DoColor"]) == 1:
		result[Mesh.ARRAY_COLOR] = colors
	return result

## State-only tick (no vertex output) for fixed-timestep catch-up ticks.
func advance(ripple_a: float, pools_a: float, pools_s: float, dt: float, material_color: Color = Color.WHITE) -> void:
	_advance_ripple(ripple_a,dt)
	_advance_pools(pools_a,pools_s,dt,material_color)

func state_snapshot() -> Dictionary:
	return {"waves":_waves.duplicate(true),"centers":_centers.duplicate(true),"palette":_palette.duplicate(true),"pool":_pool.duplicate(true),"seed":_seed}

func _unit() -> float:
	_seed = (_seed*214013+2531011)&0xffffffff
	return float((_seed>>16)&32767)*0.000030518509447574615
func _uniform(low: float, high: float) -> float:
	return low+_unit()*(high-low)
func _integer(low: float, high: float) -> float:
	return float(int(low+_unit()*(high+1.0-low)))
func _sign() -> float:
	return (float(int(_unit()+0.5))-0.5)*2.0
func _threshold_sign(key: String, multiplier: String) -> float:
	var value := -1.0 if _uniform(-1.0,1.0)>float(_r[key]) else 1.0
	_r[key] = float(_r[key])*float(_r[multiplier])
	return value

func _advance_ripple(a: float, dt: float) -> void:
	for wave in _waves:
		if not bool(wave["active"]):
			continue
		if float(wave["elapsed"]) >= float(wave["duration"]):
			wave["active"] = false
			continue
		wave["elapsed"] = float(wave["elapsed"])+dt
		wave["phase_time"] = float(wave["phase_time"])+dt
		wave["envelope"] = 0.5*(1.0+cos(float(wave["elapsed"])*PI32/float(wave["duration"])))*float(wave["peak"])
		wave["center"] = float(wave["center"])+dt*float(wave["velocity"])
		var limit := PI32 if float(wave["orientation"]) == 1.0 else TAU32
		var wrap_key := "WrapPhi" if float(wave["orientation"]) == 1.0 else "WrapTheta"
		if int(_r[wrap_key]) == 1:
			if float(wave["center"])>limit: wave["center"] = float(wave["center"])-limit
			if float(wave["center"])<0.0: wave["center"] = float(wave["center"])+limit
		elif float(wave["center"])>limit or float(wave["center"])<0.0:
			wave["velocity"] = -float(wave["velocity"])
	if _spacing >= float(_r["MinBetweenTime"]):
		_selected = -1
		for i in range(_waves.size()):
			if not bool(_waves[i]["active"]): _selected = i
		if _selected == -1:
			var minimum := 2.0
			for i in range(_waves.size()):
				if float(_waves[i]["envelope"])<minimum:
					minimum = float(_waves[i]["envelope"])
					_selected = i
	else:
		_spacing += dt
	if _selected<0 or a<=float(_r["CreationLevel"]): return
	var wave := _waves[_selected]
	if not bool(wave["active"]):
		wave["active"] = true
		wave["sign"] = _threshold_sign("BumpDir","BumpDirMult")
		wave["depth"] = 0.5*_uniform(float(_r["CosDepthMin"]),float(_r["CosDepthMax"]))
		wave["orientation"] = _threshold_sign("Orient","OrientMultiply")
		var direction := _threshold_sign("VDir","VDirMultiply")
		wave["velocity"] = _uniform(float(_r["VMin"]),float(_r["VMax"]))*direction*RAD
		wave["center"] = 0.0 if direction == 1.0 else (PI32 if float(wave["orientation"]) == 1.0 else TAU32)
		var sigma := _uniform(float(_r["SigmaMin"]),float(_r["SigmaMax"]))*RAD
		wave["inverse_sigma_squared"] = 1.0/(sigma*sigma)
		wave["m"] = _integer(float(_r["MMin"]),float(_r["Mmax"]))
		wave["w"] = _uniform(float(_r["WMin"]),float(_r["WMax"]))*_sign()*RAD
		wave["phase_time"] = 0.0
		for ignored in range(9): _unit() # Three colors generated even when DoColor=0.
	elif a<=float(wave["envelope"]) or a<=float(_r["InteruptLevel"]): return
	else:
		if _spacing>=float(_r["MinBetweenTime"]):
			for ignored in range(9): _unit()
		var w := float(wave["w"])
		wave["phase_time"] = (float(wave["phase_time"])*w-float(int(float(wave["phase_time"])*w*0.15915493667125702))*TAU32)/w if w!=0.0 else 0.0
	wave["peak"] = a
	wave["envelope"] = a
	wave["elapsed"] = 0.0
	wave["duration"] = lerpf(float(_r["DecayMin"]),float(_r["DecayMax"]),a)
	_spacing = 0.0

func ripple_weight(wave: Dictionary, param: Vector2) -> float:
	var orientation := float(wave["orientation"])
	var d := (param.y if orientation==1.0 else param.x)-float(wave["center"])
	# Preserve original asymmetric positive-wrap operations and WrapPhi negative test.
	if orientation==1.0:
		if d>PI32 and int(_r["WrapTheta"])==1: d = TAU32-d
		if d< -PI32 and int(_r["WrapPhi"])==1: d += TAU32
	else:
		if d>PI32*0.5 and int(_r["WrapPhi"])==1: d = PI32-d
		if d< -PI32*0.5 and int(_r["WrapPhi"])==1: d += PI32
	var other := param.x if orientation==1.0 else param.y
	var modulation := cos(float(wave["phase_time"])*float(wave["w"])+other*float(wave["m"]))*float(wave["depth"])+1.0-float(wave["depth"])
	return modulation*exp(-d*d*float(wave["inverse_sigma_squared"]))

func _advance_pools(a: float, s: float, dt: float, base_color: Color) -> void:
	if not _palette_ready:
		_palette.append({"position":-_uniform(float(_p["ColorDistMin"]),float(_p["ColorDistMax"]))*RAD,"color":_random_color(base_color)})
		_palette.append({"position":0.0,"color":_random_color(base_color)})
		var degrees := 0.0
		while degrees<360.0:
			degrees += _uniform(float(_p["ColorDistMin"]),float(_p["ColorDistMax"]))
			_palette.append({"position":degrees*RAD,"color":_random_color(base_color)})
		_palette_ready = true
	if float(_pool["elapsed"])>=float(_pool["duration"]):
		_pool["envelope"] = 0.0
	else:
		_pool["elapsed"] = float(_pool["elapsed"])+dt
		_pool["envelope"] = (1.0+cos(float(_pool["elapsed"])*PI32/float(_pool["duration"])))*0.5*float(_pool["peak"])
	var envelope := float(_pool["envelope"])
	if (a>float(_p["CreationLevel"]) and envelope==0.0) or (a>envelope and a>float(_p["InteruptLevel"])):
		_pool["elapsed"] = 0.0
		_pool["envelope"] = a
		_pool["peak"] = a
		_pool["duration"] = lerpf(float(_p["DecayMin"]),float(_p["DecayMax"]),a)
		envelope = a
	_pool["smoothness"] = lerpf(float(_p["SmoothnessMax"]),float(_p["SmoothnessMin"]),s*envelope)
	var growth := (1.0+lerpf(float(_p["MVMin"]),float(_p["MVMax"]),envelope)*s*dt*float(_p["MVDir"]))
	_pool["m"] = float(_pool["m"])*growth
	if float(_pool["m"])<float(_p["MMin"]) or float(_pool["m"])>float(_p["Mmax"]):
		_pool["m"] = clampf(float(_pool["m"]),float(_p["MMin"]),float(_p["Mmax"]))
		_p["MVDir"] = -float(_p["MVDir"])
	_pool["phase"] = float(_pool["phase"])+lerpf(float(_p["PhaseVMin"]),float(_p["PhaseVMax"]),envelope)*s*dt*RAD*float(_p["PhaseVDir"])
	if float(_pool["phase"])<float(_p["PhaseMin"])*RAD or float(_pool["phase"])>float(_p["PhaseMax"])*RAD:
		_pool["phase"] = clampf(float(_pool["phase"]),float(_p["PhaseMin"])*RAD,float(_p["PhaseMax"])*RAD)
		_p["PhaseVDir"] = -float(_p["PhaseVDir"])
	var palette_delta := lerpf(float(_p["ColorVMin"]),float(_p["ColorVMax"]),envelope)*s*dt*RAD
	for point in _palette:
		point["position"] = float(point["position"])+palette_delta
	if float(_palette[0]["position"])>0.0:
		_palette.push_front({"position":-_uniform(float(_p["ColorDistMin"]),float(_p["ColorDistMax"]))*RAD,"color":_random_color(base_color)})
	if _palette.size()>2 and float(_palette[_palette.size()-2]["position"])>TAU32:
		_palette.pop_back()
	var movement := lerpf(float(_p["VMin"]),float(_p["VMax"]),envelope)*s*dt*RAD
	for center in _centers:
		center["theta"] = float(center["theta"])+movement*float(center["dx"])
		center["phi"] = float(center["phi"])+movement*float(center["dy"])
		for axis in ["theta","phi"]:
			var limit := TAU32 if axis=="theta" else PI32
			var direction := "dx" if axis=="theta" else "dy"
			var wrap := "WrapTheta" if axis=="theta" else "WrapPhi"
			if int(_p[wrap]) == 1:
				if float(center[axis])>limit: center[axis] = float(center[axis])-limit
				if float(center[axis])<0.0: center[axis] = float(center[axis])+limit
			elif float(center[axis])>limit or float(center[axis])<0.0:
				center[axis] = clampf(float(center[axis]),0.0,limit)
				center[direction] = -float(center[direction])

func pools_distance(param: Vector2) -> float:
	var total := 0.0
	var minimum := 10.0
	for center in _centers:
		# Literal 0x1000716b/0x1000718c: param[1] against theta, param[0] against phi.
		var theta_delta := absf(param.y-float(center["theta"]))
		var phi_delta := absf(param.x-float(center["phi"]))
		if theta_delta>PI32 and int(_p["WrapTheta"])==1: theta_delta = TAU32-theta_delta
		if phi_delta>PI32*0.5 and int(_p["WrapPhi"])==1: phi_delta = PI32-phi_delta
		var distance := sqrt(theta_delta*theta_delta+phi_delta*phi_delta)
		minimum = minf(minimum,distance)
		total += distance
	return lerpf(minimum,total/float(_centers.size()),float(_pool.get("smoothness",0.75)))

func palette_color(distance: float) -> Color:
	if _palette.size()<2: return Color.WHITE
	var index := 1
	while index<_palette.size()-1 and distance>=float(_palette[index]["position"]): index += 1
	var lower := _palette[index-1]
	var upper := _palette[index]
	var weight := (distance-float(lower["position"]))/ (float(upper["position"])-float(lower["position"]))
	return (lower["color"] as Color).lerp(upper["color"] as Color,weight)

func _random_color(base: Color) -> Color:
	var hsi := rgb_to_hsi(base)
	hsi.x += _uniform(-float(_p["CHSigma"]),float(_p["CHSigma"]))+float(_p["CHOffset"])
	if hsi.x<0.0: hsi.x += 360.0
	if hsi.x>360.0: hsi.x -= 360.0
	hsi.y = clampf(hsi.y+_uniform(-float(_p["CSSigma"]),float(_p["CSSigma"]))+float(_p["CSOffset"]),0.0,1.0)
	hsi.z = clampf(hsi.z+_uniform(-float(_p["CISigma"]),float(_p["CISigma"]))+float(_p["CIOffset"]),0.0,1.0)
	return hsi_to_rgb(hsi)

static func rgb_to_hsi(color: Color) -> Vector3:
	var intensity := (color.r+color.g+color.b)*0.3333333432674408
	var saturation := 1.0-minf(color.r,minf(color.g,color.b))/intensity if intensity!=0.0 else 0.0
	var rg := color.r-color.g
	var rb := color.r-color.b
	var denominator := sqrt(rg*rg+(color.g-color.b)*rb)
	var hue := acos(clampf((rg+rb)*0.5/denominator,-1.0,1.0))*57.295780181884766 if denominator!=0.0 else 0.0
	if color.b>color.g: hue = 360.0-hue
	return Vector3(hue,saturation,intensity)

static func hsi_to_rgb(hsi: Vector3) -> Color:
	var hue := hsi.x
	var sector := 0
	if hue>120.0:
		hue -= 120.0
		sector = 1
		if hue>120.0:
			hue -= 120.0
			sector = 2
	var low := (1.0-hsi.y)*0.3333333432674408
	var high := (1.0+hsi.y*cos(hue*RAD)/cos((60.0-hue)*RAD))*0.3333333432674408
	var middle := 1.0-high-low
	var rgb := Vector3(high,middle,low)
	if sector==1: rgb = Vector3(low,high,middle)
	elif sector==2: rgb = Vector3(middle,low,high)
	rgb *= hsi.z*3.0
	var maximum := maxf(rgb.x,maxf(rgb.y,rgb.z))
	if maximum>1.0: rgb /= maximum
	return Color(clampf(rgb.x,0.0,1.0),clampf(rgb.y,0.0,1.0),clampf(rgb.z,0.0,1.0),1.0)
