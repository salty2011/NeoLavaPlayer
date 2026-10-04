extends RefCounted
## DefSuperBump, Lava3.dll (static analysis only; image base 0x10000000).
##   factory 0x1001be90 (new 0x2a4) -> ctor 0x10007360, vtable 0x10033298:
##   [0] scalar-deleting dtor 0x10007b20, [1] setter 0x10007db0, [2] update 0x100092c0..0x1000b1d7.
## Helpers: RandRange 0x10010b70, RandInt 0x10010b30 (hi+0.9999f), RandSign 0x10010ba0
##   ((ftol(u+0.5)-0.5)*2), RGB->HSI 0x10010730, HSI->RGB 0x10010880 (via legacy_event_colors.gd),
##   map loader 0x10010e80, _CIpow 0x10028380, _ftol 0x10028348 (truncation).
## Full notes: research/oozic/disassembly/superbump-recovery-notes.md.
##
## Angular pair per vertex = Vector2(phi, theta) radians, same as bump_deformation.gd (object +0x28,
## 8 bytes per vertex). SuperBump works in doubled phi: phi_eff = 2*phi (0x1000a7f3: 2pi * 1/pi),
## theta_eff = theta (0x1000a7cd: 2pi * 1/(2pi)).
##
## Per-frame update 0x100092c0 (state part, mirrored by _advance):
##   for each instance (0x100093ff..0x100098d6):
##     active and age>=duration -> inactive (0x10009411)
##     age+=dt; env = peak*(cos(age*pi/dur)+1)*0.5                      (0x10009432..0x10009463)
##     theta += vtheta*env*S*dt; wrap 2pi | bounce Cent*Theta | off-surface kill (0x10009466..0x10009580)
##     phi   += vphi  *env*S*dt; same with Phi fields                    (0x10009582..0x1000969c)
##     sigma += dt*vsigma; clamp [BumpSigmaMin,BumpSigmaMax] deg         (0x1000969e..0x100096f5)
##     itheta+=dt*vi; otheta+=dt*vo; if |o-i|>ThetaDiffMax: faster v := slower v (0x100096f7..0x10009781)
##     wave_t+=dt; flow_t+=dt                                             (0x10009783..0x100097a5)
##     current colour = c0->c1 (first half) / c1->c2 (second half)        (0x100097a7..0x100098c9)
##   selection/spacing as DefBump (0x100098dc..0x10009a80)
##   spawn when A>CreationLevel and selected inactive (0x10009956..0x1000a320)
##   retrigger when A>env and A>InteruptLevel (0x1000a325..0x1000a789); spacing=0 (0x1000a789)
## Vertex part (deform only, no random draws): 0x1000a790..0x1000b1c8.
const LegacyRand = preload("res://legacy_rand.gd")
const Colors = preload("res://legacy_event_colors.gd")

const RAD := 0.01745329238474369          # f32 0x100331fc
const PI32 := 3.1415927410125732          # f64 0x10033240 / f32 0x10033258
const TAU32 := 6.2831854820251465         # ctor +0x70/+0x74 = 0x40c90fdb
const INV_TAU32 := 0.15915493667125702    # f32 0x100332a8
const INV_PI32 := 0.31830987334251404     # f32 0x100332a4
const RANDINT_PAD := 0.9998999834060669   # f32 0x100333a8

