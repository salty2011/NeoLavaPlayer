extends SceneTree
## Docking (player/dock_layout.gd, player/dock_controller.gd): snap maths
## (panel edges, flush alignment, magnet distance, screen edges), group
## membership (transitive, hidden panels included), group move, detach and
## re-dock, resize pushing neighbours, hidden panels collapsing, layout
## save/restore/migration and reset, with the real split windows (headless).
##   Godot --headless --audio-driver Dummy --path native-player --script res://test_docking.gd
const Dock = preload("res://player/dock_layout.gd")
const Main = preload("res://main.gd")
const Fmt = preload("res://player/player_format.gd")
const WindowLayout = preload("res://window_layout.gd")
const AppSettings = preload("res://app_settings.gd")

func _initialize(): call_deferred("run")

func run():
	var t0 := Time.get_ticks_msec()
	_pure()
	await _live()
	print("PASS: docking snap (outer + flush edges, magnet %d px at 1x / %d px at 2x, screen edges, level-only), touching sides + corners, attachments + offsets, transitive groups incl. hidden, cycle guard, reflow + hidden collapse, re-validation after moves, resize push (chains, both axes), keep-on-screen shift, default layout (fits the screen), migration of the single-window [windows]; live: split windows, default dock, group drag moves all in one step + snaps, detach by own title + re-dock, panel resize keeps neighbours flush, library opens between main and visualiser, scale change keeps the group flush, close/hide panels, reset layout, save/restore (%d ms)" % [Dock.magnet_pixels(1.0), Dock.magnet_pixels(2.0), Time.get_ticks_msec() - t0])
	quit()

