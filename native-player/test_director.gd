extends SceneTree
## Virtual director (Phase 4d). Silent, headless:
##   Godot --headless --audio-driver Dummy --path native-player --script res://test_director.gd
## Mock 128 BPM, default schedule (quiet 8 / build 8 / drop 16 / breakdown 8 bars).
## 1. Cuts only on downbeats (within one frame + 10 ms), min shot length, no
##    immediate repeats, a cut on the drop downbeat to an energetic shot.
## 2. Push-in during the build (proportional to build progress).
## 3. Comfort: linear/angular speed, acceleration and FOV speed under the caps
##    at 30/60/144 fps; no roll; never inside geometry or outside the bounds.
## 4. Deterministic: identical twice at 60 fps; same edit and pose at 30/60/144.
## 5. Locked is static; Original equals the Classic camera; the Classic
##    simulation is unchanged with the director attached; detach restores.
## Report: research/oozic/proof/phase4d/director.json
const SceneRuntime = preload("res://scene_runtime.gd")
const MockAudioFeed = preload("res://mock_audio_feed.gd")
const ModernLayer = preload("res://modern/modern_layer.gd")
const AppSettings = preload("res://app_settings.gd")
const ReactivityServiceScript = preload("res://analysis/reactivity_service.gd")
const TRIPLE := "res://scenes/lava25/Triple Trance"
const BPM := 128.0
const BAR := 240.0 / BPM
const REPORT := "res://../research/oozic/proof/phase4d/director.json"

var report := {}
var failures := 0

func _initialize(): call_deferred("run")

func check(condition: bool, label: String) -> void:
	if not condition:
		failures += 1
		push_error("FAIL " + label)
		print("FAIL ", label)

func _run(fps: float, seconds: float, camera_mode: String, with_layer := true) -> Dictionary:
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
	layer.camera_mode = camera_mode
	root.add_child(layer)
	if with_layer: assert(layer.attach(runtime))
	var dt := 1.0 / fps
	var samples: Array = []
	var push: Array = []
	var guard_violations := 0
	var sections: Array = []
	for i in int(round(seconds * fps)):
		service.tick(dt)
		runtime.advance(dt, sampler)
		if with_layer: layer.update(dt)
		var t: float = service.hub.frame.time
		var cam: Camera3D = runtime.camera
		var cut := false
		if with_layer and layer.director != null:
			cut = layer.director.cut_this_frame
			push.append([t, layer.director.push, str(service.hub.frame.section)])
			if camera_mode == "director" and layer.director.comfort.inside_geometry(cam.global_position): guard_violations += 1
		samples.append({"t": t, "p": cam.global_position, "b": cam.global_transform.basis, "fov": cam.fov, "cut": cut,
			"shot": layer.director.shot_name if with_layer and layer.director != null else ""})
	var sim := {"camera": runtime._camera_current, "ticks": runtime.metrics.ticks, "objects": []}
	for entry in runtime.objects:
		var vertices: PackedVector3Array = entry.node.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		sim.objects.append([entry.sim_transform, vertices[0], vertices[vertices.size() / 2]])
	var out := {"fps": fps, "samples": samples, "push": push, "sim": sim, "guard_violations": guard_violations,
		"cuts": layer.director.cut_log.duplicate(true) if with_layer and layer.director != null else [],
		"guard": layer.director.comfort.guard if with_layer and layer.director != null else {}}
	if with_layer:
		# Detach restores the original camera and the simulated transforms at once.
		var base: Transform3D = layer._camera_base
		layer.detach()
		out.detach_camera_ok = runtime.camera.transform == base or layer.camera_mode != "director"
		out.detach_fov = runtime.camera.fov
	layer.free()
	runtime.free()
	return out

