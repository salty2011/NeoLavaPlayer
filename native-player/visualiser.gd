extends Node3D
## Visualiser: hosts the scene runtime in the root (main OS) window. It knows
## nothing about the control window: scene choice, tuning and display settings
## arrive as PlayerBus state/commands, and keys go back out through
## PlayerBus.handle_key. It runs the same with no controller (--scene-only).
const SceneRuntime = preload("res://scene_runtime.gd")
const AppSettings = preload("res://app_settings.gd")
const SceneCatalog = preload("res://scene_catalog.gd")
const MockAudioFeed = preload("res://mock_audio_feed.gd")
const DebugOverlay = preload("res://debug_overlay.gd")
const PlayerBusScript = preload("res://player_bus.gd")
const OriginalHotkeys = preload("res://original_hotkeys.gd")
const StyleFlags = preload("res://style_flags.gd")
const SyntheticSource = preload("res://analysis/synthetic_source.gd")
const ReactivityServiceScript = preload("res://analysis/reactivity_service.gd")
const ModernLayer = preload("res://modern/modern_layer.gd")
const ModernProfiles = preload("res://modern/modern_profiles.gd")
const SceneTransition = preload("res://scene_transition.gd")
## Style bits shown as Effects toggles (0x100/0x200 have no engine consumer).
const EFFECT_FLAGS := [StyleFlags.TEXTURE, StyleFlags.WIREFRAME, StyleFlags.STROBE, StyleFlags.COLORED_LIGHTING, StyleFlags.DYNAMIC_COLORING, StyleFlags.PAUSE_CAMERA, StyleFlags.FLAT_SHADING, StyleFlags.LIGHTS]

var bus
var runtime
## Audio service (non-visual) providing music analysis; may be null.
var audio
var settings = AppSettings.new()
var mock_feed
## Section schedule for the mock feed (--mock-sections=quiet:8,build:8,...).
var mock_schedule: Array = SyntheticSource.SCHEDULE
var overlay
var hint_button: Button
var hint_remaining := 0.0
var details: AcceptDialog
var inspection := false
var preset_index := 0
var last_signals := {"band_a": PackedFloat32Array(), "global_s": 0.0, "beat": false}
var scene_loaded := -1
## Classic/Modern switch (Phase 4c). The layer only changes materials,
## environment, lights and extra effect nodes; the runtime keeps simulating.
var modern
## Scene transitions (Phase 4e): the next scene builds in a SubViewport and is
## blended over the window; see docs/TRANSITIONS.md.
var transition
var _incoming_feed
var _last_real := {"band_a": [], "global_s": 0.0}

func _init():
	name = "Visualiser"

func _ready():
	bus = PlayerBusScript.instance()
	runtime = SceneRuntime.new()
	add_child(runtime)
	modern = ModernLayer.new()
	add_child(modern)
	transition = SceneTransition.new()
	add_child(transition)
	transition.blend_finished.connect(_finish_transition)
	_build_ui()
	bus.scene_changed.connect(_on_scene_changed)
	bus.scene_prepare.connect(_on_scene_prepare)
	bus.command_requested.connect(_on_command)
	bus.windows_changed.connect(_update_hint)
	bus.scene_key_handler = _scene_key
	if audio: audio.stream_started.connect(func(_path): _reset_runtimes())

