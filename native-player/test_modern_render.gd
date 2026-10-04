extends SceneTree
## Classic/Modern render switch (Phase 4c). Silent:
##   Godot --headless --audio-driver Dummy --path native-player --script res://test_modern_render.gd
## 1. The Modern layer never changes the simulation: Triple Trance run with the
##    layer attached, detached and re-attached mid-run matches a Classic-only run
##    exactly (camera, transforms, vertices, tick count).
## 2. Attach swaps materials/environment/lights; detach restores the Classic
##    objects exactly (material overrides, environment, light masks, viewport).
## 3. Scenes without a profile stay Classic; profiles and derived maps resolve.
## 4. Settings round trip (mode, per-scene override, quality, effects) and the
##    F9 / Shift+F9 key mapping.
## 5. Visualiser bus commands toggle without resetting the scene clock.
const SceneRuntime = preload("res://scene_runtime.gd")
const MockAudioFeed = preload("res://mock_audio_feed.gd")
const ModernLayer = preload("res://modern/modern_layer.gd")
const ModernProfiles = preload("res://modern/modern_profiles.gd")
const ModernQuality = preload("res://modern/modern_quality.gd")
const AppSettings = preload("res://app_settings.gd")
const Hotkeys = preload("res://hotkeys.gd")
const Visualiser = preload("res://visualiser.gd")
const SceneCatalog = preload("res://scene_catalog.gd")
const PlayerBusScript = preload("res://player_bus.gd")
const ReactivityServiceScript = preload("res://analysis/reactivity_service.gd")
const TRIPLE := "res://scenes/lava25/Triple Trance"

func _initialize(): call_deferred("run")

func _state(runtime) -> Dictionary:
	var out := {"camera": runtime.camera.global_position, "ticks": runtime.metrics.ticks, "objects": []}
	for entry in runtime.objects:
		if entry.node == null: continue
		var vertices: PackedVector3Array = entry.node.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		out.objects.append([entry.node.global_transform, vertices[0], vertices[vertices.size() / 2], entry.material.albedo_color])
	return out

func _run(with_layer: bool) -> Dictionary:
	var runtime = SceneRuntime.new()
	root.add_child(runtime)
	runtime.load_scene(TRIPLE)
	var feed = MockAudioFeed.new(128.0, 3)
	var sampler := func(t): return feed.sample(t)
	var layer = ModernLayer.new() if with_layer else null
	if layer != null: root.add_child(layer)
	for frame in 180:
		if layer != null:
			if frame == 20: assert(layer.attach(runtime))
			if frame == 90: layer.detach()
			if frame == 120: assert(layer.attach(runtime))
			if layer.attached: layer.update(1.0 / 60.0)
		runtime.advance(1.0 / 60.0, sampler)
	var state := _state(runtime)
	if layer != null:
		layer.detach()
		layer.free()
	runtime.free()
	return state

