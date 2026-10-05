extends SceneTree
## Windowed (not headless) check of the real docked windows:
##   Godot --audio-driver Dummy --path native-player --script res://test_windows_live.gd
## Verifies the main, playlist and library panels are separate, borderless OS
## windows (not embedded) at screen scale x user size; the visualiser (root
## window) is borderless with its themed frame reaching the window edges;
## real window positions follow the dock (default layout, a group drag moving
## every window in the same step, the library opening between main and the
## visualiser, a live re-scale); closing/minimising the visualiser (title
## bar put back for the Dock, borderless again after) keeps the player;
## minimising the player hides its panels and brings them back; fullscreen
## drops the frame and returns to the docked place. macOS animates window
## changes, so every check waits for the state with a deadline instead of a
## fixed number of frames.
const Main = preload("res://main.gd")
const Fmt = preload("res://player/player_format.gd")
const Style = preload("res://player/player_style.gd")
const TIMEOUT := 6.0

var dock

func _initialize(): call_deferred("run")

## Wait (rendering frames) until cond() is true or the timeout passes.
func wait_until(cond: Callable, timeout := TIMEOUT) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while not cond.call():
		if Time.get_ticks_msec() > deadline: return false
		await process_frame
	return true

## Every shown, windowed panel's real OS position equals the dock's rect.
func windows_follow_dock() -> bool:
	for id in dock.docked_ids():
		var w: Window = dock.windows[id]
		if w.position != dock.rects[id].position or w.size != dock.rects[id].size: return false
	return true

func describe() -> String:
	var parts := []
	for id in dock.docked_ids(): parts.append("%s real %s dock %s" % [id, Rect2i(dock.windows[id].position, dock.windows[id].size), dock.rects[id]])
	return ", ".join(parts)

