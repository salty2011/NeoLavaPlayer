extends SceneTree
## Same simulated duration under different render dt sequences must give the same
## scene state: fixed 60 Hz ticks, synthetic per-tick audio, shared legacy rand.
const SceneRuntime = preload("res://scene_runtime.gd")
const MockAudioFeed = preload("res://mock_audio_feed.gd")
const AudioInputs = preload("res://audio_inputs.gd")
const CameraRuntime = preload("res://camera_runtime.gd")
const DURATION := 12.02 # Off a tick boundary (60 Hz -> 721.2 ticks).
const TOLERANCE := 0.0001
## Start the synthetic track in its build so the run crosses into the drop.
const FEED_OFFSET := 29.0
var failures := []
var report := {}

func _initialize(): call_deferred("run")

func sequences() -> Dictionary:
	var jitter := RandomNumberGenerator.new()
	jitter.seed = 99
	var hitch := [0]
	return {
		"fps_25": func(): return 1.0 / 25.0,
		"fps_30": func(): return 1.0 / 30.0,
		"fps_60": func(): return 1.0 / 60.0,
		"fps_144": func(): return 1.0 / 144.0,
		"uncapped_jitter_90_300": func(): return 1.0 / jitter.randf_range(90.0, 300.0),
		"slow_10.5_catchup": func(): return 0.095,
		"hitching_60": func():
			hitch[0] += 1
			return 0.09 if hitch[0] % 37 == 0 else 1.0 / 60.0,
	}

func snapshot(runtime) -> Dictionary:
	var objects := {}
	for entry in runtime.objects:
		if entry.node == null: continue
		var state := {"transform": entry.sim_transform, "angles": []}
		for descriptor in entry.effects:
			if descriptor.state is RefCounted and descriptor.state.get("angle") != null: state.angles.append(descriptor.state.angle)
		var vertices: PackedVector3Array = entry.node.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var samples := []
		for i in [0, vertices.size() / 3, vertices.size() / 2, vertices.size() - 1]: samples.append(vertices[i])
		state.vertices = samples
		objects[entry.record.name] = state
	var camera = runtime.camera_runtime
	return {"ticks": runtime.metrics.ticks, "time": runtime.simulation_time(), "camera": runtime._camera_current, "camera_angles": Vector3(camera.theta, camera.phi, camera.radius), "move_counter": camera.move_counter, "objects": objects}

func run_sequence(runtime, feed, next_dt: Callable) -> Dictionary:
	runtime.reset()
	var sampler := func(t): return feed.sample(t + FEED_OFFSET)
	var elapsed := 0.0
	var frames := 0
	while elapsed < DURATION - 1e-9:
		var dt: float = minf(next_dt.call(), DURATION - elapsed)
		runtime.advance(dt, sampler)
		elapsed += dt
		frames += 1
	var result := snapshot(runtime)
	result.frames = frames
	return result

func compare(name: String, reference: Dictionary, other: Dictionary) -> float:
	var worst := 0.0
	if reference.ticks != other.ticks: failures.append({"sequence": name, "error": "tick count", "expected": reference.ticks, "got": other.ticks})
	if reference.move_counter != other.move_counter: failures.append({"sequence": name, "error": "camera A==1 counter differs"})
	worst = maxf(worst, reference.camera.distance_to(other.camera))
	worst = maxf(worst, reference.camera_angles.distance_to(other.camera_angles))
	for object_name in reference.objects:
		var a: Dictionary = reference.objects[object_name]
		var b: Dictionary = other.objects.get(object_name, {})
		if b.is_empty(): failures.append({"sequence": name, "error": "missing object", "object": object_name}); continue
		worst = maxf(worst, a.transform.origin.distance_to(b.transform.origin))
		for axis in 3: worst = maxf(worst, a.transform.basis[axis].distance_to(b.transform.basis[axis]))
		for i in a.angles.size(): worst = maxf(worst, absf(a.angles[i] - b.angles[i]))
		for i in a.vertices.size(): worst = maxf(worst, a.vertices[i].distance_to(b.vertices[i]))
	if worst > TOLERANCE: failures.append({"sequence": name, "error": "state diverged", "max_difference": worst})
	return worst

