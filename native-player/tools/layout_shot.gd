extends RefCounted
## Proof-capture helper: one image of several docked windows, each window's
## own viewport capture pasted at its dock position (screen pixels), on a
## plain desktop-like background. Used by tools/capture_docking.gd,
## capture_player.gd and capture_library.gd.

## dock: PlayerWindow.dock; ids: panels to include (closed ones are skipped).
static func composite(dock, ids: Array, margin := 0) -> Image:
	var shown := []
	for id in ids:
		if dock.has_panel(id) and dock.is_docked(id): shown.append(id)
	if shown.is_empty(): return null
	var bounds: Rect2i = dock.rects[shown[0]]
	for id in shown: bounds = bounds.merge(dock.rects[id])
	var size := bounds.size + Vector2i(margin, margin) * 2
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	# Desktop: a dark slate gradient, so the panels' edges read clearly.
	for y in size.y:
		var t := float(y) / maxf(size.y - 1, 1)
		image.fill_rect(Rect2i(0, y, size.x, 1), Color("#2a3140").lerp(Color("#141820"), t))
	for id in shown:
		var w: Window = dock.windows[id]
		var shot := w.get_texture().get_image()
		shot.convert(Image.FORMAT_RGB8)
		shot.convert(Image.FORMAT_RGBA8)
		var at: Vector2i = dock.rects[id].position - bounds.position + Vector2i(margin, margin)
		image.blit_rect(shot, Rect2i(Vector2i.ZERO, shot.get_size().min(dock.rects[id].size)), at)
	return image

## The player's own panels (main, playlist, library) as one image.
static func player(dock) -> Image:
	return composite(dock, ["main", "playlist", "library"])
