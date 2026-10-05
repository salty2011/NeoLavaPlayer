extends RefCounted
## Pure docking maths for the Winamp-style panel windows (no nodes, no bus;
## player/dock_controller.gd applies the results, test_docking.gd checks them).
##
## Panels: "main" (the player), "playlist", "library", "visualiser". Rects are
## screen pixels (Rect2i). A panel docked to another has an attachment
## {to, side, offset}: `side` is where the panel sits relative to its parent
## ("right" = flush against the parent's right edge), `offset` is its position
## along that edge in base units (so it survives a scale change). Attachments
## form trees; "main" is never attached, so everything chained to it is its
## group. A hidden panel keeps its attachment and collapses to zero thickness
## along it: a panel docked beyond it slides in, and slides back out when it
## is shown again (like the old single window growing and shrinking).
const PANELS := ["main", "playlist", "library", "visualiser"]
## Edges closer than this (px) count as touching (rounding at fractional scales).
const TOUCH := 2
## Snap distance in points (multiplied by the screen scale for pixels).
const MAGNET_POINTS := 10

static func magnet_pixels(screen_scale: float) -> int:
	return int(round(MAGNET_POINTS * maxf(screen_scale, 1.0)))

## Length of the overlap of [a0, a1) and [b0, b1); negative = gap.
static func overlap(a0: int, a1: int, b0: int, b1: int) -> int:
	return mini(a1, b1) - maxi(a0, b0)

# --- Snapping ----------------------------------------------------------------

## The shift to apply to every rect in `moving` (they move together) so that
## an edge snaps to a panel in `targets` or a screen in `screens`, per axis,
## when within `magnet` px. Panels snap outer edge to outer edge (side by
## side) and flush (aligned edges); screens snap from the inside.
static func snap_delta(moving: Array, targets: Array, screens: Array, magnet: int) -> Vector2i:
	var best := Vector2i(magnet + 1, magnet + 1)
	var shift := Vector2i.ZERO
	for m: Rect2i in moving:
		for t: Rect2i in targets:
			# Side by side or aligned horizontally: only when the panels are level
			# (their vertical ranges overlap or nearly do).
			if overlap(m.position.y, m.end.y, t.position.y, t.end.y) > -magnet:
				for d in [t.end.x - m.position.x, t.position.x - m.end.x, t.position.x - m.position.x, t.end.x - m.end.x]:
					if absi(d) < best.x:
						best.x = absi(d)
						shift.x = d
			if overlap(m.position.x, m.end.x, t.position.x, t.end.x) > -magnet:
				for d in [t.end.y - m.position.y, t.position.y - m.end.y, t.position.y - m.position.y, t.end.y - m.end.y]:
					if absi(d) < best.y:
						best.y = absi(d)
						shift.y = d
		for s: Rect2i in screens:
			if not m.intersects(s): continue
			for d in [s.position.x - m.position.x, s.end.x - m.end.x]:
				if absi(d) < best.x:
					best.x = absi(d)
					shift.x = d
			for d in [s.position.y - m.position.y, s.end.y - m.end.y]:
				if absi(d) < best.y:
					best.y = absi(d)
					shift.y = d
	return Vector2i(shift.x if best.x <= magnet else 0, shift.y if best.y <= magnet else 0)

# --- Touching and attachments -------------------------------------------------

## Where `child` sits against `parent` ("left", "right", "top", "bottom"), or
## "" when they do not share an edge (corners do not count).
static func side_of(child: Rect2i, parent: Rect2i, tol := TOUCH) -> String:
	if overlap(child.position.y, child.end.y, parent.position.y, parent.end.y) > tol:
		if absi(child.position.x - parent.end.x) <= tol: return "right"
		if absi(child.end.x - parent.position.x) <= tol: return "left"
	if overlap(child.position.x, child.end.x, parent.position.x, parent.end.x) > tol:
		if absi(child.position.y - parent.end.y) <= tol: return "bottom"
		if absi(child.end.y - parent.position.y) <= tol: return "top"
	return ""

