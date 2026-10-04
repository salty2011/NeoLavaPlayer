extends RefCounted
## Static DefScale/DefShear ports; original row-vector matrix composition transposed
## into Godot column-vector Transform3D. Apply returned effect as effect * current.
## Caller owns frame resets, attachment ordering, and parent world composition.
const LEGACY_PI := 3.1415927410125732
var kind := ""
var parameters: Dictionary = {}
var active := false
var peak := 0.0
var envelope := 0.0
var elapsed := 0.0
var duration := 0.75
var axis_selector := 0.0
var shear_ray := Vector2.ZERO
var direction := 0.0
var direction_threshold := 1.0
var random_source: Callable

func configure(effect_type: String,preset: Dictionary={}) -> void:
	kind=effect_type
	parameters=preset.duplicate()
	active=false; peak=0.0; envelope=0.0; elapsed=0.0; duration=0.75
	axis_selector=0.0; shear_ray=Vector2.ZERO; direction=0.0
	direction_threshold=float(preset.get("Direction",1.0))
func _p(key: String,value: float) -> float: return float(parameters.get(key,value))
func _random() -> float: return clampf(float(random_source.call()) if random_source.is_valid() else randf(),0.0,1.0)
func _decay(dt: float) -> void:
	if not active: return
	if elapsed>=duration:
		active=false
		# DefShear preserves stale E but outputs identity when inactive.
		if kind=="DefScale": envelope=0.0
	else:
		elapsed+=dt
		envelope=peak*(1.0+cos(LEGACY_PI*elapsed/duration))*0.5
func _trigger(a: float,fresh: bool) -> void:
	active=true; elapsed=0.0; peak=a; envelope=a
	var low:=0.75 if kind=="DefScale" else 0.4000000059604645
	var high:=0.75 if kind=="DefScale" else 0.6000000238418579
	duration=(1.0-a)*_p("DecayMin",low)+a*_p("DecayMax",high)
	if not fresh: return
	if kind=="DefScale": axis_selector=_random()
	else:
		var radius:=_random()*_p("RMax",0.5)
		var angle:=_random()*LEGACY_PI*2.0
		shear_ray=Vector2(cos(angle),sin(angle))*radius
		direction=-1.0 if _random()*2.0-1.0>direction_threshold else 1.0
		direction_threshold*=_p("DirectionMultiply",1.0)

func update(dt: float,a: float,s: float,parent_local: Variant=null) -> Transform3D:
	if kind=="DefShear" and int(parameters.get("FollowParent",0))!=0 and parent_local is Transform3D:
		# Parent's local matrix translation, not parent world position or audio.
		var parent_position: Vector3=parent_local.origin
		var shear:=_shear(parent_position/_p("Height",1.0),_p("Base",0.0))
		return shear*Transform3D(Basis.IDENTITY,-parent_position)
	_decay(dt)
	if a>_p("CreationLevel",0.0) and (not active or (a>envelope and a>_p("InteruptLevel",0.0))):
		_trigger(a,not active)
	if kind=="DefScale":
		var expansion:=1.0+envelope*_p("AmpScale",0.75)*s
		var compensation:=sqrt(1.0/expansion)
		var factors:=Vector3.ONE*compensation
		var axis:=0 if axis_selector<_p("AxisMin",0.5) else (1 if axis_selector<_p("AxisMax",1.0) else 2)
		factors[axis]=expansion
		return Transform3D(Basis.from_scale(factors),Vector3.ZERO)
	if kind=="DefShear" and active:
		var k:=s*_p("AmpScale",1.0)*envelope/_p("Height",1.0)
		return _shear(Vector3(shear_ray.x,direction*_p("ZMax",0.5),shear_ray.y)*k,_p("Base",0.0))
	return Transform3D.IDENTITY

static func _shear(h: Vector3,base: float) -> Transform3D:
	# x'=x+hx*(y-base), y'=y+hy*(y-base), z'=z+hz*(y-base).
	return Transform3D(Basis(Vector3.RIGHT,Vector3(h.x,1.0+h.y,h.z),Vector3.BACK),-base*h)

static func compose(current: Transform3D,effect: Transform3D) -> Transform3D:
	return effect*current
