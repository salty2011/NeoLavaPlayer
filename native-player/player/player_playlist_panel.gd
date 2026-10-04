extends Control
## Playlist panel, attached below the main panel in the same window (275
## base units wide, resizable height). Numbered entries with durations (once
## known), current track highlighted, failed tracks dimmed; double-click or
## Enter plays, drag reorders, Delete removes, Alt+Up/Down moves. Bottom bar:
## ADD, DIR, REM, (room for more), LOAD, SAVE; a search filter; total time.
## The bottom edge and the corner grip resize it (resize_requested).
const Style = preload("res://player/player_style.gd")
const Fmt = preload("res://player/player_format.gd")
const Widgets = preload("res://player/player_widgets.gd")
const PlayerBusScript = preload("res://player_bus.gd")

## Drag on the grip / bottom edge: `pixels_y` = mouse travel in screen pixels
## since the press; `start` true on the press itself.
signal resize_requested(pixels_y: float, start: bool)
signal drag_started()

const STRIP_HEIGHT := 12.0
## id: [x, width, command, label, tooltip]; y follows the panel height.
const BUTTONS := {
	&"add": [5.0, 24.0, &"add_tracks", "ADD", "Add files (Ctrl+A)"],
	&"add_dir": [31.0, 24.0, &"add_directory", "DIR", "Add a folder and its sub-folders (Shift+A)"],
	&"remove": [57.0, 24.0, &"remove_track", "REM", "Remove the selected track (Delete, Ctrl+D)"],
	&"load": [202.0, 26.0, &"import_m3u_dialog", "LOAD", "Import an .m3u playlist"],
	&"save": [230.0, 26.0, &"export_m3u_dialog", "SAVE", "Export the playlist as .m3u"],
}

var bus
var list: PlaylistList
var scrollbar: VScrollBar
var filter: LineEdit
var buttons := {}
var grip: ResizeHandle
var edge: ResizeHandle
## Track path -> seconds, learnt as tracks play (session cache).
var durations := {}