func _build_ui():
	# The project allows per-pixel window transparency (the shaped player
	# window needs it), so on macOS this window shows its frame's alpha too.
	# Godot's depth-of-field pass (Modern) writes alpha < 1, which showed the
	# grey window background instead of the scene. Below every other layer,
	# add (0,0,0,1): colour unchanged, alpha forced back to 1.
	var opaque_layer := CanvasLayer.new()
	opaque_layer.name = "OpaqueAlpha"
	opaque_layer.layer = -128
	add_child(opaque_layer)
	var opaque := ColorRect.new()
	opaque.color = Color(0, 0, 0, 1)
	opaque.mouse_filter = Control.MOUSE_FILTER_IGNORE
	opaque.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var additive := CanvasItemMaterial.new()
	additive.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	opaque.material = additive
	opaque_layer.add_child(opaque)
	var layer := CanvasLayer.new()
	layer.layer = 90
	add_child(layer)
	hint_button = Button.new()
	hint_button.text = "Show controls · Tab"
	hint_button.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	hint_button.position = Vector2(-190, 20)
	hint_button.size = Vector2(170, 36)
	hint_button.visible = false
	hint_button.focus_mode = Control.FOCUS_NONE
	hint_button.pressed.connect(func(): bus.command(&"show_controller"))
	layer.add_child(hint_button)
	var overlay_layer := CanvasLayer.new()
	overlay_layer.layer = 100
	add_child(overlay_layer)
	overlay = DebugOverlay.new()
	overlay_layer.add_child(overlay)
	details = AcceptDialog.new()
	details.title = "Scene recovery status"
	details.min_size = Vector2i(800, 460)
	add_child(details)

func load_scene(index: int):
	if index < 0 or index >= bus.scenes.size(): return
	if transition != null and transition.is_active(): transition.discard()
	scene_loaded = index
	preset_index = 0
	modern.detach()
	var result = runtime.load_scene(bus.scenes[index].path)
	if audio: audio.configure_bands(runtime.data.bands)
	if mock_feed: mock_feed.band_count = maxi(runtime.data.bands.size(), 1)
	runtime.set_inspection(inspection)
	apply_display()
	# Response/Brightness start from the scene's own header values, as in the
	# original (the sliders are per-scene, SetSceneInfo 0x10015da0).
	_publish_tuning()
	_publish_scene_info()
	apply_render_mode()
	if not result.errors.is_empty(): bus.publish_status("Scene couldn't load: " + str(result.errors))

# --- Scene transitions ------------------------------------------------------

func _reset_runtimes() -> void:
	runtime.reset()
	if transition != null and transition.runtime != null: transition.runtime.reset()

func _can_transition(index: int) -> bool:
	return scene_loaded >= 0 and runtime != null and runtime.camera != null and str(bus.cycling.get("transition", "cut")) != "cut" \
		and not inspection and index >= 0 and index < bus.scenes.size()

func _on_scene_changed(index: int) -> void:
	if transition.blending:
		# A new change mid-blend: land a blend that is past halfway, drop one that
		# has barely begun, then start the new one from the window's scene.
		if transition.progress >= 0.5: transition.complete_now()
		else: transition.discard()
	elif transition.is_active() and not transition.is_prepared_for(index): transition.discard()
	if not _can_transition(index):
		load_scene(index)
		return
	if not transition.is_prepared_for(index):
		prepare_incoming(index)
		if transition.runtime == null or transition.runtime.camera == null:
			transition.discard()
			load_scene(index)
			return
	start_blend()

func _on_scene_prepare(index: int) -> void:
	if index < 0:
		if transition.is_active() and not transition.blending: transition.discard()
		return
	if transition.blending or not _can_transition(index) or transition.is_prepared_for(index): return
	prepare_incoming(index)
	if transition.runtime == null or transition.runtime.camera == null: transition.discard()

## Build the incoming scene offscreen (the one blocking step; measured in transition.load_ms).
func prepare_incoming(index: int) -> void:
	var path: String = bus.scenes[index].path
	var result: Dictionary = transition.prepare(index, path, {
		"use_reconstructions": settings.use_reconstructions, "interpolate": settings.interpolate,
		"fixed_step": settings.timing != "frame",
		"use_modern": settings.effective_render_mode(path) == "modern", "quality": settings.modern_quality, "effects": settings.modern_effects,
		"camera_mode": settings.camera_mode})
	if not result.errors.is_empty(): bus.publish_status("Scene couldn't load: " + str(result.errors))

