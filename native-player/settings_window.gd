extends Window
## Settings (Ctrl+T / player menu): a normal decorated OS window.
## Laid out in base units and drawn at PlayerFormat.settings_scale (screen
## scale x a step of the player size) through content_scale_factor, so it is
## readable on Retina screens; apply_scale() follows player size changes.
## Reads PlayerBus state and settings.cfg; every change is a bus command, so it
## needs no reference to the visualiser or the services.
const AppSettings = preload("res://app_settings.gd")
const SceneDirector = preload("res://scene_director.gd")
const SceneTransition = preload("res://scene_transition.gd")
const SceneCatalog = preload("res://scene_catalog.gd")
const PlayerFormat = preload("res://player/player_format.gd")
const PlayerBusScript = preload("res://player_bus.gd")

var bus
var scene_list: ItemList
var preset_option: OptionButton
var cycle_check: CheckBox
var interval_option: OptionButton
var order_option: OptionButton
var mode_option: OptionButton
var musical_check: CheckBox
var transition_option: OptionButton
var duration_option: OptionButton
var pin_label: Label
var response_slider: HSlider
var brightness_slider: HSlider
var tuning_note: Label
var effects_page: VBoxContainer
var effect_flags_box: VBoxContainer
var effect_presets_box: VBoxContainer
var text_check: CheckBox
var fps_option: OptionButton
var vsync_check: CheckBox
var smooth_check: CheckBox
var recon_check: CheckBox
var timing_option: OptionButton
var source_option: OptionButton
var size_option: OptionButton
var visualiser_button: Button
var react_sensitivity: HSlider
var react_camera: HSlider
var react_effects: HSlider
var react_prefetch: CheckBox
var react_status: Label
var render_mode_option: OptionButton
var render_scene_option: OptionButton
var render_quality_option: OptionButton
var render_camera_option: OptionButton
var render_effect_checks := {}
var render_status: Label
var _updating := false
## Design size and minimum in base units (content scale 1).
const BASE_SIZE := Vector2(560, 520)
const BASE_MIN := Vector2(460, 420)
var ui_scale := 1.0

func _init():
	name = "Settings"
	title = "Oozic Player Settings"
	size = Vector2i(BASE_SIZE)
	min_size = Vector2i(BASE_MIN)
	content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	content_scale_aspect = Window.CONTENT_SCALE_ASPECT_IGNORE
	transient = false
	visible = false
	wrap_controls = true

func _ready():
	bus = PlayerBusScript.instance()
	close_requested.connect(hide)
	var background := Panel.new()
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]: margin.add_theme_constant_override("margin_" + side, 12)
	add_child(margin)
	var tabs := TabContainer.new()
	margin.add_child(tabs)
	_build_scenes(tabs)
	_build_effects(tabs)
	_build_display(tabs)
	_build_reactivity(tabs)
	_build_rendering(tabs)
	_build_playlist(tabs)
	_build_tools(tabs)
	bus.scene_list_changed.connect(refresh)
	bus.scene_changed.connect(func(_i): refresh())
	bus.cycling_changed.connect(refresh)
	bus.scene_pins_changed.connect(refresh)
	bus.track_changed.connect(func(_i, _t): refresh())
	bus.tuning_changed.connect(func(_r, _b): refresh())
	bus.scene_info_changed.connect(func(): refresh.call_deferred())
	bus.windows_changed.connect(refresh)
	bus.reactivity_changed.connect(func(): _refresh_reactivity.call_deferred())
	bus.render_changed.connect(func(): _refresh_rendering.call_deferred())
	refresh()

func open():
	refresh()
	popup_centered(_fitted_size())
	grab_focus()

## Render scale for a screen scale and player size, shrunk when the window
## would not fit the usable screen. Keeps the current pixel size in ratio.
func apply_scale(screen_scale: float, user_size: float):
	var usable := _usable_pixels()
	var wanted := PlayerFormat.settings_scale(screen_scale, user_size)
	var fit := minf(usable.x / BASE_MIN.x, usable.y / BASE_MIN.y)
	var old := ui_scale
	ui_scale = maxf(minf(wanted, fit), 0.5)
	content_scale_factor = ui_scale
	min_size = Vector2i((BASE_MIN * ui_scale).ceil())
	var target := Vector2(size) / old * ui_scale if visible else BASE_SIZE * ui_scale
	size = Vector2i(target.min(usable).max(Vector2(min_size)).ceil())
	_scale_popups(self)

