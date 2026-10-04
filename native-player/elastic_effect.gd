extends RefCounted
## DefElastic port (Lava3.dll, static analysis only). Matrix effect, NOT per-vertex.
## Factory 0x1001be90 (0x1d0 bytes), ctor 0x1000f1a0, vtable 0x10033364:
##   +0 0x10001bd0 dtor, +4 0x1000f2a0 property setter, +8 0x1000f810 update.
## State is a persistent 4x4 row-vector matrix M (+0x48). Every element i has its
## own clamp range [Min (+0x88), Max (+0xc8)], a velocity V (+0x108) and a speed
## range [VMin (+0x148), VMax (+0x188)]. While the audio envelope is active each
## element moves at AmpScale*E*S*dt*V (diagonal scale elements multiplicatively),
## bouncing off its clamp range; DoRestore pulls M back to identity with a
## half-life of RestoreDecay seconds. update() returns M transposed into a Godot
## column-vector Transform3D. The original multiplies M into the object matrix with
## the same helper/argument order as DefShear (0x100103b0(objMat, M, 4) at
## 0x1000fbd7 vs 0x1000f182), so compose it like DefScale/DefShear:
##   effect_transform = MatrixEffects.compose(effect_transform, elastic.update(dt, a, s))
## The matrix persists between frames (it is effect state, not rebuilt per frame).
## See research/oozic/disassembly/elastic-recovery-notes.md.
const LegacyRand = preload("res://legacy_rand.gd")
const LEGACY_PI := 3.141592653589793 # f64 at 0x10033240
const REGEN_INTERVAL := 0.1 # +0x40 = 0.1f (ctor 0x1000f1e2)
const _AXES := {"X": 0, "Y": 1, "Z": 2, "T": 3}

var random_source: Callable # U[0,1] = rand()/32767; falls back to an internal LegacyRand.
var _legacy := LegacyRand.new()

# Parameters (ctor defaults 0x1000f1a0).
var amp_scale := 1.0 # +0x3c AmpScale (id 6)
var decay_min := 0.25 # +0x24 DecayMin (0x6a)
var decay_max := 0.25 # +0x28 DecayMax (0x69)
var creation_level := 0.0 # +0x2c CreationLevel (0x64)
var interupt_level := 0.0 # +0x30 InteruptLevel (0xf1)
var reset_mat := 0 # +0xc ResetMat (0x1a0): stored, never read by DefElastic.
var do_restore := 1 # +0x1c8 DoRestore (0x86), ftol'd int, tested == 1.
var restore_decay := 0.2 # +0x1cc RestoreDecay (0x1a3), half-life seconds.
var min_values := PackedFloat64Array() # +0x88
var max_values := PackedFloat64Array() # +0xc8
var vmin_values := PackedFloat64Array() # +0x148
var vmax_values := PackedFloat64Array() # +0x188

# State.
var matrix := PackedFloat64Array() # +0x48, row-major, row-vector convention.
var velocity := PackedFloat64Array() # +0x108
var envelope := 0.0 # +0x14
var peak := 0.0 # +0x18
var duration := 0.0 # +0x1c
var age := 0.0 # +0x20
var active := false # +0x34
var regen_timer := 0.0 # +0x44
var band_a := 0.0 # +0x10
var band_s := 0.0 # +0x38

func _init() -> void:
	configure({})

static func _identity() -> PackedFloat64Array:
	var m := PackedFloat64Array()
	m.resize(16)
	m.fill(0.0)
	for i in [0, 5, 10, 15]: m[i] = 1.0
	return m

## Resets to ctor defaults, then applies preset keys (names as in .lvd files).
func configure(preset: Dictionary) -> void:
	amp_scale = 1.0; decay_min = 0.25; decay_max = 0.25
	creation_level = 0.0; interupt_level = 0.0; reset_mat = 0
	do_restore = 1; restore_decay = 0.2
	matrix = _identity()
	min_values = _identity(); max_values = _identity()
	vmin_values = PackedFloat64Array(); vmin_values.resize(16); vmin_values.fill(0.0)
	vmax_values = vmin_values.duplicate()
	velocity = vmin_values.duplicate()
	for i in [0, 5, 10]:
		min_values[i] = 0.25; max_values[i] = 2.0 # 0x1000f235.. +0x88/+0x9c/+0xb0, +0xc8/+0xdc/+0xf0
		vmin_values[i] = 5.0; vmax_values[i] = 7.0 # +0x148/+0x15c/+0x170 = 5, +0x188/+0x19c/+0x1b0 = 7
	envelope = 0.0; peak = 0.0; duration = 0.0; age = 0.0; active = false
	regen_timer = 0.0; band_a = 0.0; band_s = 0.0
	for key in preset.keys():
		_set_parameter(String(key), float(preset[key]))