## Ctor 0x10007360 defaults, keyed by LavaFile property names (setter 0x10007db0 offsets in notes).
const DEFAULTS := {
	"Input1Band":0, "AmpScale":1.0, "DoAmp":1, "DoColor":1, "DoTexture":1,
	"DecayMin":0.75, "DecayMax":0.75, "MinBetweenTime":0.1, "CreationLevel":0.0, "InteruptLevel":0.0,
	"DoBump":1, "DoWave":0, "DoFlow":0, "DoHmap":0, "DoTextureRestore":1, "DoMask":0,
	"CentiThetaMin":0.0, "CentiThetaMax":360.0, "CentThetaMin":0.0, "CentThetaMax":360.0,
	"CentWrapTheta":0, "CentBounceTheta":1,
	"CentiPhiMin":0.0, "CentiPhiMax":360.0, "CentPhiMin":0.0, "CentPhiMax":360.0,
	"CentWrapPhi":0, "CentBouncePhi":1,
	"CentVMin":180.0, "CentVMax":360.0, "CentVDirMin":0.0, "CentVDirMax":360.0,
	"BumpDir":1.0, "BumpDirMult":1.0, "BumpSigmaDirection":1.0, "BumpSigmaDirectionMultiply":1.0,
	"BumpSSigmaMin":60.0, "BumpSSigmaMax":90.0, "BumpLSigmaMin":150.0, "BumpLSigmaMax":180.0,
	"BumpVSigmaMin":240.0, "BumpVSigmaMax":300.0, "BumpSigmaMin":60.0, "BumpSigmaMax":180.0,
	"BumpiThetaMin":0.0, "BumpiThetaMax":0.0, "BumpoThetaMin":0.0, "BumpoThetaMax":0.0, "BumpSyncTheta":0,
	"BumpviThetaMin":60.0, "BumpviThetaMax":90.0, "BumpvoThetaMin":180.0, "BumpvoThetaMax":540.0,
	"BumpSyncvTheta":0, "BumpThetaDiffMax":360.0,
	"WaveMMin":2.0, "WaveMMax":8.0, "WaveNMin":2.0, "WaveNMax":8.0, "WaveWMin":360.0, "WaveWMax":720.0,
	"WaveDepthMin":1.0, "WaveDepthMax":2.0, "WaveAmpMin":0.0, "WaveAmpMax":10.0,
	"FlowMMin":1.0, "FlowMMax":4.0, "FlowNMin":2.0, "FlowNMax":8.0, "FlowWMin":360.0, "FlowWMax":720.0,
	"FlowDepthMin":2.0, "FlowDepthMax":2.0, "FlowAmpMin":0.0, "FlowAmpMax":10.0,
	"HeightMapFilter":0.01, "MaskMapFilter":0.01,
	"MapScaleXMin":0.25, "MapScaleXMax":1.0, "MapScaleYMin":0.25, "MapScaleYMax":1.0, "MapColorRatio":1.0,
	"MapNX":1.0, "MapNY":1.0, "MapNXMin":1.0, "MapNXMax":1.0, "MapNYMin":1.0, "MapNYMax":1.0,
	"TexType":0, "TexScaleXMin":0.25, "TexScaleXMax":1.0, "TexScaleYMin":0.25, "TexScaleYMax":1.0,
	"TexNX":1.0, "TexNY":1.0, "TexNXMin":1.0, "TexNXMax":1.0, "TexNYMin":1.0, "TexNYMax":1.0,
	"TexFollowMap":0, "TexAmp":2.0, "TexReset":0, "TexRestDecay":0.175,
	"CHSigma":60.0, "CHOffset":0.0, "CSSigma":0.3, "CSOffset":0.0, "CISigma":0.3, "CIOffset":0.0,
}
## Setter aliases that store to the same field (0x10007db0 switch). Names not recognised by the
## setter (e.g. FlowNMa 0xd8, Interruptlevel 0xf2, TexLayerFlag) are ignored like the original.
const ALIASES := {"CentVelocityMin":"CentVMin", "CentVelocityMax":"CentVMax",
	"CentVelocityDirectionMin":"CentVDirMin", "CentVelocityDirectionMax":"CentVDirMax", "DoTex":"DoTexture"}
## Fields the setter converts with _ftol (truncate) instead of storing the float.
const INT_FIELDS := ["Input1Band","DoAmp","DoColor","DoTexture","DoBump","DoWave","DoFlow","DoHmap",
	"DoTextureRestore","DoMask","CentWrapTheta","CentBounceTheta","CentWrapPhi","CentBouncePhi",
	"BumpSyncTheta","BumpSyncvTheta","TexType","TexFollowMap","TexReset"]

## Returns U[0,1] = rand()/32767. Defaults to an internal seed-1 MSVC LCG.
var random_source: Callable
## Object texture-mapping fields read by the vertex pass (object +0x7c,+0x84,+0x8c,+0x94,+0x9c,+0xa4).
## Names are inferred from use: base u = theta*repeat_u/2pi + offset_u, base v = (pi-phi)*repeat_v/pi + offset_v.
var texture_mapping := {"repeat_u":1.0, "repeat_v":1.0, "offset_u":0.0, "offset_v":0.0, "bias_u":0.0, "bias_v":0.0}

var _p: Dictionary = {}
var _events: Array[Dictionary] = []
var _selected := 0       # +0x4c
var _spacing := 0.0      # +0x58
var _rng = LegacyRand.new(1)
var _uv := PackedVector2Array()   # object UV state (persistent in the original object +0x38)
var _height_map: Dictionary = {}  # +0x1e0
var _mask_map: Dictionary = {}    # +0x224

func _init() -> void:
	random_source = Callable(_rng, "unit")

