extends SceneTree
## Headless checks for elastic_effect.gd (DefElastic, Lava3.dll 0x1000f810).
## Run: Godot --headless --audio-driver Dummy --path native-player --script res://test_elastic_effect.gd
const ElasticEffect = preload("res://elastic_effect.gd")
const DT := 1.0 / 60.0
var failures: Array = []
var calls := 0
var fixed_value := 0.0

func _initialize() -> void:
	call_deferred("verify")

func check(name: String, ok: bool, detail: Variant = "") -> void:
	if not ok: failures.append("%s %s" % [name, str(detail)])

func near(x: float, y: float, eps := 1e-9) -> bool:
	return absf(x - y) <= eps

func fixed() -> float:
	calls += 1
	return fixed_value

func load_preset(path: String, index: int) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	var presets: Array = []
	while not file.eof_reached():
		var parts := file.get_line().strip_edges().split("\t")
		if parts.size() < 2: continue
		if parts[0] == "Preset": presets.append({})
		elif not presets.is_empty(): presets[-1][parts[0]] = float(parts[1])
	return presets[index]

func deviation(e) -> float:
	var worst := 0.0
	for i in range(16):
		var ident := 1.0 if i in [0, 5, 10, 15] else 0.0
		worst = maxf(worst, absf(e.matrix[i] - ident))
	return worst