## Setter 0x1000f2a0. Element names are <Out><In><Min|Max|VMin|VMax>, Out in X/Y/Z
## (matrix column), In in X/Y/Z/T (matrix row; T = translation row), index = row*4+col.
## Unsupported by the original setter: ZY* (ids 0x261..0x264 fall through) and the
## XT velocity minimum (id 0x23b is named "XXVMin" in LavaFile's table, so a preset
## "XXVMin" resolves to the later id 0x23f = XX velocity minimum).
func _set_parameter(key: String, value: float) -> void:
	match key:
		"AmpScale": amp_scale = value
		"DecayMin": decay_min = value
		"DecayMax": decay_max = value
		"CreationLevel": creation_level = value
		"InteruptLevel", "Interruptlevel": interupt_level = value
		"ResetMat": reset_mat = int(value)
		"DoRestore": do_restore = int(value)
		"RestoreDecay": restore_decay = value
		_:
			if key.length() < 5 or not _AXES.has(key[0]) or not _AXES.has(key[1]): return
			var column: int = _AXES[key[0]]
			var row: int = _AXES[key[1]]
			if column > 2 or key.begins_with("ZY") or key == "XTVMin": return
			var index := row * 4 + column
			match key.substr(2):
				"Min": min_values[index] = value
				"Max": max_values[index] = value
				"VMin": vmin_values[index] = value
				"VMax": vmax_values[index] = value

func _random() -> float:
	return float(random_source.call()) if random_source.is_valid() else _legacy.unit()

## 0x10010b70 RandRange(lo, hi) = lo + rand()/32767 * (hi - lo).
func _rand_range(lo: float, hi: float) -> float:
	return lo + _random() * (hi - lo)

## 0x10010ba0: (ftol(rand()/32767 + 0.5) - 0.5) * 2 -> -1 or +1.
func _rand_sign() -> float:
	return (float(int(_random() + 0.5)) - 0.5) * 2.0

## Velocity regeneration loop (0x1000f980 / duplicate at 0x1000fa83).
func _regenerate() -> void:
	for i in range(16):
		var lo := min_values[i]
		var span := max_values[i] - lo
		var lower_quarter := span * 0.25 + lo
		var upper_quarter := span * 0.75 + lo
		if upper_quarter < matrix[i]:
			velocity[i] = -_rand_range(vmin_values[i], vmax_values[i]) # near Max: head down
		elif matrix[i] <= lower_quarter:
			velocity[i] = _rand_range(vmin_values[i], vmax_values[i]) # near Min: head up
		else:
			var speed := _rand_range(vmin_values[i], vmax_values[i])
			velocity[i] = speed * _rand_sign()

func _retrigger(a: float) -> void:
	age = 0.0; peak = a; envelope = a
	duration = (1.0 - a) * decay_min + a * decay_max

## Update 0x1000f810, once per engine tick. a/s = the Input1Band record's A
## (+0xc) and S (+0x10); an out-of-range band falls back to band 0.
func update(dt: float, a: float, s: float) -> Transform3D:
	band_a = a; band_s = s
	if do_restore == 1: # 0x1000f879: M = (1-k)*I + k*M, k = 0.5^(dt/RestoreDecay)
		var k := 0.0 if restore_decay <= 0.0 and dt > 0.0 else (1.0 if restore_decay <= 0.0 else pow(0.5, dt / restore_decay))
		var identity := _identity()
		for i in range(16): matrix[i] = (1.0 - k) * identity[i] + k * matrix[i]
	if active: # 0x1000f8dc envelope decay
		if age >= duration:
			active = false; envelope = 0.0
		else:
			age += dt
			envelope = (cos(age * LEGACY_PI / duration) + 1.0) * 0.5 * peak
	if regen_timer < REGEN_INTERVAL: regen_timer += dt # 0x1000f91d
	if a > creation_level: # 0x1000f934
		if not active:
			active = true
			_retrigger(a)
			regen_timer = 0.0
			_regenerate()
		elif a > envelope and a > interupt_level: # 0x1000fa21
			_retrigger(a)
			if regen_timer >= REGEN_INTERVAL:
				regen_timer = 0.0
				_regenerate()
	if active: # 0x1000fb23 integrate + bounce
		var gain := amp_scale * envelope * band_s * dt
		for i in range(16):
			var step := gain * velocity[i]
			if i == 0 or i == 5 or i == 10: matrix[i] = (step + 1.0) * matrix[i]
			else: matrix[i] = step + matrix[i]
			if matrix[i] <= min_values[i]:
				matrix[i] = min_values[i]; velocity[i] = absf(velocity[i])
			if matrix[i] >= max_values[i]:
				matrix[i] = max_values[i]; velocity[i] = -absf(velocity[i])
	return transform()

## Row-vector M (v' = v*M) transposed to Godot: basis column j = row j of M,
## origin = translation row 3. Column 3 of M stays (0,0,0,1): nothing can set it.
func transform() -> Transform3D:
	var m := matrix
	return Transform3D(Basis(Vector3(m[0], m[1], m[2]), Vector3(m[4], m[5], m[6]), Vector3(m[8], m[9], m[10])), Vector3(m[12], m[13], m[14]))

func state_snapshot() -> Dictionary:
	return {
		"matrix": Array(matrix), "velocity": Array(velocity), "active": active,
		"envelope": envelope, "peak": peak, "duration": duration, "age": age,
		"regen_timer": regen_timer, "band_a": band_a, "band_s": band_s,
		"do_restore": do_restore, "restore_decay": restore_decay, "amp_scale": amp_scale,
	}