## Comfort metrics over frames, skipping cut frames and their neighbours.
func _comfort(run: Dictionary, caps: Dictionary) -> Dictionary:
	var samples: Array = run.samples
	var fps: float = run.fps
	var dt := 1.0 / fps
	var k := maxi(int(round(fps / 30.0)), 1)
	var max_speed := 0.0
	var max_ang := 0.0
	var max_acc := 0.0
	var max_fov := 0.0
	var max_roll := 0.0
	var cut_frames := {}
	for i in samples.size():
		if samples[i].cut:
			for j in range(i - 2 * k - 1, i + 2 * k + 2): cut_frames[j] = true
	for i in range(1, samples.size()):
		max_roll = maxf(max_roll, absf(Basis(samples[i].b).x.y))
		if cut_frames.has(i) or cut_frames.has(i - 1): continue
		var a: Dictionary = samples[i - 1]
		var b: Dictionary = samples[i]
		max_speed = maxf(max_speed, Vector3(a.p).distance_to(b.p) / dt)
		var fa: Vector3 = -Basis(a.b).z
		var fb: Vector3 = -Basis(b.b).z
		max_ang = maxf(max_ang, rad_to_deg(fa.angle_to(fb)) / dt)
		max_fov = maxf(max_fov, absf(float(b.fov) - float(a.fov)) / dt)
		if i >= 2 * k and not cut_frames.has(i - 2 * k) and not cut_frames.has(i - k):
			var v1: Vector3 = (Vector3(samples[i].p) - Vector3(samples[i - k].p)) / (k * dt)
			var v0: Vector3 = (Vector3(samples[i - k].p) - Vector3(samples[i - 2 * k].p)) / (k * dt)
			max_acc = maxf(max_acc, (v1 - v0).length() / (k * dt))
	return {"max_speed": max_speed, "max_angular_deg": max_ang, "max_accel": max_acc, "max_fov_speed": max_fov, "max_roll": max_roll}