func reset(preset: Dictionary, instance_count: int = 3) -> void:
	_p = DEFAULTS.duplicate()
	configure(preset)
	_selected = 0
	_spacing = 0.0
	_uv = PackedVector2Array()
	_events.clear()
	for i in range(maxi(instance_count, 1)):
		_events.append({"active":false, "age":0.0, "duration":0.0, "peak":0.0, "envelope":0.0,
			"theta":0.0, "phi":0.0, "vtheta":0.0, "vphi":0.0, "sign":1.0, "sigma_dir":1.0,
			"sigma":0.0, "vsigma":0.0, "itheta":0.0, "otheta":0.0, "vi":0.0, "vo":0.0,
			"wave_m":0.0, "wave_n":0.0, "wave_w":0.0, "wave_t":0.0, "wave_depth":0.0, "wave_amp":0.0,
			"flow_m":0.0, "flow_n":0.0, "flow_w":0.0, "flow_t":0.0, "flow_depth":0.0, "flow_amp":0.0,
			"map_sx":0.0, "map_sy":0.0, "map_ix":0.0, "map_iy":0.0,
			"tex_sx":0.0, "tex_sy":0.0, "tex_ix":0.0, "tex_iy":0.0,
			"color0":Color.BLACK, "color1":Color.BLACK, "color2":Color.BLACK, "current":Color.BLACK})

## Setter 0x10007db0: apply recognised properties in dictionary order.
func configure(preset: Dictionary) -> void:
	for key in preset.keys():
		var name := String(ALIASES.get(key, key))
		if not DEFAULTS.has(name): continue
		_p[name] = int(float(preset[key])) if name in INT_FIELDS else float(preset[key])

## LoadHeightMap/LoadMaskMap (0x10007e30/0x100080a7) load "heightmap<N>.jpg|.bmp" through 0x10010e80
## using the filter value current at load time; the caller supplies the decoded Image here.
func set_height_map(image: Image) -> void:
	_height_map = build_map(image, float(_p.get("HeightMapFilter", 0.01))) if image != null else {}

func set_mask_map(image: Image) -> void:
	_mask_map = build_map(image, float(_p.get("MaskMapFilter", 0.01))) if image != null else {}

## Map loader 0x10010e80: per pixel r,g,b = byte/256, height = (b0+b1+b2)/768; rows stored
## bottom-up (internal row j = decoder row H-1-j); height box-filtered with wrap over
## rx=ftol(W*filter+0.5), ry=ftol(H*filter+0.5), then divided by the maximum box sum (0x10011048..0x10011208).
static func build_map(image: Image, filter: float) -> Dictionary:
	var img := image.duplicate() as Image
	if img.is_compressed(): img.decompress()
	img.convert(Image.FORMAT_RGB8)
	var w := img.get_width()
	var h := img.get_height()
	var rgb := PackedColorArray(); rgb.resize(w*h)
	var raw := PackedFloat32Array(); raw.resize(w*h)
	for j in range(h):
		for x in range(w):
			var c := img.get_pixel(x, h-1-j)
			var b0 := int(round(c.r*255.0)); var b1 := int(round(c.g*255.0)); var b2 := int(round(c.b*255.0))
			rgb[j*w+x] = Color(b0*0.00390625, b1*0.00390625, b2*0.00390625)
			raw[j*w+x] = float(b0+b1+b2)*0.0013020833721384406
	var rx := int(w*filter+0.5)
	var ry := int(h*filter+0.5)
	# The original sums the 2D box directly (f32 accumulator); the box is separable, so rows are
	# summed first here. Only float rounding differs.
	var rows := PackedFloat32Array(); rows.resize(w*h)
	for j in range(h):
		for x in range(w):
			var s := 0.0
			for xx in range(x-rx, x+rx+1):
				var x2 := xx+w if xx<0 else xx
				if x2>=w: x2 -= w
				s += raw[j*w+x2]
			rows[j*w+x] = s
	var sums := PackedFloat32Array(); sums.resize(w*h)
	var top := 0.0
	for j in range(h):
		for x in range(w):
			var s := 0.0
			for yy in range(j-ry, j+ry+1):
				var y2 := yy+h if yy<0 else yy
				if y2>=h: y2 -= h
				s += rows[y2*w+x]
			sums[j*w+x] = s
			if top<s: top = s
	var inv := 1.0/top if top>0.0 else 1.0
	var height := PackedFloat32Array(); height.resize(w*h)
	for i in range(w*h): height[i] = sums[i]*inv
	return {"w":w, "h":h, "rgb":rgb, "height":height}