func _init():
	name = "PlaylistPanel"
	size = Vector2(Fmt.MAIN_SIZE.x, Fmt.PLAYLIST_DEFAULT_HEIGHT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true

func _ready():
	bus = PlayerBusScript.instance()
	list = PlaylistList.new()
	list.name = "List"
	list.durations = durations
	list.play_requested.connect(func(index): bus.command(&"play_index", {"index": index}))
	list.move_requested.connect(func(from, to): bus.command(&"move_index", {"from": from, "to": to}))
	list.remove_requested.connect(func(index): bus.command(&"remove_index", {"index": index}))
	list.scrolled.connect(_sync_scrollbar)
	add_child(list)
	scrollbar = VScrollBar.new()
	scrollbar.name = "Scroll"
	_style_scrollbar(scrollbar)
	scrollbar.value_changed.connect(func(v): list.set_scroll(v))
	add_child(scrollbar)
	filter = LineEdit.new()
	filter.name = "Filter"
	filter.placeholder_text = "Search playlist (Esc clears)"
	filter.clear_button_enabled = false
	_style_filter(filter)
	filter.text_changed.connect(func(text): set_filter(text))
	filter.gui_input.connect(func(event):
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			filter.text = ""
			set_filter("")
			filter.release_focus()
			filter.accept_event())
	add_child(filter)
	for id in BUTTONS:
		var spec: Array = BUTTONS[id]
		var b := Widgets.PlayerButton.new()
		b.name = str(id)
		b.id = id
		b.command = spec[2]
		b.label = spec[3]
		b.tooltip_text = spec[4]
		b.activated.connect(func(button): bus.command(button.command, button.args))
		add_child(b)
		buttons[id] = b
	grip = ResizeHandle.new()
	grip.name = "Grip"
	grip.draw_grip = true
	grip.tooltip_text = "Drag to resize the playlist"
	grip.resize_drag.connect(func(dy, start): resize_requested.emit(dy, start))
	add_child(grip)
	edge = ResizeHandle.new()
	edge.name = "Edge"
	edge.resize_drag.connect(func(dy, start): resize_requested.emit(dy, start))
	add_child(edge)
	bus.playlist_changed.connect(refresh)
	bus.track_changed.connect(func(_i, _t): refresh())
	bus.position_changed.connect(_on_position)
	_layout()
	refresh()

func _notification(what):
	if what == NOTIFICATION_RESIZED and list != null: _layout()

func list_rect() -> Rect2: return Rect2(5, STRIP_HEIGHT + 2, 258, size.y - STRIP_HEIGHT - 33)
func filter_rect() -> Rect2: return Rect2(5, size.y - 29, 140, 10)
func total_rect() -> Rect2: return Rect2(150, size.y - 29, 120, 10)
func button_y() -> float: return size.y - 16

func _layout():
	var lr := list_rect()
	list.position = lr.position
	list.size = lr.size
	scrollbar.position = Vector2(lr.end.x + 1, lr.position.y)
	scrollbar.size = Vector2(6, lr.size.y)
	filter.position = filter_rect().position
	filter.size = filter_rect().size
	for id in BUTTONS:
		buttons[id].position = Vector2(BUTTONS[id][0], button_y())
		buttons[id].size = Vector2(BUTTONS[id][1], 10)
	grip.position = Vector2(259, button_y())
	grip.size = Vector2(12, 12)
	edge.position = Vector2(0, size.y - 3)
	edge.size = Vector2(259, 3)
	_sync_scrollbar()
	queue_redraw()

func refresh():
	if bus == null or list == null: return
	list.set_data(bus.playlist, bus.track_index, bus.failed_tracks)
	buttons[&"remove"].enabled = not bus.playlist.is_empty()
	buttons[&"save"].enabled = not bus.playlist.is_empty()
	_sync_scrollbar()
	queue_redraw()

func set_filter(query: String):
	list.set_filter(query)
	_sync_scrollbar()
	queue_redraw()

func selected_index() -> int: return list.selected

func _on_position(_seconds: float, length: float):
	if length <= 0.0 or bus.track_index < 0 or bus.track_index >= bus.playlist.size(): return
	var path: String = bus.playlist[bus.track_index]
	if durations.has(path) and is_equal_approx(durations[path], length): return
	durations[path] = length
	list.queue_redraw()
	queue_redraw()

func total_text() -> String:
	var shown := list.visible_rows.size()
	var count := "%d track%s" % [bus.playlist.size(), "" if bus.playlist.size() == 1 else "s"]
	if shown != bus.playlist.size(): count = "%d of %d" % [shown, bus.playlist.size()]
	return count + "  ·  " + Fmt.total_text(bus.playlist, durations)

func _sync_scrollbar():
	if scrollbar == null: return
	scrollbar.max_value = maxf(list.content_height(), list.size.y)
	scrollbar.page = list.size.y
	scrollbar.step = 0.0
	scrollbar.set_value_no_signal(list.scroll)
	scrollbar.visible = list.content_height() > list.size.y + 0.5

func _draw():
	Style.brushed(self, Rect2(Vector2.ZERO, size))
	var strip := Rect2(0, 0, size.x, STRIP_HEIGHT)
	Style.vgradient(self, strip, Style.STRIP_TOP, Style.STRIP_BOTTOM)
	Style.hline(self, 0, size.x, 0.25, Style.BEVEL_LIGHT)
	Style.hline(self, 0, size.x, STRIP_HEIGHT - 0.25, Style.EDGE)
	var caption := "P L A Y L I S T"
	var font := Style.bold_font()
	var cw := font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 6).x
	var cx := (size.x - cw) * 0.5
	Style.text(self, font, Rect2(cx, 0, cw + 1, STRIP_HEIGHT), caption, 6, Style.LABEL)
	for y in [4.75, 7.25]:
		Style.groove(self, 6, cx - 6, y)
		Style.groove(self, cx + cw + 6, size.x - 6, y)
	var lr := list_rect()
	Style.sunken(self, Rect2(lr.position, Vector2(lr.size.x + 7, lr.size.y)))
	Style.text(self, Style.mono_font(), total_rect(), total_text(), 5, Style.LABEL, HORIZONTAL_ALIGNMENT_RIGHT)
	draw_rect(Rect2(Vector2(0.25, 0.25), size - Vector2(0.5, 0.5)), Style.EDGE, false, 0.5)

func _gui_input(event):
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		drag_started.emit()
		accept_event()

func interactive_controls() -> Array:
	var out: Array = [list, filter, grip]
	out.append_array(buttons.values())
	return out

