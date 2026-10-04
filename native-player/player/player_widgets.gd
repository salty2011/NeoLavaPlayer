extends RefCounted
## Procedurally drawn widgets for the player window. All sizes are base
## units; the window's content scale makes them crisp at any size.
## Widgets report intent through signals; panels turn it into bus commands.
const Style = preload("res://player/player_style.gd")
const Fmt = preload("res://player/player_format.gd")

## Push button with a glyph or a short label. `toggle` buttons show an LED
## (active = lit). `command`/`args` is the bus command the panel sends.
class PlayerButton extends Control:
	signal activated(button)
	var id: StringName
	var command: StringName
	var args: Dictionary = {}
	var glyph := ""
	var label := ""
	var label_size := 6
	var toggle := false
	var flat := false
	var active := false:
		set(value):
			if active == value: return
			active = value
			queue_redraw()
	var enabled := true:
		set(value):
			if enabled == value: return
			enabled = value
			if not value: _down = false
			queue_redraw()
	var _hover := false
	var _down := false

	func _init():
		mouse_filter = Control.MOUSE_FILTER_STOP
		focus_mode = Control.FOCUS_NONE
		mouse_entered.connect(func(): _hover = true; queue_redraw())
		mouse_exited.connect(func(): _hover = false; _down = false; queue_redraw())

	func state() -> int:
		if _down: return 2
		if _hover and enabled: return 1
		return 0

	func _draw():
		var rect := Rect2(Vector2.ZERO, size)
		if flat:
			if state() > 0: draw_rect(rect, Color(1, 1, 1, 0.08 if state() == 1 else 0.16))
		else:
			Style.button_face(self, rect, state())
		var color := Style.GLYPH if enabled else Style.GLYPH_DIM
		var offset := Vector2(0, 0.5) if state() == 2 else Vector2.ZERO
		if toggle:
			var led := Rect2(Vector2(2.2, size.y * 0.5 - 1.1) + offset, Vector2(2.2, 2.2))
			draw_rect(led, Style.LED_ON if active else Style.LED_OFF)
			if active: draw_rect(led.grow(0.6), Color(Style.LED_ON, 0.25))
		if not glyph.is_empty():
			var u := minf(size.x, size.y) / 11.0
			if flat: u = minf(size.x, size.y) / 9.0
			Style.glyph(self, glyph, size * 0.5 + offset, u, color)
		if not label.is_empty():
			var text_rect := Rect2(Vector2(5.0 if toggle else 0.0, 0) + offset, Vector2(size.x - (5.0 if toggle else 0.0), size.y))
			Style.text(self, Style.bold_font(), text_rect, label, label_size, color if (active or not toggle) else Color(color, 0.75), HORIZONTAL_ALIGNMENT_CENTER)

	func _gui_input(event):
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed and enabled: _down = true
			elif not event.pressed and _down:
				_down = false
				if Rect2(Vector2.ZERO, size).has_point(event.position): activated.emit(self)
			queue_redraw()
			accept_event()

	## Test hook: a full click at the centre.
	func click():
		_gui_input(_mouse(true))
		_gui_input(_mouse(false))

	func _mouse(pressed: bool) -> InputEventMouseButton:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = pressed
		e.position = size * 0.5
		return e