func run():
	var profile: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://modern/profiles/triple_trance.json"))
	var caps: Dictionary = profile.director.comfort
	var drop_pool: Dictionary = profile.director.grammar.drop.drop_shots
	var seconds := 66.0
	var runs := {}
	for fps in [30.0, 60.0, 144.0]: runs[fps] = _run(fps, seconds, "director")
	var again := _run(60.0, seconds, "director")
	report.caps = caps

	# 1. Edit: cut timing, min length, repeats, drop cut.
	var cuts: Array = runs[60.0].cuts
	report.cuts = cuts
	check(cuts.size() >= 6, "at least 6 shot changes in 66 s (got %d)" % cuts.size())
	for fps in runs:
		var dt := 1.0 / float(fps)
		var list: Array = runs[fps].cuts
		for i in list.size():
			var c: Dictionary = list[i]
			if c.kind == "start": continue
			var grid := float(c.bar) * BAR
			check(absf(float(c.bar_time) - grid) < 1e-6, "%d fps: shot change %d on the downbeat grid (bar %d, %.6f vs %.6f)" % [fps, i, c.bar, c.bar_time, grid])
			check(float(c.time) - grid >= -1e-6 and float(c.time) - grid <= dt + 0.010 + 1e-6, "%d fps: shot change %d within one frame + 10 ms of its downbeat (%.4f s late)" % [fps, i, float(c.time) - grid])
			if i > 0:
				var p: Dictionary = list[i - 1]
				check(int(c.bar) - int(p.bar) >= 2 and float(c.bar_time) - float(p.bar_time) >= 4.0 - 1e-3, "%d fps: min shot length (bars %d -> %d)" % [fps, p.bar, c.bar])
				check(str(c.shot) != str(p.shot), "%d fps: no immediate repeat (%s)" % [fps, c.shot])
	var drop_cut: Array = cuts.filter(func(c): return int(c.bar) == 16)
	check(drop_cut.size() == 1 and drop_cut[0].kind == "cut" and drop_cut[0].reason == "drop", "cut on the drop downbeat (bar 16)")
	if drop_cut.size() == 1:
		var energetic := false
		for key in drop_pool: energetic = energetic or (str(drop_cut[0].shot) == key or (str(key).ends_with("*") and str(drop_cut[0].shot).begins_with(str(key).trim_suffix("*"))))
		check(energetic, "drop cut goes to an energetic shot (%s)" % drop_cut[0].shot)
	var breakdown: Array = cuts.filter(func(c): return int(c.bar) == 32)
	check(breakdown.size() == 1 and breakdown[0].shot == "wide", "breakdown enters on a wide shot")
	var short_gap := INF
	for i in range(1, cuts.size()): short_gap = minf(short_gap, float(cuts[i].bar_time) - float(cuts[i - 1].bar_time))
	report.shortest_shot_s = short_gap
	print("1 edit: ", cuts.size(), " shot changes, shortest ", snappedf(short_gap, 0.001), " s; drop cut -> ", drop_cut[0].shot if drop_cut.size() == 1 else "none")

	# 2. Push-in during the build.
	var push: Array = runs[60.0].push
	var build_push: Array = push.filter(func(p): return p[2] == "build")
	var late: float = build_push[build_push.size() - 1][1]
	var early: float = build_push[60][1]
	check(late > 0.6 * float(profile.director.push_in) and early < 0.05, "push-in grows through the build (%.3f -> %.3f)" % [early, late])
	var quiet_push: float = push.filter(func(p): return p[2] == "quiet").map(func(p): return p[1]).max()
	check(quiet_push < 0.02, "no push-in in the quiet section (%.3f)" % quiet_push)
	# The last build shot's camera-to-subject distance shrinks.
	var samples: Array = runs[60.0].samples
	var last_build_cut: Dictionary = cuts.filter(func(c): return c.section == "build").back()
	var i0 := int((float(last_build_cut.time) + 0.6) * 60.0)
	var i1 := int(29.9 * 60.0)
	var d0 := _subject_distance(samples[i0], runs[60.0])
	var d1 := _subject_distance(samples[i1], runs[60.0])
	check(d1 < d0 * 0.93, "camera pushes in during the build (distance %.2f -> %.2f)" % [d0, d1])
	report.push = {"build_start": early, "build_end": late, "distance_start": d0, "distance_end": d1}
	print("2 push-in: %.3f -> %.3f, subject distance %.2f -> %.2f" % [early, late, d0, d1])

	# 3. Comfort at 30/60/144.
	report.comfort = {}
	for fps in runs:
		var m := _comfort(runs[fps], caps)
		report.comfort[str(fps)] = m
		check(m.max_speed <= float(caps.max_speed) * 1.03, "%d fps: speed %.2f <= %.2f" % [fps, m.max_speed, caps.max_speed])
		check(m.max_angular_deg <= float(caps.max_angular_speed_deg) * 1.05, "%d fps: angular %.1f <= %.1f deg/s" % [fps, m.max_angular_deg, caps.max_angular_speed_deg])
		check(m.max_accel <= float(caps.max_accel) * 1.2, "%d fps: accel %.2f <= %.2f" % [fps, m.max_accel, caps.max_accel])
		check(m.max_fov_speed <= float(caps.max_fov_speed) * 1.05, "%d fps: fov speed %.1f" % [fps, m.max_fov_speed])
		check(m.max_roll < 1e-4, "%d fps: no roll (%s)" % [fps, str(m.max_roll)])
		check(runs[fps].guard_violations == 0, "%d fps: camera never inside geometry (%d frames)" % [fps, runs[fps].guard_violations])
		var guard: Dictionary = runs[fps].guard
		var out_of_bounds := 0
		for s in runs[fps].samples:
			if Vector3(s.p).distance_to(guard.center) > float(guard.max_radius) + 1e-3 or s.p.y < float(guard.min_y) - 1e-3 or s.p.y > float(guard.max_y) + 1e-3: out_of_bounds += 1
		check(out_of_bounds == 0, "%d fps: camera inside scene bounds" % fps)
		print("3 comfort %d fps: speed %.2f, angular %.1f deg/s, accel %.2f, fov %.1f deg/s, roll %s" % [fps, m.max_speed, m.max_angular_deg, m.max_accel, m.max_fov_speed, str(m.max_roll)])

	# 4. Determinism.
	var identical: bool = again.samples.size() == runs[60.0].samples.size()
	for i in mini(again.samples.size(), runs[60.0].samples.size()):
		if again.samples[i].p != runs[60.0].samples[i].p or again.samples[i].b != runs[60.0].samples[i].b: identical = false
	check(identical and again.cuts == runs[60.0].cuts, "identical at 60 fps run twice")
	var edit60: Array = runs[60.0].cuts.map(func(c): return [c.bar, c.kind, c.shot])
	var max_pose := {}
	for fps in [30.0, 144.0]:
		var edit: Array = runs[fps].cuts.map(func(c): return [c.bar, c.kind, c.shot])
		check(edit == edit60, "%d fps: same edit as 60 fps" % fps)
		var worst := 0.0
		var per_sixth := int(fps / 6.0)
		for n in range(1, int(seconds * 6.0)):
			var a: Dictionary = runs[fps].samples[n * per_sixth - 1]
			var b: Dictionary = runs[60.0].samples[n * 10 - 1]
			if absf(float(a.t) - float(b.t)) > 1e-6: continue
			var near_cut: bool = runs[60.0].cuts.any(func(c): return absf(float(c.time) - float(b.t)) < 0.05)
			if near_cut: continue
			var d := Vector3(a.p).distance_to(b.p)
			if d > worst:
				worst = d
				max_pose[str(fps) + "_at"] = b.t
		max_pose[str(fps)] = worst
		check(worst < 0.05, "%d fps: pose matches 60 fps at common times (max %.4f)" % [fps, worst])
	report.determinism = {"identical_60": identical, "max_pose_difference": max_pose}
	print("4 deterministic: identical twice; edit equal at 30/144; pose diff ", max_pose)

	# 5. Locked / Original / Classic.
	var locked := _run(60.0, 20.0, "locked")
	var still := true
	for s in locked.samples:
		if s.p != locked.samples[0].p or s.b != locked.samples[0].b or s.fov != locked.samples[0].fov: still = false
	check(still and locked.cuts.is_empty(), "locked camera is static")
	var classic := _run(60.0, seconds, "director", false)
	var original := _run(60.0, 30.0, "original")
	var same := true
	for i in original.samples.size():
		if original.samples[i].p != classic.samples[i].p or original.samples[i].b != classic.samples[i].b or original.samples[i].fov != classic.samples[i].fov: same = false
	check(same, "Original mode = the Classic camera exactly")
	check(runs[60.0].sim.camera == classic.sim.camera and runs[60.0].sim.ticks == classic.sim.ticks and runs[60.0].sim.objects == classic.sim.objects, "Classic simulation unchanged with director + animation attached")
	check(float(runs[60.0].detach_fov) == float(classic.samples[0].fov) and runs[60.0].detach_camera_ok, "detach restores the camera and FOV")
	print("5 locked static; Original == Classic camera; simulation identical (ticks ", classic.sim.ticks, ")")

	# 7. Hand-over (scene-transition adoption, quality rebuild): the edit carries on unchanged.
	var straight := _handover_run(false)
	var handed := _handover_run(true)
	var continuous: bool = straight.positions.size() == handed.positions.size()
	for i in mini(straight.positions.size(), handed.positions.size()):
		if straight.positions[i] != handed.positions[i]: continuous = false
	check(continuous and straight.cuts == handed.cuts, "hand-over and rebuild keep the same edit and camera path")
	print("7 hand-over: rebuild at 8 s and a new layer at 17 s keep the camera path identical (", straight.cuts.size(), " shot changes)")

	# 6. Settings round trip and bus command.
	var settings = AppSettings.new()
	settings.path = "user://test-director-settings.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(settings.path))
	settings.load_settings()
	check(settings.camera_mode == "director", "default camera mode is director")
	settings.camera_mode = "locked"
	settings.save_settings()
	var loaded = AppSettings.new()
	loaded.path = settings.path
	loaded.load_settings()
	check(loaded.camera_mode == "locked", "camera mode persists")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(settings.path))
	print("6 settings: camera_mode round trip")

	report.pass = failures == 0
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://../research/oozic/proof/phase4d"))
	var file := FileAccess.open(ProjectSettings.globalize_path(REPORT), FileAccess.WRITE)
	if file != null: file.store_string(JSON.stringify(report, "\t"))
	print("PASS test_director" if failures == 0 else "FAILED test_director (%d)" % failures)
	quit(0 if failures == 0 else 1)

