extends SceneTree
## Phase 4d proof captures: Triple Trance in Modern with the virtual director
## and character animation, driven by the silent mock feed (128 BPM, default
## schedule) at a fixed 60 fps, captured at chosen times. Windowed (needs a
## GPU), silent:
##   Godot --audio-driver Dummy --path native-player --script res://tools/director_capture.gd -- \
##     --out=/abs/dir [--times=5,12,19,25,29.5,30.4,38,62] [--quality=high] [--camera=director]
## Writes NN-tSS.s-<section>-<shot>.png plus capture.json (shot, section, push,
## camera pose per image).
const SceneRuntime = preload("res://scene_runtime.gd")
const MockAudioFeed = preload("res://mock_audio_feed.gd")
const ModernLayer = preload("res://modern/modern_layer.gd")
const ReactivityServiceScript = preload("res://analysis/reactivity_service.gd")

var out := ""
var times: Array = [5.0, 12.0, 19.0, 25.0, 29.5, 30.4, 38.0, 62.0]
var quality := "high"
var camera := "director"

func _initialize():
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="): out = arg.trim_prefix("--out=")
		elif arg.begins_with("--quality="): quality = arg.trim_prefix("--quality=")
		elif arg.begins_with("--camera="): camera = arg.trim_prefix("--camera=")
		elif arg.begins_with("--times="):
			times = []
			for value in arg.trim_prefix("--times=").split(",", false): times.append(value.to_float())
	call_deferred("run")

func run():
	if out.is_empty():
		push_error("director_capture: --out=dir required")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(out)
	root.size = Vector2i(1200, 760)
	var service = ReactivityServiceScript.instance()
	service.auto_tick = false
	await process_frame
	var runtime = SceneRuntime.new()
	root.add_child(runtime)
	runtime.load_scene("res://scenes/lava25/Triple Trance")
	var feed = MockAudioFeed.new(128.0, 3)
	var sampler := func(t): return feed.sample(t)
	service.set_mock(128.0)
	var layer = ModernLayer.new()
	layer.quality = quality
	layer.camera_mode = camera
	root.add_child(layer)
	layer.attach(runtime)
	var dt := 1.0 / 60.0
	var clock := 0.0
	var report := {"quality": quality, "camera": camera, "captures": []}
	for i in times.size():
		var target := float(times[i])
		while clock < target - 1e-6:
			service.tick(dt)
			runtime.advance(dt, sampler)
			layer.update(dt)
			clock += dt
		# Settle temporal effects on the same state (nothing advances).
		for f in layer.settle():
			layer.update(0.0)
			await process_frame
		await RenderingServer.frame_post_draw
		var d = layer.director
		var section := str(service.hub.frame.section)
		var shot: String = d.shot_name if d != null else camera
		var filename := "%02d-t%04.1f-%s-%s.png" % [i, target, section, shot]
		var saved := root.get_texture().get_image().save_png(out.path_join(filename)) == OK
		var item := {"file": filename, "time": target, "section": section, "shot": shot, "push": d.push if d != null else 0.0,
			"camera": var_to_str(runtime.camera.global_position), "fov": runtime.camera.fov, "saved": saved}
		report.captures.append(item)
		print("CAPTURE ", JSON.stringify(item))
	report.cuts = layer.director.cut_log if layer.director != null else []
	FileAccess.open(out.path_join("capture.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	layer.detach()
	print("CAPTURE_DONE ", times.size())
	quit()
