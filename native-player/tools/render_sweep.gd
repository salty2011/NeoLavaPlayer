extends SceneTree
## Deterministic render sweep (Phase 4c). Windowed (needs a GPU), silent:
##   Godot --audio-driver Dummy --path native-player --script res://tools/render_sweep.gd -- \
##     --out=/abs/dir [--seconds=10] [--scenes=Triple,Hydroid] [--paths=lava25/LVT2] [--mode=classic|modern]
##     [--quality=low|medium|high|ultra] [--times=6,20,40] [--frametime] [--cam=x,y,z,lx,ly,lz[,fov]]
## Every scene is reset, then driven by the silent mock feed (128 BPM, default
## section schedule) on fixed 60 Hz ticks for exactly --seconds of scene time,
## so the same build captures the same frame. Used for the Classic renderer
## migration diff (Compatibility vs Forward+) and the Modern proof captures.
## --times captures several moments of one run (e.g. quiet/build/drop);
## --frametime renders 240 extra frames per capture and reports GPU/CPU ms.
const SceneRuntime = preload("res://scene_runtime.gd")
const SceneCatalog = preload("res://scene_catalog.gd")
const MockAudioFeed = preload("res://mock_audio_feed.gd")
const ReactivityServiceScript = preload("res://analysis/reactivity_service.gd")

var out := ""
var seconds := 10.0
var times: Array = []
var filters: PackedStringArray = PackedStringArray()
var path_filters: PackedStringArray = PackedStringArray()
var mode := "classic"
var quality := "high"
var frametime := false
## --cam=x,y,z,lx,ly,lz[,fov] overrides the camera pose (world space) at capture time.
var cam: Array = []
## --effects=particles,trails,dof,post (default all); "none" disables them.
var effect_list = null

func _initialize():
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="): out = arg.trim_prefix("--out=")
		elif arg.begins_with("--seconds="): seconds = arg.trim_prefix("--seconds=").to_float()
		elif arg.begins_with("--scenes="): filters = arg.trim_prefix("--scenes=").split(",", false)
		elif arg.begins_with("--paths="): path_filters = arg.trim_prefix("--paths=").split(",", false)
		elif arg.begins_with("--mode="): mode = arg.trim_prefix("--mode=")
		elif arg.begins_with("--quality="): quality = arg.trim_prefix("--quality=")
		elif arg.begins_with("--times="):
			for value in arg.trim_prefix("--times=").split(",", false): times.append(value.to_float())
		elif arg.begins_with("--cam="):
			for value in arg.trim_prefix("--cam=").split(",", false): cam.append(value.to_float())
		elif arg == "--frametime": frametime = true
		elif arg.begins_with("--effects="): effect_list = arg.trim_prefix("--effects=").split(",", false)
	if times.is_empty(): times = [seconds]
	call_deferred("run")

func run():
	if out.is_empty():
		push_error("render_sweep: --out=dir required")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(out)
	root.size = Vector2i(1200, 760)
	var service = ReactivityServiceScript.instance()
	var catalog := SceneCatalog.load_catalog()
	var report := {"renderer": str(ProjectSettings.get_setting("rendering/renderer/rendering_method")), "adapter": RenderingServer.get_video_adapter_name(), "mode": mode, "quality": quality, "times": times, "scenes": []}
	for i in catalog.size():
		var entry: Dictionary = catalog[i]
		if not filters.is_empty() and not Array(filters).any(func(f): return str(entry.name).contains(f)): continue
		if not path_filters.is_empty() and not Array(path_filters).any(func(f): return str(entry.path).ends_with(f)): continue
		var runtime = SceneRuntime.new()
		root.add_child(runtime)
		runtime.load_scene(entry.path)
		var feed = MockAudioFeed.new(128.0, maxi(runtime.data.get("bands", []).size(), 1))
		var layer = null
		if mode == "modern":
			service.auto_tick = false
			service.hub.set_source(feed.reactivity_source())
			layer = load("res://modern/modern_layer.gd").new()
			layer.quality = quality
			if effect_list != null:
				for key in layer.effects: layer.effects[key] = effect_list.has(key)
			root.add_child(layer)
			layer.attach(runtime)
		var sampler := func(t): return feed.sample(t)
		var clock := 0.0
		for target in times:
			# Advance in 0.1 s frames (6 ticks each, geometry on the last tick).
			while clock < float(target) - 1e-6:
				var dt := minf(0.1, float(target) - clock)
				if layer != null:
					service.tick(dt)
					layer.update(dt)
				runtime.advance(dt, sampler)
				clock += dt
			if cam.size() >= 6:
				runtime.camera.global_transform = Transform3D(Basis.IDENTITY, Vector3(cam[0], cam[1], cam[2])).looking_at(Vector3(cam[3], cam[4], cam[5]), Vector3.UP)
				if cam.size() >= 7: runtime.camera.fov = cam[6]
			var settle_frames := 3
			if layer != null: settle_frames = layer.settle()
			# Settling renders the same simulation state (nothing advances).
			for f in settle_frames:
				if layer != null: layer.update(0.0)
				await process_frame
			await RenderingServer.frame_post_draw
			var filename := "%02d-%s%s.png" % [i, str(entry.name).validate_filename(), "" if times.size() == 1 else "-t%02d" % int(target)]
			var saved := root.get_texture().get_image().save_png(out.path_join(filename)) == OK
			var item := {"scene": entry.name, "time": target, "file": filename, "saved": saved}
			if frametime: item.merge(await _measure(runtime, layer, sampler, clock))
			report.scenes.append(item)
			print("SWEEP ", JSON.stringify(item))
		if layer != null:
			layer.detach()
			layer.queue_free()
		runtime.queue_free()
		await process_frame
	FileAccess.open(out.path_join("sweep.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	print("SWEEP_DONE ", report.scenes.size())
	quit()

## 240 rendered frames with the scene running in real time (vsync off).
func _measure(runtime, layer, sampler: Callable, start: float) -> Dictionary:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var viewport_rid := root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(viewport_rid, true)
	var service = ReactivityServiceScript.instance()
	var gpu := 0.0
	var cpu := 0.0
	var wall := 0.0
	var frames := 240
	for f in 20: await process_frame
	var started := Time.get_ticks_usec()
	for f in frames:
		var dt := 1.0 / 60.0
		if layer != null:
			service.tick(dt)
			layer.update(dt)
		runtime.advance(dt, sampler)
		await process_frame
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid)
		cpu += RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid)
	wall = float(Time.get_ticks_usec() - started) / 1000.0 / frames
	# Render-only: same frames with the simulation paused (Modern layer still
	# animating), so the cost of the renderer itself is visible.
	started = Time.get_ticks_usec()
	for f in frames:
		if layer != null: layer.update(1.0 / 60.0)
		await process_frame
	var render_only := float(Time.get_ticks_usec() - started) / 1000.0 / frames
	var result := {"frame_ms": wall, "render_only_ms": render_only}
	if gpu > 0.0: result.gpu_ms = gpu / frames
	return result
