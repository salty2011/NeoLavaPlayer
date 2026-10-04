extends Window
## Player window: a borderless OS window holding the main panel, below it
## the playlist panel and to their right the music library panel (the same
## window grows; see docs/WINDOWS_AND_BUS.md for why these are not docked
## second windows). Everything is drawn in base
## units and rendered at ui_scale = screen scale x user size through
## content_scale_factor, so it is sharp on any screen.
##
## Talks to the rest of the app only through PlayerBus: every control sends a
## bus command; this window answers the window-level ones (dialogs, menus,
## playlist and library panels, size) in _on_command.
const Fmt = preload("res://player/player_format.gd")
const MainPanel = preload("res://player/player_main_panel.gd")
const PlaylistPanel = preload("res://player/player_playlist_panel.gd")
const LibraryPanel = preload("res://player/player_library_panel.gd")
const Style = preload("res://player/player_style.gd")
const SettingsWindow = preload("res://settings_window.gd")
const SceneCatalog = preload("res://scene_catalog.gd")
const AppSettings = preload("res://app_settings.gd")
const WindowLayout = preload("res://window_layout.gd")
const PlayerBusScript = preload("res://player_bus.gd")

const PIN_SCENE_ID := 1000
const UNPIN_SCENE_ID := 1001
const SIZE_ID := 100
const LIBRARY_MENU_ID := 15
## Keys the focused playlist keeps for itself (selection, Enter, Delete, Alt+arrows).
const LIST_KEYS := [KEY_UP, KEY_DOWN, KEY_DELETE, KEY_BACKSPACE, KEY_ENTER, KEY_KP_ENTER, KEY_HOME, KEY_END, KEY_PAGEUP, KEY_PAGEDOWN]

var bus
var main_panel: MainPanel
var playlist_panel: PlaylistPanel
var library_panel: LibraryPanel
## Body under the main panel when the library is taller than the player column.
var filler: Control
var settings_window: Window
var picker: FileDialog
var folder_picker: FileDialog
var m3u_picker: FileDialog
var system_menu: PopupMenu
var scene_menu: PopupMenu
## Persisted by main.gd (Settings > Player size / [player] ui_size).
var user_size := Fmt.DEFAULT_USER_SIZE
var screen_scale := 1.0
var ui_scale := 1.0
var playlist_open := false
var playlist_height := Fmt.PLAYLIST_DEFAULT_HEIGHT
var library_open := false
var library_width := Fmt.LIBRARY_DEFAULT_WIDTH
var library_height := Fmt.LIBRARY_DEFAULT_HEIGHT
var _library_resize_from := Vector2.ZERO
## Save the size choice to settings.cfg (off in tests).
var persist := false
var settings_path := AppSettings.PATH
## Headless runs never open native dialogs; the last request is kept here.
var last_dialog := ""
var _resize_from := 0.0
var _scale_check := 0.0
var _manual_drag := false
var _drag_offset := Vector2i.ZERO
var _pending_layout := {}
## Minimise in progress: 1 = waiting to minimise, 2 = minimised (restore the
## borderless style once the window is back).
var _minimize_phase := 0
var _minimize_deadline := 0

func _init():
	name = "Controller"
	title = "Oozic Player"
	borderless = true
	transparent = false
	unresizable = true
	transient = false
	exclusive = false
	wrap_controls = false
	visible = false
	content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	content_scale_aspect = Window.CONTENT_SCALE_ASPECT_IGNORE

func _ready():
	bus = PlayerBusScript.instance()
	var background := ColorRect.new()
	background.name = "Background"
	background.color = Color("#07080a")
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	main_panel = MainPanel.new()
	main_panel.drag_started.connect(_start_window_drag)
	add_child(main_panel)
	playlist_panel = PlaylistPanel.new()
	playlist_panel.position = Vector2(0, Fmt.MAIN_SIZE.y)
	playlist_panel.resize_requested.connect(_on_resize_drag)
	playlist_panel.drag_started.connect(_start_window_drag)
	add_child(playlist_panel)
	filler = Filler.new()
	filler.name = "Filler"
	filler.drag_started.connect(_start_window_drag)
	add_child(filler)
	library_panel = LibraryPanel.new()
	library_panel.position = Vector2(Fmt.MAIN_SIZE.x, 0)
	library_panel.resize_requested.connect(_on_library_resize)
	library_panel.drag_started.connect(_start_window_drag)
	library_panel.menu_requested.connect(func(anchor): _popup_at(library_panel.menu, library_panel.position + anchor))
	add_child(library_panel)
	_build_dialogs()
	files_dropped.connect(func(paths): bus.command(&"add_paths", {"paths": paths}))
	close_requested.connect(func(): bus.command(&"close_controller"))
	bus.command_requested.connect(_on_command)
	apply_scale()
	if not _pending_layout.is_empty(): apply_layout_state(_pending_layout)
	_publish_windows()