func _pure():
	# --- Snap maths ---
	var m := 10
	assert(Dock.magnet_pixels(1.0) == 10 and Dock.magnet_pixels(2.0) == 20)
	var main := Rect2i(100, 100, 550, 232)
	# Dropped 6 px right of main's right edge, level with it: snaps flush (outer edge).
	assert(Dock.snap_delta([Rect2i(656, 120, 300, 200)], [main], [], m) == Vector2i(-6, 0))
	# 4 px under main, 3 px off its left edge: snaps under and aligned (flush left).
	assert(Dock.snap_delta([Rect2i(103, 336, 550, 300)], [main], [], m) == Vector2i(-3, -4))
	# Outside the magnet: no snap.
	assert(Dock.snap_delta([Rect2i(662, 120, 300, 200)], [main], [], m) == Vector2i.ZERO)
	# Not level (far below): no side-by-side snap even if x matches closely.
	assert(Dock.snap_delta([Rect2i(655, 600, 300, 200)], [main], [], m) == Vector2i.ZERO)
	# The nearest candidate wins.
	assert(Dock.snap_delta([Rect2i(652, 99, 300, 200)], [main], [], m) == Vector2i(-2, 1))
	# Screen edges snap from the inside.
	var screen := Rect2i(0, 25, 1440, 875)
	assert(Dock.snap_delta([Rect2i(7, 31, 200, 100)], [], [screen], m) == Vector2i(-7, -6))
	assert(Dock.snap_delta([Rect2i(1235, 795, 200, 100)], [], [screen], m) == Vector2i(5, 5))
	assert(Dock.snap_delta([Rect2i(50, 300, 200, 100)], [], [screen], m) == Vector2i.ZERO)
	# A group snaps as one: the best edge of any member.
	assert(Dock.snap_delta([Rect2i(20, 40, 100, 100), Rect2i(20, 140, 100, 100)], [Rect2i(128, 205, 50, 50)], [], m) == Vector2i(8, 0))
	# --- Touching ---
	assert(Dock.side_of(Rect2i(650, 100, 300, 200), main) == "right")
	assert(Dock.side_of(Rect2i(-200, 150, 300, 50), main) == "left")
	assert(Dock.side_of(Rect2i(100, 332, 550, 100), main) == "bottom")
	assert(Dock.side_of(Rect2i(300, 0, 100, 100), main) == "top")
	assert(Dock.side_of(Rect2i(651, 101, 10, 10), main) == "right") # within 2 px
	assert(Dock.side_of(Rect2i(650, 332, 100, 100), main) == "") # corner only
	assert(Dock.side_of(Rect2i(660, 100, 100, 100), main) == "") # gap
	var a := Dock.attachment_for(Rect2i(650, 140, 300, 200), main, "main", 2.0)
	assert(a.to == "main" and a.side == "right" and a.offset == 20.0)
	# --- Groups (transitive, hidden included) and cycles ---
	var att := {"playlist": {"to": "main", "side": "bottom", "offset": 0.0}, "library": {"to": "playlist", "side": "right", "offset": 0.0}, "visualiser": {"to": "library", "side": "right", "offset": 0.0}}
	assert(Dock.group_of("main", att) == ["main", "playlist", "library", "visualiser"])
	assert(Dock.group_of("library", att) == ["library", "visualiser"])
	assert(Dock.chain("visualiser", att) == ["library", "playlist", "main"])
	assert(Dock.creates_cycle("playlist", "visualiser", att) and not Dock.creates_cycle("visualiser", "main", att))
	var loose := {"library": {"to": "visualiser", "side": "left", "offset": 0.0}}
	assert(Dock.group_of("main", loose) == ["main"])
	# --- Reflow: docked positions, hidden panels collapse ---
	var rects := {"main": main, "playlist": Rect2i(0, 0, 550, 348), "library": Rect2i(0, 0, 760, 580), "visualiser": Rect2i(0, 0, 900, 580)}
	var att2: Dictionary = Dock.default_layout(290, Vector2(5000, 3000)).attachments
	var shown := {"main": true, "playlist": true, "library": false, "visualiser": true}
	var r := Dock.reflow(rects, shown, att2, 2.0)
	assert(r.playlist == Rect2i(100, 332, 550, 348))
	assert(r.library.position == Vector2i(650, 100))
	assert(r.visualiser.position == Vector2i(650, 100), "library hidden: the visualiser sits against main") # collapsed
	shown.library = true
	r = Dock.reflow(rects, shown, att2, 2.0)
	assert(r.visualiser.position == Vector2i(1410, 100), "library shown: the visualiser moves out")
	# Offsets are base units: they follow the scale.
	var att3 := {"playlist": {"to": "main", "side": "right", "offset": 10.0}}
	assert(Dock.reflow({"main": main, "playlist": Rect2i(0, 0, 10, 10)}, {}, att3, 3.0).playlist.position == Vector2i(650, 130))
	# Placement order: parents first, cycles do not hang.
	assert(Dock.placement_order(["visualiser", "library", "main"], att2) == ["main", "library", "visualiser"])
	var cyc := {"playlist": {"to": "library", "side": "right", "offset": 0.0}, "library": {"to": "playlist", "side": "right", "offset": 0.0}}
	assert(Dock.placement_order(["playlist", "library"], cyc).size() == 2)
	Dock.reflow({"playlist": main, "library": main}, {}, cyc, 1.0)
	# --- update_attachments: keep valid ones, drop moved ones, dock new touches ---
	shown = {"main": true, "playlist": true, "library": false, "visualiser": true}
	r = Dock.reflow(rects, shown, att2, 2.0)
	var docked := ["main", "playlist", "visualiser"]
	var kept := Dock.update_attachments(r, shown, att2, docked, 2.0)
	assert(kept == att2, "geometry matches: attachments kept (visualiser through the hidden library) %s" % kept)
	# Visualiser dragged away: detached.
	var moved := r.duplicate()
	moved.visualiser = Rect2i(moved.visualiser.position + Vector2i(300, 400), moved.visualiser.size)
	var after := Dock.update_attachments(moved, shown, att2, docked, 2.0, ["visualiser"])
	assert(not after.has("visualiser") and after.library == att2.library and after.playlist == att2.playlist)
	# Dropped against the playlist's bottom: docks there (offset in units).
	moved.visualiser = Rect2i(r.playlist.position + Vector2i(40, r.playlist.size.y), moved.visualiser.size)
	after = Dock.update_attachments(moved, shown, att2, docked, 2.0, ["visualiser"])
	assert(after.visualiser == {"to": "playlist", "side": "bottom", "offset": 20.0}, str(after))
	# A loose panel touching another loose panel docks to it; the pair stays out of main's group.
	var pair := {"main": main, "playlist": Rect2i(2000, 0, 550, 300), "visualiser": Rect2i(2550, 0, 500, 300)}
	after = Dock.update_attachments(pair, {}, {}, ["main", "playlist", "visualiser"], 1.0)
	assert(after.size() == 1 and after.playlist.to == "visualiser" and after.playlist.side == "left" and not "playlist" in Dock.group_of("main", after))
	# Touching two panels: main's group wins.
	var three := {"main": main, "library": Rect2i(650, 100, 300, 600), "playlist": Rect2i(100, 332, 550, 300)}
	var att4 := Dock.update_attachments(three, {}, {"library": {"to": "playlist", "side": "right", "offset": -116.0}}, ["main", "library", "playlist"], 2.0, ["library"])
	assert(att4.library.to == "main" and att4.playlist.to == "main")
	# --- Resize pushes the neighbours on the moved edges (chains, both axes) ---
	var col := {"main": main, "playlist": Rect2i(100, 332, 550, 348), "visualiser": Rect2i(650, 100, 900, 580), "library": Rect2i(100, 680, 550, 200)}
	var grown := Dock.push_neighbours(col, ["main", "playlist", "visualiser", "library"], "playlist", col.playlist, Rect2i(100, 332, 600, 400))
	assert(grown.playlist == Rect2i(100, 332, 600, 400) and grown.library.position == Vector2i(100, 732) and grown.visualiser.position == Vector2i(700, 100), str(grown))
	grown = Dock.push_neighbours(col, ["main", "playlist", "visualiser", "library"], "main", main, Rect2i(100, 100, 560, 232))
	assert(grown.visualiser.position == Vector2i(660, 100))
	var shrink := Dock.push_neighbours(col, ["main", "playlist", "visualiser", "library"], "playlist", col.playlist, Rect2i(100, 332, 550, 300))
	assert(shrink.library.position == Vector2i(100, 632))
	# --- Keep on screen ---
	var scr := [Rect2i(0, 25, 1440, 875), Rect2i(1440, 0, 1920, 1080)]
	assert(Dock.keep_on_screen_shift(Rect2i(-50, 10, 600, 300), scr) == Vector2i(50, 15))
	assert(Dock.keep_on_screen_shift(Rect2i(1500, 900, 600, 300), scr) == Vector2i(0, -120))
	assert(Dock.keep_on_screen_shift(Rect2i(9000, 9000, 600, 300), scr) == Vector2i(420, 312) - Vector2i(9000, 9000))
	assert(Dock.keep_on_screen_shift(Rect2i(100, 100, 3000, 300), scr, main).x == -100 and Dock.keep_on_screen_shift(Rect2i(100, 100, 3000, 300), scr).x == 1340) # too wide: top-left on screen
	# --- Default layout fits the usable width ---
	var d := Dock.default_layout(290.0, Vector2(735, 440))
	assert(d.visualiser_units.y == 290.0 and d.visualiser_units.x == 735 - 275 - 16, str(d))
	assert(Dock.default_layout(290.0, Vector2(4000, 2000)).visualiser_units.x == 464.0)
	assert(Dock.default_layout(290.0, Vector2(300, 2000)).visualiser_units.x == 200.0)
	# --- Persistence: migration of the old single window, round trip, junk ---
	var old := {"controller_rect": [40, 60, 1100, 464], "drawer_open": true, "library_open": false}
	var mig := Dock.load_dock(old)
	assert(mig.migrated and mig.positions.main == [40, 60] and mig.attachments.playlist.side == "bottom" and mig.attachments.library == {"to": "main", "side": "right", "offset": 0.0} and mig.attachments.visualiser.to == "library")
	var saved := {"dock": {"version": 2, "attachments": {"playlist": {"to": "main", "side": "right", "offset": 3.0}, "visualiser": {"to": "nowhere", "side": "right"}, "main": {"to": "playlist", "side": "left"}}, "positions": {"main": [1, 2], "bogus": [3, 4]}, "visualiser_units": [400, 250]}}
	var loaded := Dock.load_dock(saved)
	assert(loaded.attachments == {"playlist": {"to": "main", "side": "right", "offset": 3.0}} and loaded.positions == {"main": [1, 2]} and loaded.visualiser_units == Vector2(400, 250) and not loaded.has("migrated"))
	assert(Dock.load_dock({"dock": "junk"}).has("migrated"))