func _fitted_size() -> Vector2i:
	return Vector2i(Vector2(size).min(_usable_pixels()).max(Vector2(min_size)))

func _usable_pixels() -> Vector2:
	if DisplayServer.get_name() == "headless": return Vector2(1e5, 1e5)
	var screen := current_screen if visible else DisplayServer.window_get_current_screen()
	return Vector2(DisplayServer.screen_get_usable_rect(screen).size) * 0.94

## Option menus are their own OS windows: give them the same scale.
func _scale_popups(node: Node):
	for child in node.get_children():
		if child is OptionButton: child.get_popup().content_scale_factor = ui_scale
		_scale_popups(child)

func _page(tabs: TabContainer, caption: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = caption
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(scroll)
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 8)
	scroll.add_child(column)
	return column

func _row(parent: Control, caption: String, control: Control) -> Control:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = caption
	label.custom_minimum_size.x = 170
	row.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	parent.add_child(row)
	return control

func _heading(parent: Control, text: String):
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 15)
	parent.add_child(label)

func _build_scenes(tabs: TabContainer):
	var page := _page(tabs, "Scenes")
	_heading(page, "Scene")
	scene_list = ItemList.new()
	scene_list.custom_minimum_size.y = 150
	scene_list.item_selected.connect(func(index):
		if not _updating: bus.command(&"select_scene", {"index": index}))
	page.add_child(scene_list)
	preset_option = _row(page, "Special effects preset", OptionButton.new())
	preset_option.item_selected.connect(func(index):
		if not _updating: bus.command(&"apply_preset", {"index": index}))
	_heading(page, "Multi-scene")
	cycle_check = CheckBox.new()
	cycle_check.text = "Cycle through scenes"
	cycle_check.toggled.connect(func(on): _set_cycling({"enabled": on}))
	page.add_child(cycle_check)
	interval_option = _row(page, "Change scene every", OptionButton.new())
	for seconds in SceneDirector.INTERVALS: interval_option.add_item(SceneDirector.interval_label(seconds))
	interval_option.item_selected.connect(func(index): _set_cycling({"interval": SceneDirector.INTERVALS[index]}))
	order_option = _row(page, "Order", OptionButton.new())
	order_option.add_item("Random")
	order_option.add_item("Alphabetical")
	order_option.item_selected.connect(func(index): _set_cycling({"order": "alphabetical" if index == 1 else "random"}))
	mode_option = _row(page, "Cycle mode", OptionButton.new())
	for entry in [["time", "By time (original)"], ["track", "Each new track"], ["section", "At major section changes (min. 60 s)"]]:
		mode_option.add_item(entry[1])
		mode_option.set_item_metadata(mode_option.item_count - 1, entry[0])
	mode_option.item_selected.connect(func(index): _set_cycling({"mode": mode_option.get_item_metadata(index)}))
	musical_check = CheckBox.new()
	musical_check.text = "Musical timing: change on a downbeat or phrase, not mid-drop"
	musical_check.toggled.connect(func(on): _set_cycling({"musical": on}))
	page.add_child(musical_check)
	_heading(page, "Transitions")
	transition_option = _row(page, "Style", OptionButton.new())
	for id in SceneTransition.STYLE_IDS:
		transition_option.add_item(SceneTransition.STYLE_LABELS[id])
		transition_option.set_item_metadata(transition_option.item_count - 1, id)
	transition_option.item_selected.connect(func(index): _set_cycling({"transition": transition_option.get_item_metadata(index)}))
	duration_option = _row(page, "Duration", OptionButton.new())
	for seconds in SceneTransition.DURATIONS: duration_option.add_item("%s s" % str(seconds))
	duration_option.item_selected.connect(func(index): _set_cycling({"transition_seconds": SceneTransition.DURATIONS[index]}))
	var pin_row := HBoxContainer.new()
	var pin_button := Button.new()
	pin_button.text = "Pin scene to this track"
	pin_button.tooltip_text = "Always show the current scene when this track plays (saved with the playlist)"
	pin_button.pressed.connect(func(): bus.command(&"pin_scene"))
	pin_row.add_child(pin_button)
	var unpin_button := Button.new()
	unpin_button.text = "Unpin"
	unpin_button.pressed.connect(func(): bus.command(&"unpin_scene"))
	pin_row.add_child(unpin_button)
	pin_label = Label.new()
	pin_label.modulate = Color(1, 1, 1, 0.65)
	pin_row.add_child(pin_label)
	page.add_child(pin_row)
	_heading(page, "Response and brightness")
	response_slider = _row(page, "Response", _tuning_slider())
	brightness_slider = _row(page, "Brightness", _tuning_slider())
	response_slider.value_changed.connect(func(_v): _set_tuning())
	brightness_slider.value_changed.connect(func(_v): _set_tuning())
	var reset := Button.new()
	reset.text = "Scene values"
	reset.tooltip_text = "Return Response and Brightness to the values saved in the scene"
	reset.pressed.connect(func(): bus.command(&"set_tuning", {"response_slider": -1.0, "brightness_slider": -1.0}))
	page.add_child(reset)
	tuning_note = Label.new()
	tuning_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tuning_note.modulate = Color(1, 1, 1, 0.65)
	page.add_child(tuning_note)

