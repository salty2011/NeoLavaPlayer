extends SceneTree
## Windowed proof captures of the docked windows (no audio is played: mock
## analysis drives the scene, the playlist is published on the bus, the
## library is the synthetic fixture, never the Music app).
##   Godot --audio-driver Dummy --path native-player --script res://tools/capture_docking.gd -- <out_dir> [sizes=1,2]
## Writes, per player size: default-<n>x.png (main, playlist below, the
## visualiser beside them), library-<n>x.png (the library opened between
## main and the visualiser), alt-<n>x.png (visualiser on the left, playlist
## on the right), each a composite of the windows' own captures at their
## dock positions on a desktop-like background; plus window-<id>-2x.png.
const Main = preload("res://main.gd")
const Fmt = preload("res://player/player_format.gd")
const LayoutShot = preload("res://tools/layout_shot.gd")
const LibraryFixture = preload("res://library_fixture.gd")
const MusicBridge = preload("res://music_bridge.gd")

var app
var w
var dock

func _initialize(): call_deferred("run")

func frames(n: int):
	for i in n: await process_frame

func save(image: Image, path: String):
	var ok := image != null and image.save_png(path) == OK
	print("CAPTURE_SAVED " if ok else "CAPTURE_FAILED ", path, " ", image.get_size() if image else Vector2i.ZERO)

func composite(path: String):
	await RenderingServer.frame_post_draw
	save(LayoutShot.composite(dock, ["main", "playlist", "library", "visualiser"], int(12 * w.ui_scale)), path)

## Drag panel `id` so its top-left lands at `target` (screen pixels), then drop.
func move_panel(id: String, target: Vector2i):
	var from: Vector2i = dock.rects[id].position
	dock.begin_drag(id, from)
	dock.drag_to(target)
	dock.end_drag()

func run():
	var args := OS.get_cmdline_user_args()
	var out: String = args[0] if args.size() > 0 else OS.get_temp_dir()
	var sizes := [1.0, 2.0]
	for a in args:
		if a.begins_with("sizes="): sizes = Array(a.trim_prefix("sizes=").split(",")).map(func(v): return float(v))
	DirAccess.make_dir_recursive_absolute(out)
	app = Main.new()
	app.persist_override = false
	root.add_child(app)
	await frames(5)
	app.audio.music_bridge.helper_override = ProjectSettings.globalize_path("res://tools/fake_music_helper.sh")
	app.audio.music_bridge._refreshed = true
	var bus = app.bus
	w = app.controller
	dock = w.dock
	dock.poll_mouse = false
	app.visualiser.set_analysis_source("mock", false)
	for i in bus.scenes.size():
		if str(bus.scenes[i].name) == "Hydroid":
			app.director.select(i)
			break
	var tracks := PackedStringArray([
		"/Music/Lava Lamp Orchestra/01 - Lava Lamp Orchestra - Slow Rise.flac",
		"/Music/Lava Lamp Orchestra/02 - Lava Lamp Orchestra - Wax and Wane.flac",
		"/Music/Oozing Signals - Molten Static (Extended Mix).mp3",
		"/Music/The Convection Currents - Thermal.mp3",
		"/Music/Glass Blower - Night Bloom.flac",
		"/Music/Basalt Choir - Cooling Flow.mp3",
	])
	var durations := [312.0, 245.0, 498.0, 187.0, 263.0, 301.0]
	for i in tracks.size(): w.playlist_panel.durations[tracks[i]] = durations[i]
	bus.publish_playlist(tracks, 2, [] as Array[int])
	bus.publish_track(2, Fmt.display_title(tracks[2]))
	bus.publish_transport("playing")
	bus.publish_position(83.0, 498.0)
	bus.publish_library(MusicBridge.build_library(LibraryFixture.helper_json(1430)), "ready")
	for user_size in sizes:
		var tag := Fmt.size_label(user_size).trim_suffix("x")
		w.set_user_size(user_size, false)
		w.set_library_open(false)
		w.set_playlist_open(true)
		w.reset_layout(false)
		w.main_panel.status_left = 0.0
		await frames(90)
		await composite(out.path_join("default-%sx.png" % tag))
		if is_equal_approx(user_size, 2.0):
			for id in ["main", "playlist", "visualiser"]:
				await RenderingServer.frame_post_draw
				save(dock.windows[id].get_texture().get_image(), out.path_join("window-%s-%sx.png" % [id, tag]))
		w.set_library_open(true)
		await frames(30)
		await composite(out.path_join("library-%sx.png" % tag))
		w.set_library_open(false)
		# Alternative: the visualiser on the left of main, the playlist (as
		# tall as the visualiser) on its right.
		var main_at: Vector2i = dock.rects.main.position
		w.set_playlist_height(Fmt.MAIN_SIZE.y + Fmt.PLAYLIST_DEFAULT_HEIGHT)
		move_panel("playlist", main_at + Vector2i(dock.rects.main.size.x + 3, 2))
		move_panel("visualiser", main_at - Vector2i(dock.rects.visualiser.size.x + 4, -1))
		await frames(30)
		await composite(out.path_join("alt-%sx.png" % tag))
		print("ALT_ATTACHMENTS ", dock.attachments)
	app.queue_free()
	await create_timer(0.3).timeout
	quit()
