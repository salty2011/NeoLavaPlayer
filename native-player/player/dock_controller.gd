extends Node
## Winamp-style docking for the player's panel windows (main, playlist,
## library) and the visualiser (the root window). Owns where every panel is:
## logical rects in screen pixels, which panel is docked to which
## (dock_layout.gd attachments), the drag and resize sessions, reset and
## save/restore. Sizes come from PlayerWindow (base units x ui_scale); the
## visualiser's size is kept here in base units.
##
## Dragging: a press on a panel's title strip or body calls begin_drag(id).
## From then on _process reads the mouse in screen coordinates
## (DisplayServer.mouse_get_position) every frame and sets the position of
## every moving window in that same frame, so a docked group moves as one
## (no chasing of window-moved notifications, which lag on macOS). Dragging
## main moves its whole group; dragging any other panel moves it alone
## (detaching it); edges snap to panels and screen edges within the magnet,
## and on release the panel docks to whatever it touches.
const Dock = preload("res://player/dock_layout.gd")
const Fmt = preload("res://player/player_format.gd")
const WindowLayout = preload("res://window_layout.gd")

## A drag or resize ended, or panels were shown/hidden (for saving).
signal layout_changed()

const VISUALISER_MIN := Vector2(200, 120)

var windows := {}
var rects := {}
var attachments := {}
## Panel open (the playlist and library can be closed; main and the
## visualiser are always "shown" here: hiding the player or minimising the
## visualiser takes them out of docking without changing this).
var shown := {"main": true, "playlist": false, "library": false, "visualiser": true}
## Pixels per base unit (PlayerWindow.ui_scale) and the screen scale (magnet).
var scale := 1.0
var screen_scale := 1.0
var visualiser_units := Vector2(464, 290)
## Tests: screens to use instead of the connected ones.
var screens_override: Array = []
## Follow the real mouse during a drag (off in tests that drive drag_to).
var poll_mouse := true
var _drag := {}
var _vis_resize_from := Vector2.ZERO
## The visualiser is fullscreen or minimised: put it back in its docked place
## (which may have moved with main's group meanwhile) when it returns.
var _vis_away := false
## After it returns, macOS may still finish its own animation and put back
## another frame: keep re-applying the docked rect until this time (ms).
var _vis_settle_until := 0
var _headless := DisplayServer.get_name() == "headless"

func _init():
	name = "Dock"
	process_priority = -10

func register(id: String, w: Window) -> void:
	windows[id] = w
	if not rects.has(id): rects[id] = Rect2i(w.position, w.size)
	if id == "visualiser": rects[id].size = visualiser_pixels()

func has_panel(id: String) -> bool: return windows.has(id) and is_instance_valid(windows[id])

## Taking part in docking now: open, its window shown and windowed.
func is_docked(id: String) -> bool:
	if not has_panel(id) or not bool(shown.get(id, false)): return false
	var w: Window = windows[id]
	return w.visible and windowed(w)

## Windowed (not minimised or fullscreen). Headless servers report the root
## window as minimised; their windows are only ever logical, so they count.
func windowed(w: Window) -> bool:
	return _headless or w.mode == Window.MODE_WINDOWED

func docked_ids() -> Array:
	return Dock.PANELS.filter(func(id): return is_docked(id))

func screens() -> Array:
	if not screens_override.is_empty(): return screens_override
	if _headless: return [Rect2i(0, 0, 8000, 4000)]
	return WindowLayout.connected_screens()

func magnet() -> int: return Dock.magnet_pixels(screen_scale)

## macOS places windows in points: on a 2x screen an odd pixel position is
## rounded. Keep anchors on whole points so the windows land where asked.
func align(v: Vector2i) -> Vector2i:
	var step := maxi(int(round(screen_scale)), 1)
	return Vector2i(floori(float(v.x) / step) * step, floori(float(v.y) / step) * step)

func visualiser_pixels() -> Vector2i: return Fmt.window_pixels(visualiser_units, scale)

## Main's group: every panel docked to it, directly or through others.
func group() -> Array: return Dock.group_of("main", attachments)

# --- Applying ------------------------------------------------------------------

## Read back where the OS has the shown windows (only they can have moved).
func sync_from_windows() -> void:
	if _headless: return
	for id in docked_ids():
		var w: Window = windows[id]
		rects[id] = Rect2i(w.position, w.size)

## Move (and for the visualiser, size) every windowed panel to its rect.
func apply() -> void:
	for id in windows:
		if not has_panel(id): continue
		var w: Window = windows[id]
		if not windowed(w): continue
		var r: Rect2i = rects[id]
		if id == "visualiser" and w.size != r.size: w.size = r.size
		if w.position != r.position: w.position = r.position