## Original 0..100 sliders (TraySkn3 2228/2229). Response = 2^(s*0.02-1)
## (0.5x..2x scene time), Brightness = s*0.01 (light ambient multiplier).
func _tuning_slider() -> HSlider:
	var slider := HSlider.new()
	slider.min_value = 0
	slider.max_value = 100
	slider.step = 1
	return slider

func _set_cycling(changes: Dictionary):
	if not _updating: bus.command(&"set_cycling", changes)

func _set_tuning():
	if not _updating: bus.command(&"set_tuning", {"response_slider": response_slider.value, "brightness_slider": brightness_slider.value})

## Original Effects tab (TrayEfx3): Style-mask toggles, special effects F5-F8,
## 3D text (M) and intro (N). The runtime resets the toggles to the scene's
## Style defaults on every scene load.
func _build_effects(tabs: TabContainer):
	effects_page = _page(tabs, "Effects")
	effect_flags_box = VBoxContainer.new()
	effects_page.add_child(effect_flags_box)
	_heading(effects_page, "Special effects (F5-F8)")
	effect_presets_box = VBoxContainer.new()
	effects_page.add_child(effect_presets_box)
	_heading(effects_page, "Message and intro")
	text_check = CheckBox.new()
	text_check.text = "3D text message (M)"
	text_check.toggled.connect(func(_on):
		if not _updating: bus.command(&"toggle_text_message"))
	effects_page.add_child(text_check)
	var intro := Button.new()
	intro.text = "Show intro screen (N)"
	intro.pressed.connect(func(): bus.command(&"show_intro"))
	effects_page.add_child(intro)

func _refresh_effects():
	for box in [effect_flags_box, effect_presets_box]:
		for child in box.get_children():
			box.remove_child(child)
			child.queue_free()
	for entry in bus.scene_info.get("style_flags", []):
		var check := CheckBox.new()
		var key := str(entry.get("key", ""))
		if key in ["F3", "F4"]: key = "Shift+" + key
		check.text = str(entry.name) + ("  (" + key + ")" if not key.is_empty() else "")
		check.button_pressed = bool(entry.on)
		var flag := int(entry.flag)
		check.toggled.connect(func(on): bus.command(&"set_style_flag", {"flag": flag, "on": on}))
		effect_flags_box.add_child(check)
	var categories: Array = bus.scene_info.get("effect_categories", [])
	for i in categories.size():
		var b := Button.new()
		b.text = "F%d  %s: %s  (%d)" % [5 + i, categories[i].name, categories[i].current, categories[i].count]
		var index := i
		b.pressed.connect(func(): bus.command(&"trigger_effect_preset", {"index": index}))
		effect_presets_box.add_child(b)
	if categories.is_empty():
		var none := Label.new()
		none.text = "This scene has no special-effect categories."
		effect_presets_box.add_child(none)
	text_check.set_pressed_no_signal(bool(bus.scene_info.get("text_message", false)))