# --- Scale and size -------------------------------------------------------------

func current_screen_scale() -> float:
	if DisplayServer.get_name() == "headless": return 1.0
	var screen := current_screen if is_inside_tree() else DisplayServer.SCREEN_OF_MAIN_WINDOW
	return maxf(DisplayServer.screen_get_scale(screen), 1.0)

## Recompute ui_scale and the window size; keeps the top-left corner.
func apply_scale():
	screen_scale = current_screen_scale()
	ui_scale = Fmt.ui_scale(screen_scale, user_size)
	content_scale_factor = ui_scale
	_apply_size()
	if system_menu: _scale_popups()
	if settings_window != null: settings_window.apply_scale(screen_scale, user_size)

func base_size() -> Vector2:
	return Fmt.window_base_size(playlist_open, playlist_height, library_open, library_width, library_height)

func _apply_size():
	playlist_height = clampf(playlist_height, Fmt.PLAYLIST_MIN_HEIGHT, _max_playlist_height())
	var screen := _usable_base()
	library_width = clampf(library_width, Fmt.LIBRARY_MIN_WIDTH, maxf(screen.x - Fmt.MAIN_SIZE.x, Fmt.LIBRARY_MIN_WIDTH))
	library_height = clampf(library_height, Fmt.LIBRARY_MIN_HEIGHT, maxf(screen.y, Fmt.LIBRARY_MIN_HEIGHT))
	var base := base_size()
	var pixels := Fmt.window_pixels(base, ui_scale)
	min_size = Vector2i.ZERO
	max_size = Vector2i.ZERO
	size = pixels
	playlist_panel.visible = playlist_open
	playlist_panel.size = Vector2(Fmt.MAIN_SIZE.x, playlist_height)
	var column := Fmt.total_height(playlist_open, playlist_height)
	filler.position = Vector2(0, column)
	filler.size = Vector2(Fmt.MAIN_SIZE.x, maxf(base.y - column, 0.0))
	filler.visible = library_open and base.y - column > 0.01
	library_panel.visible = library_open
	library_panel.size = Vector2(library_width, base.y)
	keep_on_screen()

## Usable screen size in base units (huge when headless).
func _usable_base() -> Vector2:
	if DisplayServer.get_name() == "headless" or not is_inside_tree(): return Vector2(8000, 4000)
	return Vector2(DisplayServer.screen_get_usable_rect(current_screen).size) / ui_scale

## Tallest playlist that still fits the usable screen height.
func _max_playlist_height() -> float:
	if DisplayServer.get_name() == "headless" or not is_inside_tree(): return 4000.0
	var usable := DisplayServer.screen_get_usable_rect(current_screen)
	return maxf(usable.size.y / ui_scale - Fmt.MAIN_SIZE.y, Fmt.PLAYLIST_MIN_HEIGHT)

func keep_on_screen():
	if DisplayServer.get_name() == "headless" or not visible: return
	var result := WindowLayout.clamp_rect(Rect2i(position, size), current_screen, WindowLayout.connected_screens())
	if result.moved: position = result.rect.position

func set_user_size(value: float, save := true):
	user_size = Fmt.nearest_user_size(value)
	apply_scale()
	if save and persist: AppSettings.save_player_size(user_size, settings_path)
	bus.publish_status("Player size " + Fmt.size_label(user_size))
	_publish_windows()

func set_playlist_open(open: bool):
	playlist_open = open
	_apply_size()
	_publish_windows()

func set_playlist_height(height: float):
	playlist_height = height
	_apply_size()

func set_library_open(open: bool):
	library_open = open
	_apply_size()
	_publish_windows()
	if open and visible and DisplayServer.get_name() != "headless": library_panel.list.grab_focus.call_deferred()

func set_library_size(width: float, height: float):
	library_width = width
	library_height = height
	_apply_size()

