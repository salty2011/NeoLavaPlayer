extends Control
## Music library browser, attached to the right of the player in the same
## window (see docs/WINDOWS_AND_BUS.md, "One window that grows"). Left: the
## sources (Songs, Artists, Albums, Playlists with counts), the library state
## box and REFRESH. Right: search, a breadcrumb with PLAY ALL / ADD ALL when
## inside an artist, album or playlist, sortable column headers, the
## virtualised list (only visible rows are drawn) and PLAY / ADD.
##
## Reads PlayerBus.library / library_state; every action is a bus command
## (LibraryModel.commands). The right edge, bottom edge and corner grip resize
## the panel (resize_requested).
const Style = preload("res://player/player_style.gd")
const Fmt = preload("res://player/player_format.gd")
const Widgets = preload("res://player/player_widgets.gd")
const LibraryModel = preload("res://player/library_model.gd")
const PlayerBusScript = preload("res://player_bus.gd")

## Drag on a resize handle: `pixels` = mouse travel in screen pixels since
## the press, `axes` which dimensions it changes (x width, y height).
signal resize_requested(pixels: Vector2, axes: Vector2, start: bool)
signal drag_started()
## Right-click menu ready to show at `anchor` (panel base units).
signal menu_requested(anchor: Vector2)

const STRIP_HEIGHT := 12.0
const LEFT_X := 5.0
const LEFT_W := 72.0
const RIGHT_X := 82.0
const SOURCE_ROW := 11.0
const SOURCES_Y := 16.0
const SEARCH_Y := 16.0
const CRUMB_Y := 29.0
const HEADER_Y := 40.0
const LIST_Y := 49.0
const SCROLL_W := 6.0
## List narrower than this drops the album column.
const NARROW_WIDTH := 200.0
const MENU_PLAY := 0
const MENU_ADD := 1
const MENU_ENQUEUE := 2

var bus
var model := LibraryModel.new()
var sources: SourceList
var search: LineEdit
var header: HeaderRow
var list: LibraryList
var scrollbar: VScrollBar
var buttons := {}
var load_button: Widgets.PlayerButton
var menu: PopupMenu
var grip: ResizeHandle
var right_edge: ResizeHandle
var bottom_edge: ResizeHandle
## Bus status published with the last library change (state box detail).
var library_status := ""
## Library id of the playing playlist entry (highlighted), "" when none.
var playing_id := ""
var _menu_actions := {}
var _blink := 0.0