func start_blend() -> void:
	var incoming_bands: int = maxi(transition.runtime.data.get("bands", []).size(), 1)
	_incoming_feed = MockAudioFeed.new(settings.mock_bpm, incoming_bands, mock_schedule) if using_mock() else null
	# The incoming scene's clock starts at 0; shifting the mock time keeps beats continuous.
	transition.sampler_offset = runtime.simulation_time()
	transition.start(str(bus.cycling.get("transition", "crossfade")), float(bus.cycling.get("transition_seconds", 2.0)))

## Feed for the incoming runtime: the same source the window's scene has, or null while paused.
func _incoming_sampler():
	if using_mock(): return func(time: float) -> Dictionary: return _incoming_feed.sample(time + transition.sampler_offset)
	if audio != null and audio.is_playing():
		var want: int = maxi(transition.runtime.data.get("bands", []).size(), 1)
		return func(_time: float) -> Dictionary: return _match_bands(_last_real, want)
	return null

static func _match_bands(source: Dictionary, count: int) -> Dictionary:
	var bands: Array = Array(source.get("band_a", []))
	var out := []
	for i in count: out.append(float(bands[i]) if i < bands.size() else (float(bands[-1]) if not bands.is_empty() else 0.0))
	return {"band_a": out, "global_s": float(source.get("global_s", 0.0))}

## The blend reached full cover: the incoming runtime becomes the window's scene.
func _finish_transition() -> void:
	var index: int = transition.index
	var incoming = transition.release_runtime()
	if incoming == null:
		transition.discard()
		return
	modern.detach()
	remove_child(runtime)
	runtime.free()
	runtime = incoming
	add_child(runtime)
	move_child(runtime, 0)
	scene_loaded = index
	preset_index = 0
	if audio: audio.configure_bands(runtime.data.bands)
	if mock_feed: mock_feed.band_count = maxi(runtime.data.bands.size(), 1)
	runtime.set_inspection(inspection)
	apply_display()
	_publish_tuning()
	_publish_scene_info()
	modern.handoff = transition.handoff
	transition.handoff = {}
	apply_render_mode()
	# The frozen stage frame keeps covering the window until the window has drawn the adopted scene.
	transition.begin_hold(2)

# --- Render mode (Classic / Modern) -----------------------------------------

func _scene_folder() -> String:
	return str(runtime.data.get("folder", "")) if runtime != null and runtime.data != null else ""

## Attach or detach the Modern layer for the current scene. Never resets the
## scene: geometry, effects, camera and random state carry on unchanged.
func apply_render_mode() -> void:
	var folder := _scene_folder()
	var want_modern := not folder.is_empty() and settings.effective_render_mode(folder) == "modern" and not inspection
	modern.quality = settings.modern_quality
	modern.effects = settings.modern_effects.duplicate()
	modern.camera_mode = settings.camera_mode
	if want_modern:
		if not modern.attached or modern.runtime != runtime: modern.attach(runtime)
		else: modern.rebuild()
	else: modern.detach()
	_publish_render()

func _publish_render() -> void:
	var folder := _scene_folder()
	var key := AppSettings.scene_key(folder) if not folder.is_empty() else ""
	bus.publish_render({"mode": settings.render_mode, "effective": "modern" if modern.attached else "classic",
		"scene_override": str(settings.render_overrides.get(key, "")), "modern_available": ModernProfiles.has_profile(folder),
		"modern_active": modern.attached, "quality": settings.modern_quality, "effects": settings.modern_effects.duplicate(),
		"camera_mode": settings.camera_mode})

func render_status() -> String:
	if modern.attached: return "Render: Modern (%s)" % settings.modern_quality.capitalize()
	if settings.effective_render_mode(_scene_folder()) == "modern": return "Render: Classic (no Modern profile for this scene yet)"
	return "Render: Classic"