## Attachment of `child` to `parent` from their current rects ({} if apart).
static func attachment_for(child: Rect2i, parent: Rect2i, parent_id: String, scale: float) -> Dictionary:
	var side := side_of(child, parent)
	if side.is_empty(): return {}
	var along := float(child.position.y - parent.position.y) if side in ["left", "right"] else float(child.position.x - parent.position.x)
	return {"to": parent_id, "side": side, "offset": along / scale}

## Effective rect of a panel as a parent: a hidden one has no thickness along
## the side its child docks to.
static func effective(rect: Rect2i, shown: bool, side: String) -> Rect2i:
	if shown: return rect
	if side == "right": return Rect2i(rect.position, Vector2i(0, rect.size.y))
	if side == "left": return Rect2i(rect.position + Vector2i(rect.size.x, 0), Vector2i(0, rect.size.y))
	if side == "bottom": return Rect2i(rect.position, Vector2i(rect.size.x, 0))
	if side == "top": return Rect2i(rect.position + Vector2i(0, rect.size.y), Vector2i(rect.size.x, 0))
	return rect

## Top-left of a panel of `size` docked by `attachment` to `parent` (effective rect).
static func docked_position(size: Vector2i, parent: Rect2i, attachment: Dictionary, scale: float) -> Vector2i:
	var along := int(round(float(attachment.get("offset", 0.0)) * scale))
	match str(attachment.get("side", "")):
		"right": return Vector2i(parent.end.x, parent.position.y + along)
		"left": return Vector2i(parent.position.x - size.x, parent.position.y + along)
		"bottom": return Vector2i(parent.position.x + along, parent.end.y)
		"top": return Vector2i(parent.position.x + along, parent.position.y - size.y)
	return parent.position

## Parent chain of `id` (nearest first). Stops at a cycle.
static func chain(id: String, attachments: Dictionary) -> Array:
	var out := []
	var at := id
	while attachments.has(at):
		at = str(attachments[at].get("to", ""))
		if at.is_empty() or at in out or at == id: break
		out.append(at)
	return out

static func creates_cycle(child: String, parent: String, attachments: Dictionary) -> bool:
	return parent == child or child in chain(parent, attachments)

## Every panel whose attachment chain reaches `root` (transitively docked),
## `root` first. Hidden panels are included: they move with their parent.
static func group_of(root: String, attachments: Dictionary) -> Array:
	var out := [root]
	for id in PANELS:
		if id != root and attachments.has(id) and root in chain(id, attachments): out.append(id)
	for id in attachments:
		if not id in out and root in chain(id, attachments): out.append(id)
	return out

## Order in which to place panels so parents come before children.
static func placement_order(ids: Array, attachments: Dictionary) -> Array:
	var order := []
	var pending := ids.duplicate()
	var guard := 0
	while not pending.is_empty() and guard < 64:
		guard += 1
		for id in pending.duplicate():
			var parent := str(attachments.get(id, {}).get("to", ""))
			if parent.is_empty() or not parent in ids or parent in order or creates_cycle(id, parent, attachments):
				order.append(id)
				pending.erase(id)
	order.append_array(pending)
	return order

## Rects after placing every attached panel against its parent (hidden
## parents collapsed). Roots (unattached panels) keep their place.
## rects: id -> Rect2i (sizes already current); shown: id -> bool.
static func reflow(rects: Dictionary, shown: Dictionary, attachments: Dictionary, scale: float) -> Dictionary:
	var out := rects.duplicate()
	for id in placement_order(rects.keys(), attachments):
		var a: Dictionary = attachments.get(id, {})
		var parent := str(a.get("to", ""))
		if parent.is_empty() or not out.has(parent) or creates_cycle(id, parent, attachments): continue
		var r: Rect2i = out[id]
		var parent_rect := effective(out[parent], bool(shown.get(parent, true)), str(a.side))
		out[id] = Rect2i(docked_position(r.size, parent_rect, a, scale), r.size)
	return out