func _init():
	name = "LibraryPanel"
	size = Vector2(Fmt.LIBRARY_DEFAULT_WIDTH, Fmt.LIBRARY_DEFAULT_HEIGHT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true

func _ready():
	bus = PlayerBusScript.instance()
	sources = SourceList.new()
	sources.name = "Sources"
	sources.panel = self
	sources.selected.connect(func(src): set_source(src))
	add_child(sources)
	search = LineEdit.new()
	search.name = "Search"
	search.clear_button_enabled = false
	_style_search(search)
	search.text_changed.connect(func(text): set_query(text))
	search.gui_input.connect(_on_search_input)
	add_child(search)
	header = HeaderRow.new()
	header.name = "Header"
	header.panel = self
	header.sort_requested.connect(func(column): model.toggle_sort(column); _rows_changed())
	add_child(header)
	list = LibraryList.new()
	list.name = "List"
	list.panel = self
	list.activated.connect(_on_activated)
	list.context_requested.connect(_on_context)
	list.back_requested.connect(go_back)
	list.scrolled.connect(_sync_scrollbar)
	list.selection_changed.connect(_on_selection_changed)
	add_child(list)
	scrollbar = VScrollBar.new()
	scrollbar.name = "Scroll"
	_style_scrollbar(scrollbar)
	scrollbar.value_changed.connect(func(v): list.set_scroll(v))
	add_child(scrollbar)
	_add_button(&"close", "", "close", "Close the library (LIB)", func(): bus.command(&"toggle_library"), true)
	_add_button(&"refresh", "REFRESH", "", "Read the Music library again", func(): bus.command(&"library_refresh"))
	_add_button(&"back", "", "back", "Back (Left / Backspace)", go_back, true)
	_add_button(&"play_all", "PLAY ALL", "", "", func(): dispatch(model.group_commands("play")))
	_add_button(&"add_all", "ADD ALL", "", "", func(): dispatch(model.group_commands("add")))
	_add_button(&"play", "PLAY", "", "Replace the playlist with the selection and play", func(): run("play"))
	_add_button(&"add", "ADD", "", "Add the selection to the end of the playlist", func(): run("add"))
	for id in [&"play_all", &"add_all"]: buttons[id].label_size = 5
	load_button = _add_button(&"load", "LOAD MUSIC LIBRARY", "", "Read your Music library (macOS asks for Media & Apple Music access the first time)", func(): bus.command(&"library_refresh"))
	grip = _handle("Grip", Vector2(1, 1), Control.CURSOR_FDIAGSIZE, true)
	right_edge = _handle("RightEdge", Vector2(1, 0), Control.CURSOR_HSIZE)
	bottom_edge = _handle("BottomEdge", Vector2(0, 1), Control.CURSOR_VSIZE)
	menu = PopupMenu.new()
	menu.name = "LibraryMenu"
	menu.id_pressed.connect(_on_menu)
	add_child(menu)
	bus.library_changed.connect(_on_library_changed)
	bus.track_changed.connect(func(_i, _t): _update_playing())
	bus.playlist_changed.connect(_update_playing)
	_on_library_changed()
	_layout()

func _add_button(id: StringName, label: String, glyph: String, tip: String, action: Callable, flat := false) -> Widgets.PlayerButton:
	var b := Widgets.PlayerButton.new()
	b.name = str(id)
	b.id = id
	b.label = label
	b.glyph = glyph
	b.flat = flat
	b.tooltip_text = tip
	b.activated.connect(func(_b): action.call())
	add_child(b)
	buttons[id] = b
	return b

func _handle(handle_name: String, axes: Vector2, cursor: CursorShape, draw_grip := false) -> ResizeHandle:
	var h := ResizeHandle.new()
	h.name = handle_name
	h.axes = axes
	h.draw_grip = draw_grip
	h.mouse_default_cursor_shape = cursor
	h.tooltip_text = "Drag to resize the library" if draw_grip else ""
	h.resize_drag.connect(func(pixels, start): resize_requested.emit(pixels, axes, start))
	add_child(h)
	return h

func _notification(what):
	if what == NOTIFICATION_RESIZED and list != null: _layout()

# --- Geometry (base units) --------------------------------------------------------

func right_w() -> float: return size.x - RIGHT_X - 5.0
func list_rect() -> Rect2: return Rect2(RIGHT_X, LIST_Y, right_w() - SCROLL_W - 1.0, size.y - LIST_Y - 20.0)
func state_rect() -> Rect2: return Rect2(LEFT_X, SOURCES_Y + 4.0 * SOURCE_ROW + 5.0, LEFT_W, size.y - (SOURCES_Y + 4.0 * SOURCE_ROW + 5.0) - 20.0)
func bottom_y() -> float: return size.y - 15.0
func info_rect() -> Rect2: return Rect2(RIGHT_X + 62.0, bottom_y(), size.x - RIGHT_X - 62.0 - 18.0, 10.0)
func crumb_rect() -> Rect2: return Rect2(RIGHT_X, CRUMB_Y, right_w(), 10.0)

func _layout():
	var lr := list_rect()
	sources.position = Vector2(LEFT_X, SOURCES_Y)
	sources.size = Vector2(LEFT_W, 4.0 * SOURCE_ROW)
	search.position = Vector2(RIGHT_X, SEARCH_Y)
	search.size = Vector2(right_w(), 10.0)
	header.position = Vector2(RIGHT_X, HEADER_Y)
	header.size = Vector2(lr.size.x, LIST_Y - HEADER_Y)
	list.position = lr.position
	list.size = lr.size
	scrollbar.position = Vector2(lr.end.x + 1.0, lr.position.y)
	scrollbar.size = Vector2(SCROLL_W, lr.size.y)
	var place := func(id: StringName, rect: Rect2):
		buttons[id].position = rect.position
		buttons[id].size = rect.size
	place.call(&"close", Rect2(size.x - 14.0, 1.0, 12.0, 10.0))
	place.call(&"refresh", Rect2(LEFT_X, bottom_y(), LEFT_W, 10.0))
	var crumb := crumb_rect()
	place.call(&"back", Rect2(crumb.position.x, crumb.position.y, 10.0, 10.0))
	place.call(&"add_all", Rect2(crumb.end.x - 30.0, crumb.position.y, 30.0, 10.0))
	place.call(&"play_all", Rect2(crumb.end.x - 62.0, crumb.position.y, 30.0, 10.0))
	place.call(&"play", Rect2(RIGHT_X, bottom_y(), 28.0, 10.0))
	place.call(&"add", Rect2(RIGHT_X + 30.0, bottom_y(), 28.0, 10.0))
	var load_w := minf(92.0, lr.size.x - 8.0)
	place.call(&"load", Rect2(lr.position.x + (lr.size.x - load_w) * 0.5, lr.position.y + minf(lr.size.y * 0.5, 44.0), load_w, 14.0))
	grip.position = Vector2(size.x - 14.0, size.y - 14.0)
	grip.size = Vector2(12.0, 12.0)
	right_edge.position = Vector2(size.x - 3.0, STRIP_HEIGHT)
	right_edge.size = Vector2(3.0, size.y - STRIP_HEIGHT - 15.0)
	bottom_edge.position = Vector2(0.0, size.y - 3.0)
	bottom_edge.size = Vector2(size.x - 15.0, 3.0)
	_sync_scrollbar()
	_update_controls()
	queue_redraw()

# --- Library and view ------------------------------------------------------------

func _on_library_changed():
	if not is_same(model.library, bus.library):
		var keep := list.selected_keys() if list != null else []
		model.set_library(bus.library)
		_rows_changed(false)
		if not keep.is_empty(): list.select_keys(keep)
	# MusicBridge publishes the status right after the library: read it then.
	_capture_status.call_deferred()
	_update_playing()
	_update_controls()
	queue_redraw()

func _capture_status():
	library_status = str(bus.status)
	queue_redraw()

func set_source(src: String):
	model.set_source(src)
	search.text = ""
	_rows_changed()

func open_group(key: String):
	model.open_group(key)
	search.text = ""
	_rows_changed()

func go_back():
	if not model.back(): return
	search.text = model.query
	var hint := model.rows_hint
	_rows_changed()
	if hint >= 0: list.select_row(hint)
	list.grab_focus()

func set_query(text: String):
	if text == model.query: return
	model.set_query(text)
	_rows_changed()

func view_state() -> Dictionary: return model.view_state()

func apply_view_state(state: Dictionary):
	model.apply_view_state(state)
	if search != null: search.text = ""
	_rows_changed()

## The view's rows changed: reset selection and scroll, redraw everything.
func _rows_changed(reset := true):
	if list == null: return
	list.rows_changed(reset)
	_sync_scrollbar()
	_update_controls()
	header.queue_redraw()
	sources.queue_redraw()
	queue_redraw()

func _on_selection_changed():
	_update_controls()
	queue_redraw()

func _update_controls():
	if list == null: return
	var empty := model.is_empty()
	var has_selection := not list.selected_keys().is_empty()
	buttons[&"play"].enabled = has_selection
	buttons[&"add"].enabled = has_selection
	var drilled := not model.group.is_empty()
	for id in [&"back", &"play_all", &"add_all"]: buttons[id].visible = drilled
	var noun := model.group_noun()
	buttons[&"play_all"].tooltip_text = "Play the whole %s (replaces the playlist)" % noun
	buttons[&"add_all"].tooltip_text = "Add the whole %s to the playlist" % noun
	buttons[&"refresh"].enabled = bus.library_state != "refreshing"
	load_button.visible = empty and bus.library_state in ["empty", "error"]
	load_button.label = "TRY AGAIN" if bus.library_state == "error" else "LOAD MUSIC LIBRARY"
	for b in buttons.values(): b.queue_redraw()
	search.editable = not empty
	search.placeholder_text = _placeholder()
	header.visible = not empty

func _placeholder() -> String:
	if not model.group.is_empty(): return "Search this %s" % model.group_noun()
	return "Search %s" % LibraryModel.SOURCE_LABELS[model.source].to_lower()

func _update_playing():
	playing_id = ""
	if bus.track_index >= 0 and bus.track_index < bus.playlist.size():
		var entry: String = bus.playlist[bus.track_index]
		if entry.begins_with(bus.APPLE_MUSIC_PREFIX): playing_id = entry.trim_prefix(bus.APPLE_MUSIC_PREFIX).get_slice("|", 0)
		else: playing_id = str(bus.library.get("by_location", {}).get(entry, ""))
	if list != null: list.queue_redraw()

# --- Actions -------------------------------------------------------------------------

func dispatch(commands: Array):
	for c in commands: bus.command(c[0], c[1])

## PLAY / ADD / Enter on the selection.
func run(action: String):
	dispatch(model.commands(action, list.selected_keys()))

func _on_activated(key: String):
	if model.is_group_list():
		open_group(key)
		list.grab_focus()
	else:
		dispatch(model.commands("enqueue", [key]))

## Enter: tracks are added and the first plays; a single group opens.
func activate_selection():
	var keys := list.selected_keys()
	if keys.is_empty(): return
	if model.is_group_list():
		if keys.size() == 1: _on_activated(keys[0])
		else: run("enqueue")
	else: run("enqueue")

func _on_context(key: String, at: Vector2):
	build_menu(key)
	menu_requested.emit(list.position + at)

## Right-click menu for the selection (key = the row clicked).
func build_menu(key: String):
	menu.clear()
	_menu_actions.clear()
	var keys := list.selected_keys()
	if keys.is_empty(): keys = [key]
	var kind := model.row_kind()
	var what := ""
	if kind == "track": what = "song" if keys.size() == 1 else "%d songs" % keys.size()
	else: what = kind if keys.size() == 1 else "%d %ss" % [keys.size(), kind]
	_menu_item("Play %s" % what, func(): dispatch(model.commands("play", keys)))
	_menu_item("Add %s to playlist" % what, func(): dispatch(model.commands("add", keys)))
	if kind == "track" and keys.size() == 1:
		_menu_item("Add and play", func(): dispatch(model.commands("enqueue", keys)))
		var album := model.album_key_of(key)
		var artist := model.artist_of(key)
		menu.add_separator()
		if not album.is_empty() and model.group != album:
			var title := Style.elide(Style.ui_font(), model.group_label("album", album), 120.0, 6)
			_menu_item("Play album “%s”" % title, func(): dispatch(model.track_commands("play", model.group_track_ids("albums", album))))
			_menu_item("Add album “%s”" % title, func(): dispatch(model.track_commands("add", model.group_track_ids("albums", album))))
			_menu_item("Show album", func(): set_source("albums"); open_group(album))
		if model.has_group("artists", artist) and not (model.source == "artists" and model.group == artist):
			var name_text := Style.elide(Style.ui_font(), artist, 120.0, 6)
			_menu_item("Play artist “%s”" % name_text, func(): dispatch(model.track_commands("play", model.group_track_ids("artists", artist))))
			_menu_item("Add artist “%s”" % name_text, func(): dispatch(model.track_commands("add", model.group_track_ids("artists", artist))))
			_menu_item("Show artist", func(): set_source("artists"); open_group(artist))
	elif kind != "track" and keys.size() == 1:
		_menu_item("Open %s" % kind, func(): open_group(keys[0]))

func _menu_item(text: String, action: Callable):
	var id := _menu_actions.size()
	menu.add_item(text, id)
	_menu_actions[id] = action

func _on_menu(id: int):
	if _menu_actions.has(id): _menu_actions[id].call()

## Test hook: the menu entry labels.
func menu_labels() -> PackedStringArray:
	var out := PackedStringArray()
	for i in menu.item_count:
		if not menu.is_item_separator(i): out.append(menu.get_item_text(i))
	return out

func menu_run(label: String) -> bool:
	for i in menu.item_count:
		if menu.get_item_text(i) == label:
			_on_menu(menu.get_item_id(i))
			return true
	return false

func _on_search_input(event):
	if not event is InputEventKey or not event.pressed: return
	match event.keycode:
		KEY_ESCAPE:
			if search.text.is_empty(): search.release_focus()
			search.text = ""
			set_query("")
			search.accept_event()
		KEY_DOWN, KEY_ENTER, KEY_KP_ENTER:
			list.grab_focus()
			if list.selected_keys().is_empty() and not model.rows.is_empty(): list.select_row(0)
			search.accept_event()

# --- Text ------------------------------------------------------------------------------

func crumb_text() -> String:
	var label: String = LibraryModel.SOURCE_LABELS[model.source].to_upper()
	if model.group.is_empty(): return "%s  ·  %s" % [label, _count_text(model.rows.size(), model.source)]
	var kind: String = LibraryModel.KINDS[model.source]
	var name := model.group_label(kind, model.group)
	var detail := model.group_detail(kind, model.group)
	return name + ("  —  " + detail if not detail.is_empty() else "")

func _count_text(n: int, src: String) -> String:
	var total: int = model.counts().get(src, 0)
	var noun: String = {"songs": "song", "artists": "artist", "albums": "album", "playlists": "playlist"}[src]
	var count := LibraryModel._thousands(n) if n == total else "%s of %s" % [LibraryModel._thousands(n), LibraryModel._thousands(total)]
	return "%s %s%s" % [count, noun, "" if total == 1 else "s"]

func info_text() -> String:
	if model.is_empty(): return ""
	var keys := list.selected_keys()
	if keys.is_empty():
		if model.is_group_list(): return ""
		return "%s songs  ·  %s" % [LibraryModel._thousands(model.rows.size()), Fmt.time_text(model.total_seconds(model.rows))]
	var ids := model.ids_for(keys)
	return "%d selected  ·  %s" % [keys.size(), Fmt.time_text(model.total_seconds(ids))]

func state_info() -> Dictionary:
	return LibraryModel.state_info(bus.library_state, library_status, int(bus.library.get("updated", 0)), int(bus.library.get("count", 0)))

func empty_message() -> PackedStringArray:
	match bus.library_state:
		"refreshing": return PackedStringArray(["Reading your Music library…", "macOS may ask for access to Media & Apple Music."])
		"error": return PackedStringArray(["Couldn't read your Music library.", "Allow Oozic in System Settings › Privacy & Security › Media & Apple Music, then try again."])
	return PackedStringArray(["Your Music library isn't loaded yet.", "Oozic reads it from the Music app. macOS asks once for access to Media & Apple Music."])

# --- Drawing ------------------------------------------------------------------------------

func _process(delta):
	if bus != null and bus.library_state == "refreshing" and is_visible_in_tree():
		_blink = fmod(_blink + delta, 1.0)
		queue_redraw()

func _draw():
	Style.brushed(self, Rect2(Vector2.ZERO, size))
	var strip := Rect2(0, 0, size.x, STRIP_HEIGHT)
	Style.vgradient(self, strip, Style.STRIP_TOP, Style.STRIP_BOTTOM)
	Style.hline(self, 0, size.x, 0.25, Style.BEVEL_LIGHT)
	Style.hline(self, 0, size.x, STRIP_HEIGHT - 0.25, Style.EDGE)
	var caption := "M U S I C   L I B R A R Y"
	var bold := Style.bold_font()
	var ui := Style.ui_font()
	var mono := Style.mono_font()
	var cw := bold.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 6).x
	var cx := (size.x - 16.0 - cw) * 0.5
	Style.text(self, bold, Rect2(cx, 0, cw + 1, STRIP_HEIGHT), caption, 6, Style.LABEL)
	for y in [4.75, 7.25]:
		Style.groove(self, 6, cx - 6, y)
		Style.groove(self, cx + cw + 6, size.x - 18, y)
	# Left: sources (drawn by SourceList) in a sunken well, then the state box.
	Style.sunken(self, Rect2(sources.position, sources.size))
	_draw_state(state_rect())
	# Right: breadcrumb, list well, info.
	var crumb := crumb_rect()
	var drilled := not model.group.is_empty()
	var text_x := crumb.position.x + (12.0 if drilled else 1.0)
	var text_end := crumb.end.x - (64.0 if drilled else 0.0)
	if not model.is_empty():
		var label := crumb_text()
		if drilled:
			var src: String = LibraryModel.SOURCE_LABELS[model.source].to_upper() + "  ›  "
			var sw := bold.get_string_size(src, HORIZONTAL_ALIGNMENT_LEFT, -1, 5).x
			Style.text(self, bold, Rect2(text_x, crumb.position.y, sw, crumb.size.y), src, 5, Style.LABEL_DIM)
			Style.text(self, ui, Rect2(text_x + sw, crumb.position.y, text_end - text_x - sw - 2.0, crumb.size.y), Style.elide(ui, label, text_end - text_x - sw - 2.0, 6), 6, Style.LIST_TEXT)
		else:
			Style.text(self, bold, Rect2(text_x, crumb.position.y, text_end - text_x, crumb.size.y), Style.elide(bold, label, text_end - text_x, 5), 5, Style.LABEL)
	var lr := list_rect()
	var well := Rect2(Vector2(lr.position.x, HEADER_Y), Vector2(lr.size.x + SCROLL_W + 1.0, lr.end.y - HEADER_Y))
	draw_rect(well, Style.LIST_BG)
	Style.sunken(self, well)
	var info := info_text()
	if not info.is_empty():
		var ir := info_rect()
		Style.text(self, mono, ir, Style.elide(mono, info, ir.size.x, 5), 5, Style.LABEL, HORIZONTAL_ALIGNMENT_RIGHT)
	draw_rect(Rect2(Vector2(0.25, 0.25), size - Vector2(0.5, 0.5)), Style.EDGE, false, 0.5)