## scope "global" flips the global mode (and clears this scene's override);
## scope "scene" flips only this scene via a per-scene override.
func set_render_mode(mode: String, scope: String) -> void:
	var key := AppSettings.scene_key(_scene_folder())
	if scope == "scene":
		if mode == "default" or mode == settings.render_mode: settings.render_overrides.erase(key)
		elif AppSettings.RENDER_MODES.has(mode): settings.render_overrides[key] = mode
	elif AppSettings.RENDER_MODES.has(mode):
		settings.render_mode = mode
		settings.render_overrides.erase(key)
	settings.save_settings()
	apply_render_mode()
	bus.publish_status(render_status() + (" — this scene only" if settings.render_overrides.has(key) else ""))

## Render pacing and timing from settings (fps cap, vsync, smoothing, ticks).
func apply_display():
	settings.apply()
	runtime.interpolate = settings.interpolate
	runtime.fixed_step = settings.timing != "frame"
	runtime.use_reconstructions = settings.use_reconstructions

func set_analysis_source(source: String, persist: bool):
	settings.analysis_source = source
	mock_feed = MockAudioFeed.new(settings.mock_bpm, maxi(runtime.data.get("bands", []).size(), 1), mock_schedule) if source == "mock" else null
	if persist: settings.save_settings()
	_reset_runtimes()
	# The reactivity layer follows: same BPM and schedule, clock restarted with the scene.
	bus.publish_analysis_source(source, {"bpm": settings.mock_bpm, "schedule": mock_schedule} if source == "mock" else {})
	settings.changed.emit()

func using_mock() -> bool: return mock_feed != null

## Response/Brightness sliders (0..100), original mappings from the runtime
## (Response 2^(s*0.02-1), Brightness s*0.01). A negative slider = scene value.
func set_tuning(response_slider: float, brightness_slider: float):
	if runtime.has_method("set_response"):
		runtime.set_response(SceneRuntime.response_from_slider(response_slider) if response_slider >= 0.0 else null)
	if runtime.has_method("set_brightness"):
		runtime.set_brightness(SceneRuntime.brightness_from_slider(brightness_slider) if brightness_slider >= 0.0 else null)
	_publish_tuning()
	_publish_scene_info()

func _publish_tuning():
	if runtime.has_method("get_response"): bus.publish_tuning(runtime.get_response(), runtime.get_brightness())

## Original visualiser keys (T W S L C P M N F5-F8, Shift+F3/F4), offered by
## PlayerBus before player hotkeys, from either window.
func _scene_key(event: InputEventKey) -> bool:
	var text := OriginalHotkeys.handle(runtime, event)
	if text.is_empty(): return false
	bus.publish_status(text)
	_publish_scene_info()
	return true