func deform(mesh_arrays: Array, angular_parameters: PackedVector2Array, amplitude: float, scale: float, dt: float, def_scale: float = 1.0, material_color: Color = Color.WHITE) -> Array:
	var result := mesh_arrays.duplicate(true)
	var vertices: PackedVector3Array = mesh_arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = mesh_arrays[Mesh.ARRAY_NORMAL]
	var n := vertices.size()
	if angular_parameters.size()!=n or normals.size()!=n:
		push_error("SuperBump requires one angular pair and source normal per vertex.")
		return result
	_advance(amplitude, scale, dt, material_color)
	var source_uv: PackedVector2Array = mesh_arrays[Mesh.ARRAY_TEX_UV] if mesh_arrays[Mesh.ARRAY_TEX_UV]!=null else PackedVector2Array()
	var uses_uv := int(_p["DoTexture"])==1 or int(_p["DoTextureRestore"])==1 or int(_p["DoMask"])==1
	if uses_uv:
		# Object UV state persists between frames. TexReset (+0x250) raises object flag +0x54 at
		# 0x10009395; its object-side meaning (re-init UVs) is INFERRED.
		if _uv.size()!=n or int(_p["TexReset"])==1:
			_uv = source_uv.duplicate() if source_uv.size()==n else _base_uvs(angular_parameters)
		if int(_p["DoTextureRestore"])==1: _restore_uvs(angular_parameters, dt)
	var displacement := PackedFloat32Array(); displacement.resize(n)
	var source_colors: PackedColorArray = mesh_arrays[Mesh.ARRAY_COLOR] if mesh_arrays[Mesh.ARRAY_COLOR]!=null else PackedColorArray()
	var colors := PackedColorArray(); colors.resize(n)
	for i in range(n): colors[i] = source_colors[i] if source_colors.size()==n else material_color
	for ev in _events:
		if bool(ev["active"]): _apply_event(ev, angular_parameters, scale, displacement, colors)
	if int(_p["DoMask"])==1 and not _mask_map.is_empty():
		for i in range(n): displacement[i] *= _mask_sample(_uv[i])
	var output := vertices.duplicate()
	for i in range(n): output[i] += normals[i]*displacement[i]*def_scale
	result[Mesh.ARRAY_VERTEX] = output
	if int(_p["DoColor"])==1: result[Mesh.ARRAY_COLOR] = colors
	if int(_p["DoTexture"])==1 or int(_p["DoTextureRestore"])==1: result[Mesh.ARRAY_TEX_UV] = _uv.duplicate()
	return result

## State-only tick (no vertex output) for fixed-timestep catch-up. Same state evolution and random
## draws as deform(). S is needed because centre motion is scaled by env*S (0x1000947e).
## Persistent object UV state is NOT advanced here (it belongs to the mesh in the original).
func advance(amplitude: float, dt: float, material_color: Color = Color.WHITE, scale: float = 1.0) -> void:
	_advance(amplitude, scale, dt, material_color)

func state_snapshot() -> Dictionary:
	return {"events":_events.duplicate(true), "selected":_selected, "spacing":_spacing,
		"BumpDir":_p.get("BumpDir"), "BumpSigmaDirection":_p.get("BumpSigmaDirection"),
		"TexNX":_p.get("TexNX"), "TexNY":_p.get("TexNY")}

func parameters() -> Dictionary:
	return _p.duplicate()

# ---- random helpers (0x10010b70 / 0x10010b30 / 0x10010ba0) ----
func _unit() -> float:
	return float(random_source.call())
func _uniform(low: float, high: float) -> float:
	return low+_unit()*(high-low)
func _integer(low: float, high: float) -> float:
	return float(int(low+_unit()*(high+RANDINT_PAD-low)))
func _rsign() -> float:
	return (float(int(_unit()+0.5))-0.5)*2.0
func _range(lo: String, hi: String) -> float:
	return _uniform(float(_p[lo]), float(_p[hi]))
func _color(base: Color) -> Color:
	var draws := Vector3(_unit(), _unit(), _unit())
	return Colors.random_color(base, _p, draws)