func _draw_state(rect: Rect2):
	if rect.size.y < 12.0: return
	Style.lcd(self, rect)
	var info := state_info()
	var tone: String = info.tone
	var led: Color = {"dim": Style.LCD_DIM, "busy": Style.LCD_TEXT, "ok": Style.LED_ON, "error": Color("#ff3b2f")}[tone]
	if tone == "busy" and _blink > 0.5: led = Style.LED_OFF
	var y := rect.position.y + 2.0
	draw_circle(Vector2(rect.position.x + 4.5, y + 3.5), 1.4, led)
	if tone != "dim": draw_circle(Vector2(rect.position.x + 4.5, y + 3.5), 2.2, Color(led, 0.2))
	Style.text(self, Style.bold_font(), Rect2(rect.position.x + 8.0, y, rect.size.x - 10.0, 7.0), info.word, 5, Style.LCD_TEXT if tone != "dim" else Style.LCD_DIM)
	y += 8.5
	var font := Style.ui_font()
	var width := rect.size.x - 6.0
	var line_h := 6.4
	var room := int(floor((rect.end.y - y - 1.0) / line_h))
	if room <= 0: return
	var hint: String = info.hint
	var hint_lines := Style.wrap(font, hint, width, 5, 99) if not hint.is_empty() else PackedStringArray()
	var detail_lines := Style.wrap(font, str(info.detail), width, 5, maxi(room - mini(hint_lines.size(), room / 2), 1))
	for line in detail_lines:
		if room <= 0: return
		Style.text(self, font, Rect2(rect.position.x + 3.0, y, width, line_h), line, 5, Style.LCD_DIM.lightened(0.15))
		y += line_h
		room -= 1
	if hint_lines.size() > room: hint_lines = Style.wrap(font, hint, width, 5, room)
	for line in hint_lines:
		if room <= 0: return
		Style.text(self, font, Rect2(rect.position.x + 3.0, y, width, line_h), line, 5, Style.LCD_TEXT)
		y += line_h
		room -= 1

