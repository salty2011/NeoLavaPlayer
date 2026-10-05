extends RefCounted
## Key -> bus command map shared by both windows (pure; see test_windows_bus.gd).
## Ctrl and Cmd are interchangeable for the original player accelerators
## (LavaPlay/OZPlay3 ACCELERATORS: Ctrl+P/S/U/M/I/T/O/N/B, LavaPL: Ctrl+L/A/D,
## Shift+A add directory). Ctrl+I minimises the window the key was pressed in.

## Commands that act on key auto-repeat.
const REPEATABLE := [&"seek_relative", &"volume_step"]

## Keys the player always owns, even unmodified (never offered to the scene).
const PLAYER_KEYS := [KEY_SPACE, KEY_TAB, KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN, KEY_F3, KEY_F4, KEY_F9, KEY_F11, KEY_ESCAPE, KEY_PAGEUP, KEY_PAGEDOWN, KEY_DELETE, KEY_BACKSPACE]
## Shifted keys the scene runtime owns: the original F3 (flat shading) and F4
## (lights) moved to Shift+F3/Shift+F4 because plain F3/F4 are our debug keys
## (original_hotkeys.gd, docs/ENGINE_API.md).
const SCENE_SHIFT_KEYS := [KEY_F3, KEY_F4]

static func command_modifier(event: InputEventKey) -> bool:
	return event.ctrl_pressed or event.meta_pressed

## Keys offered to the scene runtime (OriginalHotkeys) before player hotkeys:
## unmodified non-player keys (T W S L C P M N F5-F8 ...) and Shift+F3/F4.
static func scene_may_claim(event: InputEventKey) -> bool:
	if command_modifier(event) or event.alt_pressed: return false
	if event.shift_pressed: return SCENE_SHIFT_KEYS.has(event.keycode)
	return not PLAYER_KEYS.has(event.keycode)

## Returns {name: StringName, args: Dictionary}; name is &"" when unmapped.
static func action_for(event: InputEventKey) -> Dictionary:
	var key := event.keycode
	var none := {"name": &"", "args": {}}
	if command_modifier(event) and not event.alt_pressed:
		if event.shift_pressed:
			match key:
				KEY_L: return _a(&"toggle_library")
				KEY_V: return _a(&"toggle_visualiser")
				KEY_R: return _a(&"reset_layout")
			return none
		match key:
			KEY_P: return _a(&"play_pause")
			KEY_U: return _a(&"pause")
			KEY_S: return _a(&"stop")
			KEY_M: return _a(&"toggle_mute")
			KEY_N: return _a(&"next")
			KEY_B: return _a(&"previous")
			KEY_O: return _a(&"cycle_repeat")
			KEY_R: return _a(&"toggle_shuffle")
			KEY_L: return _a(&"toggle_drawer")
			KEY_A: return _a(&"add_tracks")
			KEY_D: return _a(&"remove_track")
			KEY_T: return _a(&"open_settings")
			KEY_I: return _a(&"minimize")
			KEY_F: return _a(&"toggle_fullscreen")
			KEY_Q: return _a(&"quit_app")
		return none
	if event.alt_pressed: return none
	if event.shift_pressed:
		match key:
			KEY_A: return _a(&"add_directory")
			KEY_F9: return _a(&"toggle_render_mode", {"scope": "scene"})
		return none
	match key:
		KEY_SPACE: return _a(&"play_pause")
		KEY_LEFT: return _a(&"seek_relative", {"seconds": -5.0})
		KEY_RIGHT: return _a(&"seek_relative", {"seconds": 5.0})
		KEY_UP: return _a(&"volume_step", {"delta": 0.05})
		KEY_DOWN: return _a(&"volume_step", {"delta": -0.05})
		KEY_TAB: return _a(&"toggle_controller")
		KEY_F3: return _a(&"toggle_debug_overlay")
		KEY_F4: return _a(&"cycle_fps_cap")
		KEY_F9: return _a(&"toggle_render_mode", {"scope": "global"})
		KEY_F11: return _a(&"toggle_fullscreen")
		KEY_ESCAPE: return _a(&"escape")
		KEY_PAGEUP: return _a(&"previous_scene")
		KEY_PAGEDOWN: return _a(&"next_scene")
	return none

static func _a(name: StringName, args: Dictionary = {}) -> Dictionary:
	return {"name": name, "args": args}