## Recompute attachments after panels moved or changed visibility.
## Keeps every attachment that still matches the geometry (or belongs to a
## hidden panel), then docks each loose shown panel to a shown panel it
## touches, preferring panels already in main's group. `docked` lists the
## panels taking part (shown, windowed); others keep their attachment.
static func update_attachments(rects: Dictionary, shown: Dictionary, attachments: Dictionary, docked: Array, scale: float, drop: Array = []) -> Dictionary:
	var out := {}
	for id in attachments:
		if id == "main" or id in drop or not rects.has(id): continue
		var a: Dictionary = attachments[id]
		var parent := str(a.get("to", ""))
		if not rects.has(parent) or creates_cycle(id, parent, out): continue
		out[id] = a.duplicate()
	# Check the shown panels' attachments against where they really are.
	var expected := reflow(rects, shown, out, scale)
	for id in out.keys():
		var parent := str(out[id].to)
		# Only check panels that are on screen against parents on screen (or
		# hidden ones, collapsed); a fullscreen or minimised parent keeps them.
		if not id in docked or (bool(shown.get(parent, true)) and not parent in docked): continue
		var parent_rect := effective(expected[parent], bool(shown.get(parent, true)), str(out[id].side))
		var r: Rect2i = rects[id]
		var along_ok := overlap(r.position.y, r.end.y, parent_rect.position.y, parent_rect.end.y) > TOUCH if str(out[id].side) in ["left", "right"] \
			else overlap(r.position.x, r.end.x, parent_rect.position.x, parent_rect.end.x) > TOUCH
		var ex: Rect2i = expected[id]
		if (ex.position - r.position).length() > TOUCH or not along_ok:
			out.erase(id)
	# Dock loose panels that touch another shown panel.
	var changed := true
	var passes := 0
	while changed and passes < 8:
		changed = false
		passes += 1
		for id in PANELS:
			if id == "main" or not id in docked or out.has(id): continue
			var candidates := []
			for other in PANELS:
				if other == id or not other in docked: continue
				var a := attachment_for(rects[id], rects[other], other, scale)
				if a.is_empty() or creates_cycle(id, other, out): continue
				candidates.append(a)
			if candidates.is_empty(): continue
			var pick: Dictionary = candidates[0]
			for a in candidates:
				if a.to == "main" or "main" in chain(str(a.to), out):
					pick = a
					break
			out[id] = pick
			changed = true
	return out

# --- Resizing ------------------------------------------------------------------

## Shift the shown panels that sit against the edges `id` moved (right edge by
## new.end.x - old.end.x, bottom edge likewise), and the panels beyond them,
## so docked neighbours stay flush. Returns the new rects (`id` gets `new`).
static func push_neighbours(rects: Dictionary, docked: Array, id: String, old: Rect2i, new: Rect2i) -> Dictionary:
	var out := rects.duplicate()
	out[id] = new
	var dx := new.end.x - old.end.x
	var dy := new.end.y - old.end.y
	for axis in [0, 1]:
		var d := dx if axis == 0 else dy
		if d == 0: continue
		var moved := [id]
		var edge_rects := {id: old}
		var queue := [id]
		while not queue.is_empty():
			var at: String = queue.pop_front()
			var r: Rect2i = edge_rects[at]
			for other in docked:
				if other in moved: continue
				var o: Rect2i = rects[other]
				var touching := false
				if axis == 0: touching = absi(o.position.x - r.end.x) <= TOUCH and overlap(o.position.y, o.end.y, r.position.y, r.end.y) > TOUCH
				else: touching = absi(o.position.y - r.end.y) <= TOUCH and overlap(o.position.x, o.end.x, r.position.x, r.end.x) > TOUCH
				if not touching: continue
				moved.append(other)
				edge_rects[other] = o
				queue.append(other)
				var shifted: Rect2i = out[other]
				shifted.position += Vector2i(d, 0) if axis == 0 else Vector2i(0, d)
				out[other] = shifted
	return out

# --- Screens -------------------------------------------------------------------

## Bounding rect of the given panels' rects.
static func bounds(rects: Dictionary, ids: Array) -> Rect2i:
	var out := Rect2i()
	var first := true
	for id in ids:
		if not rects.has(id): continue
		out = rects[id] if first else out.merge(rects[id])
		first = false
	return out

