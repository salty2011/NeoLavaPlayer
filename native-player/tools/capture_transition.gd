extends SceneTree
## Windowed proof capture of a scene transition on mock audio (silent):
##   Godot --audio-driver Dummy --path native-player --script res://tools/capture_transition.gd -- <out_dir> [from=Triple Trance] [to=Dancing Well] [style=crossfade] [seconds=2] [mode=classic|modern]
## Drives the visualiser by hand at 30 fps so the frames land at known blend
## progress (about 25 %, 50 %, 75 %), saves them, then checks the hand-over:
## the last blended frame must match the window's own render of the adopted
## scene. Also prints the prepare hitch (ms) and the frame time of the first
## blend frames.
const PlayerBusScript = preload("res://player_bus.gd")
const SceneDirector = preload("res://scene_director.gd")
const Visualiser = preload("res://visualiser.gd")

func _initialize(): call_deferred("run")

func arg(name: String, fallback: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(name + "="): return a.get_slice("=", 1)
	return fallback

func find_scene(bus, title: String) -> int:
	for i in bus.scenes.size():
		if str(bus.scenes[i].get("title", bus.scenes[i].name)).begins_with(title): return i
	return -1

func grab() -> Image:
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func difference(a: Image, b: Image) -> float:
	var total := 0.0
	var count := 0
	for y in range(0, a.get_height(), 7):
		for x in range(0, a.get_width(), 7):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			total += absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)
			count += 3
	return total / maxf(count, 1)

func run():
	var out_dir := OS.get_cmdline_user_args()[0] if not OS.get_cmdline_user_args().is_empty() else "user://transition"
	DirAccess.make_dir_recursive_absolute(out_dir)
	var style := arg("style", "crossfade")
	var seconds := float(arg("seconds", "2"))
	var bus = PlayerBusScript.instance()
	var director = SceneDirector.new(false)
	root.add_child(director)
	await process_frame
	var visualiser = Visualiser.new()
	root.add_child(visualiser)
	await process_frame
	bus.controller_present = false
	visualiser.settings.render_mode = arg("mode", "classic")
	visualiser.set_analysis_source("mock", false)
	visualiser.set_process(false)
	visualiser.transition.set_process(false)
	var from := find_scene(bus, arg("from", "Triple Trance"))
	var to := find_scene(bus, arg("to", "Dancing Well"))
	director.set_cycling({"transition": "cut", "musical": false})
	director.select(from)
	visualiser.apply_render_mode()
	var dt := 1.0 / 30.0
	for i in 90:
		visualiser._process(dt)
		await process_frame
	director.set_cycling({"transition": style, "transition_seconds": seconds})
	var started := Time.get_ticks_usec()
	if arg("prewarm", "0") == "1":
		visualiser.prepare_incoming(to)
		var warm_started := Time.get_ticks_usec()
		for i in 2: await process_frame
		print("pre-roll frames (2) took %.1f ms" % (float(Time.get_ticks_usec() - warm_started) / 1000.0))
	director.select(to)
	print("select -> blend start blocked the main thread for %.1f ms (scene load %.1f ms)" % [float(Time.get_ticks_usec() - started) / 1000.0, visualiser.transition.load_ms])
	var targets := [0.25, 0.5, 0.75]
	var shots := 0
	var frame_times := []
	var last_blend: Image = null
	var steps := 0
	while visualiser.transition.blending and steps < 600:
		var step_started := Time.get_ticks_usec()
		visualiser._process(dt)
		visualiser.transition._process(dt)
		if shots < targets.size() and visualiser.transition.progress >= targets[shots]:
			var image := await grab()
			var path := "%s/%s-%d.png" % [out_dir, style, shots + 1]
			image.save_png(path)
			print("saved %s at progress %.2f" % [path, visualiser.transition.progress])
			shots += 1
		else:
			await process_frame
		if steps < 6: frame_times.append(float(Time.get_ticks_usec() - step_started) / 1000.0)
		if visualiser.transition.progress > 0.95 and last_blend == null:
			last_blend = await grab()
		steps += 1
	print("first blend frame times (ms): ", frame_times)
	# Hand-over: the window now draws the adopted runtime while the frozen stage covers it.
	var covered := await grab()
	visualiser.transition._process(dt)
	visualiser.transition._process(dt)
	await process_frame
	await process_frame
	var direct := await grab()
	print("scene_loaded ", visualiser.scene_loaded, " expected ", to, " stage freed ", not visualiser.transition.is_active())
	if last_blend != null: print("hand-over difference (mean abs RGB, 0..1): last blend vs window %.4f, covered vs window %.4f" % [difference(last_blend, direct), difference(covered, direct)])
	print("window size ", root.size, " camera ", root.get_camera_3d())
	visualiser.queue_free()
	director.queue_free()
	await process_frame
	quit(0)