func verify() -> void:
	# 1. ctor defaults (0x1000f1a0).
	var e = ElasticEffect.new()
	check("defaults", e.amp_scale == 1.0 and e.decay_min == 0.25 and e.restore_decay == 0.2 and e.do_restore == 1 \
		and e.min_values[5] == 0.25 and e.max_values[10] == 2.0 and e.vmin_values[0] == 5.0 and e.vmax_values[5] == 7.0 \
		and e.min_values[15] == 1.0 and e.max_values[12] == 0.0)
	# Name -> index mapping: XY = output X from input Y = row 1 col 0 = index 4; ZT = index 14.
	e.configure({"XYMin": -3.0, "ZTMax": 24.0, "YXVMax": 9.0, "ZYMin": 5.0, "XTVMin": 8.0})
	check("names", e.min_values[4] == -3.0 and e.max_values[14] == 24.0 and e.vmax_values[1] == 9.0 \
		and e.min_values[6] == 0.0 and e.vmin_values[12] == 0.0)

	# 2. Restore to identity, half-life RestoreDecay; exact under tick subdivision.
	e.configure({"DoRestore": 1, "RestoreDecay": 0.5})
	e.matrix[0] = 2.0; e.matrix[13] = 4.0
	e.update(0.5, 0.0, 1.0)
	check("restore_half_life", near(e.matrix[0], 1.5) and near(e.matrix[13], 2.0), e.matrix)
	e.matrix[0] = 2.0; e.matrix[13] = 4.0
	for t in range(30): e.update(DT, 0.0, 1.0)
	check("restore_fixed_ticks", near(e.matrix[0], 1.5, 1e-12) and near(e.matrix[13], 2.0, 1e-12), e.matrix)

	# 3. Trigger + integrate with Polyesterday preset, constant random 0.75.
	var poly := {"ResetMat": 0, "DoRestore": 1, "RestoreDecay": 0.25, "DecayMin": 0.75, "DecayMax": 0.75,
		"XXMin": 0.5, "XXMax": 2, "XXVMin": 4, "XXVMax": 4, "YYMin": 0.5, "YYMax": 2, "YYVMin": 4, "YYVMax": 4,
		"ZZMin": 1, "ZZMax": 1, "ZZVMin": 0, "ZZVMax": 0}
	e.configure(poly)
	e.random_source = Callable(self, "fixed")
	fixed_value = 0.75; calls = 0
	var t1: Transform3D = e.update(DT, 0.8, 1.0)
	var m1 := 1.0 + 0.8 * 4.0 / 60.0
	check("trigger_state", e.active and e.envelope == 0.8 and near(e.duration, 0.75) and e.velocity[0] == 4.0 and e.velocity[5] == 4.0 and e.velocity[10] == 0.0, e.state_snapshot())
	check("trigger_rand_calls", calls == 18, calls) # 16 RandRange + 2 signs (XX, YY mid-range)
	check("tick1_matrix", near(e.matrix[0], m1) and near(e.matrix[5], m1) and e.matrix[10] == 1.0, e.matrix)
	check("tick1_transform", near(t1.basis.x.x, m1, 1e-6) and near(t1.basis.y.y, m1, 1e-6) and t1.origin == Vector3.ZERO)
	var k := pow(0.5, DT / 0.25)
	var expected := (1.0 + (m1 - 1.0) * k) * (1.0 + 0.8 * 4.0 / 60.0) # interrupt resets E to 0.8 before integration
	calls = 0
	e.update(DT, 0.8, 1.0)
	check("tick2_interrupt", near(e.matrix[0], expected) and e.envelope == 0.8 and e.age == 0.0 and calls == 0, [e.matrix[0], expected, calls])

	# 4. Bounce off Min and random-sign branch (random 0 -> sign -1, RandRange = lo).
	e.configure({"DoRestore": 0, "XXMin": 0.5, "XXMax": 2, "XXVMin": 60, "XXVMax": 60})
	fixed_value = 0.0
	e.update(DT, 1.0, 1.0)
	check("bounce_min", e.matrix[0] == 0.5 and e.velocity[0] == 60.0, [e.matrix[0], e.velocity[0]])
	check("default_yy", near(e.matrix[5], 1.0 - 5.0 / 60.0) and e.velocity[5] == -5.0, [e.matrix[5], e.velocity[5]])
	e.matrix[0] = 1.8; e._regenerate()
	check("regen_upper_quarter", e.velocity[0] == -60.0, e.velocity[0])
	e.matrix[0] = 0.6; e._regenerate()
	check("regen_lower_quarter", e.velocity[0] == 60.0, e.velocity[0])
	e.matrix[0] = 1.99; e.velocity[0] = 60.0
	e.update(DT, 1.0, 1.0)
	check("bounce_max", e.matrix[0] == 2.0 and e.velocity[0] < 0.0, [e.matrix[0], e.velocity[0]])

	# 5. Interrupt regenerates velocities only once the 0.1 s timer has elapsed.
	e.configure({})
	calls = 0
	e.update(0.05, 1.0, 1.0); var c1 := calls
	e.update(0.05, 1.0, 1.0); var c2 := calls
	e.update(0.05, 1.0, 1.0); var c3 := calls
	check("regen_interval", c1 == 19 and c2 == c1 and c3 >= c1 + 16, [c1, c2, c3]) # 16 RandRange + 3 diagonal signs

	# 6. Real presets with the internal LegacyRand stream.
	var p := load_preset("res://scenes/lava25/Polyesterday/defelastic.lvd", 0)
	e = ElasticEffect.new(); e.configure(p)
	var peak_dev := 0.0
	for t in range(120):
		e.update(DT, 1.0, 1.0); peak_dev = maxf(peak_dev, deviation(e))
	for t in range(600): e.update(DT, 0.0, 1.0)
	var settled := deviation(e)
	check("poly_motion", peak_dev > 0.1, peak_dev)
	check("poly_settles", settled < 1e-4 and not e.active, settled)
	var d := load_preset("res://scenes/lava25/Cyber Diva (Hi-res)/defelastic.lvd", 0)
	var c = ElasticEffect.new(); c.configure(d)
	var diva_dev := 0.0
	for t in range(120):
		c.update(DT, 1.0, 1.0); diva_dev = maxf(diva_dev, deviation(c))
	for t in range(300): c.update(DT, 0.0, 1.0)
	var frozen: PackedFloat64Array = c.matrix.duplicate()
	for t in range(300): c.update(DT, 0.0, 1.0)
	check("diva_motion", diva_dev > 0.1, diva_dev)
	check("diva_freezes_no_restore", c.matrix == frozen and not c.active)

	var result := {"test": "elastic_effect", "passed": failures.is_empty(), "failures": failures,
		"polyesterday_peak_deviation": peak_dev, "polyesterday_settled_deviation": settled,
		"cyber_diva_peak_deviation": diva_dev, "cyber_diva_final_matrix": Array(c.matrix)}
	print(JSON.stringify(result))
	quit(0 if failures.is_empty() else 1)