## Horizontal slider: a recessed track with an amber fill and a steel thumb.
## live sliders (volume) report while dragging; others (seek) on release.
class PlayerSlider extends Control:
	signal changed(value: float)
	var id: StringName
	var value := 0.0
	var live := false
	var enabled := true:
		set(v):
			enabled = v
			if not v: dragging = false
			queue_redraw()
	var dim := false:
		set(v):
			dim = v
			queue_redraw()
	var dragging := false
	var thumb_width := 7.0
	var _hover := false

	func _init():
		mouse_filter = Control.MOUSE_FILTER_STOP
		focus_mode = Control.FOCUS_NONE
		mouse_entered.connect(func(): _hover = true; queue_redraw())
		mouse_exited.connect(func(): _hover = false; queue_redraw())

	func set_value(fraction: float):
		value = clampf(fraction, 0.0, 1.0)
		queue_redraw()

	func fraction_at(x: float) -> float:
		var usable := maxf(size.x - thumb_width, 1.0)
		return clampf((x - thumb_width * 0.5) / usable, 0.0, 1.0)

	func thumb_rect() -> Rect2:
		var x := (size.x - thumb_width) * value
		return Rect2(Vector2(x, 0), Vector2(thumb_width, size.y))

	func _draw():
		var track := Rect2(Vector2(0, size.y * 0.5 - 1.6), Vector2(size.x, 3.2))
		draw_rect(track, Style.TRACK_BG)
		Style.sunken(self, track)
		if enabled:
			var fill_end := thumb_rect().get_center().x
			if fill_end > 0.5:
				var fill := Rect2(track.position + Vector2(0.4, 0.5), Vector2(fill_end - 0.4, track.size.y - 1.0))
				Style.vgradient(self, fill, Style.FILL_DIM if dim else Style.FILL, (Style.FILL_DIM if dim else Style.FILL).darkened(0.35))
			var thumb := thumb_rect().grow_individual(0, -0.5, 0, -0.5)
			var top := Style.THUMB_TOP.lightened(0.15) if (_hover or dragging) else Style.THUMB_TOP
			Style.vgradient(self, thumb, top, Style.THUMB_BOTTOM)
			draw_rect(thumb, Style.EDGE, false, 0.5)
			var c := thumb.get_center()
			for dx in [-1.2, 0.0, 1.2]:
				Style.vline(self, c.x + dx, c.y - 1.6, c.y + 1.6, Color(0, 0, 0, 0.45), 0.4)

	func _gui_input(event):
		if not enabled: return
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			dragging = event.pressed
			set_value(fraction_at(event.position.x))
			if live or not event.pressed: changed.emit(value)
			accept_event()
		elif event is InputEventMouseMotion and dragging:
			set_value(fraction_at(event.position.x))
			if live: changed.emit(value)
			accept_event()
		elif event is InputEventMouseButton and event.pressed and live and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			set_value(value + (0.05 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -0.05))
			changed.emit(value)
			accept_event()

	## Test hook: press and release at a fraction of the track.
	func click_at(fraction: float):
		for pressed in [true, false]:
			var e := InputEventMouseButton.new()
			e.button_index = MOUSE_BUTTON_LEFT
			e.pressed = pressed
			e.position = Vector2(thumb_width * 0.5 + fraction * (size.x - thumb_width), size.y * 0.5)
			_gui_input(e)

## Big seven-segment time with a transport glyph. Click toggles elapsed /
## remaining. Paused time blinks.
class TimeDisplay extends Control:
	signal toggled(remaining: bool)
	var remaining := false
	var transport := "stopped"
	var position_s := 0.0
	var duration_s := 0.0
	var _blink := 0.0

	func _init():
		mouse_filter = Control.MOUSE_FILTER_STOP
		tooltip_text = "Click: elapsed / remaining time"

	func text_value() -> String:
		var seconds := position_s
		if remaining and duration_s > 0.0: seconds = maxf(duration_s - position_s, 0.0)
		var total := mini(int(seconds), 99 * 60 + 59)
		return "%s%02d:%02d" % ["-" if remaining else " ", total / 60, total % 60]

	func _process(delta):
		if transport == "paused":
			_blink = fmod(_blink + delta, 1.0)
			queue_redraw()

	func _draw():
		var glyph_name: String = {"playing": "play", "paused": "pause", "loading": "play"}.get(transport, "stop")
		var color := Style.LCD_TEXT if transport != "stopped" else Style.LCD_DIM
		Style.glyph(self, glyph_name, Vector2(4.0, 5.0), 0.85, color)
		if transport == "loading":
			Style.text(self, Style.mono_font(), Rect2(0, 9, 10, 5), "LD", 4, Style.LCD_DIM)
		var h := size.y - 1.0
		var value := text_value()
		var show := not (transport == "paused" and _blink > 0.5)
		var lit := Style.LCD_TEXT if transport != "stopped" else Style.LCD_DIM
		Style.segment_text(self, Vector2(size.x - Style.segment_width(value, h), 0.5), value, h, lit if show else Style.LCD_GHOST, Style.LCD_GHOST)

	func _gui_input(event):
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			remaining = not remaining
			toggled.emit(remaining)
			queue_redraw()
			accept_event()

