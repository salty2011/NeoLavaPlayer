extends RefCounted
# Static port of Lava3.dll update math; FFT-to-A/S mapping is not recovered.
# See research/oozic/disassembly/audio-mapping-notes.md for addresses/evidence.
var parameters={}
var active=false
var peak=0.0
var envelope=0.0
var elapsed=0.0
var duration=1.0
var direction=1.0
var direction_threshold=1.0
var angle=0.0
var texture_scale=Vector2.ONE
var texture_direction=Vector2.ONE
func configure(p):
	parameters=p
	angle=float(p.get("Angle",0.0))
	direction_threshold=float(p.get("AngleVelocityDirection",1.0))
	texture_scale=Vector2.ONE
func trigger(a,initial):
	active=true
	peak=a
	envelope=a
	elapsed=0.0
	duration=(1.0-a)*float(parameters.get("DecayMin",0.75))+a*float(parameters.get("DecayMax",0.75))
	if initial:
		# Hydroid thresholds are exactly +/-1; choose their limiting outcomes.
		direction=1.0 if direction_threshold>=1.0 else -1.0
		direction_threshold*=float(parameters.get("AngleVDirectionMultiply",-1.0))
func update_envelope(delta,a):
	if not active:
		if a>float(parameters.get("CreationLevel",0.0)): trigger(a,true)
	elif a>envelope and a>float(parameters.get("Interruptlevel",0.0)):
		trigger(a,false)
	elif elapsed<duration and duration>0:
		elapsed+=delta
		envelope=peak*(1.0+cos(3.1415927410125732*elapsed/duration))*0.5
	else:
		envelope=0.0
		active=false
func rotate(delta,a,s):
	update_envelope(delta,a)
	var vmin=float(parameters.get("AngleVelocityMin",0.0))
	var vmax=float(parameters.get("AngleVelocityMax",45.0))
	angle+=delta*direction*(vmin*(1.0-s*envelope)+vmax*s*envelope)
	angle=fmod(angle,360.0)
	return deg_to_rad(angle)
func texscroll(delta,a,s):
	update_envelope(delta,a)
	var vmin=float(parameters.get("VMin",0.0))
	var vmax=float(parameters.get("VMax",1.0))
	var k=delta*s*(vmin*(1.0-envelope)+vmax*envelope)
	for i in range(2):
		var suffix="X" if i==0 else "Y"
		var low=float(parameters.get("TextureLow"+suffix,1.0))
		var high=float(parameters.get("TextureHigh"+suffix,1.0))
		texture_scale[i]*=1.0+texture_direction[i]*k
		if texture_scale[i]<low:
			texture_scale[i]=low
			texture_direction[i]=1.0
		elif texture_scale[i]>high:
			texture_scale[i]=high
			texture_direction[i]=-1.0
	return texture_scale

func orbit(delta,a,s):
	# 0x1000e39f..0x1000e512: orthonormal basis from OrbitNormal;
	# translation = radius * (v*sin(angle) - (normal cross v)*cos(angle)).
	var radians=rotate(delta,a,s)
	var normal=Vector3(float(parameters.get("OrbitNormal0",0.0)),float(parameters.get("OrbitNormal1",1.0)),float(parameters.get("OrbitNormal2",0.0)))
	if normal.is_zero_approx(): normal=Vector3.UP
	normal=normal.normalized()
	var azimuth=atan2(normal.y,normal.x)
	var polar=atan2(Vector2(normal.x,normal.y).length(),normal.z)+1.5707963705062866
	var v=Vector3(sin(polar)*cos(azimuth),sin(polar)*sin(azimuth),cos(polar))
	return float(parameters.get("OrbitRadius",26.0))*(v*sin(radians)-normal.cross(v)*cos(radians))
