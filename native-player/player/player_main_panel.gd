extends Control
## Main player panel (275 x 116 base units): title strip, LCD (time,
## spectrum, scrolling title, info and scene lines), volume + window toggles,
## seek bar, transport, shuffle/repeat. Reads PlayerBus state; every control
## sends a bus command (see BUTTONS). Window chores (menus, dialogs, playlist
## panel) are bus commands too, answered by PlayerWindow.
const Style = preload("res://player/player_style.gd")
const Fmt = preload("res://player/player_format.gd")
const Widgets = preload("res://player/player_widgets.gd")
const PlayerBusScript = preload("res://player_bus.gd")

## Emitted when the user presses on the panel body or title strip (window drag).
signal drag_started()

const TITLE_STRIP := Rect2(0, 0, 275, 14)
const LCD_RECT := Rect2(7, 17, 261, 45)
const INFO_RECT := Rect2(104, 33, 160, 9)
## id: [rect, command, args, glyph, label, toggle, flat, tooltip]
const BUTTONS := {
	&"menu": [Rect2(3, 2, 12, 10), &"show_player_menu", {}, "menu", "", false, true, "Menu: scenes, playlist, size, settings"],
	&"minimize": [Rect2(246, 2, 11, 10), &"minimize", {"source": "controller"}, "minimize", "", false, true, "Minimise (Ctrl+I)"],
	&"close": [Rect2(259, 2, 12, 10), &"close_controller", {}, "close", "", false, true, "Close player and quit"],
	&"mute": [Rect2(7, 66, 14, 10), &"toggle_mute", {}, "speaker", "", false, false, "Mute (Ctrl+M)"],
	&"library": [Rect2(174, 66, 30, 10), &"toggle_library", {}, "", "LIB", true, false, "Music library (Ctrl+Shift+L)"],
	&"visualiser": [Rect2(206, 66, 30, 10), &"toggle_visualiser", {}, "", "VIS", true, false, "Show / hide the visualiser"],
	&"playlist": [Rect2(238, 66, 30, 10), &"toggle_drawer", {}, "", "PL", true, false, "Playlist (Ctrl+L)"],
	&"previous": [Rect2(7, 93, 23, 18), &"previous", {}, "previous", "", false, false, "Previous (Ctrl+B)"],
	&"play": [Rect2(31, 93, 23, 18), &"play", {}, "play", "", false, false, "Play"],
	&"pause": [Rect2(55, 93, 23, 18), &"play_pause", {}, "pause", "", false, false, "Pause / resume (Space)"],
	&"stop": [Rect2(79, 93, 23, 18), &"stop", {}, "stop", "", false, false, "Stop (Ctrl+S)"],
	&"next": [Rect2(103, 93, 23, 18), &"next", {}, "next", "", false, false, "Next (Ctrl+N)"],
	&"eject": [Rect2(131, 94, 22, 16), &"add_tracks", {}, "eject", "", false, false, "Open files (Ctrl+A)"],
	&"shuffle": [Rect2(171, 96, 36, 12), &"toggle_shuffle", {}, "", "SHUF", true, false, "Shuffle (Ctrl+R)"],
	&"repeat": [Rect2(209, 96, 36, 12), &"cycle_repeat", {}, "", "REP", true, false, "Repeat: off / all / one (Ctrl+O)"],
}
const SLIDERS := {&"volume": Rect2(23, 66, 141, 10), &"seek": Rect2(7, 80, 261, 9)}
const TIME_RECT := Rect2(10, 21, 85, 17)
const VIS_RECT := Rect2(12, 42, 82, 16)
const TITLE_RECT := Rect2(104, 20, 160, 11)
const SCENE_RECT := Rect2(104, 46, 160, 11)
const MARK_RECT := Rect2(251, 93, 17, 17)
const STATUS_SECONDS := 4.0

var bus
var buttons := {}
var sliders := {}
var time_display: Widgets.TimeDisplay
var vis: Widgets.VisDisplay
var marquee: Widgets.Marquee
var scene_line: SceneLine
var status_left := 0.0

func _init():
	name = "MainPanel"
	size = Fmt.MAIN_SIZE
	custom_minimum_size = Fmt.MAIN_SIZE
	mouse_filter = Control.MOUSE_FILTER_STOP

