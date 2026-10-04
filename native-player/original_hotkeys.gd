extends RefCounted
## Original visualiser hotkeys (LAVA.exe key handler 0x40e75c, jump tables
## 0x40e8f4/0x40e934), mapped onto the SceneRuntime engine API.
##   T 0x01 texture, W 0x02 wireframe, S 0x04 strobe, L 0x08 coloured lighting,
##   C 0x10 dynamic colouring, P 0x40 pause camera, M 3D text, N intro,
##   F5-F8 special-effect preset categories 0-3.
## Remapped because the player already uses the original key:
##   F3 (0x80 flat shading) -> Shift+F3 (F3 = debug overlay)
##   F4 (0x20 lights)       -> Shift+F4 (F4 = debug FPS cap)
##   F11 (0x100)            -> none (F11 = fullscreen; no engine consumer found)
## The original beeps on other letters; we ignore them.
const StyleFlags = preload("res://style_flags.gd")
const FLAG_KEYS := {KEY_T: StyleFlags.TEXTURE, KEY_W: StyleFlags.WIREFRAME, KEY_S: StyleFlags.STROBE, KEY_L: StyleFlags.COLORED_LIGHTING, KEY_C: StyleFlags.DYNAMIC_COLORING, KEY_P: StyleFlags.PAUSE_CAMERA}
const SHIFT_FLAG_KEYS := {KEY_F3: StyleFlags.FLAT_SHADING, KEY_F4: StyleFlags.LIGHTS}
const PRESET_KEYS := {KEY_F5: 0, KEY_F6: 1, KEY_F7: 2, KEY_F8: 3}

## Returns a short status text when the key was handled, "" otherwise.
static func handle(runtime, event: InputEventKey) -> String:
	if runtime == null or not event.pressed or event.echo: return ""
	if event.ctrl_pressed or event.meta_pressed or event.alt_pressed: return ""
	var key := event.keycode
	if event.shift_pressed:
		if SHIFT_FLAG_KEYS.has(key): return _flag(runtime, SHIFT_FLAG_KEYS[key])
		return ""
	if FLAG_KEYS.has(key): return _flag(runtime, FLAG_KEYS[key])
	if PRESET_KEYS.has(key):
		var result: Dictionary = runtime.trigger_effect_preset(PRESET_KEYS[key])
		return "Special effect %s: %s" % [result.category, result.preset] if not result.is_empty() else "No special-effect category %d in this scene" % (PRESET_KEYS[key] + 1)
	match key:
		KEY_M: return "3D text " + ("on" if runtime.toggle_text_message() else "off")
		KEY_N: return "Intro screen" if runtime.show_intro() else "This scene has no intro screen"
	return ""

static func _flag(runtime, flag: int) -> String:
	var on: bool = runtime.toggle_style_flag(flag)
	return "%s %s" % [StyleFlags.NAMES[flag], "on" if on else "off"]
