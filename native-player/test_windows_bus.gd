extends SceneTree
## Windowing and bus logic: hotkey map, key routing (scene claims first),
## window-rect clamping to connected screens, scene titles, cycling order,
## and the visualiser running with no control window. (The player UI has its
## own test: test_player_ui.gd.)
const Hotkeys = preload("res://hotkeys.gd")
const PlayerBusScript = preload("res://player_bus.gd")
const WindowLayout = preload("res://window_layout.gd")
const SceneCatalog = preload("res://scene_catalog.gd")
const SceneDirector = preload("res://scene_director.gd")
const Visualiser = preload("res://visualiser.gd")
const AppSettings = preload("res://app_settings.gd")

func _initialize(): call_deferred("run")

func key(code: Key, ctrl := false, shift := false, meta := false) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	event.ctrl_pressed = ctrl
	event.shift_pressed = shift
	event.meta_pressed = meta
	return event

func run():
	# --- Hotkey map (original accelerators + ours) ---
	var expected := {
		[KEY_SPACE, false, false]: &"play_pause", [KEY_P, true, false]: &"play_pause", [KEY_S, true, false]: &"stop",
		[KEY_U, true, false]: &"pause", [KEY_M, true, false]: &"toggle_mute", [KEY_N, true, false]: &"next",
		[KEY_B, true, false]: &"previous", [KEY_O, true, false]: &"cycle_repeat", [KEY_L, true, false]: &"toggle_drawer",
		[KEY_A, true, false]: &"add_tracks", [KEY_A, false, true]: &"add_directory", [KEY_D, true, false]: &"remove_track",
		[KEY_T, true, false]: &"open_settings", [KEY_I, true, false]: &"minimize", [KEY_F, true, false]: &"toggle_fullscreen",
		[KEY_F11, false, false]: &"toggle_fullscreen", [KEY_ESCAPE, false, false]: &"escape", [KEY_TAB, false, false]: &"toggle_controller",
		[KEY_F3, false, false]: &"toggle_debug_overlay", [KEY_F3, false, true]: &"", [KEY_F4, false, false]: &"cycle_fps_cap",
		[KEY_LEFT, false, false]: &"seek_relative", [KEY_UP, false, false]: &"volume_step", [KEY_PAGEDOWN, false, false]: &"next_scene",
		[KEY_T, false, false]: &"", [KEY_W, false, false]: &"",
		[KEY_L, true, true]: &"toggle_library", [KEY_V, true, true]: &"toggle_visualiser", [KEY_R, true, true]: &"reset_layout", [KEY_X, true, true]: &"",
	}
	for combo in expected:
		var result := Hotkeys.action_for(key(combo[0], combo[1], combo[2]))
		assert(result.name == expected[combo], "hotkey %s -> %s, expected %s" % [combo, result.name, expected[combo]])
	assert(Hotkeys.action_for(key(KEY_P, false, false, true)).name == &"play_pause") # Cmd works like Ctrl
	assert(Hotkeys.action_for(key(KEY_LEFT)).args.seconds == -5.0)
	assert(Hotkeys.scene_may_claim(key(KEY_T)) and Hotkeys.scene_may_claim(key(KEY_F5)) and Hotkeys.scene_may_claim(key(KEY_F3, false, true)) and Hotkeys.scene_may_claim(key(KEY_F4, false, true)))
	assert(not Hotkeys.scene_may_claim(key(KEY_SPACE)) and not Hotkeys.scene_may_claim(key(KEY_P, true)) and not Hotkeys.scene_may_claim(key(KEY_F3)) and not Hotkeys.scene_may_claim(key(KEY_A, false, true)))

	# --- Bus routing: commands carry their source; the scene may claim plain keys first ---
	var bus = PlayerBusScript.instance()
	assert(bus != null and PlayerBusScript.instance() == bus)
	var log := []
	bus.command_requested.connect(func(name, args): log.append([name, args.get("source", "")]))
	assert(bus.handle_key(key(KEY_SPACE), "controller") and log.back() == [&"play_pause", "controller"])
	assert(not bus.handle_key(key(KEY_T), "visualiser")) # unclaimed, unmapped
	var claimed := []
	bus.scene_key_handler = func(event): claimed.append(event.keycode); return event.keycode in [KEY_T, KEY_F3]
	log.clear()
	assert(bus.handle_key(key(KEY_T), "visualiser") and claimed == [KEY_T] and log.is_empty())
	assert(bus.handle_key(key(KEY_F3, false, true), "visualiser") and log.is_empty()) # Shift+F3: runtime flat shading
	assert(bus.handle_key(key(KEY_F3), "visualiser") and log.back()[0] == &"toggle_debug_overlay" and claimed.size() == 2) # plain F3 never offered
	assert(bus.handle_key(key(KEY_SPACE), "visualiser") and claimed.size() == 2) # player keys never offered
	var echo := key(KEY_SPACE)
	echo.echo = true
	log.clear()
	assert(bus.handle_key(echo) and log.is_empty()) # no auto-repeat play/pause
	echo.keycode = KEY_RIGHT
	assert(bus.handle_key(echo) and log.back()[0] == &"seek_relative") # seeking repeats
	bus.scene_key_handler = Callable()

	# --- Window clamping to connected screens ---
	var screens := [Rect2i(0, 25, 1512, 920), Rect2i(1512, -200, 2560, 1415)]
	var kept := WindowLayout.clamp_rect(Rect2i(1700, 100, 1200, 760), 1, screens)
	assert(kept.screen == 1 and kept.rect == Rect2i(1700, 100, 1200, 760) and not kept.moved)
	var gone := WindowLayout.clamp_rect(Rect2i(4200, 300, 1200, 760), 2, screens) # saved on a third monitor
	assert(gone.moved and gone.screen == 0 and Rect2i(screens[0]).encloses(gone.rect))
	var unplugged := WindowLayout.clamp_rect(Rect2i(1700, 100, 1200, 760), 1, [screens[0]]) # second monitor removed
	assert(unplugged.moved and unplugged.screen == 0 and Rect2i(screens[0]).encloses(unplugged.rect) and unplugged.rect.size == Vector2i(1200, 760))
	var straddle := WindowLayout.clamp_rect(Rect2i(1400, 600, 421, 148), 0, screens)
	assert(straddle.screen == 0 and Rect2i(screens[0]).encloses(straddle.rect))
	var huge := WindowLayout.clamp_rect(Rect2i(0, 0, 5000, 3000), 0, screens)
	assert(huge.rect.size.x <= 1512 and huge.rect.size.y <= 920)
	assert(WindowLayout.from_array(WindowLayout.to_array(Rect2i(1, 2, 3, 4))) == Rect2i(1, 2, 3, 4))

	# --- Settings sections merge instead of clobbering ---
	var cfg := OS.get_temp_dir().path_join("oozic-test-windows.cfg")
	DirAccess.remove_absolute(cfg)
	WindowLayout.save_state({"controller_rect": [1, 2, 3, 4]}, cfg)
	var settings := AppSettings.new()
	settings.path = cfg
	settings.vsync = false
	settings.save_settings()
	assert(WindowLayout.load_state(cfg).controller_rect == [1, 2, 3, 4] and AppSettings.load_section(cfg, "display").vsync == false)
	DirAccess.remove_absolute(cfg)

	# --- Scene titles from the ASHEX message line ---
	assert(SceneCatalog.read_title("res://scenes/lava25/LVT2", "LVT2") == "Dancing Well")
	assert(SceneCatalog.read_title("res://scenes/lava25/LVT3", "LVT3") == "Triple Trance")
	assert(SceneCatalog.read_title("res://scenes/lava25/Hydroid", "Hydroid") == "HYDROID")
	assert(SceneCatalog.read_title("res://scenes/oozic30/AK1200", "AK1200") == "AK1200")
	assert(SceneCatalog.clean_title("Gus Gus                                    Polyesterday") == "Gus Gus · Polyesterday")
	var catalog := SceneCatalog.load_catalog()
	assert(catalog.size() == 29 and catalog[0].title == "Triple Trance")

	# --- Cycling order and timer ---
	var list := [{"title": "Cyber Circus"}, {"title": "Ancient Egypt"}, {"title": "Liquid Light"}]
	var rng := RandomNumberGenerator.new()
	assert(SceneDirector.step_index(1, list, "alphabetical", 1, rng) == 0)
	assert(SceneDirector.step_index(2, list, "alphabetical", 1, rng) == 1) # wraps
	assert(SceneDirector.step_index(1, list, "alphabetical", -1, rng) == 2)
	for i in 50: assert(SceneDirector.step_index(1, list, "random", 1, rng) != 1)
	assert(SceneDirector.normalise_cycling({"interval": 100, "order": "x"}) == {"enabled": false, "interval": 120, "order": "random", "per_track": false, "mode": "time", "musical": true, "transition": "crossfade", "transition_seconds": 2.0})
	var director = SceneDirector.new(false)
	root.add_child(director)
	await process_frame
	director.select(0)
	director.set_cycling({"enabled": true, "interval": 30, "order": "alphabetical"})
	assert(not director.tick(29.0) and director.current == 0)
	assert(director.tick(1.5) and director.current != 0 and bus.scene_index == director.current)
	var before: int = director.current
	director.set_cycling({"per_track": true})
	bus.publish_transport("playing") # a restored playlist announcing its track while stopped is not a new track
	bus.publish_track(3, "Some track")
	assert(director.current != before)
	director.set_cycling({"enabled": false})
	assert(not director.tick(4000.0))

	# --- Visualiser with no control window (scene-only), mock input ---
	var visualiser = Visualiser.new()
	root.add_child(visualiser)
	await process_frame
	bus.controller_present = false
	visualiser.set_analysis_source("mock", false)
	director.select(0)
	assert(visualiser.scene_loaded == 0 and visualiser.runtime.summary().loaded_objects == 10)
	var ticks: int = visualiser.runtime.metrics.get("ticks", 0)
	for frame in 30: visualiser._process(1.0 / 60.0)
	assert(visualiser.runtime.metrics.ticks >= ticks + 29 and bus.last_analysis.has("section"))
	visualiser._input(InputEventMouseMotion.new())
	assert(not visualiser.hint_button.visible) # no controller to reveal
	assert(bus.scene_info.presets.size() >= 1 and bus.scene_info.has("tuning_supported"))

	print("PASS: hotkey map, Cmd=Ctrl, bus routing with source, scene-first key claims (T, Shift+F3), F3 overlay, echo filtering, rect clamping (kept, missing monitor, unplugged, straddling, oversized), settings section merge, scene titles, alphabetical/random cycling, cycle timer + per-track, scene-only visualiser on mock input")
	visualiser.queue_free()
	director.queue_free()
	await create_timer(0.2).timeout
	quit()