## Small spectrum / oscilloscope fed by PlayerBus analysis frames (band_a,
## global_s). Click cycles spectrum -> scope -> off.
class VisDisplay extends Control:
	const MODES := ["spectrum", "scope", "off"]
	const BARS := 19
	var mode := "spectrum"
	var levels := PackedFloat32Array()
	var peaks := PackedFloat32Array()
	var source := PackedFloat32Array()
	var energy := 0.0
	var _age := 10.0
	var _clock := 0.0

	func _init():
		mouse_filter = Control.MOUSE_FILTER_STOP
		tooltip_text = "Click: spectrum / scope / off"
		levels.resize(BARS)
		peaks.resize(BARS)

	func feed(signals: Dictionary):
		var bands = signals.get("band_a", PackedFloat32Array())
		var extra = signals.get("bands", null)
		if extra != null and extra.size() > bands.size(): bands = extra
		source = PackedFloat32Array(bands)
		energy = clampf(float(signals.get("global_s", signals.get("energy", 0.0))), 0.0, 1.0)
		_age = 0.0

	## Bar target 0..1 for bar i: bands spread across the bars (low left),
	## shaped so neighbours differ, scaled by overall level.
	func target(i: int) -> float:
		if source.is_empty() or _age > 0.35: return 0.0
		var p := float(i) / float(BARS - 1) * float(source.size() - 1)
		var a := int(floor(p))
		var b := mini(a + 1, source.size() - 1)
		var v := sqrt(clampf(lerpf(source[a], source[b], p - a), 0.0, 1.0))
		var wobble := 0.72 + 0.28 * sin(_clock * (4.0 + 1.3 * (i % 4)) + float(i) * 0.9)
		# Gentle high-frequency roll-off, like a real spectrum.
		var tilt := 1.0 - 0.25 * float(i) / float(BARS - 1)
		return clampf(v * wobble * tilt * (0.8 + 0.5 * energy), 0.0, 1.0)

	func _process(delta):
		_clock += delta
		_age += delta
		for i in BARS:
			var t := target(i)
			levels[i] = t if t > levels[i] else maxf(levels[i] - delta * 2.4, t)
			peaks[i] = levels[i] if levels[i] > peaks[i] else maxf(peaks[i] - delta * 0.5, 0.0)
		queue_redraw()

	func _draw():
		match mode:
			"spectrum": _draw_spectrum()
			"scope": _draw_scope()
			_: Style.text(self, Style.mono_font(), Rect2(Vector2.ZERO, size), "VIS OFF", 5, Style.LCD_GHOST.lightened(0.3), HORIZONTAL_ALIGNMENT_CENTER)

	func _draw_spectrum():
		var gap := 1.2
		var w := (size.x - gap * (BARS - 1)) / BARS
		for i in BARS:
			var x := i * (w + gap)
			draw_rect(Rect2(x, size.y - 0.6, w, 0.6), Style.LCD_GHOST)
			var h := levels[i] * size.y
			if h > 0.3:
				var top := Style.LCD_ACCENT.lerp(Color("#ff3b12"), levels[i])
				Style.vgradient(self, Rect2(x, size.y - h, w, h), top, Style.LCD_TEXT.darkened(0.15))
			var py := size.y - peaks[i] * size.y
			if peaks[i] > 0.02: draw_rect(Rect2(x, maxf(py - 0.7, 0.0), w, 0.7), Style.LCD_TEXT)

	func _draw_scope():
		var mid := size.y * 0.5
		Style.hline(self, 0, size.x, mid, Style.LCD_GHOST, 0.4)
		var points := PackedVector2Array()
		var n := int(size.x * 1.5)
		var amps := [0.0, 0.0, 0.0]
		for k in 3: amps[k] = levels[k * (BARS - 1) / 2] if _age < 0.35 else 0.0
		for j in n + 1:
			var x := float(j) / n
			var y: float = amps[0] * sin(TAU * (1.5 * x) + _clock * 3.0) * 0.55 + amps[1] * sin(TAU * (5.0 * x) - _clock * 7.0) * 0.3 + amps[2] * sin(TAU * (13.0 * x) + _clock * 11.0) * 0.18
			points.append(Vector2(x * size.x, mid - y * (size.y * 0.48)))
		draw_polyline(points, Style.LCD_TEXT, 0.6, true)

	func _gui_input(event):
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			mode = MODES[(MODES.find(mode) + 1) % MODES.size()]
			queue_redraw()
			accept_event()

## A line of LCD text that scrolls when it does not fit.
class Marquee extends Control:
	var value := "":
		set(v):
			if v == value: return
			value = v
			offset = 0.0
			queue_redraw()
	var font_size := 7
	var color := Style.LCD_TEXT
	var offset := 0.0
	var speed := 14.0
	var _hold := 1.5

	func _init():
		mouse_filter = Control.MOUSE_FILTER_PASS
		clip_contents = true

	func text_width() -> float:
		return Style.ui_font().get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x

	func _process(delta):
		if text_width() <= size.x:
			offset = 0.0
			return
		if _hold > 0.0:
			_hold -= delta
			return
		var loop := text_width() + 24.0
		offset += delta * speed
		if offset >= loop:
			offset = 0.0
			_hold = 1.5
		queue_redraw()

	func _draw():
		var w := text_width()
		var rect := Rect2(Vector2(-offset, 0), Vector2(w + 2.0, size.y))
		Style.text(self, Style.ui_font(), rect, value, font_size, color)
		if w > size.x:
			Style.text(self, Style.ui_font(), Rect2(rect.position + Vector2(w + 24.0, 0), rect.size), value, font_size, color)
			Style.text(self, Style.ui_font(), Rect2(Vector2(w + 8.0 - offset, 0), Vector2(12, size.y)), "•", font_size, Style.LCD_DIM)
