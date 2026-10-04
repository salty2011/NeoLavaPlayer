extends RefCounted
## Static Lava3.dll DefAlpha and DefCenter ports. Engine dt seconds, selected A/S.
## Alpha overwrites all vertex alpha values. Center returns a translation effect;
## original currentRow*effectRow converts to effect*current in Godot.
const LEGACY_PI := 3.1415927410125732
var kind := ""
var parameters: Dictionary = {}
var active := false
var peak := 0.0
var envelope := 0.0
var elapsed := 0.0
var duration := 0.75
var alpha := 1.0
var alpha_direction := -1.0
var ray := Vector2.ZERO
var center_direction := 0.0
var direction_threshold := 1.0
var random_source: Callable

func configure(effect_type: String,preset: Dictionary={}) -> void:
	kind=effect_type; parameters=preset.duplicate()
	active=false; peak=0.0; envelope=0.0; elapsed=0.0; duration=0.75
	alpha=float(preset.get("Alpha",1.0))
	# AlphaVelocityDirection enum5 is NOT handled by original DefAlpha setter.
	alpha_direction=-1.0
	ray=Vector2.ZERO; center_direction=0.0
	direction_threshold=float(preset.get("Direction",1.0))
func _p(key: String,value: float) -> float: return float(parameters.get(key,value))
func _random() -> float: return clampf(float(random_source.call()) if random_source.is_valid() else randf(),0.0,1.0)
func _envelope(dt: float,a: float) -> void:
	if active:
		if elapsed>=duration:
			active=false
			if kind=="DefAlpha": envelope=0.0
		else:
			elapsed+=dt
			envelope=peak*(1.0+cos(LEGACY_PI*elapsed/duration))*0.5
	if a<=_p("CreationLevel",0.0): return
	if active and (a<=envelope or a<=_p("InteruptLevel",0.0)): return
	var fresh:=not active
	active=true; elapsed=0.0; peak=a; envelope=a
	var low:=0.75 if kind=="DefAlpha" else 0.4000000059604645
	var high:=0.75 if kind=="DefAlpha" else 0.6000000238418579
	duration=(1.0-a)*_p("DecayMin",low)+a*_p("DecayMax",high)
	if kind=="DefCenter" and fresh:
		var radius:=_random()*_p("RMax",0.5)
		var angle:=_random()*LEGACY_PI*2.0
		ray=Vector2(cos(angle),sin(angle))*radius
		center_direction=-1.0 if _random()*2.0-1.0>direction_threshold else 1.0
		direction_threshold*=_p("DirectionMultiply",1.0)

func update(dt: float,a: float,s: float) -> Dictionary:
	_envelope(dt,a)
	if kind=="DefAlpha":
		var mix:=s*envelope
		alpha+=dt*alpha_direction*(_p("AlphaVelocityMin",0.0)*(1.0-mix)+_p("AlphaVelocityMax",0.20000000298023224)*mix)
		# Original >=maximum and <=minimum comparisons, in this order.
		if alpha>=_p("AlphaMax",1.0): alpha=_p("AlphaMax",1.0); alpha_direction=-1.0
		if alpha<=_p("AlphaMin",0.0): alpha=_p("AlphaMin",0.0); alpha_direction=1.0
		return {"alpha":alpha,"transform":Transform3D.IDENTITY}
	var offset:=Vector3.ZERO
	if kind=="DefCenter" and active:
		var k:=s*_p("AmpScale",1.0)*envelope
		offset=Vector3(ray.x,center_direction*_p("ZMax",0.5),ray.y)*k
	return {"alpha":1.0,"transform":Transform3D(Basis.IDENTITY,offset)}

func apply_alpha(colors: PackedColorArray) -> PackedColorArray:
	var result:=colors.duplicate()
	for i in range(result.size()):
		var color:=result[i]
		color.a=alpha
		result[i]=color
	return result