## Library grip / edges: screen pixels -> base units, per axis.
func _on_library_resize(pixels: Vector2, axes: Vector2, start: bool):
	if start:
		_library_resize_from = Vector2(library_width, library_panel.size.y)
		return
	var target := _library_resize_from + pixels / ui_scale
	set_library_size(target.x if axes.x > 0 else library_width, target.y if axes.y > 0 else library_height)

func _on_resize_drag(pixels_y: float, start: bool):
	if start:
		_resize_from = playlist_height
		return
	set_playlist_height(_resize_from + pixels_y / ui_scale)

func _notification(what):
	if what == NOTIFICATION_WM_DPI_CHANGE and main_panel != null: apply_scale.call_deferred()

func _process(delta):
	# Moving to a screen with a different scale: re-scale (some platforms send
	# no DPI notification for borderless windows).
	_scale_check += delta
	if _scale_check >= 0.5:
		_scale_check = 0.0
		if not is_equal_approx(current_screen_scale(), screen_scale): apply_scale()
	if _minimize_phase > 0: _track_minimize()
	if _manual_drag:
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT): position = DisplayServer.mouse_get_position() - _drag_offset
		else: _manual_drag = false

func _start_window_drag():
	if DisplayServer.get_name() == "headless": return
	if has_method("start_drag"):
		start_drag()
	else:
		_manual_drag = true
		_drag_offset = DisplayServer.mouse_get_position() - position

## {drawer_open, playlist_height, time_remaining, vis_mode, library_open,
## library_width, library_height, library_view} for [windows].
func layout_state() -> Dictionary:
	return {"drawer_open": playlist_open, "playlist_height": playlist_height, "time_remaining": main_panel.time_display.remaining if main_panel else false, "vis_mode": main_panel.vis.mode if main_panel else "spectrum",
		"library_open": library_open, "library_width": library_width, "library_height": library_height, "library_view": library_panel.view_state() if library_panel else {}}

func apply_layout_state(values: Dictionary):
	playlist_open = bool(values.get("drawer_open", playlist_open))
	playlist_height = float(values.get("playlist_height", playlist_height))
	library_open = bool(values.get("library_open", library_open))
	library_width = float(values.get("library_width", library_width))
	library_height = float(values.get("library_height", library_height))
	_pending_layout = values
	if main_panel == null: return
	main_panel.time_display.remaining = bool(values.get("time_remaining", false))
	var vis_mode := str(values.get("vis_mode", "spectrum"))
	if vis_mode in ["spectrum", "scope", "off"]: main_panel.vis.mode = vis_mode
	if values.get("library_view") is Dictionary: library_panel.apply_view_state(values.library_view)
	_apply_size()
	_publish_windows()

func _publish_windows():
	bus.library_open = library_open
	bus.publish_windows(bus.visualiser_visible, bus.visualiser_fullscreen, visible, playlist_open)

# --- Bus commands answered by the window ----------------------------------------

func _on_command(command: StringName, args: Dictionary):
	match command:
		&"toggle_drawer": set_playlist_open(not playlist_open)
		&"add_tracks": _popup_dialog(picker, "add_tracks")
		&"add_directory": _popup_dialog(folder_picker, "add_directory")
		&"remove_track": remove_selected()
		&"open_settings": open_settings()
		&"import_m3u_dialog": open_m3u_dialog(false)
		&"export_m3u_dialog": open_m3u_dialog(true)
		&"show_player_menu": popup_system_menu()
		&"show_scene_menu": popup_scene_menu()
		&"set_player_size": set_user_size(float(args.get("size", user_size)))
		# LIB / Ctrl+Shift+L / ≡ menu. Opening also sends open_library, which
		# MusicBridge answers with its once-per-session refresh.
		&"toggle_library":
			if library_open: set_library_open(false)
			else: bus.command(&"open_library")
		&"open_library":
			if not library_open: set_library_open(true)
		&"close_library": set_library_open(false)
		&"minimize":
			if args.get("source", "") == "controller": minimize_player()

## macOS will not miniaturise a borderless window, so the player takes its
## title bar back for the trip to the Dock and drops it again on return.
func minimize_player():
	if DisplayServer.get_name() == "headless": return
	borderless = false
	_minimize_phase = 1
	_minimize_deadline = Time.get_ticks_msec() + 3000
	mode = Window.MODE_MINIMIZED