func _ready():
	bus = PlayerBusScript.instance()
	for id in BUTTONS:
		var spec: Array = BUTTONS[id]
		var b := Widgets.PlayerButton.new()
		b.name = str(id)
		b.id = id
		b.position = spec[0].position
		b.size = spec[0].size
		b.command = spec[1]
		b.args = spec[2]
		b.glyph = spec[3]
		b.label = spec[4]
		b.toggle = spec[5]
		b.flat = spec[6]
		b.tooltip_text = spec[7]
		if b.toggle: b.label_size = 6 if b.label.length() <= 3 else 5
		b.activated.connect(_on_button)
		add_child(b)
		buttons[id] = b
	for id in SLIDERS:
		var s := Widgets.PlayerSlider.new()
		s.name = str(id)
		s.id = id
		s.position = SLIDERS[id].position
		s.size = SLIDERS[id].size
		s.live = id == &"volume"
		s.thumb_width = 6.0 if id == &"volume" else 9.0
		s.tooltip_text = "Volume (Up / Down)" if id == &"volume" else "Seek (Left / Right: 5 s)"
		s.changed.connect(_on_slider.bind(id))
		add_child(s)
		sliders[id] = s
	time_display = Widgets.TimeDisplay.new()
	time_display.name = "Time"
	time_display.position = TIME_RECT.position
	time_display.size = TIME_RECT.size
	add_child(time_display)
	vis = Widgets.VisDisplay.new()
	vis.name = "Vis"
	vis.position = VIS_RECT.position
	vis.size = VIS_RECT.size
	add_child(vis)
	marquee = Widgets.Marquee.new()
	marquee.name = "Title"
	marquee.position = TITLE_RECT.position
	marquee.size = TITLE_RECT.size
	add_child(marquee)
	scene_line = SceneLine.new()
	scene_line.name = "Scene"
	scene_line.position = SCENE_RECT.position
	scene_line.size = SCENE_RECT.size
	scene_line.pressed.connect(func(): bus.command(&"show_scene_menu"))
	add_child(scene_line)
	bus.transport_changed.connect(func(_s): refresh())
	bus.track_changed.connect(func(_i, _t): refresh())
	bus.position_changed.connect(_on_position)
	bus.playlist_changed.connect(refresh)
	bus.volume_changed.connect(func(_v, _m): refresh())
	bus.modes_changed.connect(func(_s, _r): refresh())
	bus.scene_changed.connect(func(_i): refresh())
	bus.scene_list_changed.connect(refresh)
	bus.windows_changed.connect(refresh)
	bus.status_changed.connect(_on_status)
	bus.analysis_frame.connect(func(signals): vis.feed(signals))
	refresh()

## Every control's command (tests drive these).
func command_for(id: StringName) -> StringName:
	return buttons[id].command if buttons.has(id) else &""

func _on_button(button):
	bus.command(button.command, button.args)

func _on_slider(value: float, id: StringName):
	if id == &"volume": bus.command(&"set_volume", {"value": value})
	else: bus.command(&"seek_fraction", {"fraction": value})

func _on_status(_text: String):
	status_left = STATUS_SECONDS
	queue_redraw()

func _on_position(seconds: float, length: float):
	time_display.position_s = seconds
	time_display.duration_s = length
	time_display.queue_redraw()
	var seek: Widgets.PlayerSlider = sliders[&"seek"]
	seek.enabled = length > 0.0
	if not seek.dragging: seek.set_value(seconds / length if length > 0.0 else 0.0)

func refresh():
	if bus == null or buttons.is_empty(): return
	var has_tracks: bool = not bus.playlist.is_empty()
	var transport: String = bus.transport
	buttons[&"play"].enabled = has_tracks
	buttons[&"pause"].enabled = transport in ["playing", "paused"]
	buttons[&"stop"].enabled = transport in ["playing", "paused"]
	buttons[&"next"].enabled = has_tracks
	buttons[&"previous"].enabled = has_tracks
	buttons[&"play"].active = transport == "playing"
	buttons[&"shuffle"].active = bus.shuffle
	var rep: int = bus.repeat_mode
	buttons[&"repeat"].active = rep != 0
	buttons[&"repeat"].label = "REP 1" if rep == 2 else "REP"
	buttons[&"repeat"].label_size = 5 if rep == 2 else 6
	buttons[&"repeat"].tooltip_text = ["Repeat: off", "Repeat: playlist", "Repeat: this track"][clampi(rep, 0, 2)] + " (Ctrl+O)"
	buttons[&"repeat"].queue_redraw()
	buttons[&"mute"].glyph = "speaker_muted" if bus.muted else "speaker"
	buttons[&"mute"].tooltip_text = ("Unmute" if bus.muted else "Mute") + " (Ctrl+M)"
	buttons[&"mute"].queue_redraw()
	buttons[&"visualiser"].active = bus.visualiser_visible
	buttons[&"visualiser"].tooltip_text = ("Hide" if bus.visualiser_visible else "Show") + " the visualiser"
	buttons[&"playlist"].active = bus.drawer_open
	buttons[&"library"].active = bus.library_open
	var volume: Widgets.PlayerSlider = sliders[&"volume"]
	if not volume.dragging: volume.set_value(bus.volume)
	volume.dim = bus.muted
	time_display.transport = transport
	time_display.queue_redraw()
	_on_position(bus.position, bus.duration)
	marquee.value = title_text()
	scene_line.queue_redraw()
	queue_redraw()

## Scrolling title: "N. Artist - Title (m:ss)", Winamp style.
func title_text() -> String:
	if bus.track_index < 0 or bus.track_index >= bus.playlist.size():
		return "Oozic Player  -  drop music here or press Open" if bus.playlist.is_empty() else "%d tracks ready  -  press Play" % bus.playlist.size()
	var text := "%d. %s" % [bus.track_index + 1, Fmt.display_title(bus.playlist[bus.track_index])]
	if bus.duration > 0.0: text += "  (%s)" % Fmt.time_text(bus.duration)
	return text