# ---- state update (0x100093a9..0x1000a789) ----
func _move_axis(ev: Dictionary, axis: String, vkey: String, wrap_key: String, bounce_key: String, min_key: String, max_key: String, limit: float, dt_scale: float) -> void:
	ev[axis] = float(ev[axis])+float(ev[vkey])*dt_scale
	var v := float(ev[axis])
	if int(_p[wrap_key])==1:
		if v>limit: ev[axis] = v-limit
		elif v<0.0: ev[axis] = v+limit
	elif int(_p[bounce_key])==1:
		var hi := float(_p[max_key])*RAD
		var lo := float(_p[min_key])*RAD
		if hi<v:
			ev[axis] = hi; ev[vkey] = -float(ev[vkey])
		elif lo>v:
			ev[axis] = lo; ev[vkey] = -float(ev[vkey])
	else:
		var sigma := float(ev["sigma"])
		if -sigma>v or limit+sigma<v: ev["active"] = false

func _advance(a: float, s: float, dt: float, base: Color) -> void:
	for ev in _events:
		if not bool(ev["active"]): continue
		if not (float(ev["age"])<float(ev["duration"])):
			ev["active"] = false
			continue
		ev["age"] = float(ev["age"])+dt
		var env := (cos(float(ev["age"])*PI32/float(ev["duration"]))+1.0)*0.5*float(ev["peak"])
		ev["envelope"] = env
		_move_axis(ev, "theta", "vtheta", "CentWrapTheta", "CentBounceTheta", "CentThetaMin", "CentThetaMax", TAU32, env*s*dt)
		_move_axis(ev, "phi", "vphi", "CentWrapPhi", "CentBouncePhi", "CentPhiMin", "CentPhiMax", TAU32, env*s*dt)
		var sigma := float(ev["sigma"])+dt*float(ev["vsigma"])
		if float(_p["BumpSigmaMin"])*RAD>sigma: sigma = float(_p["BumpSigmaMin"])*RAD
		elif float(_p["BumpSigmaMax"])*RAD<sigma: sigma = float(_p["BumpSigmaMax"])*RAD
		ev["sigma"] = sigma
		ev["itheta"] = float(ev["itheta"])+dt*float(ev["vi"])
		ev["otheta"] = float(ev["otheta"])+dt*float(ev["vo"])
		if float(_p["BumpThetaDiffMax"])*RAD<absf(float(ev["otheta"])-float(ev["itheta"])):
			if absf(float(ev["vo"]))<=absf(float(ev["vi"])): ev["vi"] = ev["vo"]
			else: ev["vo"] = ev["vi"]
		ev["wave_t"] = float(ev["wave_t"])+dt
		ev["flow_t"] = float(ev["flow_t"])+dt
		ev["current"] = _event_color(ev)
	if not (_spacing<float(_p["MinBetweenTime"])):
		_selected = -1
		for i in range(_events.size()):
			if not bool(_events[i]["active"]): _selected = i
		if _selected==-1:
			var smallest := 2.0
			for i in range(_events.size()):
				if not (smallest<=float(_events[i]["envelope"])):
					smallest = float(_events[i]["envelope"])
					_selected = i
	else:
		_spacing += dt
	if _selected<0 or not (a>float(_p["CreationLevel"])): return
	var ev := _events[_selected]
	if not bool(ev["active"]):
		_spawn(ev, a, base)
		return
	if not (a>float(ev["envelope"])) or not (a>float(_p["InteruptLevel"])): return
	ev["peak"] = a
	ev["duration"] = (1.0-a)*float(_p["DecayMin"])+float(_p["DecayMax"])*a
	ev["envelope"] = a
	ev["age"] = 0.0
	if not (_spacing<float(_p["MinBetweenTime"])): _new_colors(ev, base)
	_spacing = 0.0

