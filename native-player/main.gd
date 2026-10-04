extends Node3D
## App composer. The root (main OS) window is the visualiser; the player
## window (player/player_window.gd) is a separate OS window (display/window/subwindows/
## embed_subwindows=false). Non-visual services (AudioService, SceneDirector)
## sit under this node; every window talks to them through PlayerBus.
## See docs/WINDOWS_AND_BUS.md.
##
## Window policy (decided; the original LavaPlay.exe launched LAVA.exe and was
## the app the user ran, so the player is the "app" window):
## - Closing the control window quits (unless --scene-only, where there is none).
## - Closing the visualiser minimises it to the Dock (Godot cannot hide its
##   main window); the player's visualiser button, the system menu, Settings
##   or F11 bring it back. With no controller, closing the visualiser quits.
## - Both windows minimise independently.
const AppSettings = preload("res://app_settings.gd")
const FlacDecoder = preload("res://flac_decoder.gd")
const AudioService = preload("res://audio_service.gd")
const SceneDirector = preload("res://scene_director.gd")
const Visualiser = preload("res://visualiser.gd")
const PlayerWindow = preload("res://player/player_window.gd")
const PlayerFormat = preload("res://player/player_format.gd")
const WindowLayout = preload("res://window_layout.gd")
const PlayerBusScript = preload("res://player_bus.gd")
const SyntheticSource = preload("res://analysis/synthetic_source.gd")

var bus
var audio
var director
var visualiser
var controller: Window
var smoke_path := ""
var sweep_path := ""
var reference_path := ""
var flac_test_path := ""
var capture_path := ""
var controller_capture_path := ""
var quit_after := -1.0
var run_clock := 0.0
var scene_only := false
var windowed := false
var play_paths := PackedStringArray()
## Session-only: --drawer opens the playlist panel, --player-size=<1|1.5|2|3>
## overrides the saved player size. (The old --skin= is ignored.)
var drawer_arg := false
var size_arg := -1.0
## Off in automated test modes so they never touch the user's saved state.
var persistent := true
var quitting := false
## Tests set this false before adding the node (no args can be passed there).
var persist_override = null

# Compatibility accessors for the test modes and older scripts.
var runtime:
	get: return visualiser.runtime
var player:
	get: return audio.player
var settings:
	get: return visualiser.settings

func _init():
	RenderingServer.set_debug_generate_wireframes(true)