func _style_scrollbar(bar: VScrollBar):
	var track := StyleBoxFlat.new()
	track.bg_color = Style.LIST_BG
	track.content_margin_left = 1
	track.content_margin_right = 1
	var grabber := StyleBoxFlat.new()
	grabber.bg_color = Color("#4a525c")
	grabber.border_color = Style.EDGE
	grabber.set_border_width_all(0)
	grabber.set_corner_radius_all(1)
	var grabber_hot := grabber.duplicate()
	grabber_hot.bg_color = Color("#6a7480")
	bar.add_theme_stylebox_override("scroll", track)
	bar.add_theme_stylebox_override("scroll_focus", track)
	bar.add_theme_stylebox_override("grabber", grabber)
	bar.add_theme_stylebox_override("grabber_highlight", grabber_hot)
	bar.add_theme_stylebox_override("grabber_pressed", grabber_hot)
	bar.focus_mode = Control.FOCUS_NONE

func _style_filter(edit: LineEdit):
	var normal := StyleBoxFlat.new()
	normal.bg_color = Style.LCD_BG
	normal.border_color = Style.EDGE
	normal.set_border_width_all(0)
	normal.content_margin_left = 2.5
	normal.content_margin_right = 1.5
	normal.content_margin_top = 0
	normal.content_margin_bottom = 0
	var focus := normal.duplicate()
	focus.draw_center = false
	focus.border_color = Color(Style.LCD_ACCENT, 0.8)
	focus.set_border_width_all(1)
	edit.add_theme_stylebox_override("normal", normal)
	edit.add_theme_stylebox_override("focus", focus)
	edit.add_theme_stylebox_override("read_only", normal)
	edit.add_theme_font_override("font", Style.ui_font())
	edit.add_theme_font_size_override("font_size", 6)
	edit.add_theme_color_override("font_color", Style.LCD_TEXT)
	edit.add_theme_color_override("font_placeholder_color", Color(Style.LCD_DIM, 0.8))
	edit.add_theme_color_override("caret_color", Style.LCD_TEXT)
	edit.add_theme_color_override("selection_color", Color(Style.LCD_ACCENT, 0.35))
	edit.add_theme_constant_override("caret_width", 1)
	edit.add_theme_constant_override("minimum_character_width", 0)
	edit.custom_minimum_size = Vector2.ZERO

## Drag handle that reports vertical mouse travel in screen pixels.
class ResizeHandle extends Control:
	signal resize_drag(pixels_y: float, start: bool)
	var draw_grip := false
	var _from := 0.0
	var _active := false

	func _init():
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_default_cursor_shape = Control.CURSOR_VSIZE

	func _draw():
		if draw_grip: Style.glyph(self, "grip", size * 0.5, minf(size.x, size.y) / 9.0, Style.LABEL_DIM)

	func _gui_input(event):
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			_active = event.pressed
			_from = _screen_y(event)
			if event.pressed: resize_drag.emit(0.0, true)
			accept_event()
		elif event is InputEventMouseMotion and _active:
			resize_drag.emit(_screen_y(event) - _from, false)
			accept_event()

	## Screen-space y, so the window growing under the cursor does not feed back.
	func _screen_y(event: InputEvent) -> float:
		if DisplayServer.get_name() == "headless": return event.global_position.y
		return float(DisplayServer.mouse_get_position().y)

