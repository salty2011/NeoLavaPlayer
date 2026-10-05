extends Window
## One player panel (the playlist or the music library) in its own
## borderless OS window, docked to the others by player/dock_controller.gd.
## It renders the panel in base units at the player's ui_scale (content
## scale), like the main window, and hands keys, file drops and close
## requests to the PlayerWindow that owns it.
const Fmt = preload("res://player/player_format.gd")

var panel_id := ""
var panel: Control
## The PlayerWindow (key routing, close policy).
var player

func _init(id: String, content: Control, owner_window) -> void:
	panel_id = id
	panel = content
	player = owner_window
	name = id.capitalize() + "Window"
	title = "Oozic " + id.capitalize()
	borderless = true
	transparent = false
	unresizable = true
	transient = false
	exclusive = false
	wrap_controls = false
	visible = false
	content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	content_scale_aspect = Window.CONTENT_SCALE_ASPECT_IGNORE

func _ready() -> void:
	var background := ColorRect.new()
	background.name = "Background"
	background.color = Color("#07080a")
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	add_child(panel)
	files_dropped.connect(func(paths): player.bus.command(&"add_paths", {"paths": paths}))
	close_requested.connect(func(): player.close_panel(panel_id))

## Size the window for `units` (base units) at `ui_scale`; returns the pixels.
func set_units(units: Vector2, ui_scale: float) -> Vector2i:
	content_scale_factor = ui_scale
	var pixels := Fmt.window_pixels(units, ui_scale)
	min_size = Vector2i.ZERO
	max_size = Vector2i.ZERO
	size = pixels
	panel.position = Vector2.ZERO
	panel.size = units
	return pixels

func _input(event: InputEvent) -> void:
	player.handle_window_key(event, self)
