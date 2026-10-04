extends RefCounted
## DefShape Lava3.dll ctor 0x1000d110, update 0x1000d1f0.
## First two attached shapes receive [1-k,k]. Original does not clamp k.
var _preset: Dictionary = {}
var _active := false
var _elapsed := 0.0
var _duration := 0.0
var _peak := 0.0
var _envelope := 0.0

func reset(preset: Dictionary) -> void:
	_preset = {"AmpScale":1.0,"DecayMin":0.4,"DecayMax":0.6,"CreationLevel":0.0,"InteruptLevel":0.0}
	_preset.merge(preset,true)
	if preset.has("Interruptlevel"): _preset["InteruptLevel"] = preset["Interruptlevel"]
	_active = false
	_elapsed = 0.0
	_duration = 0.0
	_peak = 0.0
	_envelope = 0.0

func update(amplitude: float, scale: float, dt: float, shape_count: int = 2) -> PackedFloat32Array:
	if shape_count < 2: return PackedFloat32Array()
	if _active:
		if _elapsed >= _duration:
			_active = false
		else:
			_elapsed += dt
			_envelope = _peak * (1.0+cos(_elapsed*3.1415927410125732/_duration))*0.5
	if amplitude > float(_preset["CreationLevel"]):
		if not _active or (amplitude > _envelope and amplitude > float(_preset["InteruptLevel"])):
			_active = true
			_elapsed = 0.0
			_peak = amplitude
			_envelope = amplitude
			_duration = lerpf(float(_preset["DecayMin"]),float(_preset["DecayMax"]),amplitude)
	var k := _envelope*float(_preset["AmpScale"])*scale if _active else 0.0
	return PackedFloat32Array([1.0-k,k])

func state_snapshot() -> Dictionary:
	return {"active":_active,"elapsed":_elapsed,"duration":_duration,"peak":_peak,"envelope":_envelope}