## New event 0x10009966..0x1000a320 (draw order matters: see notes).
func _spawn(ev: Dictionary, a: float, base: Color) -> void:
	_spacing = 0.0
	ev["age"] = 0.0
	ev["active"] = true
	ev["peak"] = a
	ev["envelope"] = a
	ev["duration"] = (1.0-a)*float(_p["DecayMin"])+float(_p["DecayMax"])*a
	ev["theta"] = _range("CentiThetaMin", "CentiThetaMax")*RAD
	ev["phi"] = _range("CentiPhiMin", "CentiPhiMax")*RAD
	var speed := _range("CentVMin", "CentVMax")*RAD
	var direction := _range("CentVDirMin", "CentVDirMax")*RAD
	ev["vtheta"] = cos(direction)*speed
	ev["vphi"] = sin(direction)*speed
	ev["sign"] = 1.0 if _uniform(-1.0, 1.0)<=float(_p["BumpDir"]) else -1.0
	_p["BumpDir"] = float(_p["BumpDirMult"])*float(_p["BumpDir"])
	ev["sigma_dir"] = 1.0 if _uniform(-1.0, 1.0)<=float(_p["BumpSigmaDirection"]) else -1.0
	_p["BumpSigmaDirection"] = float(_p["BumpSigmaDirectionMultiply"])*float(_p["BumpSigmaDirection"])
	if float(ev["sigma_dir"])==1.0:
		ev["sigma"] = _range("BumpSSigmaMin", "BumpSSigmaMax")*RAD
		ev["vsigma"] = _range("BumpVSigmaMin", "BumpVSigmaMax")*RAD
	else:
		ev["sigma"] = _range("BumpLSigmaMin", "BumpLSigmaMax")*RAD
		ev["vsigma"] = _range("BumpVSigmaMin", "BumpVSigmaMax")*-RAD
	ev["itheta"] = _range("BumpiThetaMin", "BumpiThetaMax")*RAD
	ev["otheta"] = ev["itheta"] if int(_p["BumpSyncTheta"])==1 else _range("BumpoThetaMin", "BumpoThetaMax")*RAD
	var spin := _rsign()
	ev["vi"] = _range("BumpviThetaMin", "BumpviThetaMax")*spin*RAD
	ev["vo"] = ev["vi"] if int(_p["BumpSyncvTheta"])==1 else _range("BumpvoThetaMin", "BumpvoThetaMax")*spin*RAD
	ev["wave_m"] = _integer(float(_p["WaveMMin"]), float(_p["WaveMMax"]))
	ev["wave_n"] = _integer(float(_p["WaveNMin"]), float(_p["WaveNMax"]))
	var wave_w := _range("WaveWMin", "WaveWMax")
	ev["wave_w"] = _rsign()*wave_w*RAD
	ev["wave_t"] = 0.0
	ev["wave_depth"] = _range("WaveDepthMin", "WaveDepthMax")*0.5
	ev["wave_amp"] = _range("WaveAmpMin", "WaveAmpMax")*RAD
	ev["flow_m"] = _integer(float(_p["FlowMMin"]), float(_p["FlowMMax"]))
	ev["flow_n"] = _integer(float(_p["FlowNMin"]), float(_p["FlowNMax"]))
	var flow_w := _range("FlowWMin", "FlowWMax")
	ev["flow_w"] = _rsign()*flow_w*RAD
	ev["flow_t"] = 0.0
	ev["flow_depth"] = _range("FlowDepthMin", "FlowDepthMax")*0.5
	ev["flow_amp"] = _range("FlowAmpMin", "FlowAmpMax")*RAD
	ev["map_sx"] = _range("MapScaleXMin", "MapScaleXMax")
	ev["map_sy"] = _range("MapScaleYMin", "MapScaleYMax")
	ev["map_ix"] = _integer(float(_p["MapNXMin"]), float(_p["MapNXMax"]))
	ev["map_iy"] = _integer(float(_p["MapNYMin"]), float(_p["MapNYMax"]))
	if int(_p["TexFollowMap"])==1:
		ev["tex_sx"] = ev["map_sx"]; ev["tex_sy"] = ev["map_sy"]
		_p["TexNX"] = _p["MapNX"]; _p["TexNY"] = _p["MapNY"]   # global fields overwritten (0x10009e7f)
		ev["tex_ix"] = ev["map_ix"]; ev["tex_iy"] = ev["map_iy"]
	else:
		ev["tex_sx"] = _range("TexScaleXMin", "TexScaleXMax")
		ev["tex_sy"] = _range("TexScaleYMin", "TexScaleYMax")
		ev["tex_ix"] = _integer(float(_p["TexNXMin"]), float(_p["TexNXMax"]))
		ev["tex_iy"] = _integer(float(_p["TexNYMin"]), float(_p["TexNYMax"]))
	_new_colors(ev, base)

func _new_colors(ev: Dictionary, base: Color) -> void:
	ev["color0"] = _color(base)
	ev["color1"] = _color(base)
	ev["color2"] = _color(base)
	ev["current"] = ev["color0"]

## Colour interpolation 0x100097a7..0x100098c9 (same split as DefBump).
func _event_color(ev: Dictionary) -> Color:
	var age := float(ev["age"]); var dur := float(ev["duration"])
	var c0: Color = ev["color0"]; var c1: Color = ev["color1"]; var c2: Color = ev["color2"]
	if dur*0.5>age:
		var t := age*2.0/dur
		return Color(c0.r*(1.0-t)+c1.r*t, c0.g*(1.0-t)+c1.g*t, c0.b*(1.0-t)+c1.b*t)
	var u := minf((age-dur*0.5)*2.0/dur, 1.0)
	return Color(c1.r*(1.0-u)+c2.r*u, c1.g*(1.0-u)+c2.g*u, c1.b*(1.0-u)+c2.b*u)

