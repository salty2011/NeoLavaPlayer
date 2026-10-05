extends Control
## F3 debug overlay: frame pacing, render settings, analysis source and live inputs.
## Owner calls record(delta, info) each frame; info keys: scene, fps_cap, vsync,
## source, band_a, global_s, beat, ticks, sim_rate, and optionally react
## (ReactivityService.debug_info(): source, bands, beat, downbeat, bpm,
## confidence, section, build_progress, time_to_drop, intensity, channels).
const WINDOW := 1.0
const REACT_BANDS := ["sub", "bass", "lmid", "mid", "pres", "high"]
const REACT_CHANNELS := ["pulse", "accent", "impact", "anticipation", "swell", "calm", "sparkle"]
const LINE := 17.0
var info: Dictionary = {}
var _samples: Array[Vector2] = [] # (timestamp, frame seconds)
var _clock := 0.0
var _min_ms := 0.0
var _max_ms := 0.0
var _frame_ms := 0.0
var _beat_flash := 0.0
var _react_beat := 0.0
var _react_downbeat := 0.0

func _init():
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	position = Vector2(16, 16)
	size = Vector2(320, 220)
	visible = false

func record(delta: float, values: Dictionary) -> void:
	info = values
	_clock += delta
	_frame_ms = delta * 1000.0
	_samples.append(Vector2(_clock, delta))
	while not _samples.is_empty() and _samples[0].x < _clock - WINDOW: _samples.pop_front()
	_min_ms = INF
	_max_ms = 0.0
	for sample in _samples:
		_min_ms = minf(_min_ms, sample.y * 1000.0)
		_max_ms = maxf(_max_ms, sample.y * 1000.0)
	if bool(values.get("beat", false)): _beat_flash = 0.12
	_beat_flash = maxf(0.0, _beat_flash - delta)
	var react: Dictionary = values.get("react", {})
	if bool(react.get("beat", false)): _react_beat = 0.12
	if bool(react.get("downbeat", false)): _react_downbeat = 0.25
	_react_beat = maxf(0.0, _react_beat - delta)
	_react_downbeat = maxf(0.0, _react_downbeat - delta)
	if visible: queue_redraw()

func lines() -> PackedStringArray:
	var bands: Array = Array(info.get("band_a", []))
	var out := _base_lines(bands)
	var music := music_line()
	if not music.is_empty(): out.insert(out.size() - 1, music)
	return out

## Apple Music line ("music: <state> · tap <backend> pid <n> · level <dB> ·
## <health>"): info.music if the owner supplies it, else asked from the
## AudioService node (found once by name; the overlay owner stays unchanged).
func music_line() -> String:
	if info.has("music"): return str(info.music)
	var audio = _audio_ref.get_ref() if _audio_ref != null else null
	if audio == null and is_inside_tree() and Engine.get_process_frames() >= _next_lookup:
		_next_lookup = Engine.get_process_frames() + 60
		audio = get_tree().root.find_child("AudioService", true, false)
		if audio != null: _audio_ref = weakref(audio)
	return str(audio.music_debug_line()) if audio != null and audio.has_method("music_debug_line") else ""

var _audio_ref: WeakRef
var _next_lookup := 0

func _base_lines(bands: Array) -> PackedStringArray:
	return PackedStringArray([
		"FPS %d   frame %.2f ms" % [Engine.get_frames_per_second(), _frame_ms],
		"last 1 s: min %.2f  max %.2f ms" % [_min_ms if _min_ms != INF else 0.0, _max_ms],
		"scene: %s" % str(info.get("scene", "")),
		"fps cap: %s   vsync: %s" % [str(info.get("fps_cap", "")), "on" if bool(info.get("vsync", false)) else "off"],
		("sim: %d Hz fixed, %d ticks" % [int(info.get("sim_rate", 60)), int(info.get("ticks", 0))]) if info.get("timing", "fixed") == "fixed" else "sim: per-frame dt (<=100 ms), %d updates" % int(info.get("ticks", 0)),
		"analysis: %s" % str(info.get("source", "real")),
		"render: %s   (F9 / Shift+F9 scene)" % str(info.get("render", "Classic")),
		"global_s %.3f   beat %s" % [float(info.get("global_s", 0.0)), "●" if _beat_flash > 0 else "○"],
		"bands (%d):" % bands.size(),
	])