## The track list: custom drawn rows (number, title, duration).
class PlaylistList extends Control:
	signal play_requested(index: int)
	signal move_requested(from: int, to: int)
	signal remove_requested(index: int)
	signal scrolled()
	const ROW_HEIGHT := 9.0
	const FONT_SIZE := 6
	var entries := PackedStringArray()
	var current := -1
	var failed: Array = []
	var durations := {}
	var query := ""
	## Original playlist indices shown, in order (all, or the filter matches).
	var visible_rows: Array[int] = []
	var selected := -1
	var scroll := 0.0
	var hover_row := -1
	var drop_row := -1
	var _press_row := -1
	var _press_y := 0.0
	var _dragging := false

	func _init():
		mouse_filter = Control.MOUSE_FILTER_STOP
		focus_mode = Control.FOCUS_ALL
		clip_contents = true
		mouse_exited.connect(func(): hover_row = -1; queue_redraw())

	func set_data(paths: PackedStringArray, current_index: int, failed_indices: Array):
		var follow := current_index != current
		entries = paths
		current = current_index
		failed = failed_indices.duplicate()
		if selected >= entries.size(): selected = entries.size() - 1
		_rebuild()
		if follow and current >= 0: ensure_visible(visible_rows.find(current))

	func set_filter(text: String):
		query = text
		scroll = 0.0
		_rebuild()

	func _rebuild():
		visible_rows = Fmt.filter_indices(entries, query)
		set_scroll(scroll)
		queue_redraw()

	func content_height() -> float: return visible_rows.size() * ROW_HEIGHT

	func max_scroll() -> float: return maxf(content_height() - size.y, 0.0)

	func set_scroll(value: float):
		var clamped := clampf(value, 0.0, max_scroll())
		if is_equal_approx(clamped, scroll):
			scroll = clamped
			return
		scroll = clamped
		queue_redraw()
		scrolled.emit()

	## Visible position (0-based row among visible_rows) at local y, or -1.
	func row_at(y: float) -> int:
		var row := int(floor((y + scroll) / ROW_HEIGHT))
		return row if row >= 0 and row < visible_rows.size() else -1

	func index_at(y: float) -> int:
		var row := row_at(y)
		return visible_rows[row] if row >= 0 else -1

	func row_rect(row: int) -> Rect2: return Rect2(0, row * ROW_HEIGHT - scroll, size.x, ROW_HEIGHT)

	func ensure_visible(row: int):
		if row < 0: return
		var top := row * ROW_HEIGHT
		if top < scroll: set_scroll(top)
		elif top + ROW_HEIGHT > scroll + size.y: set_scroll(top + ROW_HEIGHT - size.y)

	func select_index(index: int):
		selected = index
		ensure_visible(visible_rows.find(index))
		queue_redraw()

	func _draw():
		draw_rect(Rect2(Vector2.ZERO, size), Style.LIST_BG)
		var font := Style.ui_font()
		var mono := Style.mono_font()
		if entries.is_empty() or visible_rows.is_empty():
			var message := "Drop music here, or press ADD" if entries.is_empty() else "No tracks match \"%s\"" % query
			Style.text(self, font, Rect2(0, 0, size.x, minf(size.y, 30)), message, FONT_SIZE, Style.LIST_FAILED, HORIZONTAL_ALIGNMENT_CENTER)
			return
		var digits := str(entries.size()).length()
		var number_w := mono.get_string_size("0".repeat(digits) + ".", HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 1).x
		var first := int(floor(scroll / ROW_HEIGHT))
		var last := mini(visible_rows.size() - 1, int(ceil((scroll + size.y) / ROW_HEIGHT)))
		for row in range(first, last + 1):
			var index: int = visible_rows[row]
			var rect := row_rect(row)
			var is_current := index == current
			var is_failed := failed.has(index)
			if index == selected: draw_rect(rect, Style.LIST_SELECTED_BG)
			elif is_current: draw_rect(rect, Style.LIST_CURRENT_BG)
			elif row == hover_row: draw_rect(rect, Style.LIST_HOVER_BG)
			if is_current: draw_rect(Rect2(rect.position, Vector2(1.0, rect.size.y)), Style.LIST_CURRENT)
			var color := Style.LIST_CURRENT if is_current else (Style.LIST_FAILED if is_failed else Style.LIST_TEXT)
			Style.text(self, mono, Rect2(rect.position.x + 2, rect.position.y, number_w, rect.size.y), "%d." % (index + 1), FONT_SIZE - 1, Style.LIST_NUMBER if not is_current else Style.LIST_CURRENT, HORIZONTAL_ALIGNMENT_RIGHT)
			var duration := ""
			if durations.has(entries[index]): duration = Fmt.time_text(durations[entries[index]])
			elif is_failed: duration = "error"
			var dur_w := mono.get_string_size(duration, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 1).x if not duration.is_empty() else 0.0
			var title_x := rect.position.x + 2 + number_w + 3
			Style.text(self, font, Rect2(title_x, rect.position.y, size.x - title_x - dur_w - 5, rect.size.y), Fmt.display_title(entries[index]), FONT_SIZE, color)
			if not duration.is_empty():
				Style.text(self, mono, Rect2(size.x - dur_w - 2, rect.position.y, dur_w, rect.size.y), duration, FONT_SIZE - 1, color if not is_current else Style.LIST_CURRENT)
			if is_failed: Style.hline(self, title_x, minf(title_x + font.get_string_size(Fmt.display_title(entries[index]), HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x, size.x - dur_w - 5), rect.get_center().y, Color(Style.LIST_FAILED, 0.8), 0.4)
		if _dragging and drop_row >= 0:
			var from_row := visible_rows.find(_drag_index())
			var y := row_rect(drop_row).position.y + (ROW_HEIGHT if drop_row > from_row else 0.0)
			draw_rect(Rect2(0, clampf(y - 0.5, 0, size.y - 1), size.x, 1.0), Style.LIST_DROP)
		if has_focus(): draw_rect(Rect2(Vector2(0.25, 0.25), size - Vector2(0.5, 0.5)), Color(Style.LCD_ACCENT, 0.35), false, 0.5)

	func _drag_index() -> int:
		return visible_rows[_press_row] if _press_row >= 0 and _press_row < visible_rows.size() else -1

	func _gui_input(event):
		if event is InputEventMouseButton:
			if event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] and event.pressed:
				set_scroll(scroll + (-3.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 3.0) * ROW_HEIGHT * maxf(event.factor, 1.0))
				accept_event()
			elif event.button_index == MOUSE_BUTTON_LEFT:
				if event.pressed:
					grab_focus()
					var row := row_at(event.position.y)
					_press_row = row
					_press_y = event.position.y
					_dragging = false
					if row >= 0:
						selected = visible_rows[row]
						if event.double_click:
							_press_row = -1
							play_requested.emit(selected)
					queue_redraw()
				else:
					if _dragging and drop_row >= 0:
						var from := _drag_index()
						var to: int = visible_rows[drop_row]
						if from >= 0 and to != from:
							move_requested.emit(from, to)
							selected = to
					_dragging = false
					_press_row = -1
					drop_row = -1
					queue_redraw()
				accept_event()
		elif event is InputEventMouseMotion:
			var row := row_at(event.position.y)
			if _press_row >= 0 and (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
				if not _dragging and absf(event.position.y - _press_y) > 3.0: _dragging = true
				if _dragging:
					if event.position.y < 0: set_scroll(scroll - ROW_HEIGHT * 0.5)
					elif event.position.y > size.y: set_scroll(scroll + ROW_HEIGHT * 0.5)
					drop_row = clampi(int(floor((clampf(event.position.y, 0, size.y - 0.01) + scroll) / ROW_HEIGHT)), 0, visible_rows.size() - 1)
			if row != hover_row or _dragging:
				hover_row = row
				queue_redraw()
		elif event is InputEventKey and event.pressed:
			if _key(event): accept_event()

	## List keys (focus on the list). Returns true when handled.
	func _key(event: InputEventKey) -> bool:
		if visible_rows.is_empty(): return false
		var row := visible_rows.find(selected)
		var page := maxi(int(size.y / ROW_HEIGHT) - 1, 1)
		match event.keycode:
			KEY_ENTER, KEY_KP_ENTER:
				if selected >= 0: play_requested.emit(selected)
				return true
			KEY_DELETE, KEY_BACKSPACE:
				if selected >= 0:
					remove_requested.emit(selected)
					# The bus applies the removal synchronously: keep the
					# selection on the same row (or the new last one).
					selected = mini(selected, entries.size() - 1)
					queue_redraw()
				return true
			KEY_UP, KEY_DOWN:
				var step := -1 if event.keycode == KEY_UP else 1
				if event.alt_pressed:
					var target := row + step
					if row >= 0 and target >= 0 and target < visible_rows.size():
						move_requested.emit(selected, visible_rows[target])
						selected = visible_rows[target]
					return true
				_select_row(clampi(row + step if row >= 0 else 0, 0, visible_rows.size() - 1))
				return true
			KEY_HOME: _select_row(0); return true
			KEY_END: _select_row(visible_rows.size() - 1); return true
			KEY_PAGEUP: _select_row(maxi(row - page, 0)); return true
			KEY_PAGEDOWN: _select_row(mini(row + page, visible_rows.size() - 1)); return true
		return false

	func _select_row(row: int):
		selected = visible_rows[row]
		ensure_visible(row)
		queue_redraw()