func _gui_input(event):
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		drag_started.emit()
		accept_event()

func _sync_scrollbar():
	if scrollbar == null: return
	scrollbar.max_value = maxf(list.content_height(), list.size.y)
	scrollbar.page = list.size.y
	scrollbar.step = 0.0
	scrollbar.set_value_no_signal(list.scroll)
	scrollbar.visible = list.content_height() > list.size.y + 0.5

## Every interactive child that is shown (hit-area tests).
func interactive_controls() -> Array:
	var out: Array = [sources, search, header, list, grip]
	for b in buttons.values():
		if b.visible: out.append(b)
	return out

func _style_scrollbar(bar: VScrollBar):
	var track := StyleBoxFlat.new()
	track.bg_color = Style.LIST_BG
	var grabber := StyleBoxFlat.new()
	grabber.bg_color = Color("#4a525c")
	grabber.set_corner_radius_all(1)
	var hot := grabber.duplicate()
	hot.bg_color = Color("#6a7480")
	bar.add_theme_stylebox_override("scroll", track)
	bar.add_theme_stylebox_override("scroll_focus", track)
	bar.add_theme_stylebox_override("grabber", grabber)
	bar.add_theme_stylebox_override("grabber_highlight", hot)
	bar.add_theme_stylebox_override("grabber_pressed", hot)
	bar.focus_mode = Control.FOCUS_NONE