## Per-frame dt mode (original structure): one update per render frame.
func per_frame(runtime, sampler: Callable, dt: float) -> Dictionary:
	runtime.fixed_step = false
	runtime.reset()
	var elapsed := 0.0
	while elapsed < DURATION - 1e-9:
		var step := minf(dt, DURATION - elapsed)
		runtime.advance(step, sampler)
		elapsed += step
	runtime.fixed_step = true
	return snapshot(runtime)

func camera_counter_check() -> Dictionary:
	# One second of A==1 at different update rates: the normalised counter
	# reaches the same value (the original counted calls: 30 vs 144).
	var result := {}
	for rate in [30.0, 60.0, 144.0]:
		var camera = CameraRuntime.new()
		camera.max_move = 1000.0
		for i in int(rate): camera.update(1.0 / rate, 0.5, 1.0)
		result["counter_at_%d" % int(rate)] = camera.move_counter
		if absf(camera.move_counter - 60.0) > 0.001: failures.append({"error": "camera A==1 counter not time-normalised", "rate": rate, "counter": camera.move_counter})
	var exact = CameraRuntime.new()
	exact.count_per_update = true
	exact.max_move = 1000.0
	for i in 144: exact.update(1.0 / 144.0, 0.5, 1.0)
	result.exact_original_counter_at_144 = exact.move_counter
	return result

func audio_rate_check() -> Dictionary:
	# Deterministic PCM: kick-like low bursts plus a steady high tone.
	var rate := 48000.0
	var pcm := PackedVector2Array()
	pcm.resize(int(rate * 4.0))
	for i in pcm.size():
		var t := float(i) / rate
		var beat := fmod(t, 0.46875)
		var value := 0.6 * exp(-beat / 0.08) * sin(TAU * 60.0 * t) + 0.08 * sin(TAU * 5000.0 * t) * (0.5 + 0.5 * sin(TAU * 0.5 * t))
		pcm[i] = Vector2(value, value)
	var results := {}
	for fps in [60.0, 30.0, 144.0]:
		var inputs := AudioInputs.new(rate)
		var trace := []
		var pushed := 0
		var ticks := 0
		var frame := 0
		var clock := 0.0
		while ticks < 230:
			frame += 1
			clock = frame / fps
			var until := mini(int(clock * rate), pcm.size())
			inputs.push(pcm.slice(pushed, until))
			pushed = until
			while ticks < int(floor(clock * 60.0 + 1e-7)) and ticks < 230:
				var signals := inputs.consume()
				trace.append([signals.band_a[0], signals.band_a[1], signals.band_a[2], signals.global_s])
				ticks += 1
		results[fps] = {"trace": trace}
	var summary := {}
	for fps in [30.0, 144.0]:
		var total := 0.0
		for i in results[60.0].trace.size():
			for k in 4: total += absf(results[60.0].trace[i][k] - results[fps].trace[i][k])
		var mean: float = total / (results[60.0].trace.size() * 4.0)
		summary["mean_abs_difference_vs_60_at_%d" % int(fps)] = mean
		var dropouts := 0
		for i in results[60.0].trace.size():
			var reference: Array = results[60.0].trace[i]
			var other: Array = results[fps].trace[i]
			if maxf(reference[0], reference[2]) > 0.2 and other[0] == 0.0 and other[2] == 0.0: dropouts += 1
		summary["dropout_ticks_at_%d" % int(fps)] = dropouts
		if mean > 0.05: failures.append({"error": "analysis differs by render rate", "fps": fps, "mean": mean})
	# Hold: a consume with no completed FFT window repeats the previous A/S.
	var hold := AudioInputs.new(rate)
	hold.push(pcm.slice(0, 4096))
	var before: Dictionary = hold.consume().duplicate(true)
	hold.push(pcm.slice(4096, 4196))
	var after: Dictionary = hold.consume()
	if before.band_a != after.band_a or before.global_s != after.global_s: failures.append({"error": "analysis did not hold between FFT windows"})
	# Previous single-call update() normalised zero power on window-less frames.
	var legacy := AudioInputs.new(rate)
	var legacy_silent := 0
	var position := 0
	var frames := 0
	while position < pcm.size():
		var until := mini(int((frames + 1) / 144.0 * rate), pcm.size())
		var pending_before: int = legacy._pending.size()
		legacy.update(pcm.slice(position, until), 1.0 / 144.0)
		if pending_before + until - position < legacy.fft_size: legacy_silent += 1
		position = until
		frames += 1
	summary["previous_update_windowless_frames_at_144"] = "%d of %d" % [legacy_silent, frames]
	return summary