func _track_minimize():
	if _minimize_phase == 1 and mode == Window.MODE_MINIMIZED: _minimize_phase = 2
	# Back on screen, or the minimise never happened: borderless again.
	elif (_minimize_phase == 2 and mode != Window.MODE_MINIMIZED) or (_minimize_phase == 1 and Time.get_ticks_msec() > _minimize_deadline):
		_minimize_phase = 0
		borderless = true
		apply_scale()

func remove_selected():
	var index: int = playlist_panel.selected_index() if playlist_open else -1
	if index < 0: index = bus.track_index
	if index >= 0: bus.command(&"remove_index", {"index": index})

func open_settings():
	if settings_window == null:
		settings_window = SettingsWindow.new()
		add_child(settings_window)
	settings_window.apply_scale(screen_scale, user_size)
	settings_window.open()

# --- Dialogs ---------------------------------------------------------------------

func _build_dialogs():
	picker = FileDialog.new()
	picker.file_mode = FileDialog.FILE_MODE_OPEN_FILES
	picker.access = FileDialog.ACCESS_FILESYSTEM
	picker.use_native_dialog = true
	picker.title = "Add tracks"
	picker.filters = PackedStringArray(PlayerBusScript.AUDIO_FILE_FILTERS)
	picker.files_selected.connect(func(paths): bus.command(&"add_paths", {"paths": paths}))
	add_child(picker)
	folder_picker = FileDialog.new()
	folder_picker.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	folder_picker.access = FileDialog.ACCESS_FILESYSTEM
	folder_picker.use_native_dialog = true
	folder_picker.title = "Add directory (includes sub-directories)"
	folder_picker.dir_selected.connect(func(path): bus.command(&"add_directory_path", {"path": path, "recursive": true}))
	add_child(folder_picker)
	m3u_picker = FileDialog.new()
	m3u_picker.access = FileDialog.ACCESS_FILESYSTEM
	m3u_picker.use_native_dialog = true
	m3u_picker.filters = PackedStringArray(["*.m3u,*.m3u8 ; M3U playlist"])
	m3u_picker.file_selected.connect(func(path):
		if m3u_picker.file_mode == FileDialog.FILE_MODE_SAVE_FILE: bus.command(&"export_m3u", {"path": path})
		else: bus.command(&"import_m3u", {"path": path}))
	add_child(m3u_picker)
	system_menu = PopupMenu.new()
	system_menu.name = "SystemMenu"
	system_menu.id_pressed.connect(_on_system_menu)
	add_child(system_menu)
	scene_menu = PopupMenu.new()
	scene_menu.name = "SceneMenu"
	scene_menu.id_pressed.connect(_on_scene_menu)
	add_child(scene_menu)
	_scale_popups()

func _popup_dialog(dialog: FileDialog, label: String):
	last_dialog = label
	if DisplayServer.get_name() == "headless": return
	dialog.popup_centered_ratio(0.75)

func open_m3u_dialog(save: bool):
	m3u_picker.file_mode = FileDialog.FILE_MODE_SAVE_FILE if save else FileDialog.FILE_MODE_OPEN_FILE
	m3u_picker.title = "Export playlist" if save else "Import playlist"
	m3u_picker.current_file = "Oozic playlist.m3u" if save else ""
	_popup_dialog(m3u_picker, "export_m3u" if save else "import_m3u")

# --- Menus -------------------------------------------------------------------------

## Menus at a readable size: the screen scale, grown a little with the player.
func popup_scale() -> float:
	return screen_scale * clampf(user_size * 0.6, 1.0, 1.8)

func _scale_popups():
	for menu in [system_menu, scene_menu, library_panel.menu if library_panel else null]:
		if menu != null: menu.content_scale_factor = popup_scale()