# ---- vertex pass (0x1000a790..0x1000b1c8) ----
func _base_uv(param: Vector2) -> Vector2:
	var m := texture_mapping
	return Vector2(param.y*float(m["repeat_u"])*INV_TAU32+float(m["offset_u"]),
		(PI32-param.x)*float(m["repeat_v"])*INV_PI32+float(m["offset_v"]))

func _base_uvs(params: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array(); out.resize(params.size())
	for i in range(params.size()): out[i] = _base_uv(params[i])
	return out

## DoTextureRestore 0x1000a804..0x1000a8b2: r = 0.5^(dt/TexRestDecay);
## uv = base*(1-r) + (uv + bias)*r.
func _restore_uvs(params: PackedVector2Array, dt: float) -> void:
	var decay := float(_p["TexRestDecay"])
	var r := pow(0.5, dt/decay) if decay>0.0 else (0.0 if dt>0.0 else 1.0)
	var bias := Vector2(float(texture_mapping["bias_u"]), float(texture_mapping["bias_v"]))
	for i in range(_uv.size()):
		_uv[i] = _base_uv(params[i])*(1.0-r)+(_uv[i]+bias)*r

## Raised-cosine bump profile 0x1000abd1..0x1000ac0c: (1+cos(pi*r/sigma))/2 inside sigma, else 0.
static func bump_profile(r: float, sigma: float) -> float:
	var x := r*(1.0/sigma)*PI32
	if x>PI32: return 0.0
	return (cos(x)+1.0)*0.5

## Per-vertex weight for one event (0x1000aaaf..0x1000ae84). Returns [weight, x', y'] where x'/y'
## are the rotated local coordinates (used by texture/heightmap stages).
func event_weight(ev: Dictionary, param: Vector2) -> Vector3:
	var sigma := float(ev["sigma"])
	var inv_sigma := 1.0/sigma
	# Scales stored as f32 at 0x1000a811/0x1000a7ec: f32(2pi*1/pi)=2.0, f32(2pi*1/(2pi))=1.0.
	var dphi := param.x*2.0-float(ev["phi"])
	if dphi>PI32 and int(_p["CentWrapPhi"])==1: dphi -= TAU32
	elif dphi< -PI32 and int(_p["CentWrapPhi"])==1: dphi += TAU32
	var dtheta := param.y*1.0-float(ev["theta"])
	if dtheta>PI32 and int(_p["CentWrapTheta"])==1: dtheta -= TAU32
	elif dtheta< -PI32 and int(_p["CentWrapTheta"])==1: dtheta += TAU32
	var r := sqrt(dtheta*dtheta+dphi*dphi)
	var rot := float(ev["itheta"])
	if int(_p["BumpSyncvTheta"])==0:
		rot = float(ev["itheta"])+(float(ev["otheta"])-float(ev["itheta"]))*(r*inv_sigma*2.0)
	var cr := cos(rot); var sr := sin(rot)
	var yp := dtheta*sr+dphi*cr
	var xp := dtheta*cr-dphi*sr
	var angle := atan2(yp, xp)
	var w := 1.0
	if int(_p["DoBump"])==1: w = bump_profile(r, sigma)
	if int(_p["DoWave"])==1 and w!=0.0:
		var depth := float(ev["wave_depth"])
		w *= cos((cos(angle*float(ev["wave_n"]))*float(ev["wave_amp"])+r)*float(ev["wave_m"])+float(ev["wave_t"])*float(ev["wave_w"]))*depth+1.0-depth
	if int(_p["DoFlow"])==1 and w!=0.0:
		var fd := float(ev["flow_depth"]) if r>sigma*0.5 else r*float(ev["flow_depth"])*(2.0*inv_sigma)
		w *= cos((cos(float(ev["flow_t"])*float(ev["flow_w"])+r*float(ev["flow_n"]))*float(ev["flow_amp"])+angle)*float(ev["flow_m"]))*fd+1.0-fd
	return Vector3(w, xp, yp)

func _apply_event(ev: Dictionary, params: PackedVector2Array, s: float, disp: PackedFloat32Array, colors: PackedColorArray) -> void:
	var k := float(ev["sign"])*float(_p["AmpScale"])*s*float(ev["envelope"])   # 0x1000a8dc
	var inv_sigma := 1.0/float(ev["sigma"])
	var hm := _height_map
	var use_hmap := int(_p["DoHmap"])==1 and not hm.is_empty()
	var hx0 := 0.0; var hy0 := 0.0; var hxs := 0.0; var hys := 0.0
	if not hm.is_empty():   # 0x1000a92e..0x1000a9bb
		var w := float(hm["w"]); var h := float(hm["h"])
		hx0 = (float(ev["map_ix"])-1.0+0.5)*(1.0/float(_p["MapNX"]))*w
		hy0 = (float(ev["map_iy"])-1.0+0.5)*(1.0/float(_p["MapNY"]))*h
		hxs = w*float(ev["map_sx"])*(1.0/float(_p["MapNX"]))*inv_sigma
		hys = h*float(ev["map_sy"])*(1.0/float(_p["MapNY"]))*inv_sigma
	var tnx := float(_p["TexNX"]); var tny := float(_p["TexNY"])
	var u0 := (float(ev["tex_ix"])-1.0+0.5)*(1.0/tnx)+float(texture_mapping["offset_u"])   # 0x1000a9c2
	var v0 := (tny-float(ev["tex_iy"])+0.5)*(1.0/tny)+float(texture_mapping["offset_v"])
	var tex_type := int(_p["TexType"])
	var tx := float(ev["tex_sx"])*inv_sigma*((1.0/tnx) if tex_type==0 else 1.0)
	var ty := -float(ev["tex_sy"])*inv_sigma*((1.0/tny) if tex_type==0 else 1.0)
	var s_env := s*float(ev["envelope"])
	var do_tex := int(_p["DoTexture"])==1 and _uv.size()==params.size()
	var cur: Color = ev["current"]
	var ratio := float(_p["MapColorRatio"])
	for i in range(params.size()):
		var wxy := event_weight(ev, params[i])
		var w := wxy.x
		if w==0.0: continue
		if do_tex:   # 0x1000ad15..0x1000adde
			if tex_type==0:
				var t := clampf(w*s_env, 0.0, 1.0)
				_uv[i] = Vector2((1.0-t)*_uv[i].x+t*(wxy.y*tx+u0), (1.0-t)*_uv[i].y+t*(wxy.z*ty+v0))
			else:
				var d := w*float(_p["TexAmp"])*k
				_uv[i] = Vector2(_uv[i].x-d*wxy.y*tx, _uv[i].y-d*wxy.z*ty)
		var pix := -1
		if int(_p["DoHmap"])==1 and not hm.is_empty():   # 0x1000ade0..0x1000ae75
			var ix := int(wxy.y*hxs+hx0+0.5) % int(hm["w"])
			if ix<0: ix += int(hm["w"])
			var iy := int(wxy.z*hys+hy0+0.5) % int(hm["h"])
			if iy<0: iy += int(hm["h"])
			pix = iy*int(hm["w"])+ix
			w *= float(hm["height"][pix])
		if w==0.0: continue
		if int(_p["DoAmp"])==1: disp[i] += w*k   # 0x1000ae84
		if int(_p["DoColor"])==1:   # 0x1000aea7..0x1000b051
			var c := clampf(w, 0.0, 1.0)
			var src := colors[i]
			var target := cur
			if use_hmap and pix>=0:
				var mp: Color = hm["rgb"][pix]
				target = Color(mp.r*ratio+cur.r*(1.0-ratio), mp.g*ratio+cur.g*(1.0-ratio), mp.b*ratio+cur.b*(1.0-ratio))
			colors[i] = Color(c*target.r+(1.0-c)*src.r, c*target.g+(1.0-c)*src.g, c*target.b+(1.0-c)*src.b, src.a)

## DoMask 0x1000b090..0x1000b1c2: wrap uv to [0,1), row = H-trunc(H*v)-1, col = trunc(W*u), clamped.
func _mask_sample(uv: Vector2) -> float:
	var fv := _frac(uv.y)
	var fu := _frac(uv.x)
	var h := int(_mask_map["h"]); var w := int(_mask_map["w"])
	var row := h-int(h*fv)-1
	row = clampi(row, 0, h-1)
	var col := clampi(int(w*fu), 0, w-1)
	return float(_mask_map["height"][row*w+col])

static func _frac(x: float) -> float:
	var f := x-float(int(x))
	if f<0.0:
		f += float(int(absf(f)))
		if f<0.0: f += 1.0
	return f
