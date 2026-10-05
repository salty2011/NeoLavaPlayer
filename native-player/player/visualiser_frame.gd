extends CanvasLayer
## Themed frame around the visualiser while it is a docked panel of the
## player (the root window is borderless then). Drawn as a 2D layer over the
## 3D view in the same window, in the player's base units at the player's
## ui_scale (PlayerBus.player_scale), with the player's palette, bevels and
## grooves (player_style.gd). The 3D view keeps rendering the whole window;
## the frame is opaque and covers the border, so what shows is exactly
## inner_rect(). Top and bottom bars have the same height and the sides the
## same width, so the camera's centre stays the centre of the picture.
##
## Talks only through PlayerBus: the title strip and bottom bar start a drag
## (begin_panel_drag), the edges and grip resize (resize_panel), the buttons
## send toggle_fullscreen / minimize / hide_visualiser / previous_scene /
## next_scene. Hidden in fullscreen (the visualiser goes frameless).
const Style = preload("res://player/player_style.gd")
const Widgets = preload("res://player/player_widgets.gd")
const PlayerBusScript = preload("res://player_bus.gd")

## Frame thickness in base units.
const TOP := 14.0
const BOTTOM := 14.0
const SIDE := 4.0

var bus
var chrome: Chrome

func _init():
	name = "VisualiserFrame"
	layer = 80

func _ready():
	bus = PlayerBusScript.instance()
	chrome = Chrome.new()
	chrome.frame = self
	add_child(chrome)
	bus.player_scale_changed.connect(func(_s): rescale())
	bus.scene_changed.connect(func(_i): chrome.queue_redraw())
	bus.scene_list_changed.connect(chrome.queue_redraw)
	get_viewport().size_changed.connect(rescale)
	rescale()

## Canvas units per screen pixel of the root viewport (its stretch).
func _canvas_per_pixel() -> float:
	var vp := get_viewport()
	var t: Transform2D = vp.get_final_transform() if vp is Window else Transform2D.IDENTITY
	return 1.0 / maxf(t.x.x, 0.0001)

## Canvas units per base unit.
func unit() -> float:
	return float(bus.player_scale) * _canvas_per_pixel() if bus != null else 1.0

func rescale():
	if chrome == null: return
	var u := unit()
	var visible_rect := get_viewport().get_visible_rect()
	# Minimised or mid-transition the window can report a zero size: keep the
	# last layout until it has a real one again.
	var units := visible_rect.size / u if u > 0.0 else Vector2.ZERO
	if not units.is_finite() or units.x < 1.0 or units.y < 1.0 or not visible_rect.position.is_finite(): return
	chrome.scale = Vector2(u, u)
	chrome.position = visible_rect.position
	chrome.size = units
	chrome.layout()

## Inner (3D) area in window pixels for a window of `pixels` at `ui_scale`.
static func inner_rect(pixels: Vector2, ui_scale: float) -> Rect2:
	var side := SIDE * ui_scale
	return Rect2(Vector2(side, TOP * ui_scale), Vector2(pixels.x - 2.0 * side, pixels.y - (TOP + BOTTOM) * ui_scale))

## Offset (canvas units) that moves a full-window overlay inside the frame.
func inner_offset() -> Vector2:
	return Vector2(SIDE, TOP) * unit() if visible else Vector2.ZERO

## Double-clicks on buttons and handles are theirs, not fullscreen toggles.
func owns_point(canvas_position: Vector2) -> bool:
	if not visible or chrome == null: return false
	var p := (canvas_position - chrome.position) / chrome.scale
	for c in chrome.interactive_controls():
		if Rect2(c.position, c.size).has_point(p): return true
	return false

