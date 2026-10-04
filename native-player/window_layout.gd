extends RefCounted
## Window placement persistence for the two OS windows ([windows] section of
## user://settings.cfg). Saved rects are clamped to the screens connected now,
## so a window saved on a monitor that has since gone comes back on screen.
const AppSettings = preload("res://app_settings.gd")
## Minimum part of a saved window that must still be visible on its screen.
const MIN_VISIBLE := Vector2i(64, 48)

## screens: Array[Rect2i] usable rects, index = screen id.
## Returns {rect: Rect2i, screen: int, moved: bool}.
static func clamp_rect(rect: Rect2i, screen: int, screens: Array) -> Dictionary:
	if screens.is_empty(): return {"rect": rect, "screen": 0, "moved": false}
	var chosen := -1
	if screen >= 0 and screen < screens.size():
		var overlap: Rect2i = rect.intersection(screens[screen])
		if overlap.size.x >= mini(MIN_VISIBLE.x, rect.size.x) and overlap.size.y >= mini(MIN_VISIBLE.y, rect.size.y): chosen = screen
	if chosen < 0:
		var best_area := 0
		for i in screens.size():
			var overlap: Rect2i = rect.intersection(screens[i])
			if overlap.get_area() > best_area:
				best_area = overlap.get_area()
				chosen = i
	var moved := chosen < 0 or chosen != screen
	if chosen < 0:
		chosen = 0
		var area: Rect2i = screens[0]
		var size := Vector2i(mini(rect.size.x, area.size.x), mini(rect.size.y, area.size.y))
		return {"rect": Rect2i(area.position + (area.size - size) / 2, size), "screen": 0, "moved": true}
	var target: Rect2i = screens[chosen]
	var fitted := Rect2i(rect.position, Vector2i(mini(rect.size.x, target.size.x), mini(rect.size.y, target.size.y)))
	var clamped_position := Vector2i(
		clampi(fitted.position.x, target.position.x, target.end.x - fitted.size.x),
		clampi(fitted.position.y, target.position.y, target.end.y - fitted.size.y))
	if clamped_position != fitted.position or fitted.size != rect.size: moved = true
	return {"rect": Rect2i(clamped_position, fitted.size), "screen": chosen, "moved": moved}

static func connected_screens() -> Array:
	var screens := []
	for i in DisplayServer.get_screen_count(): screens.append(DisplayServer.screen_get_usable_rect(i))
	return screens

static func to_array(rect: Rect2i) -> Array: return [rect.position.x, rect.position.y, rect.size.x, rect.size.y]

static func from_array(values) -> Rect2i:
	if not values is Array or values.size() != 4: return Rect2i()
	return Rect2i(int(values[0]), int(values[1]), int(values[2]), int(values[3]))

static func load_state(path: String = AppSettings.PATH) -> Dictionary:
	return AppSettings.load_section(path, "windows")

static func save_state(values: Dictionary, path: String = AppSettings.PATH) -> int:
	return AppSettings.save_section(path, "windows", values)

## Restore a saved rect for window w (a Window node). Returns the applied info
## or {} when nothing was saved. Never applies on headless display servers.
## restore_size false keeps the window's own size (the skinned controller).
static func restore(w: Window, saved_rect, saved_screen, restore_size := true) -> Dictionary:
	var rect := from_array(saved_rect)
	if rect.size.x <= 0 or DisplayServer.get_name() == "headless": return {}
	if not restore_size: rect.size = w.size
	var result := clamp_rect(rect, int(saved_screen), connected_screens())
	w.position = result.rect.position
	if restore_size: w.size = result.rect.size
	return result