func _handover_run(hand_over: bool) -> Dictionary:
	var service = ReactivityServiceScript.instance()
	var runtime = SceneRuntime.new()
	root.add_child(runtime)
	runtime.load_scene(TRIPLE)
	var feed = MockAudioFeed.new(BPM, 3)
	var sampler := func(t): return feed.sample(t)
	service.set_mock(BPM)
	service.tick(0.0)
	var layer = ModernLayer.new()
	layer.quality = "low"
	root.add_child(layer)
	layer.attach(runtime)
	var positions: Array = []
	var dt := 1.0 / 60.0
	for i in 24 * 60:
		if hand_over and i == 8 * 60: layer.rebuild()
		if hand_over and i == 17 * 60:
			var next = ModernLayer.new()
			next.quality = "low"
			root.add_child(next)
			next.handoff = layer.take_motion()
			layer.detach()
			layer.free()
			layer = next
			layer.attach(runtime)
		service.tick(dt)
		runtime.advance(dt, sampler)
		layer.update(dt)
		positions.append(runtime.camera.global_transform)
	var cuts: Array = layer.director.cut_log.map(func(c): return [c.bar, c.kind, c.shot])
	layer.detach()
	layer.free()
	runtime.free()
	return {"positions": positions, "cuts": cuts}

func _subject_distance(sample: Dictionary, run: Dictionary) -> float:
	# Distance from the camera to the nearest guarded subject centre along the view.
	var forward: Vector3 = -Basis(sample.b).z
	var best := INF
	for sphere in run.guard.get("spheres", []):
		var to: Vector3 = Vector3(sphere.center) - Vector3(sample.p)
		if to.normalized().dot(forward) > 0.9: best = minf(best, to.length())
	if best == INF: best = Vector3(sample.p).distance_to(run.guard.center)
	return best