func _on_command(command: StringName, args: Dictionary):
	match command:
		&"toggle_fullscreen": toggle_fullscreen()
		&"set_fullscreen": set_fullscreen(bool(args.get("on", true)))
		&"escape":
			if bus.scene_only: get_tree().quit()
			else: set_fullscreen(false)
		&"toggle_debug_overlay": overlay.visible = not overlay.visible
		&"cycle_fps_cap":
			settings.cycle_debug_cap()
			apply_display()
			bus.publish_status("Frame cap (F4 debug, not saved): " + AppSettings.fps_label(settings.effective_cap()))
		&"set_display":
			for key in args:
				if key in ["fps_cap", "vsync", "interpolate", "timing", "use_reconstructions"]: settings.set(key, args[key])
			if args.has("fps_cap"): settings.debug_cap_override = null
			settings.save_settings()
			apply_display()
			if args.has("timing"): runtime.reset()
			if args.has("use_reconstructions"):
				for entry in bus.scenes: SceneCatalog.mark_reconstructed(entry, settings.use_reconstructions)
				if scene_loaded >= 0: load_scene(scene_loaded)
			settings.changed.emit()
		&"set_analysis_source": set_analysis_source(str(args.get("source", "real")), true)
		&"set_inspection":
			inspection = bool(args.get("on", false))
			runtime.set_inspection(inspection)
			apply_display()
			apply_render_mode()
		&"set_style_flag":
			runtime.set_style_flag(int(args.get("flag", 0)), bool(args.get("on", false)))
			_publish_scene_info()
		&"trigger_effect_preset":
			var result: Dictionary = runtime.trigger_effect_preset(int(args.get("index", 0)))
			if not result.is_empty(): bus.publish_status("Special effect %s: %s" % [result.category, result.preset])
			_publish_scene_info()
		&"toggle_text_message":
			bus.publish_status("3D text " + ("on" if runtime.toggle_text_message() else "off"))
			_publish_scene_info()
		&"show_intro":
			bus.publish_status("Intro screen" if runtime.show_intro() else "This scene has no intro screen")
		&"set_tuning": set_tuning(float(args.get("response_slider", -1.0)), float(args.get("brightness_slider", -1.0)))
		&"apply_preset": apply_preset(int(args.get("index", 0)))
		&"show_recovery_details": show_details()
		&"toggle_render_mode":
			var current := settings.effective_render_mode(_scene_folder())
			set_render_mode("classic" if current == "modern" else "modern", str(args.get("scope", "global")))
		&"set_render_mode": set_render_mode(str(args.get("mode", "classic")), str(args.get("scope", "global")))
		&"set_modern_quality":
			var quality := str(args.get("quality", "high")).to_lower()
			settings.modern_quality = quality if AppSettings.MODERN_QUALITIES.has(quality) else "high"
			settings.save_settings()
			apply_render_mode()
			bus.publish_status(render_status())
		&"set_modern_effects":
			for key in AppSettings.MODERN_EFFECT_DEFAULTS:
				if args.has(key): settings.modern_effects[key] = bool(args[key])
			settings.save_settings()
			apply_render_mode()
		&"set_camera_mode":
			# Phase 4d: Modern camera (director / original / locked); applied live, no rebuild.
			var camera_mode := str(args.get("mode", "director")).to_lower()
			settings.camera_mode = camera_mode if AppSettings.CAMERA_MODES.has(camera_mode) else "director"
			settings.save_settings()
			modern.camera_mode = settings.camera_mode
			_publish_render()
			bus.publish_status("Camera: " + settings.camera_mode.capitalize())

func apply_preset(index: int):
	if index <= 0: load_scene(scene_loaded)
	elif index - 1 < runtime.data.effect_presets.size(): runtime.apply_preset_file(runtime.data.effect_presets[index - 1].file)
	preset_index = maxi(index, 0)
	_publish_scene_info()

func _publish_scene_info():
	var supported: bool = runtime.has_method("set_response") and runtime.has_method("set_brightness")
	var flags := []
	if runtime.has_method("get_style_flags"):
		var mask: int = runtime.get_style_flags()
		for flag in EFFECT_FLAGS: flags.append({"flag": flag, "name": StyleFlags.NAMES[flag], "on": (mask & flag) != 0, "key": StyleFlags.ORIGINAL_KEYS.get(flag, "")})
	var categories := []
	for category in runtime.get("preset_categories") if runtime.get("preset_categories") != null else []:
		var presets: Array = category.get("presets", [])
		var current := int(category.get("current", 0))
		categories.append({"name": str(category.get("name", "")), "count": presets.size(), "current": presets[current].name if current >= 0 and current < presets.size() else ""})
	bus.publish_scene_info({"presets": preset_names(), "preset_index": preset_index, "tuning_supported": supported,
		"response_slider": SceneRuntime.slider_from_response(runtime.get_response()) if supported else 50.0,
		"brightness_slider": runtime.get_brightness() * 100.0 if supported else 100.0,
		"style_flags": flags, "effect_categories": categories,
		"text_message": runtime.text_message_enabled() if runtime.has_method("text_message_enabled") else false})

func preset_names() -> PackedStringArray:
	var names := PackedStringArray(["Original scene preset"])
	for preset in runtime.data.get("effect_presets", []): names.append(preset.name)
	return names

