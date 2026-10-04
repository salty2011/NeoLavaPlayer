extends RefCounted
## Static ports of Lava3.dll DefTexTranslate / DefTexWave / DefTexZoom.
## Shared context uses repeat, center; angular=(phi,theta), in radians.
## UVs overwrite from raw angular coordinates; context must persist in binding order.
const LEGACY_PI := 3.1415927410125732
const DEGREES := 0.01745329238474369
const INV_TAU := 0.15915493667125702
const INV_PI := 0.31830987334251404
var kind := ""
var parameters: Dictionary = {}
var active := false
var peak := 0.0
var envelope := 0.0
var elapsed := 0.0
var duration := 1.0
var direction := Vector2.ZERO
var threshold := Vector2.ONE
var m := 0.0
var m_direction := 1.0
var phase := 0.0
var phase_direction := 1.0
var zoom_repeat := Vector2.ONE
var zoom_center := Vector2(LEGACY_PI,LEGACY_PI*0.5)
var center_velocity := Vector2.ZERO
var repeat_velocity := Vector2.ZERO
var between_elapsed := 0.0
## Supply CRT-derived rand/32767 values if reproducing an original random stream.
var random_source: Callable

func configure(effect_type: String, preset: Dictionary = {}) -> void:
	kind=effect_type
	parameters=preset.duplicate()
	active=false; peak=0.0; envelope=0.0; elapsed=0.0; duration=1.0
	direction=Vector2(float(preset.get("VXDirection",0)),float(preset.get("VYDirection",0)))
	threshold=Vector2(float(preset.get("VXDir",preset.get("VDirX",1))),float(preset.get("VYDir",preset.get("VDirY",1))))
	# Direction setters also select an initial sign before first activation.
	for i in range(2):
		var keys=["VXDir","VDirX"] if i==0 else ["VYDir","VDirY"]
		if preset.has(keys[0]) or preset.has(keys[1]): direction[i]=_sign(threshold[i])
	m=0.0; m_direction=1.0; phase=0.0; phase_direction=float(preset.get("PhaseVDir",1))
	zoom_repeat=Vector2.ONE; zoom_center=Vector2(LEGACY_PI,LEGACY_PI*0.5)
	center_velocity=Vector2.ZERO; repeat_velocity=Vector2.ZERO; between_elapsed=0.0

func _random() -> float:
	return clampf(float(random_source.call()) if random_source.is_valid() else randf(),0.0,1.0)
func _range(low: float,high: float) -> float: return low+(high-low)*_random()
func _sign(limit: float) -> float: return -1.0 if _range(-1.0,1.0)>limit else 1.0
func _p(key: String,default: float) -> float: return float(parameters.get(key,default))
func _decay(dt: float,clear_expired: bool=true) -> void:
	if not active: return
	if elapsed>=duration:
		active=false
		if clear_expired: envelope=0.0
	else:
		elapsed+=dt
		envelope=peak*(1.0+cos(LEGACY_PI*elapsed/duration))*0.5
func _trigger(a: float,default_decay: float) -> void:
	active=true; elapsed=0.0; peak=a; envelope=a
	duration=(1.0-a)*_p("DecayMin",default_decay)+a*_p("DecayMax",default_decay)
func _eligible(a: float) -> bool:
	return a>_p("CreationLevel",0) and (not active or (a>envelope and a>_p("InteruptLevel",0)))

func update(dt: float,a: float,s: float,context: Dictionary) -> Dictionary:
	var repeat: Vector2=context.get("repeat",Vector2.ONE)
	var center: Vector2=context.get("center",Vector2.ZERO)
	if kind=="DefTexTranslate":
		_decay(dt)
		if _eligible(a):
			var fresh:=not active
			_trigger(a,1.0)
			if fresh:
				for i in range(2):
					direction[i]=_sign(threshold[i])
					threshold[i]*=_p("VXDirMultiply" if i==0 else "VYDirMultiply",1)
		for i in range(2):
			var axis: String="X" if i==0 else "Y"
			var velocity:=dt*s*(_p("V"+axis+"Min",0)*(1.0-envelope)+_p("V"+axis+"Max",1)*envelope)
			center[i]-=repeat[i]*direction[i]*velocity
			# Original wraps a single turn, not modulo, and equality1 is retained.
			if center[i]<0.0: center[i]+=1.0
			elif center[i]>1.0: center[i]-=1.0
	elif kind=="DefTexWave":
		_decay(dt)
		if _eligible(a): _trigger(a,1.0)
		var mv:=dt*s*(_p("MVMin",0)*(1.0-envelope)+_p("MVMax",0)*envelope)
		m*=1.0+m_direction*mv
		var low:=_p("MMin",4); var high:=_p("Mmax",4)
		if m<low: m=low; m_direction=1.0
		elif m>high: m=high; m_direction=-1.0
		phase+=dt*s*(_p("PhaseVMin",0)*(1.0-envelope)+_p("PhaseVMax",180)*envelope)*DEGREES*phase_direction
		low=_p("PhaseMin",0)*DEGREES; high=_p("PhaseMax",1440)*DEGREES
		if phase<low: phase=low; phase_direction=1.0
		elif phase>high: phase=high; phase_direction=-1.0
	elif kind=="DefTexZoom":
		_update_zoom(dt,a,s)
		repeat=zoom_repeat
		center=Vector2((zoom_center.x-LEGACY_PI)*INV_TAU,(zoom_center.y-LEGACY_PI*0.5)*INV_PI)
	context.repeat=repeat
	context.center=center
	context["wave_s"]=s
	return context

