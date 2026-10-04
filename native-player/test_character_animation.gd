extends SceneTree
## Modern character animation (Phase 4d). Silent, headless:
##   Godot --headless --audio-driver Dummy --path native-player --script res://test_character_animation.gd
## Mock 128 BPM, default schedule, Triple Trance's three heads on their stems.
## 1. Beat-move peaks land on beats: every extremum of every move's contribution
##    is within one frame + 10 ms of a beat (60 and 144 fps).
## 2. Blending continuity: no jumps in the head offsets or twist, including the
##    frames where moves change (cross-fades over half a beat).
## 3. Squash and stretch preserves volume (det = 1) and stays subtle.
## 4. Stems stay planted on the platform and their tops follow the heads.
## 5. Section behaviour: drop moves are bigger than quiet; breakdown rests.
## 6. The Classic simulation is unchanged; detach restores the sim transforms;
##    the animation is frame-rate independent (60 vs 144 fps).
## Report: research/oozic/proof/phase4d/character-animation.json
const SceneRuntime = preload("res://scene_runtime.gd")
const MockAudioFeed = preload("res://mock_audio_feed.gd")
const ModernLayer = preload("res://modern/modern_layer.gd")
const ReactivityServiceScript = preload("res://analysis/reactivity_service.gd")
const TRIPLE := "res://scenes/lava25/Triple Trance"
const BPM := 128.0
const BEAT := 60.0 / BPM
const REPORT := "res://../research/oozic/proof/phase4d/character-animation.json"

var report := {}
var failures := 0

func _initialize(): call_deferred("run")

func check(condition: bool, label: String) -> void:
	if not condition:
		failures += 1
		push_error("FAIL " + label)
		print("FAIL ", label)

func _run(fps: float, seconds: float, with_layer := true) -> Dictionary:
	var service = ReactivityServiceScript.instance()
	service.auto_tick = false
	var runtime = SceneRuntime.new()
	root.add_child(runtime)
	runtime.load_scene(TRIPLE)
	var feed = MockAudioFeed.new(BPM, 3)
	var sampler := func(t): return feed.sample(t)
	service.set_mock(BPM)
	service.tick(0.0)
	var layer = ModernLayer.new()
	layer.quality = "low"
	layer.camera_mode = "original"
	root.add_child(layer)
	if with_layer: assert(layer.attach(runtime))
	var dt := 1.0 / fps
	var frames: Array = []
	var stems := {"Mushroom": "Cone1", "SignBoard": "Cone2", "Sphere": "Cone3"}
	var max_det := 0.0
	var max_base_drift := 0.0
	var max_top_gap := 0.0
	var max_squash := 0.0
	var drift_at := ""
	for i in int(round(seconds * fps)):
		service.tick(dt)
		runtime.advance(dt, sampler)
		if not with_layer: continue
		layer.update(dt)
		var t: float = service.hub.frame.time
		var row := {"t": t, "section": str(service.hub.frame.section), "heads": []}
		var animator = layer.animator
		for character in animator.characters:
			var info := {"offset": character.offset, "primary": character.primary, "twist": character.twist, "squash": character.squash, "current": character.current}
			for d in animator.debug:
				if d.name == character.name: info.moves = d.moves.duplicate()
			row.heads.append(info)
			# Volume: head display basis relative to its simulated basis.
			var head: Dictionary = runtime.object_named(character.name)
			var sim_global: Transform3D = head.node.get_parent().global_transform * character.head.base
			var display: Transform3D = head.node.global_transform
			var relative: Basis = display.basis * sim_global.basis.inverse()
			max_det = maxf(max_det, absf(relative.determinant() - 1.0))
			max_squash = maxf(max_squash, absf(float(character.squash)))
			# Stem base on the platform, stem top with the head.
			var stem: Dictionary = runtime.object_named(stems[character.name])
			var box: AABB = stem.node.mesh.get_aabb()
			var bottom_local := Vector3(box.get_center().x, box.position.y, box.get_center().z)
			var top_local := Vector3(box.get_center().x, box.end.y, box.get_center().z)
			var stem_sim: Transform3D = sim_global * character.stem.base
			var base_display: Vector3 = stem.node.global_transform * bottom_local
			var base_expected: Vector3 = animator.float_offset * (stem_sim * bottom_local)
			if base_display.distance_to(base_expected) > max_base_drift:
				max_base_drift = base_display.distance_to(base_expected)
				drift_at = "t=%.3f %s offset=%s twist=%.3f squash=%.3f display=%s expected=%s sim=%s" % [t, character.name, str(character.offset), character.twist, character.squash, str(base_display), str(base_expected), str(stem_sim * bottom_local)]
			var top_display: Vector3 = stem.node.global_transform * top_local
			var top_follow: Vector3 = display * (sim_global.affine_inverse() * (stem_sim * top_local))
			max_top_gap = maxf(max_top_gap, top_display.distance_to(top_follow))
		frames.append(row)
	var sim := {"camera": runtime._camera_current, "ticks": runtime.metrics.ticks, "objects": []}
	for entry in runtime.objects:
		var vertices: PackedVector3Array = entry.node.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		sim.objects.append([entry.sim_transform, vertices[0], vertices[vertices.size() / 2]])
	var restored := true
	if with_layer:
		var bases := []
		for character in layer.animator.characters: bases.append([character.head.node, character.head.base])
		layer.detach()
		for pair in bases:
			if pair[0].transform != pair[1]: restored = false
	layer.free()
	runtime.free()
	return {"fps": fps, "frames": frames, "sim": sim, "restored": restored, "max_det": max_det, "max_base_drift": max_base_drift,
		"max_top_gap": max_top_gap, "max_squash": max_squash, "drift_at": drift_at}

