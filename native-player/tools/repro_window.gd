extends SceneTree
## Windowed repro of the real app (main.tscn) on mock audio (silent):
##   Godot --audio-driver Dummy --path native-player --script res://tools/repro_window.gd -- --mock-audio --no-persist [style=crossfade] [mode=classic|modern] [switches=3] [every=5]
## Switches scene every `every` seconds through the director (like cycling) and
## prints, once a second, the window camera, overlay state and frame stats of
## the root window, so a grey window shows up in the log.
var main
var t := 0.0
var next_switch := 3.0
var switches := 0
var played := false
var saved := {}
var alpha_lo := 1.0

func arg(name: String, fallback: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(name + "="): return a.get_slice("=", 1)
	return fallback

func _initialize():
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	call_deferred("setup")

func setup():
	await process_frame
	main.visualiser.settings.render_mode = arg("mode", "classic")
	main.visualiser.apply_render_mode()
	main.director.set_cycling({"transition": arg("style", "crossfade"), "transition_seconds": 1.0, "musical": arg("musical", "0") == "1"})
	next_switch = float(arg("every", "5"))
	var want := arg("scene", "")
	if want != "":
		for i in main.director.scenes.size():
			if str(main.director.scenes[i].path).ends_with("/" + want): main.director.commit(i, "user")

func _process(delta: float) -> bool:
	if main == null or main.visualiser == null: return false
	t += delta
	if arg("envset", "") != "":
		for we in root.find_children("*", "WorldEnvironment", true, false):
			if we.environment == null: continue
			for kv in arg("envset", "").split(";", false):
				we.environment.set(kv.get_slice("~", 0), str_to_var(kv.get_slice("~", 1)))
	if arg("vpset", "") != "":
		for kv in arg("vpset", "").split(";", false):
			root.set(kv.get_slice("~", 0), str_to_var(kv.get_slice("~", 1)))
	if arg("noattr", "0") == "1" and root.get_camera_3d() != null: root.get_camera_3d().attributes = null
	if arg("hide", "") != "":
		for n in root.find_children(arg("hide", ""), "", true, false): n.visible = false
	if arg("msaa", "") != "": root.msaa_3d = int(arg("msaa", "0"))
	if not played and arg("play", "") != "" and t >= float(arg("play_at", "2")):
		played = true
		print("[repro] t=%.3f play %s" % [t, arg("play", "")])
		if arg("mute", "0") == "1": main.audio.set_muted(true)
		main.audio.add_tracks(PackedStringArray([arg("play", "")]), true)
	if t >= next_switch and switches < int(arg("switches", "3")):
		switches += 1
		next_switch += float(arg("every", "5"))
		var d = main.director
		main.bus.command(&"next_scene")
		print("[repro] t=%.1f switch %d -> %d %s" % [t, switches, d.current, d.scenes[d.current].path])
	if arg("every_frame", "0") == "1":
		check_frame()
	elif int(t) != int(t - delta):
		report()
	if t > float(arg("every", "5")) * (int(arg("switches", "3")) + 1.5):
		if frames > 0: print("[repro] frames=%d flat=%d worst_spread=%.3f" % [frames, flat_frames, worst])
		quit(0)
	return false

func report():
	var cam := root.get_camera_3d()
	var v = main.visualiser
	var img := root.get_texture().get_image()
	var stats := ""
	if img != null:
		var lo := 9.0
		var hi := -9.0
		var sum := 0.0
		var n := 0
		for y in range(0, img.get_height(), 23):
			for x in range(0, img.get_width(), 23):
				var l := img.get_pixel(x, y).get_luminance()
				lo = minf(lo, l); hi = maxf(hi, l); sum += l; n += 1
		stats = "lum min %.3f max %.3f mean %.3f" % [lo, hi, sum / maxf(n, 1)]
	print("[repro] t=%.1f cam=%s in_tree=%s cam_owner_is_runtime=%s transition_active=%s modern=%s %s" % [t, cam, cam != null and cam.is_inside_tree(),
		cam != null and v.runtime != null and cam == v.runtime.camera, v.transition.is_active(), v.modern.attached, stats])

var worst := 9.0
var flat_frames := 0
var frames := 0
func check_frame():
	var img := root.get_texture().get_image()
	if img == null: return
	frames += 1
	var lo := 9.0
	var hi := -9.0
	alpha_lo = 9.0
	for y in range(0, img.get_height(), 31):
		for x in range(0, img.get_width(), 31):
			var c := img.get_pixel(x, y)
			var l := c.get_luminance()
			lo = minf(lo, l); hi = maxf(hi, l); alpha_lo = minf(alpha_lo, c.a)
	worst = minf(worst, hi - lo)
	for shot in arg("shots", "").split(",", false):
		if t >= float(shot) and not saved.has(shot):
			saved[shot] = true
			img.save_png(arg("shot_dir", "user://") + "/repro-%s.png" % shot)
	if arg("trace", "0") == "1" and int(t * 4) != int((t - get_root().get_process_delta_time()) * 4):
		var a = main.audio
		print("[repro] t=%.2f alpha_min %.3f lum %.3f..%.3f playing=%s captured=%d max_s=%.3f transport=%s status=%s" % [t, alpha_lo, lo, hi, a.is_playing(), a.captured_frames, a.maximum_s, main.bus.transport, main.bus.status])
	if hi - lo < 0.08:
		flat_frames += 1
		print("[repro] FLAT t=%.3f lum %.3f..%.3f transition_active=%s cam=%s" % [t, lo, hi, main.visualiser.transition.is_active(), root.get_camera_3d()])