## Shift that keeps `area` on the screen it is mostly on (WindowLayout rules
## for one rect, applied to a whole group): fully on screen when it fits, the
## top-left corner on screen when it does not. The screen is the one that
## shows most of `anchor` (the main panel) when given, else most of `area`.
static func keep_on_screen_shift(area: Rect2i, screens: Array, anchor := Rect2i()) -> Vector2i:
	if screens.is_empty() or area.size.x <= 0: return Vector2i.ZERO
	var chosen := -1
	var best := -1
	var probe := anchor if anchor.has_area() else area
	for i in screens.size():
		var o: Rect2i = probe.intersection(screens[i])
		if o.get_area() > best:
			best = o.get_area()
			chosen = i
	var s: Rect2i = screens[chosen]
	if best <= 0:
		# Off every screen (a monitor that has gone): centre it on the first one.
		return s.position + (s.size - area.size).max(Vector2i.ZERO) / 2 - area.position
	var x := clampi(area.position.x, s.position.x, maxi(s.end.x - area.size.x, s.position.x))
	var y := clampi(area.position.y, s.position.y, maxi(s.end.y - area.size.y, s.position.y))
	return Vector2i(x, y) - area.position

# --- Default layout --------------------------------------------------------------

## The default arrangement: the playlist under the main panel, the library to
## the right of the main panel (hidden until LIB), the visualiser to the right
## of the library's slot (so, beside the player while the library is closed)
## at the height of the player column, 16:10 but narrowed to fit the screen.
## Returns {attachments, visualiser_units: Vector2}.
static func default_layout(column_height: float, usable_units: Vector2, main_width := 275.0) -> Dictionary:
	var vis_h := column_height
	var room := usable_units.x - main_width - 16.0
	var vis_w := clampf(minf(round(vis_h * 1.6), room), 200.0, 4000.0)
	return {
		"attachments": {
			"playlist": {"to": "main", "side": "bottom", "offset": 0.0},
			"library": {"to": "main", "side": "right", "offset": 0.0},
			"visualiser": {"to": "library", "side": "right", "offset": 0.0},
		},
		"visualiser_units": Vector2(vis_w, vis_h),
	}

# --- Persistence ---------------------------------------------------------------

## [windows] keys of the old single player window (layout_version absent):
## the playlist sat under the main panel and the library to its right, inside
## one window at controller_rect. Map that onto panel attachments; the
## visualiser (an independent titled window then) gets its default dock.
static func migrate(saved: Dictionary) -> Dictionary:
	var out := {"version": 2, "attachments": {
		"playlist": {"to": "main", "side": "bottom", "offset": 0.0},
		"library": {"to": "main", "side": "right", "offset": 0.0},
		"visualiser": {"to": "library", "side": "right", "offset": 0.0}}, "positions": {}, "migrated": true}
	if saved.get("controller_rect") is Array and saved.controller_rect.size() == 4:
		out.positions["main"] = [int(saved.controller_rect[0]), int(saved.controller_rect[1])]
	return out

## Saved dock state from [windows] (migrating older files). Always returns
## {version, attachments, positions: id -> [x, y], visualiser_units?}.
static func load_dock(saved: Dictionary) -> Dictionary:
	var dock = saved.get("dock", null)
	if not dock is Dictionary or int(dock.get("version", 0)) != 2: return migrate(saved)
	var out := {"version": 2, "attachments": {}, "positions": {}}
	for id in dock.get("attachments", {}):
		var a = dock.attachments[id]
		if id in PANELS and id != "main" and a is Dictionary and str(a.get("to", "")) in PANELS and str(a.get("side", "")) in ["left", "right", "top", "bottom"]:
			out.attachments[id] = {"to": str(a.to), "side": str(a.side), "offset": float(a.get("offset", 0.0))}
	for id in dock.get("positions", {}):
		var p = dock.positions[id]
		if id in PANELS and p is Array and p.size() == 2: out.positions[id] = [int(p[0]), int(p[1])]
	var vu = dock.get("visualiser_units", null)
	if vu is Array and vu.size() == 2: out["visualiser_units"] = Vector2(float(vu[0]), float(vu[1]))
	return out