func _build_display(tabs: TabContainer):
	var page := _page(tabs, "Display")
	_heading(page, "Visualiser window")
	var row := HBoxContainer.new()
	visualiser_button = Button.new()
	visualiser_button.pressed.connect(func(): bus.command(&"toggle_visualiser"))
	row.add_child(visualiser_button)
	var fullscreen := Button.new()
	fullscreen.text = "Fullscreen (F11)"
	fullscreen.pressed.connect(func(): bus.command(&"set_fullscreen", {"on": true}))
	row.add_child(fullscreen)
	page.add_child(row)
	_heading(page, "Rendering")
	fps_option = _row(page, "Frame cap", OptionButton.new())
	for cap in AppSettings.FPS_CHOICES: fps_option.add_item(AppSettings.fps_label(cap))
	fps_option.item_selected.connect(func(index): _display({"fps_cap": AppSettings.FPS_CHOICES[index]}))
	vsync_check = CheckBox.new()
	vsync_check.text = "VSync"
	vsync_check.toggled.connect(func(on): _display({"vsync": on}))
	page.add_child(vsync_check)
	smooth_check = CheckBox.new()
	smooth_check.text = "Smooth motion (interpolate between 60 Hz scene ticks)"
	smooth_check.toggled.connect(func(on): _display({"interpolate": on}))
	page.add_child(smooth_check)
	timing_option = _row(page, "Scene timing", OptionButton.new())
	timing_option.add_item("Fixed 60 Hz scene ticks")
	timing_option.add_item("Per-frame dt (original)")
	timing_option.item_selected.connect(func(index): _display({"timing": "frame" if index == 1 else "fixed"}))
	recon_check = CheckBox.new()
	recon_check.text = "Use reconstructed textures (stand-ins for textures never recovered)"
	recon_check.toggled.connect(func(on): _display({"use_reconstructions": on}))
	page.add_child(recon_check)
	source_option = _row(page, "Scene input", OptionButton.new())
	source_option.add_item("Music analysis")
	source_option.add_item("Synthetic beat (silent)")
	source_option.item_selected.connect(func(index):
		if not _updating: bus.command(&"set_analysis_source", {"source": "mock" if index == 1 else "real"}))
	_heading(page, "Player window")
	size_option = _row(page, "Player size", OptionButton.new())
	for value in PlayerFormat.USER_SIZES:
		var label := PlayerFormat.size_label(value)
		if is_equal_approx(value, PlayerFormat.DEFAULT_USER_SIZE): label += " (default)"
		size_option.add_item(label)
	size_option.tooltip_text = "Scales the player on top of the screen's own scale (Retina = 2)."
	size_option.item_selected.connect(func(index):
		if not _updating: bus.command(&"set_player_size", {"size": PlayerFormat.USER_SIZES[index]}))

## Reactivity layer (modern scenes; classic scenes keep the original analysis).
## Values are percentages in the UI and factors on the bus (set_reactivity).
func _build_reactivity(tabs: TabContainer):
	var page := _page(tabs, "Reactivity")
	var note := Label.new()
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.modulate = Color(1, 1, 1, 0.65)
	note.text = "How strongly modern scenes react to the music. Classic scenes use the original analysis and ignore these."
	page.add_child(note)
	react_sensitivity = _row(page, "Reactivity sensitivity", _percent_slider(300))
	react_camera = _row(page, "Camera intensity", _percent_slider(200))
	react_effects = _row(page, "Effects intensity", _percent_slider(200))
	react_sensitivity.value_changed.connect(func(v): _reactivity({"sensitivity": v / 100.0}))
	react_camera.value_changed.connect(func(v): _reactivity({"camera_intensity": v / 100.0}))
	react_effects.value_changed.connect(func(v): _reactivity({"effects_intensity": v / 100.0}))
	react_prefetch = CheckBox.new()
	react_prefetch.text = "Pre-analyse the next tracks in the background"
	react_prefetch.toggled.connect(func(on): _reactivity({"prefetch": on}))
	page.add_child(react_prefetch)
	var reset := Button.new()
	reset.text = "Defaults"
	reset.pressed.connect(func(): bus.command(&"set_reactivity", AppSettings.REACTIVITY_DEFAULTS.duplicate()))
	page.add_child(reset)
	react_status = Label.new()
	react_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(react_status)