## A panel's size changed (scale, user size, toggles): keep its top-left.
func set_panel_size(id: String, size: Vector2i) -> void:
	if not rects.has(id): rects[id] = Rect2i(Vector2i.ZERO, size)
	rects[id].size = size

## Re-place every docked panel against its parent (after a size or scale
## change, a panel shown or hidden, a restore), keep main's group on screen.
func relayout(keep_on_screen := true) -> void:
	if rects.has("visualiser"): rects.visualiser.size = visualiser_pixels()
	rects = Dock.reflow(rects, shown, attachments, scale)
	if keep_on_screen: _keep_group_on_screen("main")
	apply()

func _keep_group_on_screen(root: String) -> void:
	if not rects.has(root): return
	var ids: Array = Dock.group_of(root, attachments).filter(func(id): return rects.has(id) and (is_docked(id) or (_headless and bool(shown.get(id, false)))))
	if ids.is_empty(): return
	var anchor: Rect2i = rects[root]
	var shift := Dock.keep_on_screen_shift(Dock.bounds(rects, ids), screens(), anchor)
	if shift != Vector2i.ZERO: shift = align(anchor.position + shift) - anchor.position
	if shift == Vector2i.ZERO: return
	for id in Dock.group_of(root, attachments):
		if rects.has(id): rects[id] = Rect2i(rects[id].position + shift, rects[id].size)

# --- Dragging --------------------------------------------------------------------

func is_dragging() -> bool: return not _drag.is_empty()

## Start moving `id` with the mouse at `mouse` (screen pixels).
func begin_drag(id: String, mouse = null) -> void:
	if not has_panel(id): return
	sync_from_windows()
	var at: Vector2i = mouse if mouse is Vector2i else DisplayServer.mouse_get_position()
	var members: Array = group() if id == "main" else [id]
	var start := {}
	for m in members:
		if rects.has(m): start[m] = rects[m]
	_drag = {"id": id, "mouse": at, "start": start}

## Move the dragged panel (or main's group) so the grab point follows `mouse`,
## snapping to other panels and screen edges. All windows move in this call.
func drag_to(mouse: Vector2i) -> void:
	if _drag.is_empty(): return
	var delta: Vector2i = align(mouse - _drag.mouse)
	var start: Dictionary = _drag.start
	var moving := []
	for m in start:
		if is_docked(m): moving.append(Rect2i(start[m].position + delta, start[m].size))
	var targets := []
	for id in docked_ids():
		if not start.has(id): targets.append(rects[id])
	var snap := Dock.snap_delta(moving, targets, screens(), magnet())
	for m in start: rects[m] = Rect2i(start[m].position + delta + snap, start[m].size)
	apply()

## Drop: the dragged panel docks to what it touches (main's group picks up
## panels it now touches).
func end_drag() -> void:
	if _drag.is_empty(): return
	var id: String = _drag.id
	_drag = {}
	attachments = Dock.update_attachments(rects, shown, attachments, docked_ids(), scale, [] if id == "main" else [id])
	relayout(false)
	layout_changed.emit()

func _process(_delta):
	if has_panel("visualiser"):
		var vis: Window = windows.visualiser
		if not windowed(vis): _vis_away = true
		elif _vis_away and vis.borderless:
			_vis_away = false
			_vis_settle_until = Time.get_ticks_msec() + 2000
			relayout(false)
		elif Time.get_ticks_msec() < _vis_settle_until and _drag.is_empty() and Rect2i(vis.position, vis.size) != rects.visualiser:
			apply()
	if _drag.is_empty() or _headless or not poll_mouse: return
	if DisplayServer.mouse_get_button_state() & MOUSE_BUTTON_MASK_LEFT or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		drag_to(DisplayServer.mouse_get_position())
	else:
		drag_to(DisplayServer.mouse_get_position())
		end_drag()

# --- Resizing and showing -------------------------------------------------------------

## `id` was resized to `size` px from its right/bottom edges: panels against
## the moved edges shift with them.
func panel_resized(id: String, size: Vector2i) -> void:
	if not rects.has(id): return
	sync_from_windows()
	var old: Rect2i = rects[id]
	var new := Rect2i(old.position, size)
	if is_docked(id): rects = Dock.push_neighbours(rects, docked_ids(), id, old, new)
	else: rects[id] = new
	attachments = Dock.update_attachments(rects, shown, attachments, docked_ids(), scale)
	rects = Dock.reflow(rects, shown, attachments, scale)
	apply()

## Visualiser frame grip/edges: mouse travel in screen pixels -> base units.
func resize_visualiser(pixels: Vector2, axes: Vector2, start: bool) -> void:
	if start:
		_vis_resize_from = visualiser_units
		return
	var target := _vis_resize_from + pixels / scale
	set_visualiser_units(Vector2(target.x if axes.x > 0 else visualiser_units.x, target.y if axes.y > 0 else visualiser_units.y))