func build_system_menu():
	system_menu.clear()
	system_menu.add_item("Hide visualiser" if bus.visualiser_visible else "Show visualiser", 1)
	system_menu.add_item("Fullscreen visualiser (F11)", 2)
	system_menu.add_item("Choose scene…", 10)
	system_menu.add_item("Next scene (Page Down)", 3)
	system_menu.add_item("Previous scene (Page Up)", 11)
	system_menu.add_separator()
	system_menu.add_check_item("Playlist (Ctrl+L)", 4)
	system_menu.set_item_checked(system_menu.get_item_index(4), playlist_open)
	system_menu.add_check_item("Music library (Ctrl+Shift+L)", LIBRARY_MENU_ID)
	system_menu.set_item_checked(system_menu.get_item_index(LIBRARY_MENU_ID), library_open)
	system_menu.add_item("Add files… (Ctrl+A)", 12)
	system_menu.add_item("Add folder… (Shift+A)", 13)
	system_menu.add_item("Import playlist (.m3u)…", 5)
	system_menu.add_item("Export playlist (.m3u)…", 6)
	system_menu.add_item("Clear playlist", 14)
	system_menu.add_separator("Player size")
	for i in Fmt.USER_SIZES.size():
		system_menu.add_radio_check_item(Fmt.size_label(Fmt.USER_SIZES[i]), SIZE_ID + i)
		system_menu.set_item_checked(system_menu.item_count - 1, is_equal_approx(Fmt.USER_SIZES[i], user_size))
	system_menu.add_separator()
	system_menu.add_item("Settings… (Ctrl+T)", 7)
	system_menu.add_item("Minimise (Ctrl+I)", 8)
	system_menu.add_item("Exit (Ctrl+Q)", 9)

## Base-unit anchor -> screen popup rect.
func _popup_at(menu: PopupMenu, anchor: Vector2):
	if DisplayServer.get_name() == "headless": return
	menu.popup(Rect2i(position + Vector2i((anchor * ui_scale).round()), Vector2i.ZERO))

func popup_system_menu():
	build_system_menu()
	var b: Control = main_panel.buttons[&"menu"]
	_popup_at(system_menu, b.position + Vector2(0, b.size.y))

func _on_system_menu(id: int):
	match id:
		1: bus.command(&"toggle_visualiser")
		2: bus.command(&"toggle_fullscreen")
		3: bus.command(&"next_scene")
		11: bus.command(&"previous_scene")
		10: bus.command(&"show_scene_menu")
		4: bus.command(&"toggle_drawer")
		LIBRARY_MENU_ID: bus.command(&"toggle_library")
		12: bus.command(&"add_tracks")
		13: bus.command(&"add_directory")
		5: bus.command(&"import_m3u_dialog")
		6: bus.command(&"export_m3u_dialog")
		14: bus.command(&"clear_playlist")
		7: bus.command(&"open_settings")
		8: bus.command(&"minimize", {"source": "controller"})
		9: bus.command(&"quit_app")
		_:
			if id >= SIZE_ID and id < SIZE_ID + Fmt.USER_SIZES.size(): bus.command(&"set_player_size", {"size": Fmt.USER_SIZES[id - SIZE_ID]})

func build_scene_menu():
	scene_menu.clear()
	for i in bus.scenes.size():
		scene_menu.add_radio_check_item(SceneCatalog.label(bus.scenes[i]), i)
		scene_menu.set_item_checked(i, i == bus.scene_index)
	scene_menu.add_separator()
	scene_menu.add_item("Pin scene to this track", PIN_SCENE_ID)
	scene_menu.add_item("Unpin scene from this track", UNPIN_SCENE_ID)

func popup_scene_menu():
	build_scene_menu()
	var line: Control = main_panel.scene_line
	_popup_at(scene_menu, line.position + Vector2(0, line.size.y))

func _on_scene_menu(id: int):
	if id == PIN_SCENE_ID: bus.command(&"pin_scene")
	elif id == UNPIN_SCENE_ID: bus.command(&"unpin_scene")
	else: bus.command(&"select_scene", {"index": id})

# --- Keys ----------------------------------------------------------------------------

func _input(event):
	if not event is InputEventKey or not event.pressed: return
	var focus := gui_get_focus_owner()
	# Typing in the search field never triggers player or scene keys.
	if focus is LineEdit: return
	if focus == playlist_panel.list and event.keycode in LIST_KEYS and not event.ctrl_pressed and not event.meta_pressed: return
	if focus == library_panel.list and library_panel.list.wants_key(event): return
	if bus.handle_key(event, "controller"): set_input_as_handled()

## Plain body under the main panel when the library is taller than the
## player column (playlist closed or short). Drags the window.
class Filler extends Control:
	signal drag_started()

	func _init():
		mouse_filter = Control.MOUSE_FILTER_STOP

	func _draw():
		Style.brushed(self, Rect2(Vector2.ZERO, size))
		draw_rect(Rect2(Vector2(0.25, 0.25), size - Vector2(0.5, 0.5)), Style.EDGE, false, 0.5)
		Style.raised(self, Rect2(Vector2(0.75, 0.75), size - Vector2(1.5, 1.5)), 0.4)

	func _gui_input(event):
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			drag_started.emit()
			accept_event()