func info_text() -> String:
	if status_left > 0.0 and not str(bus.status).is_empty(): return str(bus.status)
	if bus.playlist.is_empty(): return "NO TRACKS"
	var parts := PackedStringArray()
	if bus.track_index >= 0 and bus.track_index < bus.playlist.size():
		var tag := Fmt.format_tag(bus.playlist[bus.track_index])
		if not tag.is_empty(): parts.append(tag)
		parts.append("TRACK %d/%d" % [bus.track_index + 1, bus.playlist.size()])
	else: parts.append("%d TRACKS" % bus.playlist.size())
	parts.append({"playing": "PLAYING", "paused": "PAUSED", "loading": "LOADING", "stopped": "STOPPED"}.get(bus.transport, ""))
	if bus.analysis_source == "mock": parts.append("SYNTH BEAT")
	return "  ·  ".join(parts)

func _process(delta):
	if status_left > 0.0:
		status_left -= delta
		if status_left <= 0.0: queue_redraw()

func _draw():
	Style.brushed(self, Rect2(Vector2.ZERO, size))
	# Title strip.
	Style.vgradient(self, TITLE_STRIP, Style.STRIP_TOP, Style.STRIP_BOTTOM)
	Style.hline(self, 0, size.x, TITLE_STRIP.end.y - 0.25, Style.EDGE)
	var caption := "O O Z I C   P L A Y E R"
	var font := Style.bold_font()
	var cw := font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 6).x
	var cx := (size.x - cw) * 0.5
	Style.text(self, font, Rect2(cx, 1, cw + 1, 12), caption, 6, Style.LABEL)
	for y in [5.5, 8.0]:
		Style.groove(self, 19, cx - 6, y)
		Style.groove(self, cx + cw + 6, 242, y)
	# LCD.
	Style.lcd(self, LCD_RECT)
	Style.vline(self, 99, LCD_RECT.position.y + 3, LCD_RECT.end.y - 3, Color(Style.LCD_DIM, 0.25), 0.5)
	Style.hline(self, 102, LCD_RECT.end.x - 3, 43.5, Color(Style.LCD_DIM, 0.2), 0.4)
	var info := info_text()
	var info_color := Style.LCD_TEXT if status_left > 0.0 else Style.LCD_DIM
	Style.text(self, Style.mono_font(), INFO_RECT, info, 5, info_color)
	# Small engraved labels.
	Style.lava_mark(self, MARK_RECT)
	# Outer frame.
	draw_rect(Rect2(Vector2(0.25, 0.25), size - Vector2(0.5, 0.5)), Style.EDGE, false, 0.5)
	Style.raised(self, Rect2(Vector2(0.75, TITLE_STRIP.end.y + 0.5), size - Vector2(1.5, TITLE_STRIP.end.y + 1.25)), 0.6)

func _gui_input(event):
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if event.double_click and not TITLE_STRIP.has_point(event.position): bus.command(&"toggle_visualiser")
		else: drag_started.emit()
		accept_event()

## Every interactive child (hit-area tests).
func interactive_controls() -> Array:
	var out: Array = []
	out.append_array(buttons.values())
	out.append_array(sliders.values())
	out.append_array([time_display, vis, scene_line])
	return out

## Scene line: "SCENE  Title   n/N"; click opens the scene menu.
class SceneLine extends Control:
	signal pressed()
	var _hover := false

	func _init():
		mouse_filter = Control.MOUSE_FILTER_STOP
		tooltip_text = "Click to choose a scene (Page Up / Page Down to step)"
		mouse_entered.connect(func(): _hover = true; queue_redraw())
		mouse_exited.connect(func(): _hover = false; queue_redraw())

	func _draw():
		var bus = preload("res://player_bus.gd").instance()
		if bus == null: return
		var tag_rect := Rect2(0, 1.5, 22, size.y - 3)
		draw_rect(tag_rect, Color(Style.LCD_DIM, 0.35 if _hover else 0.22))
		Style.text(self, Style.bold_font(), tag_rect, "SCENE", 5, Style.LCD_TEXT, HORIZONTAL_ALIGNMENT_CENTER)
		var count: int = bus.scenes.size()
		var counter := "%d/%d" % [bus.scene_index + 1, count] if count > 0 and bus.scene_index >= 0 else ""
		var font := Style.mono_font()
		var counter_w := font.get_string_size(counter, HORIZONTAL_ALIGNMENT_LEFT, -1, 5).x
		var title: String = bus.scene_title()
		if title.is_empty(): title = "Choose a scene"
		Style.text(self, Style.ui_font(), Rect2(25, 0, size.x - 28 - counter_w, size.y), title + "  ▾", 7, Style.LCD_TEXT if _hover else Style.LCD_TEXT.darkened(0.08))
		Style.text(self, font, Rect2(size.x - counter_w, 0, counter_w, size.y), counter, 5, Style.LCD_DIM)

	func _gui_input(event):
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			pressed.emit()
			accept_event()
