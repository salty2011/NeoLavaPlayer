extends SceneTree
## Windowed (not headless) check of the real two-window setup:
##   Godot --audio-driver Dummy --path native-player --script res://test_windows_live.gd
## Verifies the player is a separate, borderless OS window (not embedded),
## sized at screen scale x user size, that it grows with the playlist panel,
## and that hiding/showing/minimising the visualiser and fullscreen toggling
## work independently of it. macOS animates window changes, so every check
## waits for the state with a timeout instead of a fixed number of frames.
const Main = preload("res://main.gd")
const Fmt = preload("res://player/player_format.gd")
const TIMEOUT := 5.0

func _initialize(): call_deferred("run")

## Wait (rendering frames) until cond() is true or the timeout passes.
func wait_until(cond: Callable, timeout := TIMEOUT) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while not cond.call():
		if Time.get_ticks_msec() > deadline: return false
		await process_frame
	return true

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
	assert(await wait_until(func(): return controller.visible and DisplayServer.get_window_list().size() >= 2), "player window shown")
	var ids := DisplayServer.get_window_list()
	assert(controller != null and not controller.is_embedded(), "player must be its own OS window")
	assert(controller.get_window_id() != root.get_window_id())
	assert(controller.borderless and not controller.transparent)
	# Scale: screen scale x user size, applied as the content scale.
	var screen_scale := maxf(DisplayServer.screen_get_scale(controller.current_screen), 1.0)
	assert(is_equal_approx(controller.ui_scale, screen_scale * controller.user_size) and is_equal_approx(controller.content_scale_factor, controller.ui_scale))
	assert(controller.size == Fmt.window_pixels(controller.base_size(), controller.ui_scale), "size %s" % controller.size)
	assert(root.visible and controller.visible)
	# Playlist panel: the same window grows, then shrinks back.
	var closed_size := controller.size
	bus.command(&"toggle_drawer")
	assert(await wait_until(func(): return controller.size.y > closed_size.y), "window grows with the playlist")
	assert(controller.playlist_open and bus.drawer_open and controller.size.x == closed_size.x)
	bus.command(&"toggle_drawer")
	assert(await wait_until(func(): return controller.size == closed_size), "window shrinks back")
	# User size change re-scales live.
	bus.command(&"set_player_size", {"size": 1.0})
	assert(await wait_until(func(): return controller.size == Fmt.window_pixels(Fmt.MAIN_SIZE, screen_scale)), "1x size")
	bus.command(&"set_player_size", {"size": 2.0})
	assert(await wait_until(func(): return controller.size == closed_size), "back to 2x")
	# The capture shows the drawn player (opaque body, not the clear colour).
	await RenderingServer.frame_post_draw
	var image := controller.get_texture().get_image()
	assert(image.get_size() == controller.size and image.get_pixel(image.get_width() / 2, int(20 * controller.ui_scale)).a > 0.99)
	# Visualiser hide (its close button) keeps the player; show brings it back.
	app._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	assert(await wait_until(func(): return root.mode == Window.MODE_MINIMIZED and not bus.visualiser_visible), "visualiser minimised and published")
	assert(controller.visible and not app.quitting)
	bus.command(&"toggle_visualiser")
	assert(await wait_until(func(): return root.mode != Window.MODE_MINIMIZED and bus.visualiser_visible), "visualiser restored")
	# Minimise the player alone (its own _ button sends this), then restore:
	# it is borderless again and the same size.
	var player_size := controller.size
	bus.command(&"minimize", {"source": "controller"})
	assert(await wait_until(func(): return controller.mode == Window.MODE_MINIMIZED), "player minimised")
	assert(root.mode != Window.MODE_MINIMIZED)
	controller.mode = Window.MODE_WINDOWED
	assert(await wait_until(func(): return controller.mode == Window.MODE_WINDOWED and controller.borderless and controller.size == player_size), "player restored borderless")
	# Fullscreen the visualiser on its current screen, then back.
	var screen := root.current_screen
	bus.command(&"toggle_fullscreen")
	assert(await wait_until(func(): return app.visualiser.is_fullscreen() and bus.visualiser_fullscreen), "fullscreen")
	assert(root.current_screen == screen)
	bus.command(&"escape")
	assert(await wait_until(func(): return not app.visualiser.is_fullscreen()), "left fullscreen")
	print("PASS: separate OS windows (ids %s), borderless player at %.1fx (screen %.1f x size %.1f) = %s px, playlist grows/shrinks the window, live re-scale, opaque capture, visualiser close (minimise)/restore keeps player, independent minimise, fullscreen on screen %d and back" % [ids, controller.ui_scale, screen_scale, controller.user_size, closed_size, screen])
	app.queue_free()
	await create_timer(0.3).timeout
	quit()