## Extremum times of each (head, move) contribution and their distance to the nearest beat.
func _peaks(run: Dictionary) -> Dictionary:
	var frames: Array = run.frames
	var dt := 1.0 / float(run.fps)
	var tolerance := dt + 0.010
	var count := 0
	var worst := 0.0
	var bad := 0
	var by_move := {}
	for h in 3:
		var names := {}
		for row in frames: for name in row.heads[h].get("moves", {}): names[name] = true
		for name in names:
			var series: Array = frames.map(func(row): return float(row.heads[h].get("moves", {}).get(name, 0.0)))
			var peak := 0.0
			for v in series: peak = maxf(peak, absf(v))
			for i in range(1, series.size() - 1):
				var v: float = series[i]
				if absf(v) < 0.3 * peak or absf(v) < 1e-4: continue
				var is_max: bool = v > series[i - 1] and v >= series[i + 1]
				var is_min: bool = v < series[i - 1] and v <= series[i + 1]
				if not (is_max and v > 0.0) and not (is_min and v < 0.0): continue
				var t: float = frames[i].t
				var off := absf(t - roundf(t / BEAT) * BEAT)
				count += 1
				worst = maxf(worst, off)
				if off > tolerance:
					bad += 1
					if bad <= 5: print("   off-beat extremum: head %d %s at %.4f (%.1f ms)" % [h, name, t, off * 1000.0])
				by_move[name] = int(by_move.get(name, 0)) + 1
	return {"count": count, "worst_ms": worst * 1000.0, "off_beat": bad, "tolerance_ms": tolerance * 1000.0, "by_move": by_move}