## The frame itself: strips, borders, buttons and resize handles in base units.
class Chrome extends Control:
	var frame
	var buttons := {}
	var title_strip: DragArea
	var bottom_bar: DragArea
	var right_edge: Handle
	var bottom_edge: Handle
	var grip: Handle
	## id: [command, args, glyph, tooltip]
	const BUTTONS := {
		&"minimize": [&"minimize", {"source": "visualiser"}, "minimize", "Minimise the visualiser (Ctrl+I)"],
		&"fullscreen": [&"toggle_fullscreen", {}, "fullscreen", "Fullscreen (F11, double-click)"],
		&"close": [&"hide_visualiser", {}, "close", "Close the visualiser (VIS shows it again)"],
		&"previous_scene": [&"previous_scene", {}, "back", "Previous scene (Page Up)"],
		&"next_scene": [&"next_scene", {}, "forward", "Next scene (Page Down)"],
	}

	func _init():
		name = "Chrome"
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		title_strip = DragArea.new()
		title_strip.name = "TitleStrip"
		add_child(title_strip)
		bottom_bar = DragArea.new()
		bottom_bar.name = "BottomBar"
		add_child(bottom_bar)
		for id in BUTTONS:
			var spec: Array = BUTTONS[id]
			var b := Widgets.PlayerButton.new()
			b.name = str(id)
			b.id = id
			b.command = spec[0]
			b.args = spec[1]
			b.glyph = spec[2]
			b.flat = true
			b.tooltip_text = spec[3]
			b.activated.connect(func(button): PlayerBusScript.instance().command(button.command, button.args))
			add_child(b)
			buttons[id] = b
		right_edge = Handle.new(Vector2(1, 0), Control.CURSOR_HSIZE)
		right_edge.name = "RightEdge"
		add_child(right_edge)
		bottom_edge = Handle.new(Vector2(0, 1), Control.CURSOR_VSIZE)
		bottom_edge.name = "BottomEdge"
		add_child(bottom_edge)
		grip = Handle.new(Vector2.ONE, Control.CURSOR_FDIAGSIZE)
		grip.name = "Grip"
		grip.draw_grip = true
		grip.tooltip_text = "Drag to resize the visualiser"
		add_child(grip)

	func layout():
		var w := size.x
		var h := size.y
		title_strip.position = Vector2.ZERO
		title_strip.size = Vector2(w, TOP)
		bottom_bar.position = Vector2(0, h - BOTTOM)
		bottom_bar.size = Vector2(w, BOTTOM)
		_place(&"close", Rect2(w - 16, 2, 12, 10))
		_place(&"fullscreen", Rect2(w - 29, 2, 12, 10))
		_place(&"minimize", Rect2(w - 42, 2, 12, 10))
		_place(&"previous_scene", Rect2(SIDE + 2, h - BOTTOM + 2, 12, 10))
		_place(&"next_scene", Rect2(SIDE + 15, h - BOTTOM + 2, 12, 10))
		grip.position = Vector2(w - 14, h - 13)
		grip.size = Vector2(12, 12)
		right_edge.position = Vector2(w - SIDE, TOP)
		right_edge.size = Vector2(SIDE, h - TOP - BOTTOM)
		bottom_edge.position = Vector2(0, h - 3)
		bottom_edge.size = Vector2(w - 15, 3)
		queue_redraw()

	func _place(id: StringName, rect: Rect2):
		buttons[id].position = rect.position
		buttons[id].size = rect.size

	func interactive_controls() -> Array:
		var out: Array = buttons.values()
		out.append_array([right_edge, bottom_edge, grip])
		return out

	## Text at device resolution: this Control is scaled by the frame unit, and
	## a glyph rasterised at the base size would be upscaled (blurry). Undo the
	## scale for the string and draw it at size x scale instead (the root
	## canvas' own stretch is oversampled by the viewport as usual).
	func _text(font: Font, rect: Rect2, value: String, font_size: int, color: Color, align := HORIZONTAL_ALIGNMENT_LEFT):
		var k := maxf(scale.x, 0.01)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2(1.0 / k, 1.0 / k))
		Style.text(self, font, Rect2(rect.position * k, rect.size * k), value, maxi(int(round(font_size * k)), 1), color, align)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	func scene_rect() -> Rect2:
		return Rect2(SIDE + 30, size.y - BOTTOM + 2.5, maxf(size.x - SIDE - 30 - 20, 0), 9)

	func _draw():
		var w := size.x
		var h := size.y
		if not size.is_finite() or not scale.is_finite() or w < TOP or h < TOP + BOTTOM: return
		# Body: the side borders and the bottom bar in brushed steel.
		Style.brushed(self, Rect2(0, TOP, SIDE, h - TOP))
		Style.brushed(self, Rect2(w - SIDE, TOP, SIDE, h - TOP))
		Style.brushed(self, Rect2(0, h - BOTTOM, w, BOTTOM))
		# Title strip, as on the main panel.
		Style.vgradient(self, Rect2(0, 0, w, TOP), Style.STRIP_TOP, Style.STRIP_BOTTOM)
		Style.hline(self, 0, w, 0.25, Style.BEVEL_LIGHT)
		Style.hline(self, 0, w, TOP - 0.25, Style.EDGE)
		var caption := "O O Z I C   V I S U A L I S E R"
		var font := Style.bold_font()
		var cw := font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 6).x
		var cx := clampf((w - cw) * 0.5, 8.0, maxf(w - 46.0 - cw, 8.0))
		_text(font, Rect2(cx, 1, cw + 1, 12), caption, 6, Style.LABEL)
		for y in [5.5, 8.0]:
			Style.groove(self, 6, cx - 6, y)
			Style.groove(self, cx + cw + 6, w - 45, y)
		# The 3D view sits in a recessed well.
		var inner := Rect2(SIDE, TOP, w - 2.0 * SIDE, h - TOP - BOTTOM)
		Style.sunken(self, inner)
		# Bottom bar: scene LCD between the scene buttons and the grip.
		var lcd := scene_rect()
		if lcd.size.x > 30:
			Style.lcd(self, lcd)
			var bus = PlayerBusScript.instance()
			var count: int = bus.scenes.size() if bus else 0
			var counter := "%d/%d" % [bus.scene_index + 1, count] if count > 0 and bus.scene_index >= 0 else ""
			var mono := Style.mono_font()
			var counter_w := mono.get_string_size(counter, HORIZONTAL_ALIGNMENT_LEFT, -1, 5).x
			var tag := Rect2(lcd.position + Vector2(2, 1.5), Vector2(22, lcd.size.y - 3))
			draw_rect(tag, Color(Style.LCD_DIM, 0.22))
			_text(font, tag, "SCENE", 5, Style.LCD_TEXT, HORIZONTAL_ALIGNMENT_CENTER)
			var title: String = bus.scene_title() if bus else ""
			var ui := Style.ui_font()
			var title_w := lcd.size.x - 30 - counter_w - 4
			_text(ui, Rect2(lcd.position.x + 27, lcd.position.y, title_w, lcd.size.y), Style.elide(ui, title, title_w, 7), 7, Style.LCD_TEXT)
			_text(mono, Rect2(lcd.end.x - counter_w - 2, lcd.position.y, counter_w, lcd.size.y), counter, 5, Style.LCD_DIM)
		# Outer edge and bevel, as on every panel.
		draw_rect(Rect2(Vector2(0.25, 0.25), size - Vector2(0.5, 0.5)), Style.EDGE, false, 0.5)
		Style.raised(self, Rect2(Vector2(0.75, TOP + 0.5), Vector2(w - 1.5, h - TOP - 1.25)), 0.6)