func show_details():
	var summary = runtime.summary()
	details.dialog_text = bus.scene_title(scene_loaded) + "\nRecovered objects: %d / %d\nOriginal rendering and whole-scene random sequence parity are still unverified.\n\nTextures recovered from other discs (original Creative files): %s\nTextures RECONSTRUCTED (procedural stand-ins, NOT Creative assets): %s\n\nMissing resources: %s\n\nUnimplemented behavior: %s" % [summary.loaded_objects, summary.total_objects, str(summary.recovered_textures), str(summary.reconstructed_textures), str(summary.missing_resources), JSON.stringify(summary.unsupported, "  ")]
	details.popup_centered(Vector2i(900, 600))

# --- Window -------------------------------------------------------------

func is_fullscreen() -> bool:
	var mode := get_window().mode
	return mode == Window.MODE_FULLSCREEN or mode == Window.MODE_EXCLUSIVE_FULLSCREEN

func toggle_fullscreen(): set_fullscreen(not is_fullscreen())

## Fullscreen on the screen the window is on now (second monitors included).
func set_fullscreen(on: bool):
	var w := get_window()
	if DisplayServer.get_name() == "headless": return
	if on:
		if w.mode == Window.MODE_MINIMIZED: w.mode = Window.MODE_WINDOWED
		var screen := DisplayServer.window_get_current_screen(w.get_window_id())
		w.current_screen = screen
		w.mode = Window.MODE_FULLSCREEN
	elif is_fullscreen(): w.mode = Window.MODE_WINDOWED
	_publish_windows()

func _publish_windows():
	bus.publish_windows(get_window().mode != Window.MODE_MINIMIZED, is_fullscreen(), bus.controller_visible, bus.drawer_open)

func _update_hint():
	if bus.controller_visible or not bus.controller_present: hint_button.visible = false

# --- Input / frame --------------------------------------------------------

func _input(event):
	if event is InputEventKey and event.pressed:
		if details.visible: return
		if bus.handle_key(event, "visualiser"): get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed and event.double_click and event.button_index == MOUSE_BUTTON_LEFT:
		toggle_fullscreen()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and bus.controller_present and not bus.controller_visible:
		hint_remaining = 3.0
		hint_button.visible = true

func _process(delta):
	if hint_button.visible:
		hint_remaining = maxf(0.0, hint_remaining - delta)
		if hint_remaining == 0.0 and not hint_button.is_hovered(): hint_button.visible = false
	var playing: bool = audio != null and audio.is_playing()
	if using_mock(): runtime.advance(delta, _sample_mock)
	elif playing: runtime.advance(delta, _sample_real)
	if modern.attached: modern.update(delta)
	if transition.blending: transition.advance(delta, _incoming_sampler())
	overlay.record(delta, overlay_info() if overlay.visible else {})

func _sample_real(time: float) -> Dictionary:
	var signals: Dictionary = audio.sample(time)
	last_signals = {"band_a": signals.band_a, "global_s": signals.global_s, "beat": false}
	_last_real = last_signals
	bus.publish_analysis(last_signals)
	return signals

func _sample_mock(time: float) -> Dictionary:
	last_signals = mock_feed.sample(time)
	bus.publish_analysis(last_signals)
	return last_signals

func overlay_info() -> Dictionary:
	return {"scene": bus.scene_title(scene_loaded), "fps_cap": AppSettings.fps_label(settings.effective_cap()) + (" (F4)" if settings.debug_cap_override != null else ""), "vsync": settings.vsync, "source": ("synthetic %d BPM (%s)" % [int(settings.mock_bpm), last_signals.get("section", "")]) if using_mock() else "music analysis", "band_a": last_signals.get("band_a", []), "global_s": last_signals.get("global_s", 0.0), "beat": last_signals.get("beat", false), "ticks": runtime.metrics.get("ticks", 0), "sim_rate": runtime.simulation_rate(), "timing": "fixed" if runtime.fixed_step else "per-frame dt", "react": ReactivityServiceScript.instance().debug_info(), "render": render_status().trim_prefix("Render: ")}
