extends SceneTree
## Windowed proof captures of the player window in several states (no audio
## is played: the playlist and transport are published on the bus directly).
##   Godot --audio-driver Dummy --path native-player --script res://tools/capture_player.gd -- <out_dir> [size=2]
## Writes states-<size>x-{paused,filter,empty,collapsed}.png into out_dir.
const Main = preload("res://main.gd")
const Fmt = preload("res://player/player_format.gd")

func _initialize(): call_deferred("run")

func frames(n: int):
	for i in n: await process_frame

func shot(w: Window, path: String):
	await RenderingServer.frame_post_draw
	var ok := w.get_texture().get_image().save_png(path) == OK
	print("CAPTURE_SAVED " if ok else "CAPTURE_FAILED ", path)

func run():
	var args := OS.get_cmdline_user_args()
	var out: String = args[0] if args.size() > 0 else OS.get_temp_dir()
	var user_size := 2.0
	for a in args:
		if a.begins_with("size="): user_size = a.trim_prefix("size=").to_float()
	DirAccess.make_dir_recursive_absolute(out)
	var app = Main.new()
	app.persist_override = false
	root.add_child(app)
	await frames(5)
	var bus = app.bus
	var w = app.controller
	w.set_user_size(user_size, false)
	app.visualiser.set_analysis_source("mock", false)
	var tracks := PackedStringArray([
		"/Music/Lava Lamp Orchestra/01 - Lava Lamp Orchestra - Slow Rise.flac",
		"/Music/Lava Lamp Orchestra/02 - Lava Lamp Orchestra - Wax and Wane.flac",
		"/Music/Oozing Signals - Molten Static (Extended Mix).mp3",
		"/Music/Missing Drive/Gone Track.mp3",
		"/Music/The Convection Currents - Thermal.mp3",
		"/Music/Glass Blower - Night Bloom.flac",
	])
	var durations := [312.0, 245.0, 498.0, 0.0, 187.0, 263.0]
	for i in tracks.size():
		if durations[i] > 0.0: w.playlist_panel.durations[tracks[i]] = durations[i]
	var failed: Array[int] = [3]
	bus.publish_playlist(tracks, 2, failed)
	bus.publish_track(2, Fmt.display_title(tracks[2]))
	bus.publish_transport("paused")
	bus.publish_position(83.0, 498.0)
	w.main_panel.time_display.remaining = true
	w.set_playlist_open(true)
	w.set_playlist_height(130)
	w.playlist_panel.list.select_index(4)
	w.main_panel.status_left = 0.0
	await frames(40)
	await shot(w, out.path_join("states-%sx-paused.png" % Fmt.size_label(user_size).trim_suffix("x")))
	w.playlist_panel.filter.text = "lava"
	w.playlist_panel.set_filter("lava")
	w.main_panel.vis.mode = "scope"
	bus.publish_transport("playing")
	w.main_panel.time_display.remaining = false
	await frames(30)
	await shot(w, out.path_join("states-%sx-filter.png" % Fmt.size_label(user_size).trim_suffix("x")))
	w.playlist_panel.filter.text = ""
	w.playlist_panel.set_filter("")
	app.audio.clear_playlist()
	app.visualiser.set_analysis_source("real", false)
	await frames(30)
	w.main_panel.status_left = 0.0
	await shot(w, out.path_join("states-%sx-empty.png" % Fmt.size_label(user_size).trim_suffix("x")))
	w.set_playlist_open(false)
	await frames(10)
	await shot(w, out.path_join("states-%sx-collapsed.png" % Fmt.size_label(user_size).trim_suffix("x")))
	app.queue_free()
	await create_timer(0.2).timeout
	quit()