var _dock

## Where the dock has put window `w`. Headless windows are embedded in the
## (tiny) root viewport, which clamps their real positions; the windowed
## test_windows_live.gd checks that real positions follow these rects.
func _at(w: Window) -> Vector2i:
	for id in _dock.windows:
		if _dock.windows[id] == w: return _dock.rects[id].position
	return w.position

func _live():
	var app = Main.new()
	app.persist_override = false
	root.add_child(app)
	await process_frame
	var bus = app.bus
	var w = app.controller
	var dock = w.dock
	_dock = dock
	var main_w: Window = w
	var pl: Window = w.playlist_window
	var lib: Window = w.library_window
	var vis: Window = root
	assert(app.framed and app.visualiser.framed and app.visualiser.frame != null and dock.has_panel("visualiser"))
	# (A headless server reports no window flags for the root window.)
	assert(pl != main_w and lib != main_w and pl.borderless and lib.borderless and (vis.borderless or DisplayServer.get_name() == "headless"))
	dock.screens_override = [Rect2i(0, 0, 4000, 2400)]
	w.reset_layout(false)
	w.set_playlist_open(true)
	# --- Default: playlist under main, visualiser right of main at the column's height ---
	var column_px: int = main_w.size.y + pl.size.y
	assert(_at(pl) == _at(main_w) + Vector2i(0, main_w.size.y), "playlist under main")
	assert(_at(vis) == _at(main_w) + Vector2i(main_w.size.x, 0) and vis.size.y == column_px, "visualiser beside the column: %s %s" % [_at(vis), vis.size])
	assert(dock.attachments.visualiser.to == "library" and not w.library_open)
	assert(Dock.group_of("main", dock.attachments).size() == 4)
	# --- Group drag: one call moves every docked window by the same delta ---
	var start := {"main": _at(main_w), "pl": _at(pl), "vis": _at(vis)}
	dock.begin_drag("main", Vector2i(500, 500))
	dock.drag_to(Vector2i(560, 540))
	assert(_at(main_w) == start.main + Vector2i(60, 40) and _at(pl) == start.pl + Vector2i(60, 40) and _at(vis) == start.vis + Vector2i(60, 40), "group moved together")
	assert(dock.rects.library.position == dock.rects.main.position + Vector2i(main_w.size.x, 0), "hidden library moves with the group")
	dock.end_drag()
	# Dragged to 6 px from the screen's left edge: the group snaps to it.
	dock.begin_drag("main", Vector2i(0, 0))
	dock.drag_to(Vector2i(6 - _at(main_w).x, 0))
	assert(_at(main_w).x == 0 and _at(pl).x == 0 and _at(vis).x == main_w.size.x, "snapped to the screen edge")
	dock.end_drag()
	# --- Detach by the panel's own title, re-dock against an edge ---
	var main_at := _at(main_w)
	dock.begin_drag("playlist", Vector2i(100, 100))
	dock.drag_to(Vector2i(400, 700))
	assert(_at(pl) == main_at + Vector2i(300, main_w.size.y + 600) and _at(main_w) == main_at and _at(vis) == main_at + Vector2i(main_w.size.x, 0), "only the playlist moves")
	dock.end_drag()
	assert(not dock.attachments.has("playlist") and not "playlist" in dock.group())
	# Main's group no longer carries it.
	dock.begin_drag("main", Vector2i(0, 0))
	dock.drag_to(Vector2i(100, 0))
	assert(_at(pl) == main_at + Vector2i(300, main_w.size.y + 600))
	dock.end_drag()
	main_at = _at(main_w)
	# Dropped 7 px below and 4 px right of main's bottom-left: snaps flush, docks.
	var target: Vector2i = main_at + Vector2i(4, main_w.size.y + 7)
	dock.begin_drag("playlist", _at(pl))
	dock.drag_to(target)
	assert(_at(pl) == main_at + Vector2i(0, main_w.size.y), "snapped under main: %s" % _at(pl))
	dock.end_drag()
	assert(dock.attachments.playlist == {"to": "main", "side": "bottom", "offset": 0.0} and "playlist" in dock.group())
	# --- Alternative layout: visualiser on the left of main, playlist on the right ---
	dock.begin_drag("visualiser", _at(vis))
	dock.drag_to(main_at - Vector2i(vis.size.x + 5, -3))
	assert(_at(vis) == main_at - Vector2i(vis.size.x, 0), "visualiser snapped to main's left edge, tops aligned: %s" % _at(vis))
	dock.end_drag()
	assert(dock.attachments.visualiser.to == "main" and dock.attachments.visualiser.side == "left")
	dock.begin_drag("playlist", _at(pl))
	dock.drag_to(main_at + Vector2i(main_w.size.x + 4, 2))
	assert(_at(pl) == main_at + Vector2i(main_w.size.x, 0))
	dock.end_drag()
	assert(dock.attachments.playlist.to == "main" and dock.attachments.playlist.side == "right")
	# The whole arrangement moves with main.
	dock.begin_drag("main", Vector2i(0, 0))
	dock.drag_to(Vector2i(-30, 25))
	assert(_at(main_w) == main_at + Vector2i(-30, 25) and _at(vis) == main_at + Vector2i(-30 - vis.size.x, 25) and _at(pl) == main_at + Vector2i(main_w.size.x - 30, 25))
	dock.end_drag()
	main_at = _at(main_w)
	# --- Resizing keeps neighbours flush ---
	# Visualiser (left of main) grows from its right edge: main's group shifts right.
	var vis_w: int = vis.size.x
	dock.resize_visualiser(Vector2.ZERO, Vector2.ONE, true)
	dock.resize_visualiser(Vector2(40, 20), Vector2.ONE, false)
	assert(vis.size == Vector2i(vis_w + 40, column_px + 20), "visualiser resized: %s" % vis.size)
	assert(_at(main_w) == main_at + Vector2i(40, 0) and _at(pl) == main_at + Vector2i(main_w.size.x + 40, 0), "main and the playlist pushed right: %s %s %s %s" % [main_at, _at(main_w), _at(pl), dock.attachments])
	dock.resize_visualiser(Vector2.ZERO, Vector2.ONE, false) # back to the press point
	assert(vis.size == Vector2i(vis_w, column_px) and _at(main_w) == main_at)
	# Back to the default, then: playlist taller pushes a panel docked under it.
	bus.command(&"reset_layout")
	assert(dock.attachments == Dock.default_layout(0, Vector2(9999, 9999)).attachments and _at(pl) == _at(main_w) + Vector2i(0, main_w.size.y))
	assert(w.playlist_height == Fmt.PLAYLIST_DEFAULT_HEIGHT and bus.status == "Window layout reset")
	w.set_library_open(true)
	assert(lib.visible and _at(lib) == _at(main_w) + Vector2i(main_w.size.x, 0) and _at(vis) == _at(lib) + Vector2i(lib.size.x, 0), "library between main and the visualiser")
	dock.begin_drag("library", _at(lib))
	dock.drag_to(_at(pl) + Vector2i(3, pl.size.y + 5))
	dock.end_drag()
	assert(dock.attachments.library.to == "playlist" and dock.attachments.library.side == "bottom" and _at(lib) == _at(pl) + Vector2i(0, pl.size.y))
	w._on_resize_drag(0.0, true)
	w._on_resize_drag(30.0, false)
	assert(pl.size.y == Fmt.window_pixels(Vector2(275, Fmt.PLAYLIST_DEFAULT_HEIGHT + 15), w.ui_scale).y and _at(lib) == _at(pl) + Vector2i(0, pl.size.y), "library pushed down")
	# Playlist wider: a panel against its right edge moves out.
	dock.begin_drag("visualiser", _at(vis))
	dock.drag_to(_at(pl) + Vector2i(pl.size.x + 3, 4))
	dock.end_drag()
	assert(_at(vis) == _at(pl) + Vector2i(pl.size.x, 0), "visualiser against the playlist's right edge")
	w.set_playlist_size(300, w.playlist_height)
	assert(_at(vis).x == _at(pl).x + pl.size.x and pl.size.x == 600, "visualiser pushed by the wider playlist")
	w.set_playlist_size(275, Fmt.PLAYLIST_DEFAULT_HEIGHT)
	assert(_at(vis) == _at(pl) + Vector2i(pl.size.x, 0) and _at(lib) == _at(pl) + Vector2i(0, pl.size.y))
	# --- Scale change: everything stays flush at the new size ---
	w.set_user_size(3.0, false)
	assert(main_w.size == Fmt.window_pixels(Fmt.MAIN_SIZE, 3.0) and pl.content_scale_factor == 3.0 and lib.content_scale_factor == 3.0 and bus.player_scale == 3.0)
	assert(_at(pl) == _at(main_w) + Vector2i(0, main_w.size.y) and _at(lib) == _at(pl) + Vector2i(0, pl.size.y) and _at(vis) == _at(pl) + Vector2i(pl.size.x, 0))
	assert(vis.size == Fmt.window_pixels(dock.visualiser_units, 3.0))
	w.set_user_size(2.0, false)
	# --- Closing panels: the playlist's × hides it; the library docked under it slides up ---
	w.playlist_panel.buttons.close.click()
	assert(not w.playlist_open and not pl.visible and not bus.drawer_open and _at(lib) == _at(main_w) + Vector2i(0, main_w.size.y), "library slid up: %s" % _at(lib))
	bus.command(&"toggle_drawer")
	assert(pl.visible and _at(lib) == _at(pl) + Vector2i(0, pl.size.y))
	w.close_panel("library")
	assert(not w.library_open and not lib.visible)
	# Tab hides every player window; again shows them.
	bus.command(&"toggle_controller")
	assert(not main_w.visible and not pl.visible and not bus.controller_visible)
	bus.command(&"toggle_controller")
	assert(main_w.visible and pl.visible and not lib.visible and bus.controller_visible)
	# --- Save / restore ---
	dock.begin_drag("visualiser", _at(vis))
	dock.drag_to(_at(vis) + Vector2i(700, 900))
	dock.end_drag()
	var state: Dictionary = w.layout_state()
	var saved_main := _at(main_w)
	var saved_vis := _at(vis)
	var cfg := OS.get_temp_dir().path_join("oozic-test-docking.cfg")
	WindowLayout.save_state(state, cfg)
	var loaded: Dictionary = WindowLayout.load_state(cfg)
	assert(loaded.dock.version == 2 and loaded.dock.attachments.playlist.side == "bottom" and not loaded.dock.attachments.has("visualiser"))
	bus.command(&"reset_layout")
	assert(_at(vis) != saved_vis)
	w.restore_dock(loaded)
	assert(_at(main_w) == saved_main and _at(vis) == saved_vis and _at(pl) == saved_main + Vector2i(0, main_w.size.y) and not dock.attachments.has("visualiser"), "restored")
	# A saved layout on a monitor that has gone comes back on screen as a group.
	var far: Dictionary = loaded.duplicate(true)
	far.dock.positions.main = [9000, 9000]
	w.restore_dock(far)
	assert(Rect2i(0, 0, 4000, 2400).encloses(Rect2i(_at(main_w), main_w.size)) and _at(pl) == _at(main_w) + Vector2i(0, main_w.size.y))
	# Migration: the old single-window [windows] keys.
	w.restore_dock({"controller_rect": [120, 80, 1100, 464], "drawer_open": true})
	assert(_at(main_w) == Vector2i(120, 80) and _at(pl) == Vector2i(120, 80 + main_w.size.y) and _at(vis) == Vector2i(120 + main_w.size.x, 80), "migrated: %s %s" % [_at(pl), _at(vis)])
	DirAccess.remove_absolute(cfg)
	# The visualiser frame: buttons send their commands; drags and resizes go through the bus.
	var frame = app.visualiser.frame
	var log := []
	var rec := func(name, args): log.append([name, args])
	bus.command_requested.connect(rec)
	var frame_expected := {&"minimize": &"minimize", &"fullscreen": &"toggle_fullscreen", &"close": &"hide_visualiser", &"previous_scene": &"previous_scene", &"next_scene": &"next_scene"}
	for c in bus.command_requested.get_connections():
		if c.callable != rec: bus.command_requested.disconnect(c.callable)
	for id in frame_expected:
		log.clear()
		frame.chrome.buttons[id].click()
		assert(log.size() == 1 and log[0][0] == frame_expected[id], "frame %s sent %s" % [id, log])
	assert(frame.chrome.buttons.minimize.args.source == "visualiser")
	log.clear()
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	frame.chrome.title_strip._gui_input(press)
	frame.chrome.grip._gui_input(press)
	assert(log.size() == 2 and log[0] == [&"begin_panel_drag", {"panel": "visualiser"}] and log[1][0] == &"resize_panel" and log[1][1].start, str(log))
	var inner: Rect2 = frame.inner_rect(Vector2(vis.size), w.ui_scale)
	assert(inner.position == Vector2(8, 28) and inner.size == Vector2(vis.size) - Vector2(16, 56))
	app.queue_free()
	await create_timer(0.2).timeout