## Text lines of the ReactFrame section (empty without react info).
func react_lines() -> PackedStringArray:
	var r: Dictionary = info.get("react", {})
	if r.is_empty(): return PackedStringArray()
	var ttd := float(r.get("time_to_drop", INF))
	var source := str(r.get("source", ""))
	if not str(r.get("analysing", "")).is_empty(): source += "  (analysing %s)" % str(r.analysing)
	if bool(r.get("blending", false)): source += "  blending"
	return PackedStringArray([
		"reactivity: %s" % source,
		"BPM %.1f  conf %.2f   beat %s  bar %s" % [float(r.get("bpm", 0.0)), float(r.get("confidence", 0.0)), "●" if _react_beat > 0 else "○", "●" if _react_downbeat > 0 else "○"],
		"section %s   tier %s   energy %.2f" % [str(r.get("section", "")), str(r.get("intensity", "")), float(r.get("energy", 0.0))],
		"build %.2f   drop in %s" % [float(r.get("build_progress", 0.0)), ("%.1f s" % ttd) if is_finite(ttd) else "-"],
	])

func _draw():
	var font := get_theme_default_font()
	var text := lines()
	var bands: Array = Array(info.get("band_a", []))
	var react: Dictionary = info.get("react", {})
	var rtext := react_lines()
	var height := 14.0 + text.size() * LINE + 46.0
	if not rtext.is_empty(): height += rtext.size() * LINE + 52.0 + 14.0 + REACT_CHANNELS.size() * 10.0 + 8.0
	draw_rect(Rect2(Vector2.ZERO, Vector2(size.x, height)), Color(0, 0, 0, 0.72))
	for i in text.size():
		draw_string(font, Vector2(10, 20 + i * LINE), text[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.85, 0.95, 1.0))
	var top := 14.0 + text.size() * LINE
	_bars(top, bands, 36.0)
	if rtext.is_empty(): return
	top += 46.0
	for i in rtext.size():
		draw_string(font, Vector2(10, top + 6 + i * LINE), rtext[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1.0, 0.92, 0.75))
	top += rtext.size() * LINE
	var rb: Array = Array(react.get("bands", []))
	_bars(top, rb, 30.0, REACT_BANDS)
	top += 52.0
	var channels: Dictionary = react.get("channels", {})
	for i in REACT_CHANNELS.size():
		var y := top + i * 10.0
		var value := clampf(float(channels.get(REACT_CHANNELS[i], 0.0)), 0.0, 1.0)
		draw_string(font, Vector2(10, y + 8), REACT_CHANNELS[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0.8, 0.8, 0.8))
		draw_rect(Rect2(96, y + 1, size.x - 106, 7), Color(1, 1, 1, 0.12))
		draw_rect(Rect2(96, y + 1, (size.x - 106) * value, 7), Color(1.0, 0.7, 0.3))

func _bars(top: float, values: Array, bar_height: float, labels: Array = []):
	var width := (size.x - 20.0) / maxf(values.size(), 1)
	var font := get_theme_default_font()
	for b in values.size():
		var value := clampf(float(values[b]), 0.0, 1.0)
		var rect := Rect2(10 + b * width + 2, top, width - 4, bar_height)
		draw_rect(rect, Color(1, 1, 1, 0.12))
		draw_rect(Rect2(rect.position.x, rect.end.y - rect.size.y * value, rect.size.x, rect.size.y * value), Color(0.35, 0.8, 1.0) if value < 1.0 else Color(1.0, 0.55, 0.3))
		if b < labels.size(): draw_string(font, Vector2(rect.position.x, rect.end.y + 11), labels[b], HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0.8, 0.8, 0.8))
