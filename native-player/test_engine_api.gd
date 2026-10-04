extends SceneTree
## Phase 1b engine API checks: style flags, light FX, text, intro, presets,
## DefSwitch, Response/Brightness. Headless, Dummy audio, no sound.
const StyleFlags = preload("res://style_flags.gd")
const LegacyLightFx = preload("res://legacy_light_fx.gd")
const DefSwitch = preload("res://switch_effect.gd")
const MockAudioFeed = preload("res://mock_audio_feed.gd")
var failures := []
var checks := {}

func _initialize(): call_deferred("run")

func check(name: String, ok: bool, detail = null) -> void:
	checks[name] = ok
	if not ok: failures.append({"check": name, "detail": detail})

func run():
	var runtime = load("res://scene_runtime.gd").new()
	root.add_child(runtime)
	var scene_data = load("res://scene_data.gd")
	# --- Style defaults --------------------------------------------------
	check("triple_style_49", StyleFlags.from_scene(scene_data.new().read_scene("res://scenes/lava25/Triple Trance")) == 49)
	check("lvc_style_from_fields", StyleFlags.from_scene(scene_data.new().read_scene("res://scenes/oozic30/Mind's Eye")) == 0x21)
	runtime.load_scene("res://scenes/lava25/Triple Trance")
	check("loaded_default_mask", runtime.get_style_flags() == 49 and runtime.default_style_flags == 49)
	var mushroom = runtime.object_named("Mushroom")
	# --- Texture -----------------------------------------------------------
	check("texture_on_default", mushroom.legacy_material.get_shader_parameter("has_texture") == true)
	check("texture_toggle_off", runtime.toggle_style_flag(StyleFlags.TEXTURE) == false and mushroom.legacy_material.get_shader_parameter("has_texture") == false and mushroom.material.albedo_texture == null)
	runtime.toggle_style_flag(StyleFlags.TEXTURE)
	check("texture_toggle_on", mushroom.legacy_material.get_shader_parameter("has_texture") == true and mushroom.material.albedo_texture != null)
	# --- Wireframe ----------------------------------------------------------
	runtime.set_style_flag(StyleFlags.WIREFRAME, true)
	check("wireframe_on", runtime.get_viewport().debug_draw == Viewport.DEBUG_DRAW_WIREFRAME)
	runtime.set_style_flag(StyleFlags.WIREFRAME, false)
	check("wireframe_off", runtime.get_viewport().debug_draw == Viewport.DEBUG_DRAW_DISABLED)
	# --- Flat shading (legacy shader) ---------------------------------------
	runtime.set_style_flag(StyleFlags.FLAT_SHADING, true)
	check("flat_legacy", mushroom.legacy_material.get_shader_parameter("flat_shading") == true)
	runtime.set_style_flag(StyleFlags.FLAT_SHADING, false)
	# --- Lights (0x20) ------------------------------------------------------
	runtime.set_style_flag(StyleFlags.LIGHTS, false)
	check("lights_off_unlit", mushroom.legacy_material.get_shader_parameter("lighting_enabled") == false)
	runtime.set_style_flag(StyleFlags.LIGHTS, true)
	check("lights_on_lit", mushroom.legacy_material.get_shader_parameter("lighting_enabled") == true)
	# --- Dynamic colouring ---------------------------------------------------
	var do_color_values := []
	runtime.set_style_flag(StyleFlags.DYNAMIC_COLORING, false)
	for entry in runtime.objects:
		for d in entry.effects:
			if d.kind in runtime.DO_COLOR_KINDS: do_color_values.append(int(d.preset.DoColor))
	check("dyncol_off_forces_zero", not do_color_values.is_empty() and not do_color_values.has(1), do_color_values)
	runtime.set_style_flag(StyleFlags.DYNAMIC_COLORING, true)
	var bump_state = null
	for d in runtime.object_named("SignBoard").effects:
		if d.kind == "DefBump": bump_state = d.state
	check("dyncol_on_forces_state", bump_state != null and int(bump_state._p.DoColor) == 1)
	# --- Original hotkeys ----------------------------------------------------
	var hotkeys = load("res://original_hotkeys.gd")
	var key_t := InputEventKey.new()
	key_t.keycode = KEY_T
	key_t.pressed = true
	check("hotkey_t", hotkeys.handle(runtime, key_t) == "Texture off" and (runtime.get_style_flags() & StyleFlags.TEXTURE) == 0)
	hotkeys.handle(runtime, key_t)
	var shift_f3 := InputEventKey.new()
	shift_f3.keycode = KEY_F3
	shift_f3.shift_pressed = true
	shift_f3.pressed = true
	check("hotkey_shift_f3_flat", hotkeys.handle(runtime, shift_f3).begins_with("Flat shading on"))
	hotkeys.handle(runtime, shift_f3)
	var plain_f3 := InputEventKey.new()
	plain_f3.keycode = KEY_F3
	plain_f3.pressed = true
	var ctrl_p := InputEventKey.new()
	ctrl_p.keycode = KEY_P
	ctrl_p.ctrl_pressed = true
	ctrl_p.pressed = true
	check("hotkey_reserved_keys_ignored", hotkeys.handle(runtime, plain_f3) == "" and hotkeys.handle(runtime, ctrl_p) == "" and runtime.get_style_flags() == 49)
	# --- Pause camera --------------------------------------------------------
	var feed = MockAudioFeed.new(128.0, 3)
	var sampler := func(t): return feed.sample(t)
	runtime.set_style_flag(StyleFlags.PAUSE_CAMERA, true)
	var before: Vector3 = runtime.camera_runtime.position()
	for i in 120: runtime.advance(1.0 / 60.0, sampler)
	check("pause_camera_freezes", runtime.camera_runtime.position() == before)
	runtime.set_style_flag(StyleFlags.PAUSE_CAMERA, false)
	for i in 120: runtime.advance(1.0 / 60.0, sampler)
	check("unpause_camera_moves", runtime.camera_runtime.position() != before)
	# --- Brightness / Response -----------------------------------------------
	check("brightness_header", is_equal_approx(runtime.get_brightness(), 0.75))
	runtime.set_brightness(0.5)
	check("brightness_override_ambient", is_equal_approx(runtime.current_light_terms().ambient.r, 0.5) and is_equal_approx(Vector3(mushroom.legacy_material.get_shader_parameter("light_ambient")).x, 0.5))
	runtime.set_brightness(null)
	check("response_slider_map", is_equal_approx(runtime.response_from_slider(0), 0.5) and is_equal_approx(runtime.response_from_slider(50), 1.0) and is_equal_approx(runtime.response_from_slider(100), 2.0) and is_equal_approx(runtime.slider_from_response(2.0), 100.0))
	runtime.set_response(2.0)
	var ticks_before: int = runtime.metrics.ticks
	var orbit_before := _rotate_angle(runtime)
	runtime.advance(1.0 / 60.0, sampler)
	var orbit_fast := _rotate_angle(runtime) - orbit_before
	runtime.set_response(null)
	check("response_override", runtime.metrics.ticks == ticks_before + 1 and is_equal_approx(runtime.get_response(), 1.0))
	# --- Strobe / coloured lighting (unit) ------------------------------------
	var fx = LegacyLightFx.new()
	var phases := []
	for i in 12:
		fx.update(1.0 / 60.0, 0.0, 1.0, true, false)
		phases.append(fx.strobe_phase)
	# threshold 0.075/dt = 4.5 updates: toggles on updates 6 and 11.
	check("strobe_period", phases == [1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 1, 1], phases)
	var dim: Dictionary = fx.light_terms(Color.WHITE, 0.75, true, false)
	check("strobe_dim_terms", phases[9] == 0 and is_equal_approx(dim.diffuse.r, 1.0 if fx.strobe_phase == 1 else 0.25))
	fx.reset()
	fx.strobe_phase = 0
	fx.level = 1.0
	var dark: Dictionary = fx.light_terms(Color.WHITE, 0.75, true, false)
	check("strobe_off_phase_scales", is_equal_approx(dark.diffuse.r, 0.25) and is_equal_approx(dark.ambient.r, 0.75 * 0.75))
	fx.reset()
	check("colored_initial_red", fx.light_terms(Color.WHITE, 1.0, false, true).diffuse == Color(1, 0, 0, 1))
	for i in 6: fx.update(1.0 / 60.0, 1.0, 1.0, false, true)
	check("colored_waits_counter", fx.hsi.x == 0.0)
	fx.update(1.0 / 60.0, 0.5, 1.0, false, true)
	check("colored_needs_beat", fx.hsi.x == 0.0)
	fx.update(1.0 / 60.0, 1.0, 1.0, false, true)
	var yellow: Color = fx.light_terms(Color.WHITE, 1.0, false, true).diffuse
	check("colored_hue_step", fx.hsi.x == 60.0 and yellow.is_equal_approx(Color(1, 1, 0, 1)), yellow)
	for i in 5:
		for k in 8: fx.update(1.0 / 60.0, 1.0, 1.0, false, true)
	check("colored_hue_360_kept", fx.hsi.x == 360.0, fx.hsi)
	# Frame-rate independence of the light FX under fixed ticks.
	runtime.set_style_flags(49 | StyleFlags.STROBE | StyleFlags.COLORED_LIGHTING)
	var states := []
	for fps in [30.0, 144.0]:
		runtime.reset()
		for frame in int(round(20.0 * fps)): runtime.advance(1.0 / fps, sampler)
		states.append([runtime.light_fx.state_snapshot(), runtime.metrics.ticks])
	check("light_fx_frame_rate_independent", str(states[0]) == str(states[1]), states)
	runtime.set_style_flags(49)
	# --- 3D text --------------------------------------------------------------
	var text: Dictionary = runtime.text_message.summary()
	check("text_from_header", text.enabled and text.message == "Triple Trance" and text.weight == 700 and text.font == "Arial" and is_equal_approx(text.extrusion, 0.2) and text.color == [255, 0, 255, 255], text)
	check("text_glyphs", text.glyphs == 12 and text.deforms == ["DefMsgRot"] and is_equal_approx(text.layout.TextRadius, 2.2), text)
	var first_glyph: Node3D = runtime.text_message.get_node("Ring").get_child(0)
	var radial := Vector2(first_glyph.position.x, first_glyph.position.z).length()
	check("text_ring_radius", absf(radial - 2.2) < 0.15, radial)
	var angle_before: float = runtime.text_message.deforms[0].state.angle
	for i in 60: runtime.advance(1.0 / 60.0, sampler)
	check("text_rotates", runtime.text_message.deforms[0].state.angle != angle_before)
	check("text_toggle", runtime.toggle_text_message() == false and not runtime.text_message.visible and runtime.toggle_text_message() == true)
	runtime.set_text_message("Dancing Well")
	check("text_set_message", runtime.text_message.summary().glyphs == 11)
	# --- Intro ----------------------------------------------------------------
	var intro = runtime.intro_screen
	check("intro_parsed", intro.available and is_equal_approx(intro.duration, 5.0) and not intro.on_at_load)
	check("intro_show", runtime.show_intro() and is_equal_approx(intro.current_alpha(), 0.85))
	intro.step(0.5)
	check("intro_dt_clamp", is_equal_approx(intro.timer, 6.4))
	for i in 54: intro.step(0.1)
	check("intro_fading", intro.current_alpha() < 0.85 and intro.current_alpha() > 0.0, intro.current_alpha())
	for i in 20: intro.step(0.1)
	check("intro_done", intro.current_alpha() == 0.0)
	# --- DefSwitch unit -------------------------------------------------------
	var switch = DefSwitch.new(4)
	switch.random_source = func(): return 0.0
	switch.apply_preset({"DecayMin": 0.5, "DecayMax": 0.5})
	switch.apply_preset({"NextShape": 2.0})
	switch.update(1.0 / 60.0)
	check("switch_starts", switch.switching == 1 and is_equal_approx(switch.duration, 0.5))
	for i in 15: switch.update(1.0 / 60.0)
	check("switch_midpoint", absf(switch.weights[0] - 0.5) < 1e-5 and absf(switch.weights[2] - 0.5) < 1e-5, switch.weights)
	for i in 17: switch.update(1.0 / 60.0)
	check("switch_done", switch.switching == 0 and switch.current == 2 and switch.weights[2] == 1.0 and switch.weights[0] == 0.0, switch.state_snapshot())
	# --- F5-F8 presets + DefSwitch integration (LVT6) ---------------------------
	var lvt6: Dictionary = runtime.load_scene("res://scenes/lava25/LVT6")
	check("lvt6_categories", runtime.preset_categories.size() == 3 and runtime.preset_categories[2].name == "Morph" and runtime.preset_categories[2].presets.size() == 4)
	var unsupported_kinds := []
	for item in lvt6.unsupported:
		if item.get("system", "") == "effect": unsupported_kinds.append(item.kind)
	check("lvt6_switch_supported", not unsupported_kinds.has("DefSwitch"), unsupported_kinds)
	var mirror = runtime.object_named("Mirror")
	var vertex_before: Vector3 = mirror.node.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX][10]
	var result: Dictionary = runtime.trigger_effect_preset(2)
	check("f7_morph_sphere", result.get("preset", "") == "sphere" and result.get("applied", 0) >= 1, result)
	for i in 90: runtime.advance(1.0 / 60.0, func(t): return {"band_a": [0.0, 0.0, 0.0], "global_s": 0.0})
	var switch_state = null
	for d in mirror.effects:
		if d.kind == "DefSwitch": switch_state = d.state
	check("lvt6_switch_to_sphere", switch_state != null and switch_state.current == 1 and switch_state.weights[1] == 1.0, switch_state.state_snapshot() if switch_state else null)
	var vertex_after: Vector3 = mirror.node.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX][10]
	check("lvt6_mesh_morphed", vertex_after.distance_to(vertex_before) > 0.01, [vertex_before, vertex_after])
	check("preset_out_of_range", runtime.trigger_effect_preset(3).is_empty())
	# --- Flat shading on the StandardMaterial path ------------------------------
	runtime.set_style_flag(StyleFlags.FLAT_SHADING, true)
	var flat_arrays: Array = mirror.node.mesh.surface_get_arrays(0)
	check("flat_standard_deindexed", flat_arrays[Mesh.ARRAY_INDEX] == null and flat_arrays[Mesh.ARRAY_VERTEX].size() % 3 == 0)
	runtime.advance(1.0 / 60.0, sampler)
	check("flat_survives_rebuild", mirror.node.mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX] == null)
	runtime.set_style_flag(StyleFlags.FLAT_SHADING, false)
	check("flat_standard_restored", mirror.node.mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX] != null)
	# --- DefElastic integration ---------------------------------------------
	var poly: Dictionary = runtime.load_scene("res://scenes/lava25/Polyesterday")
	var elastic_unsupported := false
	for item in poly.unsupported:
		if item.get("kind", "") == "DefElastic": elastic_unsupported = true
	check("elastic_supported", poly.effect_coverage.has("DefElastic") and not elastic_unsupported, poly.effect_coverage)
	# --- DefSuperBump integration (LVT7: heightmap + mask) -----------------------
	var lvt7: Dictionary = runtime.load_scene("res://scenes/lava25/LVT7")
	var superbump_unsupported := false
	for item in lvt7.unsupported:
		if item.get("kind", "") == "DefSuperBump": superbump_unsupported = true
	check("superbump_supported", lvt7.effect_coverage.has("DefSuperBump") and not superbump_unsupported and not lvt7.missing_resources.has("heightmap0"), lvt7.effect_coverage)
	var land = null
	for entry in runtime.objects:
		for d in entry.effects:
			if d.kind == "DefSuperBump": land = entry
	var superbump_samples := []
	for fps in [30.0, 144.0]:
		runtime.reset()
		for frame in int(round(4.0 * fps)): runtime.advance(1.0 / fps, sampler)
		var vertices: PackedVector3Array = land.node.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		superbump_samples.append([vertices[0], vertices[vertices.size() / 3], vertices[vertices.size() / 2], vertices[vertices.size() - 1]])
	var base_vertices: PackedVector3Array = land.base_arrays[Mesh.ARRAY_VERTEX]
	var moved: float = superbump_samples[1][2].distance_to(base_vertices[base_vertices.size() / 2]) + superbump_samples[1][1].distance_to(base_vertices[base_vertices.size() / 3])
	var drift := 0.0
	for i in 4: drift = maxf(drift, superbump_samples[0][i].distance_to(superbump_samples[1][i]))
	check("superbump_frame_rate_independent", drift < 1e-4, drift)
	checks["superbump_displacement_sample"] = moved
	var report := {"passed": failures.is_empty(), "checks": checks, "failures": failures}
	print(JSON.stringify(report))
	runtime.queue_free()
	quit(0 if failures.is_empty() else 1)

func _rotate_angle(runtime) -> float:
	for entry in runtime.objects:
		for d in entry.effects:
			if d.kind == "DefRotate": return float(d.state.angle)
	return 0.0
