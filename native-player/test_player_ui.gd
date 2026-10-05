extends SceneTree
## Player UI (player/): scaling math, titles/filter/total helpers, every
## control's bus command, window-level commands and menus, hit areas,
## playlist reorder/remove/filter/durations, keys and resize, with the
## split panel windows (main / playlist / library; docking in test_docking.gd).
##   Godot --headless --audio-driver Dummy --path native-player --script res://test_player_ui.gd
const Main = preload("res://main.gd")
const Fmt = preload("res://player/player_format.gd")
const AppSettings = preload("res://app_settings.gd")

func _initialize(): call_deferred("run")

func key(code: Key, ctrl := false, alt := false) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	event.ctrl_pressed = ctrl
	event.alt_pressed = alt
	return event

func mouse(position: Vector2, pressed: bool, double := false) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.double_click = double
	e.position = position
	return e

func motion(position: Vector2) -> InputEventMouseMotion:
	var e := InputEventMouseMotion.new()
	e.position = position
	e.button_mask = MOUSE_BUTTON_MASK_LEFT
	return e

func run():
	# --- Scaling math ---
	assert(Fmt.ui_scale(1.0, 1.0) == 1.0 and Fmt.ui_scale(2.0, 1.0) == 2.0 and Fmt.ui_scale(2.0, 2.0) == 4.0 and Fmt.ui_scale(2.0, 3.0) == 6.0 and Fmt.ui_scale(1.0, 1.5) == 1.5)
	assert(Fmt.ui_scale(0.0, 2.0) == 2.0) # unknown screen scale counts as 1
	assert(Fmt.window_pixels(Fmt.MAIN_SIZE, 1.0) == Vector2i(276, 116)) # even pixels
	assert(Fmt.window_pixels(Fmt.MAIN_SIZE, 2.0) == Vector2i(550, 232))
	assert(Fmt.window_pixels(Fmt.MAIN_SIZE, 3.0) == Vector2i(826, 348))
	assert(Fmt.window_pixels(Fmt.MAIN_SIZE, 4.0) == Vector2i(1100, 464)) # Retina default: 550 points wide
	assert(Fmt.DEFAULT_USER_SIZE == 2.0 and Fmt.USER_SIZES == [1.0, 1.5, 2.0, 3.0])
	assert(Fmt.nearest_user_size(1.4) == 1.5 and Fmt.nearest_user_size(9.0) == 3.0 and Fmt.size_label(1.5) == "1.5x" and Fmt.size_label(2.0) == "2x")
	assert(Fmt.total_height(false, 200) == 116.0 and Fmt.total_height(true, 200) == 316.0 and Fmt.total_height(true, 10) == 116.0 + Fmt.PLAYLIST_MIN_HEIGHT)
	assert(is_equal_approx(Fmt.playlist_height_for(632, 2.0), 200.0) and Fmt.playlist_height_for(10, 2.0) == Fmt.PLAYLIST_MIN_HEIGHT)
	# --- Titles, times, filter, totals ---
	assert(Fmt.display_title("/Music/Artist - Song.mp3") == "Artist - Song")
	assert(Fmt.display_title("/Music/01 - Artist - Song.flac") == "Artist - Song")
	assert(Fmt.display_title("/Music/07. Intro.mp3") == "Intro" and Fmt.display_title("/Music/03_Deep_Blue.mp3") == "Deep Blue")
	assert(Fmt.display_title("/Music/2001.mp3") == "2001") # a number-only title stays
	assert(Fmt.display_title("applemusic:123|Some Artist - Some Song") == "Some Artist - Some Song")
	assert(Fmt.time_text(0) == "0:00" and Fmt.time_text(245.9) == "4:05" and Fmt.time_text(-61) == "-1:01" and Fmt.time_text(3725) == "1:02:05")
	var entries := PackedStringArray(["/m/Alpha - One.mp3", "/m/Beta - Two.flac", "/m/Alpha - Three.mp3"])
	assert(Fmt.filter_indices(entries, "") == [0, 1, 2] and Fmt.filter_indices(entries, "alpha") == [0, 2] and Fmt.filter_indices(entries, "alpha three") == [2] and Fmt.filter_indices(entries, "FLAC") == [1])
	assert(Fmt.total_text(entries, {"/m/Alpha - One.mp3": 60.0, "/m/Beta - Two.flac": 90.0}) == "2:30+" and Fmt.total_text(entries.slice(0, 2), {"/m/Alpha - One.mp3": 60.0, "/m/Beta - Two.flac": 90.0}) == "2:30")
	assert(Fmt.format_tag("/m/x.FLAC") == "FLAC" and Fmt.format_tag("applemusic:1|x") == "")

	# --- The player window inside the app ---
	var app = Main.new()
	app.persist_override = false
	root.add_child(app)
	await process_frame
	var bus = app.bus
	var audio = app.audio
	# Never the real Music library: LIB sends open_library, which refreshes it.
	audio.music_bridge.helper_override = ProjectSettings.globalize_path("res://tools/fake_music_helper.sh")
	var w = app.controller
	var main = w.main_panel
	var pl = w.playlist_panel
	assert(w != null and w.borderless and not w.transparent and w.user_size == 2.0)
	assert(w.screen_scale == 1.0 and w.ui_scale == 2.0 and w.content_scale_factor == 2.0 and w.size == Vector2i(550, 232))
	assert(not w.playlist_open and not w.playlist_window.visible)
	# Split windows: main, playlist and library are separate (embedded when headless) windows.
	assert(w.playlist_window is Window and w.library_window is Window and pl.get_window() == w.playlist_window and w.library_panel.get_window() == w.library_window and main.get_window() == w)
	for pair in [[1.0, Vector2i(276, 116)], [3.0, Vector2i(826, 348)], [2.0, Vector2i(550, 232)]]:
		w.set_user_size(pair[0], false)
		assert(w.size == pair[1] and is_equal_approx(w.content_scale_factor, pair[0]), "size %s" % pair[0])
	assert(bus.status == "Player size 2x")

	# --- Hit areas: inside the panel, no overlaps, comfortable minimum ---
	for panel_controls in [[main, main.interactive_controls()], [pl, pl.interactive_controls()]]:
		var panel: Control = panel_controls[0]
		var controls: Array = panel_controls[1]
		if panel == pl: pl.size = Vector2(275, 180)
		var bounds := Rect2(Vector2.ZERO, panel.size)
		for i in controls.size():
			var a: Rect2 = Rect2(controls[i].position, controls[i].size)
			assert(bounds.encloses(a), "%s inside %s" % [controls[i].name, panel.name])
			assert(a.size.x >= 9.0 and a.size.y >= 9.0, "%s at least 9x9 units" % controls[i].name)
			for j in range(i + 1, controls.size()):
				var b: Rect2 = Rect2(controls[j].position, controls[j].size)
				assert(not a.intersects(b), "%s overlaps %s" % [controls[i].name, controls[j].name])

	# --- Every control sends the right bus command (handlers detached) ---
	audio.playlist = PackedStringArray(["res://test-media/DemoBeat.mp3", "res://test-media/DemoBeat.mp3", "res://test-media/DemoBeat.mp3"])
	assert(await audio.play_track(0))
	var saved_connections: Array = bus.command_requested.get_connections()
	for c in saved_connections: bus.command_requested.disconnect(c.callable)
	var log: Array = []
	var recorder := func(name, args): log.append([name, args])
	bus.command_requested.connect(recorder)
	var expected := {
		&"menu": &"show_player_menu", &"minimize": &"minimize", &"close": &"close_controller", &"mute": &"toggle_mute",
		&"library": &"toggle_library", &"visualiser": &"toggle_visualiser", &"playlist": &"toggle_drawer",
		&"previous": &"previous", &"play": &"play", &"pause": &"play_pause", &"stop": &"stop", &"next": &"next",
		&"eject": &"add_tracks", &"shuffle": &"toggle_shuffle", &"repeat": &"cycle_repeat",
	}
	assert(main.buttons.size() == expected.size())
	for id in expected:
		log.clear()
		main.buttons[id].click()
		assert(log.size() == 1 and log[0][0] == expected[id], "button %s sent %s" % [id, log])
	assert(log.size() == 1 and main.buttons.close.args.is_empty() and main.buttons.minimize.args.source == "controller")
	var pl_expected := {&"close": &"toggle_drawer", &"add": &"add_tracks", &"add_dir": &"add_directory", &"remove": &"remove_track", &"load": &"import_m3u_dialog", &"save": &"export_m3u_dialog"}
	for id in pl_expected:
		log.clear()
		pl.buttons[id].click()
		assert(log.size() == 1 and log[0][0] == pl_expected[id], "playlist button %s sent %s" % [id, log])
	log.clear()
	main.sliders.volume.click_at(0.5)
	assert(log.size() >= 1 and log.back()[0] == &"set_volume" and absf(log.back()[1].value - 0.5) < 0.01)
	log.clear()
	main.sliders.seek.click_at(0.25)
	assert(log.size() == 1 and log[0][0] == &"seek_fraction" and absf(log[0][1].fraction - 0.25) < 0.01)
	log.clear()
	main.scene_line._gui_input(mouse(Vector2(30, 5), true))
	assert(log.size() == 1 and log[0][0] == &"show_scene_menu")
	# Disabled buttons send nothing.
	main.buttons.stop.enabled = false
	log.clear()
	main.buttons.stop.click()
	assert(log.is_empty())
	main.refresh()
	# Playlist rows: double-click plays, drag reorders, Delete removes, Alt+Down moves.
	var list = pl.list
	list.size = Vector2(258, 100)
	log.clear()
	list._gui_input(mouse(Vector2(20, 1.5 * list.ROW_HEIGHT), true, true))
	assert(log.size() == 1 and log[0][0] == &"play_index" and log[0][1].index == 1)
	list._gui_input(mouse(Vector2(20, 1.5 * list.ROW_HEIGHT), false))
	log.clear()
	list._gui_input(mouse(Vector2(20, 0.5 * list.ROW_HEIGHT), true))
	list._gui_input(motion(Vector2(20, 1.6 * list.ROW_HEIGHT)))
	list._gui_input(motion(Vector2(20, 2.5 * list.ROW_HEIGHT)))
	assert(list.drop_row == 2)
	list._gui_input(mouse(Vector2(20, 2.5 * list.ROW_HEIGHT), false))
	assert(log.size() == 1 and log[0][0] == &"move_index" and log[0][1].from == 0 and log[0][1].to == 2 and list.selected == 2)
	log.clear()
	list._gui_input(key(KEY_DELETE))
	assert(log.size() == 1 and log[0][0] == &"remove_index" and log[0][1].index == 2)
	log.clear()
	list.select_index(0)
	list._gui_input(key(KEY_DOWN, false, true))
	assert(log.size() == 1 and log[0][0] == &"move_index" and log[0][1].from == 0 and log[0][1].to == 1)
	log.clear()
	list._gui_input(key(KEY_ENTER))
	assert(log.size() == 1 and log[0][0] == &"play_index" and log[0][1].index == 1)
	# Menus: every system-menu entry and the scene menu dispatch bus commands.
	w.build_system_menu()
	var menu_expected := {1: &"toggle_visualiser", 2: &"toggle_fullscreen", 3: &"next_scene", 11: &"previous_scene", 10: &"show_scene_menu", 4: &"toggle_drawer", 15: &"toggle_library", 16: &"reset_layout", 12: &"add_tracks", 13: &"add_directory", 5: &"import_m3u_dialog", 6: &"export_m3u_dialog", 14: &"clear_playlist", 7: &"open_settings", 8: &"minimize", 9: &"quit_app", 100: &"set_player_size", 103: &"set_player_size"}
	for id in menu_expected:
		assert(w.system_menu.get_item_index(id) >= 0, "menu item %d" % id)
		log.clear()
		w._on_system_menu(id)
		assert(log.size() == 1 and log[0][0] == menu_expected[id], "menu %d sent %s" % [id, log])
	assert(log[0][1].size == 3.0)
	w.build_scene_menu()
	assert(w.scene_menu.item_count == bus.scenes.size() + 3)
	for pair in [[3, &"select_scene"], [w.PIN_SCENE_ID, &"pin_scene"], [w.UNPIN_SCENE_ID, &"unpin_scene"]]:
		log.clear()
		w._on_scene_menu(pair[0])
		assert(log.size() == 1 and log[0][0] == pair[1])
	# Keys from the player: Space plays/pauses; typing in the search field
	# never reaches player or scene keys; the focused list keeps Up/Down.
	log.clear()
	w._input(key(KEY_SPACE))
	assert(log.size() == 1 and log[0][0] == &"play_pause" and log[0][1].source == "controller")
	w._input(key(KEY_L, true))
	assert(log.back()[0] == &"toggle_drawer")
	bus.command_requested.disconnect(recorder)
	for c in saved_connections: bus.command_requested.connect(c.callable)

	# --- Window-level commands with the real handlers ---
	var closed_height: int = w.size.y
	bus.command(&"toggle_drawer")
	var pw: Window = w.playlist_window
	assert(w.playlist_open and pw.visible and bus.drawer_open and w.size.y == closed_height and main.buttons.playlist.active)
	assert(pw.size == Fmt.window_pixels(Vector2(275, w.playlist_height), w.ui_scale) and pw.content_scale_factor == w.ui_scale)
	assert(pw.position == w.position + Vector2i(0, w.size.y), "playlist docked under main: %s / %s" % [pw.position, w.position])
	bus.command(&"add_tracks")
	assert(w.last_dialog == "add_tracks")
	bus.command(&"add_directory")
	assert(w.last_dialog == "add_directory")
	bus.command(&"export_m3u_dialog")
	assert(w.last_dialog == "export_m3u" and w.m3u_picker.file_mode == FileDialog.FILE_MODE_SAVE_FILE)
	bus.command(&"import_m3u_dialog")
	assert(w.last_dialog == "import_m3u")
	# LIB: the library panel opens to the right (the window widens), LED lit.
	var lw: Window = w.library_window
	var vis_window: Window = root
	assert(vis_window.position == w.position + Vector2i(w.size.x, 0), "visualiser docked right of main while the library is closed")
	bus.command(&"toggle_library")
	assert(w.library_open and lw.visible and bus.library_open and main.buttons.library.active)
	assert(lw.size == Fmt.window_pixels(Vector2(w.library_width, w.library_height), w.ui_scale) and lw.position == w.position + Vector2i(w.size.x, 0))
	assert(vis_window.position == lw.position + Vector2i(lw.size.x, 0), "the library opens between main and the visualiser")
	bus.command(&"toggle_library")
	assert(not w.library_open and not lw.visible and not bus.library_open and vis_window.position == w.position + Vector2i(w.size.x, 0))
	bus.command(&"set_player_size", {"size": 1.5})
	assert(w.user_size == 1.5 and w.ui_scale == 1.5)
	bus.command(&"set_player_size", {"size": 2.0})
	# Resize from the grip: pixel travel / ui_scale; clamped to the minimum.
	w.set_playlist_height(150)
	w._on_resize_drag(0.0, true)
	w._on_resize_drag(40.0, false)
	assert(is_equal_approx(w.playlist_height, 170.0) and pl.size.y == 170.0 and pw.size == Fmt.window_pixels(Vector2(275, 170), 2.0) and w.size == Fmt.window_pixels(Fmt.MAIN_SIZE, 2.0))
	# Width too (grip): LOAD / SAVE follow the right edge.
	w._on_playlist_resize(Vector2.ZERO, Vector2.ONE, true)
	w._on_playlist_resize(Vector2(50, 0), Vector2.ONE, false)
	assert(is_equal_approx(w.playlist_width, 300.0) and pl.size.x == 300.0 and pl.buttons.save.position.x == 255.0 and pl.list.size.x == 283.0)
	w._on_playlist_resize(Vector2(-500, 0), Vector2.ONE, false)
	assert(w.playlist_width == 275.0)
	w._on_resize_drag(-1000.0, false)
	assert(w.playlist_height == Fmt.PLAYLIST_MIN_HEIGHT)
	w.set_playlist_height(170)
	assert(pl.list.size.y > 100 and pl.filter.position.y > pl.list.position.y + pl.list.size.y)
	var state: Dictionary = w.layout_state()
	assert(state.drawer_open and state.playlist_height == 170.0 and state.playlist_width == 275.0 and state.has("time_remaining") and state.vis_mode == "spectrum" and state.dock.version == 2)

	# --- Playlist through the real AudioService: filter, reorder, remove, durations ---
	audio.stop_play()
	audio.playlist = PackedStringArray(["res://m/Alpha - One.mp3", "res://m/Beta - Two.mp3", "res://test-media/DemoBeat.mp3", "res://m/Gamma - Four.mp3"])
	audio.queue.configure(4)
	assert(await audio.play_track(2))
	assert(list.visible_rows == [0, 1, 2, 3] and list.current == 2)
	bus.publish_position(10.0, 245.0)
	assert(pl.durations.get("res://test-media/DemoBeat.mp3") == 245.0 and pl.total_text().ends_with("4:05+"))
	pl.filter.text = "//m/"
	pl.set_filter(pl.filter.text)
	assert(list.visible_rows == [0, 1, 3] and pl.total_text().begins_with("3 of 4"))
	# Drag within the filtered view maps back to playlist indices.
	list.scroll = 0.0
	list._gui_input(mouse(Vector2(20, 0.5 * list.ROW_HEIGHT), true))
	list._gui_input(motion(Vector2(20, 2.5 * list.ROW_HEIGHT)))
	list._gui_input(mouse(Vector2(20, 2.5 * list.ROW_HEIGHT), false))
	assert(audio.playlist[3] == "res://m/Alpha - One.mp3" and audio.track_index == 1, "filtered drag moved 0 -> 3")
	pl.set_filter("")
	assert(list.visible_rows.size() == 4 and list.current == 1)
	list.select_index(0)
	w.remove_selected()
	assert(audio.playlist.size() == 3 and audio.playlist[0] == "res://test-media/DemoBeat.mp3" and list.current == 0)
	audio.queue.mark_failed(2)
	audio._publish_playlist()
	assert(list.failed.has(2))
	main.status_left = 0.0
	assert(main.marquee.value.begins_with("1. DemoBeat") and main.info_text().begins_with("MP3  ·  TRACK 1/3"), main.marquee.value + " / " + main.info_text())
	# Delete on the last row removes it and keeps the selection on the new last row.
	list.select_index(2)
	list._gui_input(key(KEY_DELETE))
	assert(audio.playlist.size() == 2 and list.selected == 1)
	# Typing in the filter does not trigger keys; Escape clears it.
	pl.filter.grab_focus()
	var volume_before: float = bus.volume
	pw._input(key(KEY_UP))
	pw._input(key(KEY_T))
	assert(bus.volume == volume_before)
	pl.filter.text = "zzz"
	pl.set_filter("zzz")
	assert(list.visible_rows.is_empty())
	pl.filter.gui_input.emit(key(KEY_ESCAPE))
	assert(pl.filter.text == "" and list.visible_rows.size() == 2)
	# Elapsed / remaining toggle and the spectrum.
	main.time_display.position_s = 65.0
	main.time_display.duration_s = 245.0
	assert(main.time_display.text_value() == " 01:05")
	main.time_display._gui_input(mouse(Vector2(30, 5), true))
	assert(main.time_display.remaining and main.time_display.text_value() == "-03:00")
	main.vis.feed({"band_a": PackedFloat32Array([1.0, 0.5, 0.2]), "global_s": 1.0})
	main.vis._process(0.05)
	assert(main.vis.levels[0] > 0.3 and main.vis.levels[0] > main.vis.levels[18])
	main.vis._gui_input(mouse(Vector2(5, 5), true))
	assert(main.vis.mode == "scope")
	# Settings: the player-size choice goes through the bus.
	w.open_settings()
	var settings = w.settings_window
	assert(settings.size_option.item_count == 4 and settings.size_option.selected == 2)
	settings.size_option.item_selected.emit(3)
	assert(w.user_size == 3.0 and w.size.x == 826)
	# Persistence of the size choice (scratch settings file).
	var scratch := OS.get_temp_dir().path_join("oozic-test-player-ui.cfg")
	assert(AppSettings.save_player_size(1.5, scratch) == OK and AppSettings.load_player_size(scratch) == 1.5)
	AppSettings.save_section(scratch, "player", {"ui_size": 7.0})
	assert(AppSettings.load_player_size(scratch) == 2.0)
	DirAccess.remove_absolute(scratch)
	print("PASS: player UI scaling math 1x/1.5x/2x/3x (+ Retina default 550 pt), titles/filter/totals, window size + content scale per size, hit areas (inside, no overlaps, >= 9 units), all %d main + %d playlist buttons, volume/seek sliders, scene line, list double-click/drag/Delete/Alt+Down/Enter, %d menu entries + scene menu, Space/Ctrl+L from the player, split windows (playlist docked under main, library opening between main and the visualiser), dialogs, LIB toggle, size command, grip resize (height + width) + clamp, filtered drag reorder, remove selected, durations + total, failed marks, filter swallows keys, time toggle, spectrum + scope, Settings size choice, size persistence" % [expected.size(), pl_expected.size(), menu_expected.size()])
	app.queue_free()
	await create_timer(0.2).timeout
	quit()