func run():
	var runtime = SceneRuntime.new()
	runtime.random_seed = 7
	root.add_child(runtime)
	for scene in ["res://scenes/lava25/Triple Trance", "res://scenes/Hydroid"]:
		var loaded: Dictionary = runtime.load_scene(scene)
		if not loaded.errors.is_empty(): failures.append({"scene": scene, "errors": loaded.errors}); continue
		var feed = MockAudioFeed.new(128.0, maxi(runtime.data.bands.size(), 1))
		var results := {}
		var generators := sequences()
		for name in generators: results[name] = run_sequence(runtime, feed, generators[name])
		var reference: Dictionary = results.fps_60
		var scene_report := {"ticks": reference.ticks, "simulated_seconds": reference.time, "sequences": {}}
		if reference.ticks != int(DURATION * runtime.simulation_rate()): failures.append({"scene": scene, "error": "unexpected tick count", "ticks": reference.ticks})
		scene_report.simulation_rate = runtime.simulation_rate()
		for name in results:
			scene_report.sequences[name] = {"frames": results[name].frames, "ticks": results[name].ticks, "max_difference_vs_60_hz_render": compare(scene.get_file() + "/" + name, reference, results[name])}
		# Per-frame dt mode: continuous motion is speed-correct (constant input)...
		var steady := func(_t): return {"band_a": [0.4, 0.4, 0.4], "global_s": 0.6}
		var steady_30 := per_frame(runtime, steady, 1.0 / 30.0)
		var steady_144 := per_frame(runtime, steady, 1.0 / 144.0)
		var steady_angles := 0.0
		for object_name in steady_30.objects:
			for i in steady_30.objects[object_name].angles.size(): steady_angles = maxf(steady_angles, absf(steady_30.objects[object_name].angles[i] - steady_144.objects[object_name].angles[i]))
		var steady_camera: float = steady_30.camera_angles.distance_to(steady_144.camera_angles)
		# Event boundaries quantise to the update period (original behaviour), so
		# phase drifts slightly; a frame-locked speed error would be ~4.8x.
		if steady_angles > 0.5 or steady_camera > 1.0: failures.append({"scene": scene, "error": "per-frame mode speed differs with frame rate", "angles": steady_angles, "camera": steady_camera})
		# ...but event triggers and rand draws follow update count (informational).
		var sampler := func(t): return feed.sample(t + FEED_OFFSET)
		var music_30 := per_frame(runtime, sampler, 1.0 / 30.0)
		var music_144 := per_frame(runtime, sampler, 1.0 / 144.0)
		scene_report.per_frame_mode = {"steady_input_max_angle_difference_30_vs_144": steady_angles, "steady_input_camera_difference_30_vs_144": steady_camera, "music_camera_distance_30_vs_144": music_30.camera.distance_to(music_144.camera)}
		# Presentation: interpolation off shows the latest tick exactly.
		runtime.reset()
		runtime.interpolate = false
		runtime.advance(0.05, func(t): return feed.sample(t))
		for entry in runtime.objects:
			if entry.node != null and not entry.node.transform.is_equal_approx(entry.sim_transform): failures.append({"scene": scene, "error": "uninterpolated presentation differs from tick"})
		runtime.interpolate = true
		# Catch-up is capped: a 2 s stall runs at most MAX_CATCHUP_TICKS.
		var before: int = runtime.metrics.ticks
		runtime.advance(2.0, func(t): return feed.sample(t))
		if runtime.metrics.ticks - before != SceneRuntime.MAX_CATCHUP_TICKS or runtime.metrics.dropped_ticks <= 0: failures.append({"scene": scene, "error": "catch-up cap not applied"})
		report[scene.get_file()] = scene_report
	report.audio_analysis = audio_rate_check()
	report.camera_counter = camera_counter_check()
	report.passed = failures.is_empty()
	report.failures = failures
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://../research/oozic/proof/phase1"))
	var file := FileAccess.open("res://../research/oozic/proof/phase1/frame-rate-independence.json", FileAccess.WRITE)
	if file: file.store_string(JSON.stringify(report, "\t") + "\n")
	print(JSON.stringify(report, "  "))
	runtime.free()
	quit(0 if failures.is_empty() else 1)