func _percent_slider(maximum: float) -> HSlider:
	var slider := HSlider.new()
	slider.min_value = 0
	slider.max_value = maximum
	slider.step = 5
	slider.tooltip_text = "100% = default"
	return slider

func _reactivity(changes: Dictionary):
	if not _updating: bus.command(&"set_reactivity", changes)

func _refresh_reactivity():
	if react_sensitivity == null: return
	var was := _updating
	_updating = true
	var r: Dictionary = AppSettings.sanitize_reactivity(bus.reactivity)
	react_sensitivity.value = r.sensitivity * 100.0
	react_camera.value = r.camera_intensity * 100.0
	react_effects.value = r.effects_intensity * 100.0
	react_prefetch.button_pressed = r.prefetch
	var source := str(bus.reactivity.get("source", "idle"))
	var labels := {"pre-analysed": "pre-analysed track (beats, sections and drops known ahead)", "live": "live analysis (no lookahead yet)", "mock": "synthetic beat", "idle": "idle"}
	react_status.text = "Source: " + str(labels.get(source, source))
	if float(bus.reactivity.get("track_bpm", 0.0)) > 0.0: react_status.text += " · %.1f BPM" % float(bus.reactivity.track_bpm)
	if not str(bus.reactivity.get("analysing", "")).is_empty(): react_status.text += "\nAnalysing " + str(bus.reactivity.analysing) + "…"
	_updating = was

## Classic / Modern render mode (Phase 4c; docs/MODERN_RENDERING.md). Every
## change is a bus command; the visualiser applies it without a scene reset.
const RENDER_EFFECT_LABELS := {"particles": "Music motes and drop bursts", "trails": "Light trails on moving heads", "dof": "Depth of field", "post": "Lens hit on drops (aberration + blur)"}
func _build_rendering(tabs: TabContainer):
	var page := _page(tabs, "Rendering")
	var note := Label.new()
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.modulate = Color(1, 1, 1, 0.65)
	note.text = "Classic renders exactly as the original. Modern is the upgraded look, on scenes that have a Modern profile. F9 switches everywhere; Shift+F9 switches only the current scene."
	page.add_child(note)
	render_mode_option = _row(page, "Render mode", OptionButton.new())
	render_mode_option.add_item("Classic", 0)
	render_mode_option.add_item("Modern", 1)
	render_mode_option.item_selected.connect(func(i): if not _updating: bus.command(&"set_render_mode", {"mode": ["classic", "modern"][i], "scope": "global"}))
	render_scene_option = _row(page, "This scene", OptionButton.new())
	render_scene_option.add_item("Follow render mode", 0)
	render_scene_option.add_item("Always Classic", 1)
	render_scene_option.add_item("Always Modern", 2)
	render_scene_option.item_selected.connect(func(i): if not _updating: bus.command(&"set_render_mode", {"mode": ["default", "classic", "modern"][i], "scope": "scene"}))
	render_quality_option = _row(page, "Modern quality", OptionButton.new())
	for i in AppSettings.MODERN_QUALITIES.size(): render_quality_option.add_item(str(AppSettings.MODERN_QUALITIES[i]).capitalize(), i)
	render_quality_option.item_selected.connect(func(i): if not _updating: bus.command(&"set_modern_quality", {"quality": AppSettings.MODERN_QUALITIES[i]}))
	render_camera_option = _row(page, "Modern camera", OptionButton.new())
	render_camera_option.add_item("Director (cuts and moves with the music)", 0)
	render_camera_option.add_item("Original (recovered Lava camera)", 1)
	render_camera_option.add_item("Locked (static)", 2)
	render_camera_option.item_selected.connect(func(i): if not _updating: bus.command(&"set_camera_mode", {"mode": AppSettings.CAMERA_MODES[i]}))
	_heading(page, "Modern effects")
	for key in RENDER_EFFECT_LABELS:
		var check := CheckBox.new()
		check.text = RENDER_EFFECT_LABELS[key]
		check.toggled.connect(func(on): if not _updating: bus.command(&"set_modern_effects", {key: on}))
		page.add_child(check)
		render_effect_checks[key] = check
	render_status = Label.new()
	render_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(render_status)