## Title strip / bottom bar: a press starts moving the visualiser (the dock
## controller follows the mouse from there).
class DragArea extends Control:
	func _init():
		mouse_filter = Control.MOUSE_FILTER_STOP

	func _gui_input(event):
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed and not event.double_click:
			PlayerBusScript.instance().command(&"begin_panel_drag", {"panel": "visualiser"})
			accept_event()

## Edge / grip: reports mouse travel in screen pixels on its axes.
class Handle extends Control:
	var axes := Vector2.ONE
	var draw_grip := false
	var _from := Vector2.ZERO
	var _active := false

	func _init(handle_axes: Vector2, cursor: CursorShape):
		axes = handle_axes
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_default_cursor_shape = cursor

	func _draw():
		if draw_grip: Style.glyph(self, "grip", size * 0.5, minf(size.x, size.y) / 9.0, Style.LABEL_DIM)

	func _gui_input(event):
		var bus = PlayerBusScript.instance()
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			_active = event.pressed
			_from = _screen(event)
			if event.pressed: bus.command(&"resize_panel", {"panel": "visualiser", "pixels": Vector2.ZERO, "axes": axes, "start": true})
			accept_event()
		elif event is InputEventMouseMotion and _active:
			bus.command(&"resize_panel", {"panel": "visualiser", "pixels": (_screen(event) - _from) * axes, "axes": axes, "start": false})
			accept_event()

	func _screen(event: InputEvent) -> Vector2:
		if DisplayServer.get_name() == "headless": return event.global_position
		return Vector2(DisplayServer.mouse_get_position())
