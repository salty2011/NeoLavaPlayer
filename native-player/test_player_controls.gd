extends SceneTree
## Player integration: services + both windows (headless: the control window is
## embedded) driven through PlayerBus, player controls and keys from either window.
const Main = preload("res://main.gd")
const Queue = preload("res://playback_queue.gd")
var app

func _initialize(): call_deferred("run")

func key(code: Key, ctrl := false) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	event.ctrl_pressed = ctrl
	return event

func run():
	app = Main.new()
	app.persist_override = false
	root.add_child(app)
	await process_frame
	var bus = app.bus
	var audio = app.audio
	var controller = app.controller
	var panel = controller.main_panel
	var playlist = controller.playlist_panel
	assert(controller != null and controller.user_size == 2.0)
	assert(bus.transport == "stopped" and not panel.buttons.play.enabled and playlist.selected_index() == -1)
	audio.playlist = PackedStringArray(["res://test-media/DemoBeat.mp3", "res://test-media/DemoBeat.mp3"])
	assert(await audio.play_track(0))
	assert(audio.queue.current == 0 and bus.transport == "playing" and bus.track_index == 0)
	assert(playlist.list.visible_rows.size() == 2 and panel.buttons.pause.enabled and panel.buttons.play.active)
	assert(panel.marquee.value.begins_with("1. DemoBeat"))
	# Space from the control window pauses; from the visualiser resumes.
	controller._input(key(KEY_SPACE))
	assert(audio.player.stream_paused and bus.transport == "paused" and not panel.buttons.play.active and panel.time_display.transport == "paused")
	app.visualiser._input(key(KEY_SPACE))
	assert(not audio.player.stream_paused and bus.transport == "playing")
	audio.queue.repeat_mode = Queue.Repeat.ALL
	await audio.play_track(1)
	await audio.advance_track(true)
	assert(audio.track_index == 0)
	audio.queue.repeat_mode = Queue.Repeat.ONE
	await audio.advance_track(true)
	assert(audio.track_index == 0)
	audio.queue.repeat_mode = Queue.Repeat.OFF
	await audio.play_track(1)
	audio.player.stop()
	await audio.advance_track(true)
	assert(audio.track_index == 1 and bus.transport == "stopped")
	# Player buttons reach the services through the bus.
	panel.buttons.shuffle.click()
	assert(audio.queue.shuffle and bus.shuffle and panel.buttons.shuffle.active)
	panel.buttons.repeat.click()
	assert(audio.queue.repeat_mode == Queue.Repeat.ALL and bus.repeat_mode == Queue.Repeat.ALL)
	controller._input(key(KEY_O, true))
	assert(bus.repeat_mode == Queue.Repeat.ONE and panel.buttons.repeat.label == "REP 1")
	# Volume (Up/Down, the volume slider) and mute (Ctrl+M) act on the Master bus.
	panel.sliders.volume.click_at(0.5)
	assert(absf(audio.volume - 0.5) < 0.01 and absf(panel.sliders.volume.value - 0.5) < 0.01)
	audio.set_volume(0.5)
	app.visualiser._input(key(KEY_UP))
	assert(is_equal_approx(bus.volume, 0.55))
	controller._input(key(KEY_M, true))
	assert(bus.muted and AudioServer.is_bus_mute(0) and panel.buttons.mute.glyph == "speaker_muted")
	controller._input(key(KEY_M, true))
	assert(not bus.muted and not AudioServer.is_bus_mute(0))
	# Tab hides the control window from the visualiser; motion shows the hint.
	app.visualiser._input(key(KEY_TAB))
	assert(not controller.visible and not bus.controller_visible)
	app.visualiser._input(InputEventMouseMotion.new())
	assert(app.visualiser.hint_button.visible)
	app.visualiser._process(3.1)
	assert(not app.visualiser.hint_button.visible)
	app.visualiser._input(key(KEY_TAB))
	assert(controller.visible and bus.controller_visible)
	# Decode failure keeps the current track.
	audio.playlist.append("/tmp/oozic-no-such-track.mp3")
	assert(not await audio.play_track(2))
	assert(audio.track_index == 1 and audio.queue.current == 1)
	audio.stop_play()
	assert(not audio.player.playing and bus.transport == "stopped")
	# Continuous playback skips an undecodable next track instead of stopping.
	var good := "res://test-media/DemoBeat.mp3"
	audio.playlist = PackedStringArray([good, "/tmp/oozic-no-such-track-a.mp3", good])
	audio.queue = Queue.new()
	audio.queue.configure(3)
	audio.queue.repeat_mode = Queue.Repeat.ALL
	assert(await audio.play_track(0))
	audio.player.stop()
	await audio.advance_track(true)
	assert(audio.track_index == 2 and audio.queue.failed.has(1) and audio.player.playing)
	# An all-bad remainder terminates (bounded) and leaves playback stopped.
	audio.playlist = PackedStringArray(["/tmp/oozic-no-such-a.mp3", "/tmp/oozic-no-such-b.mp3", "/tmp/oozic-no-such-c.mp3"])
	audio.queue = Queue.new()
	audio.queue.configure(3)
	audio.queue.current = 0
	audio.player.stop()
	await audio.advance_track(true)
	assert(audio.queue.failed.size() == 3 and bus.transport == "stopped" and not audio.player.playing)
	# End-of-track during a load is queued, then resolved when the load fails.
	audio.playlist = PackedStringArray([good, "/tmp/oozic-no-such-track-b.mp3", good])
	audio.queue = Queue.new()
	audio.queue.configure(3)
	assert(await audio.play_track(0))
	audio.player.stop()
	audio.loading_audio = true
	await audio.advance_track(true)
	assert(audio.pending_advance and audio.track_index == 0)
	audio.loading_audio = false
	assert(not await audio.play_track(1))
	assert(not audio.pending_advance)
	for frame in 5: await process_frame
	assert(audio.track_index == 2 and audio.player.playing)
	# A successful load during a pending advance keeps the newly loaded track.
	audio.loading_audio = true
	await audio.advance_track(true)
	audio.loading_audio = false
	assert(await audio.play_track(0))
	for frame in 5: await process_frame
	assert(audio.track_index == 0 and not audio.pending_advance)
	# Playlist editing keeps the current track and failure marks on the same files.
	audio.playlist = PackedStringArray(["res://a.mp3", "res://b.mp3", good, "res://d.mp3"])
	audio.queue = Queue.new()
	audio.queue.configure(4)
	assert(await audio.play_track(2))
	audio.queue.mark_failed(0)
	assert(audio.move_track(2, 0) and audio.track_index == 0 and audio.playlist[0] == good and audio.queue.failed == [1])
	assert(audio.move_track(3, 1) and audio.playlist[1] == "res://d.mp3" and audio.track_index == 0)
	assert(audio.remove_track(1) and audio.playlist.size() == 3 and audio.track_index == 0 and audio.queue.failed == [1])
	assert(bus.playlist.size() == 3 and playlist.list.visible_rows.size() == 3)
	playlist.list.select_index(0)
	playlist.list._gui_input(key(KEY_DELETE))
	assert(audio.track_index == -1 and bus.transport == "stopped" and audio.playlist.size() == 2)
	# M3U export / import round trip.
	var m3u := OS.get_temp_dir().path_join("oozic-test-playlist.m3u")
	audio.playlist = PackedStringArray([good, "/Music/Some Track.flac"])
	assert(audio.export_m3u(m3u))
	audio.clear_playlist()
	assert(audio.playlist.is_empty() and bus.playlist.is_empty())
	assert(audio.import_m3u(m3u, false) == 2 and audio.playlist[1] == "/Music/Some Track.flac")
	DirAccess.remove_absolute(m3u)
	# Automatic playlist persistence (scratch file).
	var saved := OS.get_temp_dir().path_join("oozic-test-playlist.json")
	audio.persist = true
	audio.playlist_path = saved
	audio.settings_path = OS.get_temp_dir().path_join("oozic-test-settings.cfg")
	audio.track_index = 1
	assert(audio.save_playlist_file())
	audio.playlist = PackedStringArray()
	assert(audio.load_playlist_file() and audio.playlist.size() == 2 and audio.track_index == 1)
	audio.persist = false
	DirAccess.remove_absolute(saved)
	DirAccess.remove_absolute(audio.settings_path)
	# Playlist panel: Ctrl+L from the visualiser opens it; the window grows.
	var closed_height: int = controller.size.y
	app.visualiser._input(key(KEY_L, true))
	assert(controller.playlist_open and bus.drawer_open and controller.size.y > closed_height and playlist.visible)
	# Debug keys from the control window: F3 overlay, F4 session-only cap cycle.
	controller._input(key(KEY_F3))
	assert(app.visualiser.overlay.visible)
	app.visualiser._process(0.016)
	assert(app.visualiser.overlay.lines().size() > 5)
	var saved_cap: int = app.settings.fps_cap
	controller._input(key(KEY_F4))
	assert(app.settings.effective_cap() == 30 and Engine.max_fps == 30 and app.settings.fps_cap == saved_cap)
	for cap in [60, 144, 0]:
		app.visualiser._input(key(KEY_F4))
		assert(app.settings.effective_cap() == cap and Engine.max_fps == cap)
	app.visualiser._input(key(KEY_F4))
	assert(Engine.max_fps == 60)
	app.visualiser._input(key(KEY_F3))
	assert(not app.visualiser.overlay.visible)
	# Scene selection by title from the control side; Page Down steps alphabetically.
	assert(bus.scene_title(0) == "Triple Trance" and app.visualiser.scene_loaded == 0)
	var lvt2 := -1
	for i in bus.scenes.size():
		if bus.scenes[i].path.ends_with("lava25/LVT2"): lvt2 = i
	bus.command(&"select_scene", {"index": lvt2})
	assert(bus.scene_title() == "Dancing Well (partly reconstructed)" and app.visualiser.scene_loaded == lvt2)
	controller._input(key(KEY_PAGEDOWN))
	assert(bus.scene_index != lvt2 and app.visualiser.scene_loaded == bus.scene_index)
	# Engine-parity API through the bus: original keys from either window,
	# Effects toggles, Response/Brightness sliders (original mappings).
	const StyleFlags = preload("res://style_flags.gd")
	var runtime = app.runtime
	var texture_before: bool = (runtime.get_style_flags() & StyleFlags.TEXTURE) != 0
	controller._input(key(KEY_T))
	assert(((runtime.get_style_flags() & StyleFlags.TEXTURE) != 0) != texture_before and bus.status.begins_with("Texture"))
	var overlay_before: bool = app.visualiser.overlay.visible
	var shift_f3 := key(KEY_F3)
	shift_f3.shift_pressed = true
	app.visualiser._input(shift_f3)
	assert((runtime.get_style_flags() & StyleFlags.FLAT_SHADING) != 0 and app.visualiser.overlay.visible == overlay_before)
	bus.command(&"set_style_flag", {"flag": StyleFlags.WIREFRAME, "on": true})
	assert((runtime.get_style_flags() & StyleFlags.WIREFRAME) != 0)
	var wire_entry: Dictionary = bus.scene_info.style_flags.filter(func(e): return e.flag == StyleFlags.WIREFRAME)[0]
	assert(wire_entry.on and bus.scene_info.style_flags.size() == 8)
	bus.command(&"set_style_flag", {"flag": StyleFlags.WIREFRAME, "on": false})
	var scene_response: float = runtime.get_response()
	bus.command(&"set_tuning", {"response_slider": 100.0, "brightness_slider": 50.0})
	assert(is_equal_approx(runtime.get_response(), 2.0) and is_equal_approx(runtime.get_brightness(), 0.5) and is_equal_approx(bus.response, 2.0))
	assert(is_equal_approx(bus.scene_info.response_slider, 100.0) and bus.scene_info.tuning_supported)
	bus.command(&"set_tuning", {"response_slider": -1.0, "brightness_slider": -1.0})
	assert(is_equal_approx(runtime.get_response(), scene_response))
	controller.open_settings()
	assert(controller.settings_window.effect_flags_box.get_child_count() == 8 and is_equal_approx(controller.settings_window.response_slider.value, bus.scene_info.response_slider))
	# Synthetic analysis drives the scene without any audio playing.
	audio.stop_play()
	app.visualiser.set_analysis_source("mock", false)
	var ticks: int = app.runtime.metrics.ticks
	for frame in 10: app.visualiser._process(1.0 / 60.0)
	assert(app.runtime.metrics.ticks > ticks and app.visualiser.last_signals.has("section") and bus.last_analysis.has("section"))
	app.visualiser.set_analysis_source("real", false)
	print("PASS: bus transport/track state, play/pause state, Space from both windows, repeat all/one/off completion, shuffle/repeat buttons, Ctrl+O, volume/mute on Master, Tab controller toggle + hint timer, decode failure preserves current, stop, skip undecodable next track, bounded all-bad termination, queued end-of-track during load, playlist move/remove bookkeeping, m3u round trip, playlist persistence, playlist panel via Ctrl+L, F3/F4 from either window, scene titles + select + Page Down, original keys T/Shift+F3 from either window, Effects flags, Response/Brightness slider mappings, settings Effects tab, mock analysis source")
	app.queue_free()
	app = null
	await create_timer(0.2).timeout
	quit()