func _ready():
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--smoke-report="): smoke_path = arg.trim_prefix("--smoke-report=")
		elif arg.begins_with("--scene-sweep-report="): sweep_path = arg.trim_prefix("--scene-sweep-report=")
		elif arg.begins_with("--flac-report="): flac_test_path = arg.trim_prefix("--flac-report=")
		elif arg.begins_with("--reference-report="): reference_path = arg.trim_prefix("--reference-report=")
		elif arg.begins_with("--capture="): capture_path = arg.trim_prefix("--capture=")
		elif arg.begins_with("--capture-controller="): controller_capture_path = arg.trim_prefix("--capture-controller=")
		elif arg.begins_with("--quit-after="): quit_after = arg.trim_prefix("--quit-after=").to_float()
		elif arg.begins_with("--play="): play_paths.append(arg.trim_prefix("--play="))
		elif arg == "--scene-only": scene_only = true
		elif arg == "--windowed": windowed = true
		elif arg.begins_with("--player-size="): size_arg = arg.trim_prefix("--player-size=").to_float()
		elif arg == "--drawer": drawer_arg = true
	var test_mode := not (smoke_path + sweep_path + reference_path + flac_test_path).is_empty()
	persistent = not test_mode and not OS.get_cmdline_user_args().has("--no-persist")
	if persist_override != null: persistent = bool(persist_override)
	bus = PlayerBusScript.instance()
	bus.scene_only = scene_only
	get_tree().set_auto_accept_quit(false)
	FlacDecoder.clean_stale_temp_files()
	audio = AudioService.new(persistent)
	add_child(audio)
	director = SceneDirector.new(persistent)
	add_child(director)
	visualiser = Visualiser.new()
	visualiser.audio = audio
	add_child(visualiser)
	visualiser.settings.load_settings()
	for arg in OS.get_cmdline_user_args():
		# Session-only override; the saved analysis source is left untouched.
		if arg == "--mock-audio" or arg.begins_with("--mock-audio="):
			visualiser.settings.analysis_source = "mock"
			if "=" in arg: visualiser.settings.mock_bpm = clampf(arg.get_slice("=", 1).to_float(), 30.0, 300.0)
		elif arg.begins_with("--mock-sections="):
			visualiser.mock_schedule = SyntheticSource.parse_schedule(arg.trim_prefix("--mock-sections="))
	# Screensaver-style scene-only run with nothing to play: silent synthetic input.
	if scene_only and play_paths.is_empty(): visualiser.settings.analysis_source = "mock"
	bus.command_requested.connect(_on_command)
	director.select(director.initial_index() if persistent else 0)
	visualiser.set_analysis_source(visualiser.settings.analysis_source, false)
	if "--debug-overlay" in OS.get_cmdline_user_args(): visualiser.overlay.visible = true
	get_tree().root.files_dropped.connect(func(paths): bus.command(&"add_paths", {"paths": paths}))
	get_window().title = "Oozic Visualiser"
	if not scene_only and (not test_mode or not reference_path.is_empty()): _create_controller()
	bus.controller_present = controller != null
	_restore_windows()
	if not play_paths.is_empty(): audio.add_tracks(play_paths, true)
	if scene_only and not windowed: _enter_screensaver()
	_publish_windows()
	if not flac_test_path.is_empty(): run_flac_test()
	elif not smoke_path.is_empty(): run_smoke()
	elif not sweep_path.is_empty(): run_sweep()
	elif not reference_path.is_empty(): run_reference()

func _create_controller():
	controller = PlayerWindow.new()
	controller.persist = persistent
	var saved := WindowLayout.load_state() if persistent else {}
	if drawer_arg: saved.drawer_open = true
	controller.apply_layout_state(saved)
	var saved_size := AppSettings.load_player_size() if persistent else PlayerFormat.DEFAULT_USER_SIZE
	controller.user_size = PlayerFormat.nearest_user_size(size_arg if size_arg > 0.0 else saved_size)
	add_child(controller)
	# Default: player below-left of the visualiser on the same screen.
	var root := get_window()
	controller.position = root.position + Vector2i(24, maxi(root.size.y - controller.size.y - 24, 0))
	controller.show()
	controller.keep_on_screen()

func _enter_screensaver():
	if DisplayServer.get_name() == "headless": return
	visualiser.set_fullscreen(true)
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN

# --- Window policy ---------------------------------------------------------

func _notification(what):
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		# Close button on the root (visualiser) window.
		if controller == null: quit_app()
		else: set_visualiser_visible(false)

func _on_command(command: StringName, args: Dictionary):
	match command:
		&"quit_app": quit_app()
		&"close_controller": quit_app()
		&"toggle_visualiser": set_visualiser_visible(not visualiser_shown())
		&"show_visualiser": set_visualiser_visible(true)
		&"hide_visualiser": set_visualiser_visible(false)
		&"toggle_controller": set_controller_visible(controller != null and not controller.visible)
		&"show_controller": set_controller_visible(true)
		&"hide_controller": set_controller_visible(false)
		&"toggle_fullscreen", &"set_fullscreen": call_deferred("_save_windows")
		&"minimize":
			if args.get("source", "") == "visualiser": get_window().mode = Window.MODE_MINIMIZED

