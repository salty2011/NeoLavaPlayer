extends RefCounted
## DefSwitch, Lava3.dll (factory 0x1001be90: size 0x38, ctor 0x1000d360,
## vtable 0x100332fc: setter 0x1000d3a0, update 0x1000d450). Confirmed by
## static disassembly; see docs/EFFECTS_RECOVERED.md.
##
## Cross-fades the object's morph-target weights (object+0x40 array,
## count object+0x3c >= 2) from the current shape to the next one with a
## raised-cosine over a random duration. No audio input is read by update.
##
## Fields: +0x10 DecayMin (0x6a, ctor 0.5), +0x14 DecayMax (0x69, ctor 1.0),
## +0xc duration, +0x18 elapsed, +0x28 current (0), +0x2c next (1),
## +0x30 DoSwitch request (0x87), +0x34 switching.
## Setter NextShape (0x145): if value >= 0 and not switching and value !=
## current: next = value, request = 1.
## Update:
##   if switching:
##     if elapsed >= duration: w[current]=0, w[next]=1, current=next,
##        next=current+1, switching=0          (no wrap here; wrapped on request)
##     else: elapsed += dt; k=(1+cos(pi*elapsed/duration))/2
##           w[current]=k, w[next]=1-k
##   elif request: if next >= count: next=0
##        elapsed=0, duration=RandRange(DecayMin, DecayMax), switching=1, request=0
## RandRange 0x10010b70 draws one rand() (shared stream) per switch.
const LEGACY_PI := 3.141592653589793
var decay_min := 0.5
var decay_max := 1.0
var duration := 0.0
var elapsed := 0.0
var current := 0
var next := 1
var request := 0
var switching := 0
var weights := PackedFloat32Array()
var random_source: Callable

func _init(shape_count: int = 2):
	weights.resize(maxi(shape_count, 0))
	weights.fill(0.0)
	if weights.size() > 0: weights[0] = 1.0

## Applies preset values through the original setter semantics.
func apply_preset(preset: Dictionary) -> void:
	if preset.has("DecayMin"): decay_min = float(preset.DecayMin)
	if preset.has("DecayMax"): decay_max = float(preset.DecayMax)
	if preset.has("DoSwitch"): request = int(float(preset.DoSwitch))
	if preset.has("NextShape"): set_next_shape(int(float(preset.NextShape)))

func set_next_shape(value: int) -> void:
	if value >= 0 and switching == 0 and value != current:
		next = value
		request = 1

func _random() -> float:
	return clampf(float(random_source.call()), 0.0, 1.0) if random_source.is_valid() else 0.5

func update(dt: float) -> void:
	var count := weights.size()
	if count < 2: return
	if switching == 1:
		if elapsed >= duration:
			if current < count: weights[current] = 0.0
			if next < count: weights[next] = 1.0
			current = next
			next = current + 1
			switching = 0
			return
		elapsed += dt
		var k := (1.0 + cos(LEGACY_PI * elapsed / duration)) * 0.5
		if current < count: weights[current] = k
		if next < count: weights[next] = 1.0 - k
	elif request == 1:
		if next >= count: next = 0
		elapsed = 0.0
		duration = decay_min + _random() * (decay_max - decay_min)
		switching = 1
		request = 0

## Weighted morph-target blend (positions and normals).
func blend(targets: Array, field: int) -> Variant:
	var first = targets[0][field]
	if first == null: return null
	var out := PackedVector3Array()
	out.resize(first.size())
	for k in mini(weights.size(), targets.size()):
		var w := weights[k]
		if w == 0.0: continue
		var source: PackedVector3Array = targets[k][field]
		if source.size() != out.size(): continue
		for i in out.size(): out[i] += source[i] * w
	if field == Mesh.ARRAY_NORMAL:
		for i in out.size(): out[i] = out[i].normalized()
	return out

func state_snapshot() -> Dictionary:
	return {"current": current, "next": next, "switching": switching, "elapsed": elapsed, "duration": duration, "weights": weights}