func _style_search(edit: LineEdit):
	var normal := StyleBoxFlat.new()
	normal.bg_color = Style.LCD_BG
	normal.content_margin_left = 3.0
	normal.content_margin_right = 2.0
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
	edit.add_theme_color_override("font_uneditable_color", Style.LCD_DIM)
	edit.add_theme_color_override("font_placeholder_color", Color(Style.LCD_DIM, 0.8))
	edit.add_theme_color_override("caret_color", Style.LCD_TEXT)
	edit.add_theme_color_override("selection_color", Color(Style.LCD_ACCENT, 0.35))
	edit.add_theme_constant_override("caret_width", 1)
	edit.add_theme_constant_override("minimum_character_width", 0)
	edit.custom_minimum_size = Vector2.ZERO

## Column rects for a list width: [{id, label, x, w, align}], badge first for tracks.
func column_layout(width: float) -> Array:
	var cols := model.columns(width < NARROW_WIDTH)
	var out := []
	var x := 1.0
	if not model.is_group_list():
		out.append({"id": "badge", "label": "", "x": x, "w": 8.0, "align": HORIZONTAL_ALIGNMENT_CENTER})
		x += 9.0
	var gap := 3.0
	var fixed := 0.0
	var flex := 0.0
	for c in cols:
		if c.has("width"): fixed += c.width
		else: flex += c.flex
	var free := maxf(width - x - fixed - gap * cols.size() - 1.0, 0.0)
	for c in cols:
		var w: float = c.width if c.has("width") else free * c.flex / maxf(flex, 0.001)
		out.append({"id": c.id, "label": c.label, "x": x, "w": w, "align": c.get("align", HORIZONTAL_ALIGNMENT_LEFT)})
		x += w + gap
	return out