## Godot cannot hide its main window ("Can't change visibility of main
## window"), so "closing" the visualiser minimises it to the Dock; the player
## restores it. Leaving fullscreen first: macOS animates the exit, so the
## minimise waits for it.
func set_visualiser_visible(on: bool):
	var root := get_window()
	if on:
		if root.mode == Window.MODE_MINIMIZED: root.mode = Window.MODE_WINDOWED
		root.grab_focus()
	elif controller != null:
		# Never leave both windows out of sight.
		if not controller.visible: set_controller_visible(true)
		if visualiser.is_fullscreen():
			root.mode = Window.MODE_WINDOWED
			await get_tree().create_timer(0.8).timeout
		root.mode = Window.MODE_MINIMIZED
	_publish_windows()
	# macOS minimises and restores asynchronously (the mode reads the old value
	# until the animation ends): publish again once the mode has changed.
	await _mode_settled(root, on)
	_publish_windows()

## Wait (at most `timeout` s) until w is shown (not minimised) == shown.
func _mode_settled(w: Window, shown: bool, timeout := 2.0) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while (w.mode != Window.MODE_MINIMIZED) != shown and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame

func visualiser_shown() -> bool:
	return get_window().mode != Window.MODE_MINIMIZED

func set_controller_visible(on: bool):
	if controller == null: return
	if on:
		if controller.mode == Window.MODE_MINIMIZED: controller.mode = Window.MODE_WINDOWED
		controller.show()
		controller.grab_focus()
	else:
		controller.hide()
		if not visualiser_shown(): set_visualiser_visible(true)
	_publish_windows()

func _publish_windows():
	var drawer: bool = controller.playlist_open if controller != null else false
	bus.publish_windows(visualiser_shown(), visualiser.is_fullscreen(), controller != null and controller.visible, drawer)

func quit_app():
	if quitting: return
	quitting = true
	_save_windows()
	audio.save_playlist_file()
	get_tree().quit()

# --- Window persistence ----------------------------------------------------

func _save_windows():
	if not persistent or DisplayServer.get_name() == "headless": return
	var root := get_window()
	var values := {"visualiser_fullscreen": visualiser.is_fullscreen()}
	if root.mode == Window.MODE_WINDOWED:
		values.visualiser_rect = WindowLayout.to_array(Rect2i(root.position, root.size))
		values.visualiser_screen = root.current_screen
	if controller != null:
		values.controller_rect = WindowLayout.to_array(Rect2i(controller.position, controller.size))
		values.controller_screen = controller.current_screen
		values.merge(controller.layout_state(), true)
	WindowLayout.save_state(values)

func _restore_windows():
	if not persistent or DisplayServer.get_name() == "headless": return
	var saved := WindowLayout.load_state()
	if saved.has("visualiser_rect"): WindowLayout.restore(get_window(), saved.visualiser_rect, saved.get("visualiser_screen", 0))
	if controller != null and saved.has("controller_rect"):
		WindowLayout.restore(controller, saved.controller_rect, saved.get("controller_screen", 0), false)
		# The saved screen may have another scale: re-scale there.
		controller.apply_scale()
	if bool(saved.get("visualiser_fullscreen", false)) and not scene_only: visualiser.set_fullscreen(true)

# --- Frame -----------------------------------------------------------------

func _process(delta):
	if quit_after >= 0:
		run_clock += delta
		if run_clock >= quit_after:
			quit_after = -1.0
			finish_capture()

## --capture=path.png [--capture-controller=path.png] --quit-after=seconds:
## save the window(s), then quit.
func finish_capture():
	await RenderingServer.frame_post_draw
	if not capture_path.is_empty():
		DirAccess.make_dir_recursive_absolute(capture_path.get_base_dir())
		var saved := get_viewport().get_texture().get_image().save_png(capture_path) == OK
		print("CAPTURE_SAVED " if saved else "CAPTURE_FAILED ", capture_path)
	if not controller_capture_path.is_empty() and controller != null:
		DirAccess.make_dir_recursive_absolute(controller_capture_path.get_base_dir())
		var saved := controller.get_texture().get_image().save_png(controller_capture_path) == OK
		print("CAPTURE_SAVED " if saved else "CAPTURE_FAILED ", controller_capture_path)
	quit_app()