func _refresh_rendering():
	if render_mode_option == null or bus.render.is_empty(): return
	var was := _updating
	_updating = true
	var r: Dictionary = bus.render
	render_mode_option.select(1 if r.get("mode", "modern") == "modern" else 0)
	render_scene_option.select({"classic": 1, "modern": 2}.get(str(r.get("scene_override", "")), 0))
	render_quality_option.select(maxi(AppSettings.MODERN_QUALITIES.find(str(r.get("quality", "high"))), 0))
	render_camera_option.select(maxi(AppSettings.CAMERA_MODES.find(str(r.get("camera_mode", "director"))), 0))
	for key in render_effect_checks: render_effect_checks[key].button_pressed = bool(r.get("effects", {}).get(key, true))
	render_status.text = ("Showing: Modern" if r.get("modern_active", false) else "Showing: Classic") + ("" if r.get("modern_available", false) else " (this scene has no Modern profile yet)")
	_updating = was

func _display(changes: Dictionary):
	if not _updating: bus.command(&"set_display", changes)

func _build_playlist(tabs: TabContainer):
	var page := _page(tabs, "Playlist")
	var note := Label.new()
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.text = "The playlist is saved automatically and restored at the next start. Import and export use .m3u files."
	page.add_child(note)
	for spec in [["Import .m3u…", &"import_m3u_dialog"], ["Export .m3u…", &"export_m3u_dialog"], ["Add files… (Ctrl+A)", &"add_tracks"], ["Add folder… (Shift+A)", &"add_directory"], ["Clear playlist", &"clear_playlist"]]:
		var b := Button.new()
		b.text = spec[0]
		var command: StringName = spec[1]
		b.pressed.connect(func(): bus.command(command))
		page.add_child(b)
	_build_apple_music(page)

## Apple Music options (docs/APPLE_MUSIC.md): the volume link (default off)
## and the diagnostics log.
var music_volume_check: CheckBox
func _build_apple_music(page: Control):
	_heading(page, "Apple Music")
	music_volume_check = CheckBox.new()
	music_volume_check.text = "Oozic volume controls the Music app"
	music_volume_check.tooltip_text = "Off (default): Oozic's volume and mute only affect files Oozic plays itself; the Music app keeps its own volume. On: Oozic sets Music's volume (mute sets it to 0 until you unmute or quit)."
	music_volume_check.toggled.connect(func(on): if not _updating: bus.command(&"set_music_volume_link", {"on": on}))
	page.add_child(music_volume_check)
	var reveal := Button.new()
	reveal.text = "Reveal diagnostics log"
	reveal.tooltip_text = "~/Library/Logs/NeoLavaPlayer/music.log: what Oozic asked Music to do and what it heard back. Send it with a problem report."
	reveal.pressed.connect(func(): bus.command(&"reveal_diagnostics"))
	page.add_child(reveal)