func run():
	ReactivityServiceScript.instance().auto_tick = false
	# 1. Simulation identical with/without the layer.
	var classic := _run(false)
	var mixed := _run(true)
	assert(classic.ticks == mixed.ticks and classic.ticks == 180)
	assert(classic.camera == mixed.camera)
	assert(classic.objects.size() == 10 and classic.objects == mixed.objects)
	print("1 simulation identical across attach/detach: ticks ", classic.ticks, " objects ", classic.objects.size())

	# 2. Attach/detach restores Classic exactly.
	var runtime = SceneRuntime.new()
	root.add_child(runtime)
	runtime.load_scene(TRIPLE)
	var overrides := []
	for entry in runtime.objects: overrides.append(entry.node.material_override)
	var world_env: WorldEnvironment
	for child in runtime._world.get_children():
		if child is WorldEnvironment: world_env = child
	var classic_env: Environment = world_env.environment
	var viewport := root.get_viewport()
	var msaa := viewport.msaa_3d
	var layer = ModernLayer.new()
	layer.quality = "ultra"
	root.add_child(layer)
	assert(layer.attach(runtime))
	assert(world_env.environment != classic_env and world_env.environment.tonemap_mode != Environment.TONE_MAPPER_LINEAR)
	assert(viewport.msaa_3d == Viewport.MSAA_4X and viewport.use_taa)
	assert(world_env.environment.sdfgi_enabled and world_env.environment.ssr_enabled and world_env.environment.volumetric_fog_enabled)
	for i in runtime.objects.size():
		var entry = runtime.objects[i]
		assert(entry.node.material_override is ShaderMaterial and entry.node.material_override != overrides[i])
		assert(entry.node.material_override.shader.code.contains("Lava-25"))
	for light in runtime._lights: assert(light.node.light_cull_mask == 0)
	layer.detach()
	for i in runtime.objects.size(): assert(runtime.objects[i].node.material_override == overrides[i])
	assert(world_env.environment == classic_env and classic_env.tonemap_mode == Environment.TONE_MAPPER_LINEAR and not classic_env.glow_enabled)
	assert(viewport.msaa_3d == msaa and not viewport.use_taa)
	for light in runtime._lights: assert(light.node.light_cull_mask != 0)
	print("2 attach/detach restores Classic materials, environment, light masks, viewport")
	# Quality presets gate features.
	for quality in ModernQuality.NAMES:
		layer.quality = quality
		assert(layer.attach(runtime))
		var env: Environment = world_env.environment
		var row := ModernQuality.preset(quality)
		assert(env.sdfgi_enabled == (row.gi == "sdfgi") and env.ssr_enabled == bool(row.ssr) and env.ssao_enabled == bool(row.ssao) and env.volumetric_fog_enabled == (row.fog == "volumetric"))
		assert(layer._key.shadow_enabled == (int(row.shadows) > 0))
		layer.detach()
	print("2b quality presets gate GI/SSR/SSAO/fog/shadows")

	# 3. Profiles.
	assert(ModernProfiles.has_profile(TRIPLE) and not ModernProfiles.has_profile("res://scenes/lava25/Unprofiled Scene"))
	var maps := ModernProfiles.derived_maps("res://scenes/lava25/Triple Trance/blue-oil.jpg")
	assert(maps.has("albedo") and maps.has("normal") and maps.has("roughness"))
	# Phase 4f coverage: every catalog scene has a profile, and templates resolve.
	for scene in SceneCatalog.load_catalog():
		assert(ModernProfiles.has_profile(str(scene.path)), "no Modern profile: " + str(scene.path))
	assert(ModernProfiles.for_folder("res://scenes/oozic30/LVT3").get("environment", {}).has("glow_intensity") and not ModernProfiles.for_folder("res://scenes/lava25/LVT2").get("environment", {}).get("sky", {}).is_empty())
	# Transparency: DefAlpha / alpha < 1 objects get the translucent variant (ALPHA written, blend_mix), opaque ones do not.
	runtime.load_scene("res://scenes/lava25/KaleidaTribe")
	assert(layer.attach(runtime))
	var sheet: MeshInstance3D = runtime.object_named("Sheet03").node
	var backdrop: MeshInstance3D = runtime.object_named("Background").node
	assert((sheet.material_override as ShaderMaterial).shader.code.contains("ALPHA = clamp(") and not (backdrop.material_override as ShaderMaterial).shader.code.contains("ALPHA = clamp("))
	layer.detach()
	print("3b transparency variant: DefAlpha sheets translucent, backdrop opaque")
	runtime.load_scene("res://scenes/lava25/Hydroid")
	runtime.data["folder"] = "res://scenes/lava25/Unprofiled Scene"   # a scene with no profile stays Classic
	assert(not layer.attach(runtime) and not layer.attached)
	print("3 profiles: Triple Trance has one, an unprofiled scene stays Classic; derived maps ", maps.keys())
	layer.free()
	runtime.free()

	# 4. Settings and keys.
	var settings = AppSettings.new()
	settings.path = "user://test-modern-settings.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(settings.path))
	settings.load_settings()
	assert(settings.render_mode == "modern" and settings.modern_quality == "high")
	settings.render_mode = "classic"
	settings.render_overrides = {"lava25/Triple Trance": "modern"}
	settings.modern_quality = "ultra"
	settings.modern_effects.particles = false
	settings.save_settings()
	var loaded = AppSettings.new()
	loaded.path = settings.path
	loaded.load_settings()
	assert(loaded.render_mode == "classic" and loaded.modern_quality == "ultra" and not loaded.modern_effects.particles)
	assert(loaded.effective_render_mode(TRIPLE) == "modern" and loaded.effective_render_mode("res://scenes/lava25/Hydroid") == "classic")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(settings.path))
	var f9 := InputEventKey.new()
	f9.keycode = KEY_F9
	f9.pressed = true
	assert(Hotkeys.action_for(f9).name == &"toggle_render_mode" and Hotkeys.action_for(f9).args.scope == "global")
	assert(not Hotkeys.scene_may_claim(f9))
	f9.shift_pressed = true
	assert(Hotkeys.action_for(f9).args.scope == "scene")
	print("4 settings round trip and F9 / Shift+F9")

	# 5. Visualiser commands.
	var bus = PlayerBusScript.instance()
	bus.publish_scenes(SceneCatalog.load_catalog())
	var visualiser = Visualiser.new()
	root.add_child(visualiser)
	visualiser.settings.path = "user://test-modern-visualiser.cfg"
	visualiser.settings.render_mode = "modern"
	visualiser.settings.render_overrides = {}
	visualiser.set_analysis_source("mock", false)
	visualiser.load_scene(0)
	assert(str(visualiser.runtime.data.folder).ends_with("Triple Trance"))
	assert(visualiser.modern.attached and bus.render.modern_active)
	for i in 30: visualiser._process(1.0 / 60.0)
	var ticks: int = visualiser.runtime.metrics.ticks
	bus.command(&"toggle_render_mode", {"scope": "global"})
	assert(not visualiser.modern.attached and visualiser.settings.render_mode == "classic" and bus.render.effective == "classic")
	assert(visualiser.runtime.metrics.ticks == ticks)
	for i in 30: visualiser._process(1.0 / 60.0)
	bus.command(&"toggle_render_mode", {"scope": "scene"})
	assert(visualiser.modern.attached and visualiser.settings.render_overrides.get("lava25/Triple Trance") == "modern")
	bus.command(&"set_modern_quality", {"quality": "low"})
	assert(visualiser.modern.attached and visualiser.modern.quality == "low" and root.get_viewport().scaling_3d_scale < 1.0)
	bus.command(&"set_modern_effects", {"particles": false, "post": false})
	assert(not visualiser.modern.effects.particles and visualiser.runtime.metrics.ticks >= ticks + 30)
	bus.command(&"set_render_mode", {"mode": "default", "scope": "scene"})
	assert(not visualiser.modern.attached)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(visualiser.settings.path))
	visualiser.queue_free()
	await process_frame
	print("5 visualiser commands toggle without resetting (ticks ", ticks, " -> ", visualiser.runtime.metrics.ticks if is_instance_valid(visualiser) else -1, ")")
	print("PASS test_modern_render")
	quit()
