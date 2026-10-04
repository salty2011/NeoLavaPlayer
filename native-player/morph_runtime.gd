extends RefCounted
## DefMorph static port: Lava3.dll 0x1000d550 / 0x1000d690.
## update receives original selected band A, global S, and engine dt in seconds.
## Position-only interpolation is verified at 0x10021473; UV/color remain base data.
## Normal recomputation is a separate object+138==2 path, not a target-normal blend.
var parameters: Dictionary = {}
var target_count := 0
var current_index := 0
var next_index := 1
var phase := 0.0
var active := false
var peak := 0.0
var envelope := 0.0
var elapsed := 0.0
var duration := 1.5
var weights := PackedFloat32Array()

func _init(count: int = 0, preset: Dictionary = {}):
	configure(count, preset)

func configure(count: int, preset: Dictionary = {}) -> void:
	target_count = maxi(count, 0)
	parameters = preset.duplicate()
	current_index = 0
	next_index = 1
	phase = 0.0
	active = false
	peak = 0.0
	envelope = 0.0
	elapsed = 0.0
	duration = 1.5
	weights.resize(target_count)
	weights.fill(0.0)
	if target_count > 0: weights[0] = 1.0

func update(delta: float, a: float, s: float, random_value: float = 0.0) -> PackedFloat32Array:
	if target_count < 2: return weights
	# Decay precedes threshold/retrigger tests in the DLL.
	if active:
		if elapsed >= duration:
			active = false
			envelope = 0.0
		else:
			elapsed += delta
			envelope = peak * (1.0 + cos(3.1415927410125732 * elapsed / duration)) * 0.5
	if a > float(parameters.get("CreationLevel", 0.0)):
		if not active or (a > envelope and a > float(parameters.get("InteruptLevel", 0.0))):
			active = true
			elapsed = 0.0
			peak = a
			envelope = a
			duration = (1.0-a)*float(parameters.get("DecayMin", 1.5)) + a*float(parameters.get("DecayMax", 1.5))
	var mix := s * envelope
	phase += delta * (float(parameters.get("MorphMin", 0.05))*(1.0-mix) + float(parameters.get("MorphMax", 0.5))*mix)
	# The strict > and single advance are intentional legacy behavior.
	if phase > 1.0:
		phase -= float(int(phase))
		weights[current_index] = 0.0
		if int(parameters.get("Random", 0)) == 1:
			current_index = next_index
			# DLL integer helper truncates min + rand/32767*(max+.9999-min).
			# Caller supplies random_value to avoid pretending Godot matches CRT RNG.
			next_index = int(clampf(random_value, 0.0, 1.0) * (float(target_count-1) + 0.9998999834060669))
			if next_index == current_index: next_index += 1
			if next_index == target_count: next_index = 0
		else:
			current_index = (current_index+1) % target_count
			next_index = (next_index+1) % target_count
	weights[current_index] = 1.0-phase
	weights[next_index] = phase
	return weights

func blend_positions(targets: Array) -> PackedVector3Array:
	# targets are PackedVector3Array in ASHEX morph-list order, including repeats.
	if targets.size() != target_count or target_count == 0: return PackedVector3Array()
	var count: int = targets[0].size()
	for target in targets:
		if not target is PackedVector3Array or target.size() != count: return PackedVector3Array()
	var result := PackedVector3Array()
	result.resize(count)
	for i in range(target_count):
		if weights[i] <= 0.0: continue
		for j in range(count): result[j] += targets[i][j] * weights[i]
	return result