func _build_tools(tabs: TabContainer):
	var page := _page(tabs, "Scene tools")
	var inspect := CheckBox.new()
	inspect.text = "Inspect objects"
	inspect.toggled.connect(func(on): bus.command(&"set_inspection", {"on": on}))
	page.add_child(inspect)
	var details := Button.new()
	details.text = "Recovery details"
	details.pressed.connect(func(): bus.command(&"show_recovery_details"))
	page.add_child(details)
	var keys := Label.new()
	keys.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	keys.text = "Keys (either window): Space play/pause · ←/→ seek 5 s · ↑/↓ volume · Tab show/hide player · F11 or double-click fullscreen · Esc leave fullscreen · Page Up/Down scene · F3 debug overlay · F4 frame-cap cycle · Ctrl+P/S/U/M/N/B/O/L/A/D/T/I original player keys · T W S L C P, Shift+F3/F4, M, N, F5-F8 original visualiser keys."
	page.add_child(keys)

func refresh():
	if bus == null or scene_list == null: return
	_updating = true
	scene_list.clear()
	for entry in bus.scenes: scene_list.add_item(SceneCatalog.label(entry))
	if bus.scene_index >= 0 and bus.scene_index < scene_list.item_count:
		scene_list.select(bus.scene_index)
		scene_list.ensure_current_is_visible()
	preset_option.clear()
	for preset in bus.scene_info.get("presets", PackedStringArray(["Original scene preset"])): preset_option.add_item(preset)
	preset_option.disabled = preset_option.item_count <= 1
	if preset_option.item_count > 0: preset_option.select(clampi(int(bus.scene_info.get("preset_index", 0)), 0, preset_option.item_count - 1))
	cycle_check.button_pressed = bool(bus.cycling.enabled)
	interval_option.select(maxi(SceneDirector.INTERVALS.find(int(bus.cycling.interval)), 0))
	order_option.select(1 if bus.cycling.order == "alphabetical" else 0)
	for i in mode_option.item_count:
		if mode_option.get_item_metadata(i) == bus.cycling.get("mode", "time"): mode_option.select(i)
	musical_check.button_pressed = bool(bus.cycling.get("musical", true))
	for i in transition_option.item_count:
		if transition_option.get_item_metadata(i) == bus.cycling.get("transition", "crossfade"): transition_option.select(i)
	duration_option.select(maxi(SceneTransition.DURATIONS.find(float(bus.cycling.get("transition_seconds", 2.0))), 2))
	duration_option.disabled = bus.cycling.get("transition", "crossfade") == "cut"
	var pinned_path := str(bus.playlist[bus.track_index]) if bus.track_index >= 0 and bus.track_index < bus.playlist.size() else ""
	pin_label.text = ("  pinned: " + str(bus.scene_pins[pinned_path]).get_file()) if bus.scene_pins.has(pinned_path) else ""
	response_slider.value = float(bus.scene_info.get("response_slider", 50.0))
	brightness_slider.value = float(bus.scene_info.get("brightness_slider", 100.0))
	var supported: bool = bus.scene_info.get("tuning_supported", false)
	response_slider.editable = supported
	brightness_slider.editable = supported
	tuning_note.text = "Response %.2fx scene time (original mapping 2^(s·0.02−1)); Brightness %.2f light ambient (s·0.01). Per scene: loading a scene restores its own values." % [bus.response, bus.brightness]
	_refresh_effects()
	var settings := AppSettings.new()
	settings.load_settings()
	fps_option.select(maxi(AppSettings.FPS_CHOICES.find(settings.fps_cap), 0))
	vsync_check.button_pressed = settings.vsync
	smooth_check.button_pressed = settings.interpolate
	timing_option.select(1 if settings.timing == "frame" else 0)
	recon_check.button_pressed = settings.use_reconstructions
	source_option.select(1 if settings.analysis_source == "mock" else 0)
	music_volume_check.button_pressed = bool(AppSettings.load_section(settings.path, "player").get("music_volume_link", false))
	var controller := get_parent()
	var current_size: float = controller.user_size if controller and "user_size" in controller else AppSettings.load_player_size()
	size_option.select(maxi(PlayerFormat.USER_SIZES.find(PlayerFormat.nearest_user_size(current_size)), 0))
	visualiser_button.text = "Hide visualiser" if bus.visualiser_visible else "Show visualiser"
	_refresh_reactivity()
	_refresh_rendering()
	_updating = false