func select_scene(index: int): director.select(index)

func _exit_tree():
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

# --- Automated test modes (single window; the reference mode adds the player) --

func run_smoke():
	AudioServer.set_bus_volume_db(0, -35)
	for i in bus.scenes.size():
		if bus.scenes[i].name == "Hydroid": select_scene(i); break
	var checks := {"missing_file_rejected": not audio.load_mp3("/tmp/oozic-missing-test.mp3"), "wrong_format_rejected": not audio.load_mp3("res://main.gd")}
	checks.bundled_mp3_decoded = audio.load_mp3("res://test-media/DemoBeat.mp3")
	var external := OS.get_environment("OOZIC_TEST_MP3")
	checks.external_mp3_decoded = audio.load_mp3(external) if not external.is_empty() else false
	checks.original_band_ranges = audio.inputs.band_a.size() == 3 and audio.inputs._bins[1].x > audio.inputs._bins[0].y
	await get_tree().create_timer(5.0).timeout
	checks.playback_advanced = player.get_playback_position() > 1
	checks.fft_nonzero = audio.maximum_s > 0 and audio.maximum_a > 0 and audio.captured_frames > 1024
	checks.tree_animates = runtime.metrics.tree_size_change > 0.001
	checks.audio_driven_motion = runtime.metrics.motion_radians > 0.001
	checks.torus_centerline_passage = runtime.metrics.maximum_torus_centerline_error < 0.001
	var tree = runtime.object_named("Hydra")
	var board = runtime.object_named("Surfboard")
	checks.tree_on_board_source_placement = abs(tree.record.engine_position.y - (board.record.engine_position.y + board.record.scale.y)) < 0.02 and is_zero_approx(tree.record.engine_position.z)
	audio.toggle_play()
	var old_frames = runtime.metrics.frames
	await get_tree().create_timer(0.3).timeout
	checks.pause_stops_motion = player.stream_paused and runtime.metrics.frames == old_frames
	audio.toggle_play()
	audio.seek_to(10)
	await get_tree().create_timer(0.3).timeout
	checks.seek_works = player.get_playback_position() > 9
	await RenderingServer.frame_post_draw
	checks.screenshot_saved = get_viewport().get_texture().get_image().save_png(smoke_path.get_base_dir() + "/native-player.png") == OK
	var metrics = runtime.metrics.duplicate(true)
	audio.stop_play()
	checks.stop_works = not player.playing
	audio.playlist = PackedStringArray(["res://test-media/DemoBeat.mp3", "res://test-media/DemoBeat.mp3"])
	checks.playlist_next = (await audio.play_track(1)) and audio.track_index == 1
	audio.stop_play()
	var report := {"checks": checks, "metrics": metrics, "scene_count": bus.scenes.size(), "capture_frames": audio.captured_frames, "maximum_global_scale": audio.maximum_s, "maximum_band_response": audio.maximum_a, "scene_summary": runtime.summary(), "original_scene_fidelity": false}
	FileAccess.open(smoke_path, FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	print("SMOKE_RESULT ", JSON.stringify(report))
	get_tree().call_deferred("quit", 0 if not checks.values().has(false) else 1)

func run_sweep():
	AudioServer.set_bus_volume_db(0, -35)
	var results := []
	var folder := sweep_path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(folder)
	audio.load_mp3("res://test-media/DemoBeat.mp3")
	for i in bus.scenes.size():
		select_scene(i)
		await get_tree().create_timer(0.6).timeout
		await RenderingServer.frame_post_draw
		var entry: Dictionary = bus.scenes[i]
		var filename := "%02d-%s-%s.png" % [i, entry.version, str(entry.name).validate_filename()]
		var result = runtime.summary()
		result.scene = entry
		result.screenshot = filename
		result.screenshot_saved = get_viewport().get_texture().get_image().save_png(folder + "/" + filename) == OK
		results.append(result)
	FileAccess.open(sweep_path, FileAccess.WRITE).store_string(JSON.stringify({"scenes": results, "actual_local_mp3": true, "original_scene_fidelity": false}, "\t"))
	print("SCENE_SWEEP_SAVED ", results.size())
	get_tree().call_deferred("quit")

func run_reference():
	AudioServer.set_bus_volume_db(0, -35)
	var folder := reference_path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(folder)
	var checks := {"tripletrance_objects": runtime.summary().loaded_objects == 10, "tripletrance_textures": runtime.summary().missing_resources.is_empty()}
	checks.actual_mp3_decoded = audio.load_mp3("res://test-media/DemoBeat.mp3")
	var samples := []
	for frame in 3:
		await get_tree().create_timer(2.0).timeout
		await RenderingServer.frame_post_draw
		var filename := "tripletrance-%02d.png" % frame
		var saved := get_viewport().get_texture().get_image().save_png(folder + "/" + filename) == OK
		samples.append({"time": player.get_playback_position(), "screenshot": filename, "saved": saved, "metrics": runtime.metrics.duplicate(true)})
	checks.actual_audio_drives_geometry = runtime.metrics.geometry_frames > 0 and audio.maximum_s > 0 and audio.captured_frames > 1024
	get_viewport().debug_draw = Viewport.DEBUG_DRAW_WIREFRAME
	await RenderingServer.frame_post_draw
	checks.wireframe_screenshot = get_viewport().get_texture().get_image().save_png(folder + "/tripletrance-wireframe.png") == OK
	get_viewport().debug_draw = Viewport.DEBUG_DRAW_DISABLED
	# The player is its own window now: capture it separately.
	await RenderingServer.frame_post_draw
	checks.controls_screenshot = controller != null and controller.get_texture().get_image().save_png(folder + "/tripletrance-controls.png") == OK
	var report := {"checks": checks, "frames": samples, "scene_summary": runtime.summary(), "original_visual_parity": false, "reference": "https://www.youtube.com/watch?v=zqd5DscKfkQ", "music": "Bundled synthetic DemoBeat MP3; different from reference recording, so elapsed poses are not compared"}
	FileAccess.open(reference_path, FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	print("REFERENCE_CHECK_RESULT ", JSON.stringify(report))
	get_tree().call_deferred("quit", 0 if not checks.values().has(false) else 1)

func run_flac_test():
	AudioServer.set_bus_volume_db(0, -35)
	var path := OS.get_environment("OOZIC_TEST_FLAC")
	var checks := {"missing_flac_rejected": not (await audio.load_audio("/tmp/oozic-missing-test.flac")), "flac_decoded": await audio.load_audio(path)}
	await get_tree().create_timer(1.2).timeout
	checks.playback_advanced = player.get_playback_position() > 0.5
	checks.audio_drives_scene = audio.maximum_s > 0 and audio.maximum_a > 0 and audio.captured_frames > 1024
	audio.toggle_play()
	checks.pause = player.stream_paused
	audio.toggle_play()
	audio.seek_to(0.5)
	await get_tree().create_timer(0.2).timeout
	checks.seek = player.get_playback_position() > 0.5
	audio.playlist = PackedStringArray([path, "res://test-media/DemoBeat.mp3"])
	checks.mixed_playlist_mp3 = (await audio.play_track(1)) and player.stream is AudioStreamMP3
	checks.mixed_playlist_flac = (await audio.play_track(0)) and player.stream is AudioStreamWAV
	audio.stop_play()
	checks.stop = not player.playing
	var report := {"checks":checks,"input":path,"format":"FLAC decoded by macOS Core Audio to stereo 16-bit PCM; no MP3 encoding"}
	FileAccess.open(flac_test_path, FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("FLAC_RESULT ",JSON.stringify(report))
	get_tree().call_deferred("quit",0 if not checks.values().has(false) else 1)
