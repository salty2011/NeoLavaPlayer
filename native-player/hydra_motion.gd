extends RefCounted
## Recovered Lava3.dll Hydra effect dynamics; inputs A/S must be supplied in
## original engine units. FFT normalization and original global random seed
## remain unresolved. Each instance preserves temporal effect state.
var _creation: Dictionary
var _effects: Array[Dictionary] = []
var _slots: Array[float] = []
var _random_state: int = 1

func reset(creation: Dictionary, effects: Array, random_seed: int = 1) -> void:
	_creation = creation.duplicate()
	_random_state = random_seed
	_slots = [float(creation.get("Rotation", 0.0)), 0.0, 0.0, 0.0, float(creation.get("ScaleFactor", 0.9))]
	_effects.clear()
	for configuration in effects:
		var kind := str(configuration.get("kind", "crawl"))
		var state: Dictionary
		if kind == "decay":
			state = {"AmpScale":1.0,"InteruptLevel":0.0,"OutputMin":0.91,"OutputMax":0.98,"DecayMin":0.2,"DecayMax":0.8,"Decay":1.0,"DecayTime":1.0,"Envelope":1.0,"Peak":0.0,"Output":0.0}
		else:
			state = {"AmpScale":1.0,"CreationLevel":0.0,"OutputLow1":0.0,"OutputHigh1":10.0,"OutputLow2":0.1,"OutputHigh2":50.0,"VMin1":0.5,"VMax1":1.0,"VMin2":1.0,"VMax2":4.0,"VDir1":1.0,"VDir2":1.0,"V1":0.0,"V2":0.0,"Output1":0.0,"Output2":0.0,"Decay":0.15}
		state.merge(configuration.get("preset", {}), true)
		# Legacy files spell this as Interruptlevel; engine ID0xf1 is InteruptLevel.
		var preset: Dictionary = configuration.get("preset", {})
		if preset.has("Interruptlevel"):
			state["InteruptLevel"] = preset["Interruptlevel"]
		state["kind"] = kind
		state["band"] = int(configuration.get("band", 0))
		state["ParamIndex0"] = int(configuration.get("param_index0", 0))
		state["ParamIndex1"] = int(configuration.get("param_index1", 1))
		# Hydra object config 0x1001e28e routes by the original effect name.
		match str(configuration.get("name", "")):
			"crawl1":
				state["ParamIndex0"] = 0
				state["ParamIndex1"] = 1
			"crawl2":
				state["ParamIndex0"] = 5
				state["ParamIndex1"] = 3
			"decay":
				state["ParamIndex0"] = 2
				state["ParamIndex1"] = 4
			"decay2":
				state["ParamIndex1"] = 4
		_effects.append(state)

func advance(engine_delta: float, bands: Array) -> Dictionary:
	# Order matters: original frame executes attached effects sequentially.
	for state in _effects:
		var band_index := int(state["band"])
		if band_index < 0 or band_index >= bands.size():
			band_index = 0
		var input: Dictionary = bands[band_index] if not bands.is_empty() else {"a":0.0,"s":0.0}
		var amplitude := float(input.get("a", 0.0))
		var scale := float(input.get("s", 0.0))
		if state["kind"] == "decay":
			_advance_decay(state, engine_delta, amplitude, scale)
		else:
			_advance_crawl(state, engine_delta, amplitude, scale)
	return frame_parameters()

func frame_parameters() -> Dictionary:
	var parameters := _creation.duplicate()
	parameters["Rotation"] = _slots[0]
	parameters["RuntimeAmplitude"] = _slots[1]
	parameters["TranslationX"] = 0.0
	parameters["TranslationY"] = 0.03999999910593033 * _slots[2] + 0.07999999821186066
	parameters["TranslationZ"] = 0.009999999776482582 * _slots[3]
	parameters["ScaleFactor"] = _slots[4]
	return parameters

func effect_states() -> Array:
	return _effects.duplicate(true)

func _write_slot(index: int, value: float, fallback: int) -> void:
	# Original clamps invalid indices to 0/1, and ignores null pointer slots.
	if index < 0 or index >= 10:
		index = fallback
	if index < _slots.size():
		_slots[index] = value

func _random_unit() -> float:
	# Exact MSVC rand LCG at 0x10028250; seed is controlled, not recovered.
	_random_state = (_random_state * 214013 + 2531011) & 0xffffffff
	return float((_random_state >> 16) & 32767) * 0.000030518509447574615

func _advance_crawl(state: Dictionary, dt: float, amplitude: float, scale: float) -> void:
	var drive := amplitude * scale * float(state["AmpScale"])
	var candidate1 := 0.0
	var candidate2 := 0.0
	if drive >= float(state["CreationLevel"]):
		candidate1 = ((1.0-drive)*float(state["VMin1"])+drive*float(state["VMax1"])) * dt * 0.5
		candidate2 = ((1.0-drive)*float(state["VMin2"])+drive*float(state["VMax2"])) * dt * 0.5
	if candidate1 >= float(state["V1"]):
		state["VDir1"] = 1.0 if _random_unit() > 0.5 else -1.0
		state["V1"] = candidate1
		state["V2"] = candidate2
	else:
		var decay := float(state["Decay"])
		var factor := exp(-0.3465735912322998 * dt / decay) if decay != 0.0 else 0.0
		state["V1"] = float(state["V1"]) * factor
		state["V2"] = float(state["V2"]) * factor
	for channel in [1, 2]:
		var suffix := str(channel)
		var output := float(state["Output"+suffix]) + float(state["VDir"+suffix]) * float(state["V"+suffix])
		if output < float(state["OutputLow"+suffix]):
			output = float(state["OutputLow"+suffix])
			state["VDir"+suffix] = 1.0
		elif output > float(state["OutputHigh"+suffix]):
			output = float(state["OutputHigh"+suffix])
			state["VDir"+suffix] = -1.0
		state["Output"+suffix] = output
	_write_slot(int(state["ParamIndex0"]), float(state["Output1"]), 0)
	_write_slot(int(state["ParamIndex1"]), float(state["Output2"]), 1)

func _advance_decay(state: Dictionary, dt: float, amplitude: float, scale: float) -> void:
	var elapsed := float(state["DecayTime"])
	var duration := float(state["Decay"])
	var envelope := 0.0
	if elapsed < duration:
		envelope = (cos(elapsed * 3.1415927410125732 / duration)+1.0) * 0.5 * float(state["Peak"])
		state["DecayTime"] = elapsed + dt
	if envelope == 0.0 or (amplitude > float(state["InteruptLevel"]) and amplitude > envelope):
		state["DecayTime"] = 0.0
		state["Peak"] = amplitude
		envelope = amplitude
		state["Decay"] = ((1.0-amplitude)*float(state["DecayMin"])+amplitude*float(state["DecayMax"])) * 0.5
	state["Envelope"] = envelope
	var output := float(state["OutputMin"]) + (float(state["OutputMax"])-float(state["OutputMin"])) * float(state["AmpScale"]) * scale * envelope
	state["Output"] = output
	_write_slot(int(state["ParamIndex0"]), output, 0)
	_write_slot(int(state["ParamIndex1"]), output, 1)