# --- Pieces -----------------------------------------------------------------------------------

## Songs / Artists / Albums / Playlists with counts.
class SourceList extends Control:
	signal selected(source: String)
	var panel
	var hover := -1

	func _init():
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_exited.connect(func(): hover = -1; queue_redraw())

	func _draw():
		draw_rect(Rect2(Vector2.ZERO, size), Style.LIST_BG)
		var counts: Dictionary = panel.model.counts()
		var glyphs := {"songs": "note", "artists": "person", "albums": "disc", "playlists": "list"}
		for i in LibraryModel.SOURCES.size():
			var src: String = LibraryModel.SOURCES[i]
			var rect := Rect2(0, i * SOURCE_ROW, size.x, SOURCE_ROW)
			var on: bool = panel.model.source == src
			if on: draw_rect(rect, Style.LIST_SELECTED_BG)
			elif i == hover: draw_rect(rect, Style.LIST_HOVER_BG)
			if on: draw_rect(Rect2(rect.position, Vector2(1.0, rect.size.y)), Style.LIST_CURRENT)
			var color := Style.LIST_CURRENT if on else Style.LIST_TEXT
			Style.glyph(self, glyphs[src], rect.position + Vector2(6.5, SOURCE_ROW * 0.5), 0.8, color if on else Style.LABEL)
			var count := LibraryModel._thousands(int(counts[src])) if not panel.model.is_empty() else ""
			var mono := Style.mono_font()
			var cw := mono.get_string_size(count, HORIZONTAL_ALIGNMENT_LEFT, -1, 5).x
			Style.text(self, Style.ui_font(), Rect2(13.0, rect.position.y, size.x - 16.0 - cw, rect.size.y), LibraryModel.SOURCE_LABELS[src], 6, color)
			Style.text(self, mono, Rect2(size.x - cw - 2.5, rect.position.y, cw, rect.size.y), count, 5, Style.LIST_NUMBER if not on else Style.LCD_DIM)

	func _gui_input(event):
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			var i := int(event.position.y / SOURCE_ROW)
			if i >= 0 and i < LibraryModel.SOURCES.size(): selected.emit(LibraryModel.SOURCES[i])
			accept_event()
		elif event is InputEventMouseMotion:
			var i := int(event.position.y / SOURCE_ROW)
			if i != hover:
				hover = i
				queue_redraw()

	func _get_tooltip(_at: Vector2) -> String: return ""

## Clickable column headers: ascending ▲, descending ▼, third click natural order.
class HeaderRow extends Control:
	signal sort_requested(column: String)
	var panel

	func _init():
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		tooltip_text = "Click a column to sort (again: reverse, third time: original order)"

	func _draw():
		Style.vgradient(self, Rect2(Vector2.ZERO, size), Style.STRIP_TOP, Style.STRIP_BOTTOM)
		Style.hline(self, 0, size.x, size.y - 0.25, Style.EDGE)
		var font := Style.bold_font()
		for c in panel.column_layout(size.x):
			if c.label.is_empty(): continue
			var label: String = c.label
			var active: bool = panel.model.sort_key == c.id
			var color := Style.LCD_TEXT if active else Style.LABEL
			var arrow := (" ▼" if panel.model.sort_desc else " ▲") if active else ""
			Style.text(self, font, Rect2(c.x, 0, c.w, size.y), Style.elide(font, label + arrow, c.w, 5), 5, color, c.align)
			if c.x > 2.0: Style.vline(self, c.x - 1.5, 1.5, size.y - 1.5, Style.GROOVE_DARK)

	func column_at(x: float) -> String:
		for c in panel.column_layout(size.x):
			if c.id != "badge" and x >= c.x - 1.5 and x < c.x + c.w + 1.5: return c.id
		return ""

	func _gui_input(event):
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			var column := column_at(event.position.x)
			if not column.is_empty(): sort_requested.emit(column)
			accept_event()

## Drag handle reporting screen-pixel travel on its axes.
class ResizeHandle extends Control:
	signal resize_drag(pixels: Vector2, start: bool)
	var axes := Vector2.ONE
	var draw_grip := false
	var _from := Vector2.ZERO
	var _active := false

	func _init():
		mouse_filter = Control.MOUSE_FILTER_STOP

	func _draw():
		if draw_grip: Style.glyph(self, "grip", size * 0.5, minf(size.x, size.y) / 9.0, Style.LABEL_DIM)

	func _gui_input(event):
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			_active = event.pressed
			_from = _screen(event)
			if event.pressed: resize_drag.emit(Vector2.ZERO, true)
			accept_event()
		elif event is InputEventMouseMotion and _active:
			resize_drag.emit((_screen(event) - _from) * axes, false)
			accept_event()

	## Screen-space position, so the window growing under the cursor does not feed back.
	func _screen(event: InputEvent) -> Vector2:
		if DisplayServer.get_name() == "headless": return event.global_position
		return Vector2(DisplayServer.mouse_get_position())