func set_visualiser_units(units: Vector2) -> void:
	var usable := Vector2(screens()[0].size) / scale if not screens().is_empty() else Vector2(8000, 4000)
	visualiser_units = Vector2(clampf(units.x, VISUALISER_MIN.x, maxf(usable.x, VISUALISER_MIN.x)), clampf(units.y, VISUALISER_MIN.y, maxf(usable.y, VISUALISER_MIN.y)))
	if has_panel("visualiser"): panel_resized("visualiser", visualiser_pixels())

## Open or close a panel: it takes its docked place (panels docked beyond
## it slide out or back in) and main's group stays on screen.
func set_shown(id: String, on: bool) -> void:
	shown[id] = on
	if on: _make_room(id)
	relayout(true)
	layout_changed.emit()

## A panel shown where another panel now sits, docked to the same parent
## edge (it was docked there while this one was closed): that panel docks
## beyond this one instead.
func _make_room(id: String) -> void:
	var a: Dictionary = attachments.get(id, {})
	if a.is_empty(): return
	var placed := Dock.reflow(rects, shown, attachments, scale)
	for other in attachments.keys():
		if other == id or not is_docked(other): continue
		var b: Dictionary = attachments[other]
		if b.to != a.to or b.side != a.side: continue
		if not placed[id].intersects(placed[other]): continue
		attachments[other] = {"to": id, "side": b.side, "offset": float(b.offset) - float(a.offset)}

# --- Layouts ---------------------------------------------------------------------------

## The default arrangement (dock_layout.gd default_layout), centred on the
## screen main is on. Sizes of the player panels are PlayerWindow's to reset.
func reset_layout(column_height: float) -> void:
	var screen: Rect2i = _screen_of("main")
	var usable := Vector2(screen.size) / scale
	var d := Dock.default_layout(column_height, usable)
	attachments = d.attachments
	visualiser_units = d.visualiser_units
	rects.main = Rect2i(Vector2i.ZERO, rects.main.size)
	if rects.has("visualiser"): rects.visualiser.size = visualiser_pixels()
	rects = Dock.reflow(rects, shown, attachments, scale)
	var ids: Array = group().filter(func(id): return rects.has(id) and bool(shown.get(id, false)))
	var area := Dock.bounds(rects, ids)
	var origin := screen.position + ((screen.size - area.size) / 2).max(Vector2i.ZERO)
	var shift := align(origin) - area.position
	for id in rects: rects[id] = Rect2i(rects[id].position + shift, rects[id].size)
	relayout(true)
	layout_changed.emit()

func _screen_of(id: String) -> Rect2i:
	var list := screens()
	if list.is_empty(): return Rect2i(0, 0, 1920, 1080)
	if has_panel(id) and not _headless and screens_override.is_empty():
		var s: int = windows[id].current_screen
		if s >= 0 and s < list.size(): return list[s]
	var best: Rect2i = list[0]
	if rects.has(id):
		for s: Rect2i in list:
			if s.intersection(rects[id]).get_area() > best.intersection(rects[id]).get_area(): best = s
	return best

## {version, attachments, positions, visualiser_units} for [windows] dock.
func save_state() -> Dictionary:
	sync_from_windows()
	var positions := {}
	for id in rects: positions[id] = [rects[id].position.x, rects[id].position.y]
	return {"version": 2, "attachments": attachments.duplicate(true), "positions": positions, "visualiser_units": [visualiser_units.x, visualiser_units.y]}

## Restore from Dock.load_dock(saved [windows]). Returns false when there is
## no saved main position (first run): the caller resets the layout then.
func restore_state(loaded: Dictionary) -> bool:
	attachments = loaded.get("attachments", {}).duplicate(true)
	if loaded.has("visualiser_units"):
		var u: Vector2 = loaded.visualiser_units
		visualiser_units = Vector2(maxf(u.x, VISUALISER_MIN.x), maxf(u.y, VISUALISER_MIN.y))
	var positions: Dictionary = loaded.get("positions", {})
	if not positions.has("main"): return false
	for id in positions:
		if rects.has(id): rects[id] = Rect2i(Vector2i(int(positions[id][0]), int(positions[id][1])), rects[id].size)
	if rects.has("visualiser"): rects.visualiser.size = visualiser_pixels()
	rects = Dock.reflow(rects, shown, attachments, scale)
	# Each group back on a connected screen (a monitor may have gone).
	_keep_group_on_screen("main")
	for id in Dock.PANELS:
		if id != "main" and rects.has(id) and not attachments.has(id): _keep_group_on_screen(id)
	apply()
	return true