func run():
	var seconds := 64.0
	var r60 := _run(60.0, seconds)
	var r144 := _run(144.0, seconds)
	var classic := _run(60.0, seconds, false)

	# 1. Peaks on beats.
	report.peaks = {}
	for r in [r60, r144]:
		var p := _peaks(r)
		report.peaks[str(r.fps)] = p
		check(p.count > 100 and p.off_beat == 0, "%d fps: %d move peaks, all within %.1f ms of a beat (worst %.1f ms)" % [r.fps, p.count, p.tolerance_ms, p.worst_ms])
		print("1 peaks %d fps: %d extrema, worst %.1f ms from a beat (tolerance %.1f ms), moves %s" % [r.fps, p.count, p.worst_ms, p.tolerance_ms, p.by_move])

	# 2. Continuity (144 fps: per-frame change bounded; no jump on move switches).
	var max_speed := 0.0
	var max_twist_rate := 0.0
	var max_switch_step := 0.0
	var max_accel := 0.0
	var f: Array = r144.frames
	var dt := 1.0 / 144.0
	for i in range(2, f.size()):
		for h in 3:
			var a: Vector3 = f[i - 1].heads[h].offset
			var b: Vector3 = f[i].heads[h].offset
			var z: Vector3 = f[i - 2].heads[h].offset
			var step := a.distance_to(b)
			max_speed = maxf(max_speed, step / dt)
			max_accel = maxf(max_accel, ((b - a) - (a - z)).length() / (dt * dt))
			max_twist_rate = maxf(max_twist_rate, absf(float(f[i].heads[h].twist) - float(f[i - 1].heads[h].twist)) / dt)
			if f[i].heads[h].current != f[i - 1].heads[h].current: max_switch_step = maxf(max_switch_step, step)
	report.continuity = {"max_speed": max_speed, "max_accel": max_accel, "max_twist_rate": max_twist_rate, "max_step_on_switch": max_switch_step}
	check(max_speed < 1.5, "head offset speed bounded (%.3f units/s)" % max_speed)
	check(max_accel < 60.0, "head offset acceleration bounded (%.1f units/s^2)" % max_accel)
	check(max_twist_rate < 2.0, "twist rate bounded (%.3f rad/s)" % max_twist_rate)
	check(max_switch_step < 1.5 * dt, "no jump when moves switch (%.5f units in one frame)" % max_switch_step)
	print("2 continuity 144 fps: speed %.3f u/s, accel %.1f u/s^2, twist %.3f rad/s, step on switch %.5f" % [max_speed, max_accel, max_twist_rate, max_switch_step])

	# 3. Squash keeps volume.
	report.squash = {"max_det_error": r60.max_det, "max_squash": r60.max_squash}
	check(r60.max_det < 1e-4 and r144.max_det < 1e-4, "squash/stretch preserves volume (|det-1| %s)" % str(r60.max_det))
	check(r60.max_squash > 0.02 and r60.max_squash <= 0.15, "squash is visible but subtle (max %.3f)" % r60.max_squash)
	print("3 squash: max %.3f, |det - 1| <= %s" % [r60.max_squash, str(r60.max_det)])

	# 4. Stems.
	report.stems = {"max_base_drift": r60.max_base_drift, "max_top_gap": r60.max_top_gap}
	check(r60.max_base_drift < 2e-3 and r144.max_base_drift < 2e-3, "stem bases stay planted (%s)" % str(r60.max_base_drift))
	check(r60.max_top_gap < 0.02, "stem tops follow the heads (%.4f)" % r60.max_top_gap)
	print("   worst drift: ", r60.drift_at, " | ", r144.drift_at)
	print("4 stems: base drift %s, top gap %.4f" % [str(r60.max_base_drift), r60.max_top_gap])

	# 5. Sections.
	var level := {}
	for row in r60.frames:
		var s: String = row.section
		if not level.has(s): level[s] = [0.0, 0]
		for head in row.heads: level[s][0] += Vector3(head.primary).length()
		level[s][1] += 3
	var mean := {}
	for s in level: mean[s] = level[s][0] / maxf(level[s][1], 1.0)
	report.section_level = mean
	check(mean.get("drop", 0.0) > 1.5 * mean.get("quiet", 1.0), "drop moves bigger than quiet (%s)" % str(mean))
	check(mean.get("breakdown", 1.0) < 0.6 * mean.get("drop", 0.0), "breakdown rests (%s)" % str(mean))
	print("5 mean head offset by section: ", mean)

	# 6. Classic unchanged, detach restores, frame-rate independence.
	check(r60.sim.camera == classic.sim.camera and r60.sim.ticks == classic.sim.ticks and r60.sim.objects == classic.sim.objects, "Classic simulation unchanged with animation attached")
	check(r60.restored and r144.restored, "detach restores the simulated head transforms")
	var worst := 0.0
	for n in range(1, int(seconds * 6.0)):
		var a: Dictionary = r144.frames[n * 24 - 1]
		var b: Dictionary = r60.frames[n * 10 - 1]
		if absf(float(a.t) - float(b.t)) > 1e-6: continue
		for h in 3: worst = maxf(worst, Vector3(a.heads[h].offset).distance_to(b.heads[h].offset))
	report.fps_difference = worst
	check(worst < 0.006, "60 vs 144 fps head offsets agree (max %.4f)" % worst)
	print("6 classic sim identical; detach restores; 60 vs 144 fps max offset difference %.4f" % worst)

	report.pass = failures == 0
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://../research/oozic/proof/phase4d"))
	var file := FileAccess.open(ProjectSettings.globalize_path(REPORT), FileAccess.WRITE)
	if file != null: file.store_string(JSON.stringify(report, "\t"))
	print("PASS test_character_animation" if failures == 0 else "FAILED test_character_animation (%d)" % failures)
	quit(0 if failures == 0 else 1)