## The rows: virtualised (only the visible rows are drawn and measured), with
## multi-select (click, Cmd/Ctrl-click toggles, Shift-click / Shift+arrows
## extend), keyboard navigation, double-click / Enter to act, right-click menu.
class LibraryList extends Control:
	signal activated(key: String)
	signal context_requested(key: String, at: Vector2)
	signal back_requested()
	signal scrolled()
	signal selection_changed()
	const ROW_HEIGHT := 9.0
	const FONT_SIZE := 6
	var panel
	var scroll := 0.0
	var hover_row := -1
	## Row index the keyboard is on, and the Shift anchor.
	var cursor := -1
	var anchor := -1
	var selected := {}
	## Rows drawn in the last _draw (virtualisation check).
	var drawn_rows := 0

	func _init():
		mouse_filter = Control.MOUSE_FILTER_STOP
		focus_mode = Control.FOCUS_ALL
		clip_contents = true
		mouse_exited.connect(func(): hover_row = -1; queue_redraw())

	func rows() -> Array: return panel.model.rows

	func rows_changed(reset: bool):
		if reset:
			selected.clear()
			cursor = -1
			anchor = -1
			scroll = 0.0
		else:
			var keep := {}
			for key in selected:
				if panel.model.rows.has(key): keep[key] = true
			selected = keep
			cursor = mini(cursor, rows().size() - 1)
		set_scroll(scroll)
		queue_redraw()
		selection_changed.emit()

	## Selected keys in display order.
	func selected_keys() -> Array:
		if selected.is_empty(): return []
		var out := []
		for key in rows():
			if selected.has(key): out.append(key)
		return out

	func select_keys(keys: Array):
		selected.clear()
		for key in keys:
			if rows().has(key): selected[key] = true
		queue_redraw()
		selection_changed.emit()

	func select_row(row: int, extend := false, toggle := false):
		var list := rows()
		if row < 0 or row >= list.size(): return
		if extend and anchor >= 0:
			selected.clear()
			for r in range(mini(anchor, row), maxi(anchor, row) + 1): selected[list[r]] = true
		elif toggle:
			if selected.has(list[row]): selected.erase(list[row])
			else: selected[list[row]] = true
			anchor = row
		else:
			selected.clear()
			selected[list[row]] = true
			anchor = row
		cursor = row
		ensure_visible(row)
		queue_redraw()
		selection_changed.emit()

	func select_all():
		selected.clear()
		for key in rows(): selected[key] = true
		queue_redraw()
		selection_changed.emit()

	func content_height() -> float: return rows().size() * ROW_HEIGHT
	func max_scroll() -> float: return maxf(content_height() - size.y, 0.0)

	func set_scroll(value: float):
		var clamped := clampf(value, 0.0, max_scroll())
		if is_equal_approx(clamped, scroll):
			scroll = clamped
			return
		scroll = clamped
		queue_redraw()
		scrolled.emit()

	func row_at(y: float) -> int:
		var row := int(floor((y + scroll) / ROW_HEIGHT))
		return row if row >= 0 and row < rows().size() else -1

	func row_rect(row: int) -> Rect2: return Rect2(0, row * ROW_HEIGHT - scroll, size.x, ROW_HEIGHT)

	## First and last row index that intersect the view (x > y when none).
	func visible_range() -> Vector2i:
		if rows().is_empty(): return Vector2i(0, -1)
		return Vector2i(int(floor(scroll / ROW_HEIGHT)), mini(rows().size() - 1, int(ceil((scroll + size.y) / ROW_HEIGHT)) - 1))

	func ensure_visible(row: int):
		if row < 0: return
		var top := row * ROW_HEIGHT
		if top < scroll: set_scroll(top)
		elif top + ROW_HEIGHT > scroll + size.y: set_scroll(top + ROW_HEIGHT - size.y)

	func _draw():
		draw_rect(Rect2(Vector2.ZERO, size), Style.LIST_BG)
		drawn_rows = 0
		var model = panel.model
		var font := Style.ui_font()
		var mono := Style.mono_font()
		if model.is_empty():
			_draw_message(panel.empty_message())
			return
		var list: Array = rows()
		if list.is_empty():
			var what: String = LibraryModel.SOURCE_LABELS[model.source].to_lower() if model.group.is_empty() else "songs"
			_draw_message(PackedStringArray(["No %s match “%s”." % [what, model.query]]) if not model.query.is_empty() else PackedStringArray(["This %s is empty." % model.group_noun()]) if not model.group.is_empty() else PackedStringArray(["No %s." % what]))
			return
		var cols: Array = panel.column_layout(size.x)
		var range_ := visible_range()
		var is_tracks: bool = not model.is_group_list()
		for row in range(range_.x, range_.y + 1):
			drawn_rows += 1
			var key: String = list[row]
			var rect := row_rect(row)
			var playing: bool = is_tracks and key == panel.playing_id
			if selected.has(key): draw_rect(rect, Style.LIST_SELECTED_BG)
			elif playing: draw_rect(rect, Style.LIST_CURRENT_BG)
			elif row == hover_row: draw_rect(rect, Style.LIST_HOVER_BG)
			elif row % 2 == 1: draw_rect(rect, Color(1, 1, 1, 0.014))
			if row == cursor and has_focus(): draw_rect(rect.grow(-0.25), Color(Style.LCD_ACCENT, 0.45), false, 0.5)
			if playing: draw_rect(Rect2(rect.position, Vector2(1.0, rect.size.y)), Style.LIST_CURRENT)
			for c in cols:
				var cell := Rect2(c.x, rect.position.y, c.w, rect.size.y)
				if c.id == "badge":
					var streaming: bool = model.is_streaming(key)
					Style.glyph(self, "stream" if streaming else "file", cell.get_center() + Vector2(0.6 if streaming else 0.0, 0), 0.62, Color(Style.LCD_DIM, 0.95) if streaming else Style.LABEL)
					continue
				var value: String = model.cell(key, c.id)
				if value.is_empty(): continue
				var primary: bool = c.id in ["title", "name"]
				var numeric: bool = c.id in ["time", "tracks", "track"]
				var f := mono if numeric else font
				var fs := FONT_SIZE - 1 if numeric else FONT_SIZE
				var color := Style.LIST_CURRENT if playing else (Style.LIST_TEXT if primary else Style.LIST_TEXT.darkened(0.25))
				if numeric and not playing: color = Style.LIST_NUMBER
				Style.text(self, f, cell, Style.elide(f, value, c.w, fs), fs, color, c.align)
		if has_focus(): draw_rect(Rect2(Vector2(0.25, 0.25), size - Vector2(0.5, 0.5)), Color(Style.LCD_ACCENT, 0.35), false, 0.5)

	func _draw_message(lines: PackedStringArray):
		var font := Style.ui_font()
		var y := 8.0
		for i in lines.size():
			for line in Style.wrap(font, lines[i], size.x - 16.0, 6 if i == 0 else 5, 3):
				Style.text(self, font, Rect2(8, y, size.x - 16.0, 8.0), line, 6 if i == 0 else 5, Style.LIST_TEXT if i == 0 else Style.LIST_FAILED, HORIZONTAL_ALIGNMENT_CENTER)
				y += 8.0 if i == 0 else 6.5
			y += 3.0

	func _get_tooltip(at: Vector2) -> String:
		var row := row_at(at.y)
		if row < 0: return ""
		var model = panel.model
		var key: String = rows()[row]
		if model.is_group_list(): return "%d tracks  ·  double-click to open" % model.group_count(model.row_kind(), key)
		if model.is_streaming(key): return "Apple Music  ·  plays in the Music app"
		return "Local file  ·  " + str(model.tracks.get(key, {}).get("location", ""))

	func _gui_input(event):
		if event is InputEventMouseButton and event.pressed:
			match event.button_index:
				MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
					set_scroll(scroll + (-3.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 3.0) * ROW_HEIGHT * maxf(event.factor, 1.0))
				MOUSE_BUTTON_LEFT:
					grab_focus()
					var row := row_at(event.position.y)
					if row >= 0:
						var multi: bool = event.meta_pressed or event.ctrl_pressed
						select_row(row, event.shift_pressed, multi)
						if event.double_click and not event.shift_pressed and not multi: activated.emit(rows()[row])
					elif not event.shift_pressed:
						selected.clear()
						selection_changed.emit()
						queue_redraw()
				MOUSE_BUTTON_RIGHT:
					grab_focus()
					var row := row_at(event.position.y)
					if row >= 0:
						if not selected.has(rows()[row]): select_row(row)
						context_requested.emit(rows()[row], event.position)
			accept_event()
		elif event is InputEventMouseMotion:
			var row := row_at(event.position.y)
			if row != hover_row:
				hover_row = row
				queue_redraw()
		elif event is InputEventKey and event.pressed:
			if _key(event): accept_event()

	## Keys this list keeps from the player's hotkeys while focused.
	func wants_key(event: InputEventKey) -> bool:
		if event.keycode == KEY_A and (event.meta_pressed or event.ctrl_pressed): return true
		if event.meta_pressed or event.ctrl_pressed: return false
		return event.keycode in [KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_HOME, KEY_END, KEY_PAGEUP, KEY_PAGEDOWN, KEY_ENTER, KEY_KP_ENTER, KEY_BACKSPACE, KEY_ESCAPE]

	func _key(event: InputEventKey) -> bool:
		var count := rows().size()
		var page := maxi(int(size.y / ROW_HEIGHT) - 1, 1)
		if event.keycode == KEY_A and (event.meta_pressed or event.ctrl_pressed):
			select_all()
			return true
		match event.keycode:
			KEY_ENTER, KEY_KP_ENTER:
				panel.activate_selection()
				return true
			KEY_LEFT, KEY_BACKSPACE:
				back_requested.emit()
				return true
			KEY_RIGHT:
				if panel.model.is_group_list() and cursor >= 0 and cursor < count: activated.emit(rows()[cursor])
				return true
			KEY_ESCAPE:
				selected.clear()
				selection_changed.emit()
				queue_redraw()
				return true
		if count == 0: return false
		var target := -1
		match event.keycode:
			KEY_UP: target = maxi(cursor - 1, 0) if cursor >= 0 else 0
			KEY_DOWN: target = mini(cursor + 1, count - 1) if cursor >= 0 else 0
			KEY_HOME: target = 0
			KEY_END: target = count - 1
			KEY_PAGEUP: target = maxi(cursor - page, 0)
			KEY_PAGEDOWN: target = mini(maxi(cursor, 0) + page, count - 1)
			_: return false
		select_row(target, event.shift_pressed)
		return true