func run():
	if DisplayServer.get_name() == "headless":
		print("SKIP: needs a window (run without --headless)")
		quit()
		return
	var app = Main.new()
	app.persist_override = false
	root.add_child(app)
	var controller: Window = app.controller
	var bus = app.bus
	dock = controller.dock
	dock.poll_mouse = false # this test drives drags itself
	var pl: Window = controller.playlist_window
	var lib: Window = controller.library_window
	assert(await wait_until(func(): return controller.visible and DisplayServer.get_window_list().size() >= 2), "player window shown")
	assert(controller != null and not controller.is_embedded() and not pl.is_embedded() and not lib.is_embedded(), "player panels are their own OS windows")
	assert(controller.borderless and not controller.transparent and pl.borderless and lib.borderless)
	# Scale: screen scale x user size, applied as the content scale of every panel.
	var screen_scale := maxf(DisplayServer.screen_get_scale(controller.current_screen), 1.0)
	assert(is_equal_approx(controller.ui_scale, screen_scale * controller.user_size) and is_equal_approx(controller.content_scale_factor, controller.ui_scale))
	assert(controller.size == Fmt.window_pixels(controller.base_size(), controller.ui_scale), "size %s" % controller.size)
	# The visualiser: borderless, framed, the frame's canvas reaching the window edges.
	assert(app.framed and root.borderless and app.visualiser.frame.visible and root.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_EXPAND)
	# Work at 1x so the whole group has room on any screen.
	bus.command(&"set_player_size", {"size": 1.0})
	assert(await wait_until(func(): return controller.size == Fmt.window_pixels(Fmt.MAIN_SIZE, screen_scale)), "1x size")
	bus.command(&"reset_layout")
	bus.command(&"toggle_drawer")
	assert(await wait_until(func(): return pl.visible and windows_follow_dock()), "playlist window shown in its docked place: " + describe())
	assert(pl.position == controller.position + Vector2i(0, controller.size.y) and root.position == controller.position + Vector2i(controller.size.x, 0), "default dock: " + describe())
	assert(root.size.y == controller.size.y + pl.size.y, "visualiser as tall as the player column")
	var ids := DisplayServer.get_window_list()
	assert(ids.size() >= 3 and controller.get_window_id() != root.get_window_id() and pl.get_window_id() >= 0 and pl.get_window_id() != controller.get_window_id())
	# The frame is drawn at the window's edges (title strip colour at the top
	# left), the 3D view inside it.
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var shot := root.get_texture().get_image()
	assert(shot.get_size() == root.size, "root renders the whole window: %s vs %s" % [shot.get_size(), root.size])
	var corner := shot.get_pixel(int(30 * controller.ui_scale), int(3 * controller.ui_scale))
	assert(corner.a > 0.99 and absf(corner.r - Style.STRIP_TOP.r) < 0.08 and absf(corner.b - Style.STRIP_TOP.b) < 0.08, "title strip at the top: %s" % corner)
	# Group drag: one drag_to moves every window; the OS shows them there.
	var before := {"main": controller.position, "pl": pl.position, "vis": root.position}
	dock.begin_drag("main", Vector2i(1000, 1000))
	dock.drag_to(Vector2i(1050, 1040))
	var moved := Vector2i(50, 40)
	assert(controller.position == before.main + moved and pl.position == before.pl + moved and root.position == before.vis + moved, "all windows moved in the same step: " + describe())
	dock.end_drag()
	assert(await wait_until(windows_follow_dock), "positions stay: " + describe())
	# Library: opens between main and the visualiser.
	bus.command(&"toggle_library")
	assert(await wait_until(func(): return lib.visible and windows_follow_dock()), "library shown: " + describe())
	assert(lib.position == controller.position + Vector2i(controller.size.x, 0) and root.position.x == lib.position.x + lib.size.x, "library between: " + describe())
	bus.command(&"toggle_library")
	assert(await wait_until(func(): return not lib.visible and root.position == controller.position + Vector2i(controller.size.x, 0)), "visualiser back against main")
	# Live re-scale: 2x, every panel bigger and still flush.
	bus.command(&"set_player_size", {"size": 2.0})
	assert(await wait_until(func(): return controller.size == Fmt.window_pixels(Fmt.MAIN_SIZE, screen_scale * 2.0) and windows_follow_dock()), "2x: " + describe())
	assert(pl.position == controller.position + Vector2i(0, controller.size.y) and root.position == controller.position + Vector2i(controller.size.x, 0) and pl.content_scale_factor == controller.ui_scale)
	bus.command(&"set_player_size", {"size": 1.0})
	assert(await wait_until(func(): return controller.size == Fmt.window_pixels(Fmt.MAIN_SIZE, screen_scale) and windows_follow_dock()), "back to 1x")
	# The capture shows the drawn player (opaque body, not the clear colour).
	await RenderingServer.frame_post_draw
	var image := controller.get_texture().get_image()
	assert(image.get_size() == controller.size and image.get_pixel(image.get_width() / 2, int(20 * controller.ui_scale)).a > 0.99)
	# Visualiser close (its frame's ×) keeps the player; show brings it back
	# borderless, in its docked place.
	var vis_rect := Rect2i(root.position, root.size)
	bus.command(&"hide_visualiser")
	assert(await wait_until(func(): return root.mode == Window.MODE_MINIMIZED and not bus.visualiser_visible), "visualiser minimised and published")
	assert(controller.visible and pl.visible and not app.quitting)
	bus.command(&"toggle_visualiser")
	assert(await wait_until(func(): return root.mode != Window.MODE_MINIMIZED and bus.visualiser_visible and root.borderless and Rect2i(root.position, root.size) == vis_rect), "visualiser restored borderless in place: %s vs %s" % [Rect2i(root.position, root.size), vis_rect])
	# Minimise the player (its own _ button sends this): its panels hide with
	# it and come back with it; it is borderless again and the same size.
	var player_size := controller.size
	bus.command(&"minimize", {"source": "controller"})
	assert(await wait_until(func(): return controller.mode == Window.MODE_MINIMIZED and not pl.visible), "player minimised with its panels")
	assert(root.mode != Window.MODE_MINIMIZED)
	controller.mode = Window.MODE_WINDOWED
	assert(await wait_until(func(): return controller.mode == Window.MODE_WINDOWED and controller.borderless and controller.size == player_size and pl.visible), "player restored borderless with its playlist")
	# Fullscreen the visualiser on its current screen: no frame; back: framed, docked.
	var screen := root.current_screen
	bus.command(&"toggle_fullscreen")
	assert(await wait_until(func(): return app.visualiser.is_fullscreen() and bus.visualiser_fullscreen and not app.visualiser.frame.visible), "fullscreen without the frame")
	assert(root.current_screen == screen and root.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_KEEP)
	bus.command(&"escape")
	assert(await wait_until(func(): return not app.visualiser.is_fullscreen() and root.borderless and app.visualiser.frame.visible and Rect2i(root.position, root.size) == vis_rect, 8.0), "left fullscreen, framed in its docked place: %s vs %s (mode %d borderless %s frame %s away %s)" % [Rect2i(root.position, root.size), vis_rect, root.mode, root.borderless, app.visualiser.frame.visible, dock._vis_away])
	print("PASS: separate OS windows (ids %s): main, playlist and library borderless at %.1fx (screen %.1f x size %.1f), framed borderless visualiser drawn to its edges, real positions follow the dock (default layout, group drag in one step, library between main and visualiser, live re-scale 1x/2x), opaque capture, visualiser close (minimise via title bar)/restore borderless in place keeps the player, player minimise hides/restores its panels, fullscreen on screen %d without the frame and back to the docked rect" % [ids, controller.ui_scale, screen_scale, controller.user_size, screen])
	app.queue_free()
	await create_timer(0.3).timeout
	quit()