func apply_uv(angular: PackedVector2Array,context: Dictionary,previous: PackedVector2Array=PackedVector2Array()) -> PackedVector2Array:
	if kind != "DefTexZoom" and int(parameters.get("DoTex",parameters.get("DoTexture",1)))!=1: return previous
	var repeat: Vector2=context.get("repeat",Vector2.ONE)
	var center: Vector2=context.get("center",Vector2.ZERO)
	var out:=PackedVector2Array()
	out.resize(angular.size())
	for i in range(angular.size()):
		var coord:=angular[i]
		var uv:=Vector2(repeat.x*coord.y*INV_TAU+center.x,(LEGACY_PI-coord.x)*repeat.y*INV_PI+center.y)
		if kind=="DefTexWave":
			var depth:=_p("CosDepth",2)*0.5
			var horizontal:=_p("Orient",_p("Orientation",1))==-1.0
			var angle: float=coord.x if horizontal else coord.y
			var shape:=cos(angle*m+phase)*depth+(1.0-depth)
			var displacement:=shape*float(context.get("wave_s",0))*_p("Direction",1)*_p("AmpScale",7.5)
			if horizontal: uv.x+=displacement*repeat.x*0.0027777778450399637
			else: uv.y-=displacement*repeat.y*0.0055555556900799274
		out[i]=uv
	return out

func _pick_zoom_velocity() -> void:
	var speed:=_range(_p("CentVelocityMin",_p("CentVMin",360)),_p("CentVelocityMax",_p("CentVMax",540)))*DEGREES
	var angle:=_range(_p("CentVelocityDirectionMin",_p("CentVDirMin",0)),_p("CentVelocityDirectionMax",_p("CentVDirMax",360)))*DEGREES
	center_velocity=Vector2(cos(angle),sin(angle))*speed
	# DLL setter bug: both RepXVMin/RepXVMax write the max slot; min stays4.
	var x_max:=_p("RepXVMax",_p("RepXVMin",8))
	var vx:=_range(4.0,x_max)
	if zoom_repeat.x>=_p("RepXMax",2): vx=-vx
	elif zoom_repeat.x>=_p("RepXMin",0.25): vx*=(-1.0 if _random()<0.5 else 1.0)
	repeat_velocity.x=vx
	var vy:=_range(_p("RepYVMin",4),_p("RepYVMax",8))
	if zoom_repeat.y>=_p("RepYMax",2): vy=-vy
	# The original Y low test incorrectly tests X repeat and X minimum.
	elif zoom_repeat.x>=_p("RepXMin",0.25): vy*=(-1.0 if _random()<0.5 else 1.0)
	repeat_velocity.y=vy

func _update_zoom(dt: float,a: float,s: float) -> void:
	if int(parameters.get("DoRestore",1))==1:
		var factor:=pow(0.5,dt/_p("RestoreDecay",0.2))
		zoom_center=zoom_center*factor+Vector2(LEGACY_PI,LEGACY_PI*0.5)*(1.0-factor)
		zoom_repeat=zoom_repeat*factor+Vector2.ONE*(1.0-factor)
	_decay(dt,false)
	if between_elapsed<_p("MinBetweenTime",0.1): between_elapsed+=dt
	if _eligible(a):
		var fresh:=not active
		_trigger(a,0.25)
		if fresh or between_elapsed>=_p("MinBetweenTime",0.1):
			between_elapsed=0.0
			_pick_zoom_velocity()
	var k:=s*envelope*_p("AmpScale",1)*dt
	zoom_center+=center_velocity*zoom_repeat*k
	zoom_repeat*=Vector2.ONE+repeat_velocity*k
	for i in range(2):
		var maximum:=LEGACY_PI*2.0 if i==0 else LEGACY_PI
		if zoom_center[i]>maximum: zoom_center[i]=maximum; center_velocity[i]=-absf(center_velocity[i])
		elif zoom_center[i]<0.0: zoom_center[i]=0.0; center_velocity[i]=absf(center_velocity[i])
