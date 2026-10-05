extends SceneTree
## Windowed proof captures of the player window with the library browser open
## (no audio, never the Music app: the fake helper answers and the library is
## published on the bus directly).
##   Godot --audio-driver Dummy --path native-player --script res://tools/capture_library.gd -- <out_dir> [size=2] [real]
## Default: the synthetic fixture (library_fixture.gd, 1,430 tracks).
## `real`: the cached user://music-library.json instead - for private layout
## checks only; never commit those captures.
## Writes library-<size>x-{songs,album,artists,narrow,empty,error}.png and
## settings-<size>x.png (the Settings window at that player size).
const Main = preload("res://main.gd")
const Fmt = preload("res://player/player_format.gd")
const LayoutShot = preload("res://tools/layout_shot.gd")
const LibraryFixture = preload("res://library_fixture.gd")
const MusicBridge = preload("res://music_bridge.gd")

func _initialize(): call_deferred("run")

func frames(n: int):
	for i in n: await process_frame

func shot(w: Window, path: String):
	await RenderingServer.frame_post_draw
	# The player's panels are separate docked windows: one composite image.
	var image: Image = LayoutShot.player(w.dock) if w.get("dock") != null else w.get_texture().get_image()
	var ok := image.save_png(path) == OK
	print("CAPTURE_SAVED " if ok else "CAPTURE_FAILED ", path, " ", w.size)

func run():
	var args := OS.get_cmdline_user_args()
	var out: String = args[0] if args.size() > 0 else OS.get_temp_dir()
	var user_size := 2.0
	for a in args:
		if a.begins_with("size="): user_size = a.trim_prefix("size=").to_float()
	var real := "real" in args
	DirAccess.make_dir_recursive_absolute(out)
	var app = Main.new()
	app.persist_override = false
	root.add_child(app)
	await frames(5)
	app.audio.music_bridge.helper_override = ProjectSettings.globalize_path("res://tools/fake_music_helper.sh")
	app.audio.music_bridge._refreshed = true
	var bus = app.bus
	var w = app.controller
	var lib = w.library_panel
	var tag := Fmt.size_label(user_size).trim_suffix("x")
	var name := func(state): return out.path_join("library-%sx-%s.png" % [tag, state])
	w.set_user_size(user_size, false)
	app.visualiser.set_analysis_source("mock", false)
	var data: Dictionary
	if real:
		data = MusicBridge.build_library(FileAccess.get_file_as_string("user://music-library.json"))
		data.updated = int(Time.get_unix_time_from_system()) - 3600
	else:
		data = MusicBridge.build_library(LibraryFixture.helper_json(1430))
	# Empty first run, then a permission error.
	bus.publish_library({}, "empty")
	w.set_playlist_open(true)
	w.set_playlist_height(Fmt.PLAYLIST_DEFAULT_HEIGHT)
	w.set_library_open(true)
	w.main_panel.status_left = 0.0
	await frames(20)
	await shot(w, name.call("empty"))
	bus.publish_library({}, "error")
	bus.publish_status("Couldn't read your Music library. Allow Oozic under System Settings › Privacy & Security › Media & Apple Music.")
	await frames(10)
	w.main_panel.status_left = 0.0
	await shot(w, name.call("error"))
	# Loaded: a few library tracks in the playlist, one playing (published only).
	bus.publish_library(data, "ready")
	bus.publish_status("Music library: %d tracks, %d playlists." % [data.count, data.playlists.size()])
	var order: Array = data.order
	var entries := PackedStringArray()
	for i in [3, 4, 5, 6, 17, 40]: entries.append(data.tracks[order[mini(i, order.size() - 1)]].entry)
	bus.publish_playlist(entries, 1, [] as Array[int])
	bus.publish_track(1, Fmt.display_title(entries[1]))
	bus.publish_transport("playing")
	bus.publish_position(83.0, 245.0)
	await frames(5)
	lib.list.select_row(4)
	lib.list.select_row(6, true)
	lib.list.select_row(9, false, true)
	w.main_panel.status_left = 0.0
	await frames(30)
	await shot(w, name.call("songs"))
	# Albums -> an album with several tracks (disc/track order, PLAY ALL / ADD ALL).
	lib.set_source("albums")
	var album := ""
	for key in lib.model.rows:
		if lib.model.group_count("album", key) >= 6 and str(key).length() > 30:
			album = key
			break
	if album.is_empty(): album = lib.model.rows[0]
	lib.open_group(album)
	lib.list.select_row(2)
	await frames(20)
	await shot(w, name.call("album"))
	# Artists with a search, playlist closed (the filler fills the column).
	w.set_playlist_open(false)
	lib.set_source("artists")
	lib.search.text = "the"
	lib.set_query("the")
	lib.list.select_row(1)
	await frames(20)
	await shot(w, name.call("artists"))
	# Narrowest library, songs sorted by artist, playlist back.
	w.set_playlist_open(true)
	lib.set_source("songs")
	lib.model.toggle_sort("artist")
	lib._rows_changed()
	w.set_library_size(Fmt.LIBRARY_MIN_WIDTH, w.library_height)
	await frames(20)
	await shot(w, name.call("narrow"))
	w.open_settings()
	await frames(20)
	await shot(w.settings_window, out.path_join("settings-%sx.png" % tag))
	app.queue_free()
	await create_timer(0.2).timeout
	quit()
