extends Node3D
## Native executor for recovered scene data. Unsupported systems remain explicit.
const SceneData = preload("res://scene_data.gd")
const ParametricMesh = preload("res://parametric_mesh.gd")
const BinaryLVO = preload("res://binary_lvo.gd")
const HydraMesh = preload("res://hydra_mesh.gd")
const HydraMotion = preload("res://hydra_motion.gd")
const CameraRuntime = preload("res://camera_runtime.gd")
const CosDeformation = preload("res://cos_deformation.gd")
const LegacyEffect = preload("res://legacy_effect.gd")
const MorphRuntime = preload("res://morph_runtime.gd")
const RipplePools = preload("res://ripple_pools.gd")
const TextureEffects = preload("res://texture_effects.gd")
const BumpDeformation = preload("res://bump_deformation.gd")
const ShapeWeights = preload("res://shape_weights.gd")
const AlphaCenterEffects = preload("res://alpha_center_effects.gd")
const MatrixEffects = preload("res://matrix_effects.gd")
const LegacyLighting = preload("res://legacy_lighting.gd")
const LegacyNormals = preload("res://legacy_normals.gd")
const LegacyRand = preload("res://legacy_rand.gd")
const StyleFlags = preload("res://style_flags.gd")
const LegacyLightFx = preload("res://legacy_light_fx.gd")
const TextMessage = preload("res://text_message.gd")
const IntroScreen = preload("res://intro_screen.gd")
const DefSwitch = preload("res://switch_effect.gd")
const ElasticEffect = preload("res://elastic_effect.gd")
const SuperBumpDeformation = preload("res://superbump_deformation.gd")
## Effect classes whose original setter accepts DoColor (property 0x82); the
## Dynamic Coloring flag overwrites it every frame (Lava3 0x10025c20).
const DO_COLOR_KINDS = ["DefCos", "DefBump", "DefRipple", "DefPools", "DefSuperBump"]
## Fixed simulation rate = original Lava3Aud MaxFrameRate default (60). The
## scene FramesPerSecond header has no recovered reader and does not pace.
const SIM_RATE := 60.0
## Original GetFilteredData clamps a frame's dt to 100 ms.
const MAX_FRAME_DT := 0.1
## Catch-up cap per rendered frame: 6 ticks = the same 100 ms clamp.
const MAX_CATCHUP_TICKS := 6
const SUPPORTED_EFFECTS = ["DefRotate", "DefOrbit", "DefTexScroll", "DefCos", "DefTexCos", "DefHydraCreate", "DefHydraCrawl", "DefHydraDecay", "DefMorph", "DefRipple", "DefPools", "DefTexTranslate", "DefTexWave", "DefTexZoom", "DefScale", "DefShear", "DefAlpha", "DefCenter", "DefBump", "DefShape", "DefSwitch", "DefElastic", "DefSuperBump", "DefMsgRot", "DefMsgAlpha"]
var camera: Camera3D
var objects: Array = []
var data: Dictionary = {}
var metrics: Dictionary = {}
var inspection := false
var camera_runtime
var _world: Node3D
## Interpolate object/camera transforms between the last two simulation ticks.
var interpolate := true
## true: fixed 60 Hz ticks (deterministic, render-rate independent).
## false: one update per rendered frame with dt clamped to 100 ms (original structure).
var fixed_step := true
## Seed of the shared legacy rand stream at reset (original: 1, never reseeded).
var random_seed := 1
var rand = LegacyRand.new()
var _clock := 0.0
var _clock_ticks := 0
var _camera_previous := Vector3.ZERO
var _camera_current := Vector3.ZERO
var _mesh_cache := {}
var _summary: Dictionary = {}
var _shared_texture_files: PackedStringArray = PackedStringArray()
## Live effects mask (StyleFlags bits). Reset to the scene's Style on load,
## as LAVA.exe re-reads GetEfxInfo after loading (0x40fe2e).
var style_flags := 0
var default_style_flags := 0
## null = scene header value. See set_response()/set_brightness().
var response_override = null
var brightness_override = null
var light_fx = LegacyLightFx.new()
var text_message: Node3D
var intro_screen: CanvasLayer
var preset_categories: Array = []
var _lights: Array = []
var _environment: Environment
var _applied_wireframe := false
## Fallback texture sources (see modern_assets/README.md). Reconstructions are
## procedurally generated stand-ins, never Creative assets; set false to skip them.
const RECOVERED_MAP_PATH := "res://modern_assets/recovered/texture-map.json"
const RECONSTRUCTION_ROOT := "res://modern_assets/reconstructions"
const IMAGE_EXTENSIONS := ["bmp", "jpg", "jpeg", "png", "tga"]
var use_reconstructions := true
static var _recovered_map = null

func _init():
	# Wireframe (Style 0x02) uses the viewport wireframe debug draw, which
	# needs wireframe index data generated with each mesh.
	RenderingServer.set_debug_generate_wireframes(true)

func summary() -> Dictionary:
	var result := _summary.duplicate(true)
	result["metrics"] = metrics.duplicate(true)
	result["style_flags"] = style_flags
	result["default_style_flags"] = default_style_flags
	result["preset_categories"] = preset_categories.map(func(category): return {"name": category.name, "count": category.count, "current": category.current})
	return result

func load_scene(folder: String) -> Dictionary:
	_clear_world()
	data = SceneData.new().read_scene(folder)
	var shared_directory := DirAccess.open("res://scenes/shared-textures")
	_shared_texture_files = shared_directory.get_files() if shared_directory != null else PackedStringArray()
	_summary = {"loaded_objects": 0, "total_objects": data.objects.size(), "missing_resources": [], "unsupported": data.unsupported.duplicate(true), "errors": data.errors.duplicate(), "effect_coverage": {}, "resource_aliases": [], "texture_provenance": {}, "reconstructed_textures": [], "recovered_textures": []}
	if not data.errors.is_empty(): return _summary
	_summary.unsupported = _summary.unsupported.filter(func(item): return item.get("system", "") not in ["procedural_hydra", "effect_preset_events"])
	_summary.implemented_effects = SUPPORTED_EFFECTS.duplicate()
	data.unsupported = data.unsupported.filter(func(item): return item.get("system", "") not in ["procedural_hydra", "effect_preset_events", "text_deformation"])
	_summary.unsupported = _summary.unsupported.filter(func(item): return item.get("system", "") != "text_deformation")
	default_style_flags = StyleFlags.from_scene(data)
	style_flags = default_style_flags
	preset_categories = _parse_preset_categories()
	_world = Node3D.new()
	add_child(_world)
	camera = Camera3D.new()
	_world.add_child(camera)
	camera.current = true
	_build_environment()
	for record in data.objects:
		var entry := {"record": record, "node": null, "params": {}, "material": null, "base_arrays": [], "angular": PackedVector2Array(), "morph_meshes": [], "morph_arrays": [], "effects": [], "hydra_motion": null, "hydra_generator": null, "initial_size": Vector3.ZERO, "texture_context": {"repeat": Vector2.ONE, "center": Vector2.ZERO}, "normal_indices": PackedInt32Array()}
		for filename in record.morphs:
			var decoded: Dictionary
			if filename.to_lower() == "hydra.lvo":
				var creation := {}
				for effect in record.effects:
					if effect.definition.get("type", "") == "DefHydraCreate": creation = _preset(effect)
				entry.hydra_generator = HydraMesh.new()
				decoded = {"mesh": entry.hydra_generator.mesh_from_frame_snapshot(creation), "params": creation, "angular": PackedVector2Array()}
			else: decoded = _read_mesh(filename)
			if decoded.has("error"):
				_summary.unsupported.append({"object": record.name, "file": filename, "reason": decoded.error})
				entry.morph_meshes.append(null)
				entry.morph_arrays.append([])
			else:
				entry.morph_meshes.append(decoded.mesh)
				entry.morph_arrays.append(decoded.mesh.surface_get_arrays(0) if decoded.mesh.get_surface_count() > 0 else [])
				if entry.params.is_empty():
					entry.params = decoded.params
					entry.angular = decoded.angular
		if not entry.morph_meshes.is_empty() and entry.morph_meshes[0] != null and entry.morph_meshes[0].get_surface_count() > 0:
			var node := MeshInstance3D.new()
			node.name = record.name.validate_node_name()
			node.mesh = entry.morph_meshes[0]
			entry.base_arrays = entry.morph_arrays[0]
			entry.normal_indices = entry.base_arrays[Mesh.ARRAY_INDEX].duplicate()
			# Parametric grids use modern Godot clockwise triangles; undo that
			# orientation for the original cross-product normal accumulator.
			if entry.params.get("kind", "") != "BINARY_MESH":
				for triangle in range(0, entry.normal_indices.size(), 3):
					var swap = entry.normal_indices[triangle + 1]
					entry.normal_indices[triangle + 1] = entry.normal_indices[triangle + 2]
					entry.normal_indices[triangle + 2] = swap
			entry.initial_size = node.mesh.get_aabb().size
			entry.material = _material(record)
			entry.texture = entry.material.albedo_texture
			entry.lit = int(record.get("EnableLighting", "1")) != 0
			node.material_override = entry.material
			if folder.trim_suffix("/").get_file() == "Triple Trance":
				entry.legacy_material = LegacyLighting.create(record, entry.material, data)
				node.material_override = entry.legacy_material
			node.visible = int(record.get("Visible", "1")) != 0
			_world.add_child(node)
			entry.node = node
			_summary.loaded_objects += 1
		objects.append(entry)
	for link in data.links:
		var parent = object_named(link.parent)
		var child = object_named(link.child)
		if not parent.is_empty() and not child.is_empty() and parent.node != null and child.node != null and parent.node != child.node and not child.node.is_ancestor_of(parent.node): child.node.reparent(parent.node, false)
		else: _summary.unsupported.append({"system": "invalid_parent_link", "raw": link.raw})
	text_message = TextMessage.new()
	text_message.name = "TextMessage"
	_world.add_child(text_message)
	text_message.build(data, self)
	_summary.text_message = text_message.summary()
	intro_screen = IntroScreen.new()
	intro_screen.name = "IntroScreen"
	_world.add_child(intro_screen)
	intro_screen.configure(data, self)
	_summary.intro = intro_screen.summary()
	reset()
	return _summary

func _clear_world():
	if is_instance_valid(_world):
		remove_child(_world)
		_world.free()
	_world = null
	camera = null
	text_message = null
	intro_screen = null
	_lights.clear()
	_environment = null
	objects.clear()
	_mesh_cache.clear()
	_clock = 0.0
	_clock_ticks = 0

func object_named(object_name: String) -> Dictionary:
	for entry in objects:
		if entry.record.name == object_name: return entry
	return {}

func original_basis(rotation: Vector3) -> Basis:
	return Basis(Vector3.BACK, deg_to_rad(rotation.z)) * Basis(Vector3.RIGHT, deg_to_rad(rotation.y)) * Basis(Vector3.UP, deg_to_rad(rotation.x))

func resource_path(filename: String) -> String:
	var direct := str(data.get("folder", "")).path_join(filename)
	if FileAccess.file_exists(direct) or ResourceLoader.exists(direct): return direct
	for file in data.get("files", []):
		var original := str(file).trim_suffix(".import")
		if original.to_lower() == filename.to_lower(): return str(data.folder).path_join(original)
	for file in _shared_texture_files:
		var original := str(file).trim_suffix(".import")
		if original.to_lower() == filename.to_lower(): return "res://scenes/shared-textures".path_join(original)
	# Recovered packages retain BMP references beside same-stem JPEG assets.
	# Exact names always win; this compatibility inference applies only to images.
	if filename.get_extension().to_lower() in ["bmp", "jpg", "jpeg", "png", "tga"]:
		for location in [{"folder": data.folder, "files": data.get("files", [])}, {"folder": "res://scenes/shared-textures", "files": _shared_texture_files}]:
			for file in location.files:
				var original := str(file).trim_suffix(".import")
				if original.get_basename().to_lower() == filename.get_basename().to_lower() and original.get_extension().to_lower() in ["jpg", "jpeg", "png", "bmp", "tga"]:
					var alias := {"requested": filename, "resolved": str(location.folder).path_join(original), "basis": "Recovered same-stem image compatibility inference"}
					if not _summary.resource_aliases.has(alias): _summary.resource_aliases.append(alias)
					return alias.resolved
		return _fallback_texture(filename)
	return ""

## (a) recovered-original from texture-map.json, then (b) reconstruction.
## Records provenance for every texture resolved this way.
func _fallback_texture(filename: String) -> String:
	var folder := str(data.get("folder", "")).trim_suffix("/")
	var scene := folder.get_file()
	var set_name := folder.get_base_dir().get_file()
	if _recovered_map == null:
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(RECOVERED_MAP_PATH)) if FileAccess.file_exists(RECOVERED_MAP_PATH) else null
		_recovered_map = parsed if parsed is Dictionary else {}
	var entries: Dictionary = _recovered_map.get("%s/%s" % [set_name, scene], {})
	for name in entries:
		if str(name).to_lower() != filename.to_lower(): continue
		var resolved := "res://" + str(entries[name]).trim_prefix("native-player/")
		if not (FileAccess.file_exists(resolved) or ResourceLoader.exists(resolved)): continue
		_record_provenance(filename, "recovered-original", resolved)
		return resolved
	if use_reconstructions:
		var directory := DirAccess.open(RECONSTRUCTION_ROOT.path_join(scene))
		if directory != null:
			for file in directory.get_files():
				var original := str(file).trim_suffix(".import")
				if original.get_extension().to_lower() in ["png", "jpg", "jpeg"] and original.get_basename().to_lower() == filename.get_basename().to_lower():
					var resolved := RECONSTRUCTION_ROOT.path_join(scene).path_join(original)
					_record_provenance(filename, "reconstruction", resolved)
					return resolved
	return ""

func _record_provenance(filename: String, provenance: String, resolved: String) -> void:
	_summary.texture_provenance[filename] = {"provenance": provenance, "path": resolved}
	var list: Array = _summary.reconstructed_textures if provenance == "reconstruction" else _summary.recovered_textures
	if not list.has(filename): list.append(filename)

func _read_mesh(filename: String) -> Dictionary:
	if _mesh_cache.has(filename.to_lower()): return _mesh_cache[filename.to_lower()]
	var path := resource_path(filename)
	if path.is_empty():
		_summary.missing_resources.append(filename)
		return {"error": "Missing geometry resource"}
	var bytes := FileAccess.get_file_as_bytes(path)
	var offset := bytes.decode_u32(2) if bytes.size() >= 6 and bytes[0] == 66 and bytes[1] == 77 else 0
	if offset < 0 or offset >= bytes.size(): return {"error": "Invalid LVO offset"}
	var decoded: Dictionary
	if bytes[offset] == 70:
		decoded = BinaryLVO.new().decode(bytes)
		if not decoded.has("error"):
			decoded.params = {"kind": "BINARY_MESH", "frame_matrix": decoded.frame_matrix}
			decoded.angular = decoded.extra_coordinates
	elif bytes.slice(offset, mini(offset + 11, bytes.size())).get_string_from_ascii() == "PARAMETRIC ":
		var generator := ParametricMesh.new()
		var parameters := generator.decode_definition(bytes)
		var mesh := generator.mesh_for(parameters)
		if mesh == null: return {"error": generator.last_error}
		var angular := PackedVector2Array()
		for y in range(int(parameters.NY) + 1):
			for x in range(int(parameters.NX) + 1):
				angular.append(Vector2(float(y) / parameters.NY * 3.1415927410125732, (1.0 - float(x) / parameters.NX if int(parameters.Inside) == 1 else float(x) / parameters.NX) * 6.2831854820251465))
		decoded = {"mesh": mesh, "params": parameters, "angular": angular}
	else: return {"error": "Unsupported procedural geometry (BLOB or unknown type)"}
	_mesh_cache[filename.to_lower()] = decoded
	return decoded

func _preset(effect: Dictionary) -> Dictionary:
	for preset in effect.definition.get("presets", []):
		if int(preset.index) == int(effect.preset):
			var parameters: Dictionary = preset.parameters.duplicate(true)
			if parameters.has("Interruptlevel"): parameters["InteruptLevel"] = parameters["Interruptlevel"]
			return parameters
	return {}

func _material(record: Dictionary) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = _color(record.material.get("color_bytes", [255, 255, 255, 255]))
	material.vertex_color_use_as_albedo = true
	# Compatibility linearises the whole albedo product (colour x texture x
	# vertex colour) in its scene shader, i.e. treats vertex colours as sRGB;
	# Forward+ needs the flag to give the same Classic result.
	material.vertex_color_is_srgb = RenderingServer.get_current_rendering_method() != "gl_compatibility"
	material.roughness = 1.0 - clampf(float(record.material.get("gloss", 0)) / 128.0, 0, 1)
	material.cull_mode = BaseMaterial3D.CULL_DISABLED if str(record.material.get("culling", "back")).to_lower() == "none" else BaseMaterial3D.CULL_BACK
	if material.albedo_color.a < 1: material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if int(record.get("EnableLighting", "1")) == 0: material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var texture_file := str(record.material.get("texture", ""))
	if not texture_file.is_empty():
		var path := resource_path(texture_file)
		var texture: Texture2D
		if not path.is_empty():
			if ResourceLoader.exists(path): texture = load(path) as Texture2D
			else:
				var image := Image.load_from_file(path)
				if image != null and not image.is_empty(): texture = ImageTexture.create_from_image(image)
		if texture != null: material.albedo_texture = texture
		else: _summary.missing_resources.append(texture_file)
	return material

func _absolute_colors(arrays: Array, diffuse: Color):
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR] if arrays[Mesh.ARRAY_COLOR] != null else PackedColorArray()
	if colors.size() != arrays[Mesh.ARRAY_VERTEX].size():
		colors.resize(arrays[Mesh.ARRAY_VERTEX].size())
		colors.fill(diffuse)
	else:
		for i in range(colors.size()): colors[i] *= diffuse
	arrays[Mesh.ARRAY_COLOR] = colors

func _color(values: Array) -> Color:
	return Color(values[0] / 255.0, values[1] / 255.0, values[2] / 255.0, values[3] / 255.0) if values.size() >= 4 else Color.WHITE

func _build_environment():
	var world_environment := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color.BLACK
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = 0.0
	# Classic colour contract (Forward+): no tonemapping curve, exposure 1, no
	# glow/adjustments/fog, so the legacy shader's pre-decoded output encodes
	# back to the original raw bytes (legacy_vertex_lighting.gdshader).
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	environment.tonemap_exposure = 1.0
	environment.tonemap_white = 1.0
	environment.glow_enabled = false
	environment.adjustment_enabled = false
	environment.fog_enabled = false
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	world_environment.environment = environment
	_world.add_child(world_environment)
	_environment = environment
	var lights := {}
	for command in data.lighting:
		if not lights.has(command.index): lights[command.index] = {}
		lights[command.index][command.property] = command.value
	for settings in lights.values():
		var light := OmniLight3D.new()
		var position: Array = settings.get("Position", [0, 4, 0, 1])
		light.position = Vector3(position[0], position[1], position[2])
		var color: Array = settings.get("Diffuse", [1, 1, 1, 1])
		light.light_color = Color(color[0], color[1], color[2])
		# No original GL attenuation setters: default constant attenuation = 1.
		light.omni_attenuation = 0.0
		light.omni_range = float(data.camera.get("FarClip", 200))
		_world.add_child(light)
		_lights.append({"node": light, "color": Color(color[0], color[1], color[2])})
		if settings.get("Spot", [0])[0] != 0: _summary.unsupported.append({"system": "spot_light_parity", "settings": settings})
	# Original global ambient is zero; each light ambient is diffuse * Brightness.
	_apply_lighting()
	_summary.lighting = {"global_ambient": [0, 0, 0, 1], "per_light_ambient_multiplier": float(data.header.get("Brightness", 1.0)), "native_ambient": _environment.ambient_light_color * _environment.ambient_light_energy, "attenuation": "Original constant1; modern conversion exponent0 with finite range", "dynamic_lights": false}
	if str(data.folder).trim_suffix("/").get_file() == "Triple Trance":
		_summary.lighting["attenuation"] = "Original constant1 in shader, no finite light range"
		_summary.lighting["vertex_color_material"] = "Ambient and diffuse (original display format0x1f)"
		_summary.lighting["native_path"] = "Original normalized vertex lighting, exponent shininess, infinite viewer, constant attenuation, single-color texture modulation"
		_summary.unsupported.append({"system": "legacy_lighting_parity", "note": "Fixed-function equations and ambient/diffuse vertex routing restored; original GPU/texture precision and shared event inputs still differ"})
	else:
		_summary.unsupported.append({"system": "native_material_lighting_parity", "note": "Original light ambient/diffuse/position retained; modern PBR specular, finite light range and per-fragment shading differ from original OpenGL"})

func reset():
	if data.is_empty() or camera == null: return
	_clock = 0.0
	_clock_ticks = 0
	rand.reseed(random_seed)
	metrics = {"frames": 0, "ticks": 0, "dropped_ticks": 0, "motion_radians": 0.0, "tree_size_change": 0.0, "maximum_torus_centerline_error": 0.0, "geometry_frames": 0, "texture_frames": 0, "normal_updates": 0, "matrix_frames": 0, "shape_frames": 0, "bump_frames": 0}
	camera_runtime = CameraRuntime.new(data.camera, style_flags)
	light_fx.reset()
	camera_runtime.rand = rand
	_summary.effect_coverage = {}
	for entry in objects:
		entry.effects = []
		entry.hydra_motion = null
		entry.local_effect_transform = Transform3D.IDENTITY
		entry.texture_context = {"repeat": Vector2.ONE, "center": Vector2.ZERO}
		var hydra_configuration := []
		for effect in entry.record.effects:
			var kind: String = effect.definition.get("type", "")
			var preset := _preset(effect)
			_summary.effect_coverage[kind] = _summary.effect_coverage.get(kind, 0) + 1
			match kind:
				"DefHydraCrawl", "DefHydraDecay": hydra_configuration.append({"kind": "crawl" if kind == "DefHydraCrawl" else "decay", "name": effect.name, "band": effect.band, "preset": preset})
				"DefHydraCreate": entry.params = preset
			entry.effects.append(_make_descriptor(entry, effect))
		if entry.record.morphs.has("hydra.lvo"):
			entry.hydra_motion = HydraMotion.new()
			entry.hydra_motion.reset(entry.params, hydra_configuration)
			entry.hydra_generator = HydraMesh.new()
			var initial_mesh: ArrayMesh = entry.hydra_generator.mesh_from_frame_snapshot(entry.params)
			if initial_mesh.get_surface_count() > 0:
				entry.morph_meshes[0] = initial_mesh
				entry.base_arrays = initial_mesh.surface_get_arrays(0)
				entry.initial_size = initial_mesh.get_aabb().size
		if entry.node != null:
			entry.node.mesh = entry.morph_meshes[0]
			entry.material.uv1_scale = Vector3.ONE
			entry.material.albedo_color = _color(entry.record.material.get("color_bytes", []))
		_apply_transform(entry, Transform3D.IDENTITY)
	if text_message != null: text_message.reset()
	if intro_screen != null: intro_screen.reset()
	_apply_style()
	# Establish original initial Orbit transforms without advancing effect state.
	step(0.0, [], 0.0)
	set_inspection(inspection)
	_snapshot_previous()

## Builds one effect binding's runtime state (also used when a special-effect
## preset rebinds an effect while the scene keeps running).
func _make_descriptor(entry: Dictionary, effect: Dictionary) -> Dictionary:
	var kind: String = effect.definition.get("type", "")
	var preset := _preset(effect)
	var descriptor := {"binding": effect, "kind": kind, "preset": preset, "state": null}
	match kind:
		"DefRotate", "DefOrbit", "DefTexScroll":
			descriptor.state = LegacyEffect.new()
			descriptor.state.configure(preset)
			if kind == "DefTexScroll": descriptor.state.texture_scale = Vector2.ONE
		"DefBump":
			descriptor.state = BumpDeformation.new()
			descriptor.state.reset(preset, int(effect.definition.header.get("MaxInstance", "3")))
		"DefShape":
			descriptor.state = ShapeWeights.new()
			descriptor.state.reset(preset)
		"DefAlpha", "DefCenter":
			descriptor.state = AlphaCenterEffects.new()
			descriptor.state.random_source = Callable(self, "_texture_random")
			descriptor.state.configure(kind, preset)
		"DefScale", "DefShear":
			descriptor.state = MatrixEffects.new()
			descriptor.state.random_source = Callable(self, "_texture_random")
			descriptor.state.configure(kind, preset)
		"DefTexTranslate", "DefTexWave", "DefTexZoom":
			descriptor.state = TextureEffects.new()
			descriptor.state.random_source = Callable(self, "_texture_random")
			descriptor.state.configure(kind, preset)
		"DefCos", "DefTexCos":
			descriptor.state = CosDeformation.new()
			descriptor.state.reset(preset if kind == "DefCos" else {"DoAmp": 0, "CreationLevel": 2}, preset if kind == "DefTexCos" else {}, int(effect.definition.header.get("MaxInstance", "2")))
		"DefRipple", "DefPools":
			descriptor.state = RipplePools.new()
			descriptor.state.reset(preset if kind == "DefRipple" else {"DoAmp": 0, "CreationLevel": 2}, preset if kind == "DefPools" else {"DoAmp": 0, "DoColor": 0, "CreationLevel": 2}, int(effect.definition.header.get("MaxInstance", "3")))
		"DefMorph":
			var compatible := true
			for arrays in entry.morph_arrays:
				if arrays.is_empty() or entry.base_arrays.is_empty() or arrays[Mesh.ARRAY_VERTEX].size() != entry.base_arrays[Mesh.ARRAY_VERTEX].size(): compatible = false
			if compatible: descriptor.state = MorphRuntime.new(entry.morph_arrays.size(), preset)
			else: _unsupported_effect(entry, "Incompatible morph target topology")
		"DefSuperBump":
			descriptor.state = SuperBumpDeformation.new()
			descriptor.state.random_source = Callable(self, "_texture_random")
			descriptor.state.reset(preset, int(effect.definition.header.get("MaxInstance", "3")))
			descriptor.state.texture_mapping.repeat_u = float(entry.params.get("TexRepX", 1))
			descriptor.state.texture_mapping.repeat_v = float(entry.params.get("TexRepY", 1))
			descriptor.state.texture_mapping.offset_u = float(entry.params.get("TexCentX", 0))
			descriptor.state.texture_mapping.offset_v = float(entry.params.get("TexCentY", 0))
			for map_kind in ["heightmap", "maskmap"]:
				var key := "LoadHeightMap" if map_kind == "heightmap" else "LoadMaskMap"
				if not preset.has(key) or int(float(preset[key])) < 0: continue
				var image := _load_image("%s%d.jpg" % [map_kind, int(float(preset[key]))], "%s%d.bmp" % [map_kind, int(float(preset[key]))])
				if image == null: _summary.missing_resources.append("%s%d" % [map_kind, int(float(preset[key]))])
				elif map_kind == "heightmap": descriptor.state.set_height_map(image)
				else: descriptor.state.set_mask_map(image)
		"DefElastic":
			descriptor.state = ElasticEffect.new()
			descriptor.state.random_source = Callable(self, "_texture_random")
			descriptor.state.configure(preset)
		"DefSwitch":
			if _morphs_compatible(entry) and entry.morph_arrays.size() >= 2:
				descriptor.state = DefSwitch.new(entry.morph_arrays.size())
				descriptor.state.random_source = Callable(self, "_texture_random")
				descriptor.state.apply_preset(preset)
			else: _unsupported_effect(entry, "DefSwitch needs >= 2 morph targets with equal topology")
		"DefHydraCrawl", "DefHydraDecay", "DefHydraCreate": pass
		_: _unsupported_effect(entry, kind)
	_sync_descriptor_do_color(descriptor)
	return descriptor

## SuperBump map loader input (original tries <name>.jpg, then .bmp).
func _load_image(primary: String, fallback: String) -> Image:
	for filename in [primary, fallback]:
		var path := resource_path(filename)
		if path.is_empty(): continue
		var texture: Texture2D = load(path) as Texture2D if ResourceLoader.exists(path) else null
		var image: Image = texture.get_image() if texture != null else Image.load_from_file(path)
		if image != null and not image.is_empty():
			if image.is_compressed(): image.decompress()
			return image
	return null

func _morphs_compatible(entry: Dictionary) -> bool:
	if entry.base_arrays.is_empty(): return false
	for arrays in entry.morph_arrays:
		if arrays.is_empty() or arrays[Mesh.ARRAY_VERTEX].size() != entry.base_arrays[Mesh.ARRAY_VERTEX].size(): return false
	return true

func _texture_random() -> float:
	return rand.unit()

func _unsupported_effect(entry: Dictionary, kind: String):
	var item := {"system": "effect", "object": entry.record.name, "kind": kind}
	if not _summary.unsupported.has(item): _summary.unsupported.append(item)

func _amplitude(binding: Dictionary, bands: Array) -> float:
	var index := int(binding.get("Input1Band", binding.get("band", 0)))
	if index < 0 or index >= bands.size(): index = 0
	return float(bands[index].get("a", 0.0)) if not bands.is_empty() and bands[index] is Dictionary else (float(bands[index]) if not bands.is_empty() else 0.0)

func simulation_rate() -> float:
	return SIM_RATE

## Scene driver; see docs/FRAME_TIMING.md. The original ran one update per
## rendered frame (dt = measured ms, clamped to 100 ms, cap MaxFrameRate=60).
## Effect triggers, RNG draws and the camera counter are evaluated per update,
## so the default here runs whole fixed 1/60 s ticks regardless of render rate
## (= the original at its 60 fps cap), carries the remainder, caps catch-up at
## 100 ms, and interpolates transforms for display. sampler.call(sim_time)
## returns {band_a, global_s} per update. Returns updates run this frame.
func advance(delta: float, sampler: Callable) -> int:
	if camera == null: return 0
	metrics.frames += 1
	if not fixed_step:
		var frame_dt := clampf(delta, 0.0, MAX_FRAME_DT)
		if frame_dt <= 0.0: return 0
		var frame_input: Dictionary = sampler.call(_clock) if sampler.is_valid() else {}
		_snapshot_previous()
		step(frame_dt, Array(frame_input.get("band_a", [])), float(frame_input.get("global_s", 0.0)))
		_clock += frame_dt
		present(1.0)
		return 1
	var rate := simulation_rate()
	_clock += maxf(delta, 0.0)
	# Tick boundaries derive from total time, so dt sequences agree to 1e-7 tick.
	var due := int(floor(_clock * rate + 1e-7)) - _clock_ticks
	if due > MAX_CATCHUP_TICKS:
		metrics.dropped_ticks += due - MAX_CATCHUP_TICKS
		due = MAX_CATCHUP_TICKS
		_clock = float(_clock_ticks + due) / rate
	for i in due:
		var input: Dictionary = sampler.call(float(_clock_ticks) / rate) if sampler.is_valid() else {}
		if i == due - 1: _snapshot_previous()
		# Vertex output only on the frame's final tick; earlier ticks advance state.
		step(1.0 / rate, Array(input.get("band_a", [])), float(input.get("global_s", 0.0)), i == due - 1)
		_clock_ticks += 1
	present(clampf(_clock * rate - float(_clock_ticks), 0.0, 1.0))
	return due

## Seconds of simulated scene time since reset (whole ticks in fixed mode).
func simulation_time() -> float:
	return float(_clock_ticks) / simulation_rate() if fixed_step else _clock

func _snapshot_previous():
	_camera_previous = _camera_current
	for entry in objects:
		if entry.node != null: entry.previous_transform = entry.get("sim_transform", entry.node.transform)

## Display interpolation between the previous and latest tick (alpha 0..1).
func present(alpha: float):
	if inspection or camera == null: return
	for entry in objects:
		if entry.node == null or not entry.has("sim_transform"): continue
		entry.node.transform = _lerp_transform(entry.get("previous_transform", entry.sim_transform), entry.sim_transform, alpha) if interpolate else entry.sim_transform
	camera.position = _camera_previous.lerp(_camera_current, alpha) if interpolate else _camera_current
	_camera_look_at()
	if text_message != null: text_message.present(alpha if interpolate else 1.0)
	if intro_screen != null: intro_screen.present()
	if style_flags & (StyleFlags.STROBE | StyleFlags.COLORED_LIGHTING): _apply_lighting()

static func _lerp_transform(from: Transform3D, to: Transform3D, weight: float) -> Transform3D:
	# Component lerp keeps scale/shear effects intact; per-tick rotations are small.
	return Transform3D(Basis(from.basis.x.lerp(to.basis.x, weight), from.basis.y.lerp(to.basis.y, weight), from.basis.z.lerp(to.basis.z, weight)), from.origin.lerp(to.origin, weight))

## One simulation update of delta seconds (one original engine frame).
## build_geometry=false advances effect state without producing vertices.
func step(delta: float, band_a: Array, global_s: float, build_geometry := true):
	if camera == null: return
	if delta > 0: metrics.ticks += 1
	var responsiveness := get_response()
	var dt := delta * responsiveness
	var advancing := dt > 0
	var geometry_ready := advancing and build_geometry
	var geometry_delta := dt
	var bands := []
	var maximum_a := 0.0
	for amplitude in band_a:
		var a := float(amplitude.get("a", 0.0)) if amplitude is Dictionary else float(amplitude)
		maximum_a = maxf(maximum_a, a)
		bands.append({"a": a, "s": global_s})
	# Original order (0x10025a80): camera, lights, then objects share the rand stream.
	if not inspection:
		_camera_current = camera_runtime.update(delta, global_s, maximum_a, responsiveness)
		camera.position = _camera_current
		_camera_look_at()
	light_fx.update(dt, maximum_a, global_s, (style_flags & StyleFlags.STROBE) != 0, (style_flags & StyleFlags.COLORED_LIGHTING) != 0)
	for entry in objects:
		if entry.node == null: continue
		var effect_transform := Transform3D.IDENTITY
		var arrays: Array = entry.base_arrays.duplicate(true) if geometry_ready else []
		var repeat := Vector2(float(entry.params.get("TexRepX", 1)), float(entry.params.get("TexRepY", 1)))
		var center := Vector2(float(entry.params.get("TexCentX", 0)), float(entry.params.get("TexCentY", 0)))
		var changed := false
		var deformed := false
		var absolute_vertex_colors := false
		var vertex_count: int = entry.base_arrays[Mesh.ARRAY_VERTEX].size() if not entry.base_arrays.is_empty() else -1
		var deformable: bool = vertex_count > 0 and entry.angular.size() == vertex_count and entry.base_arrays[Mesh.ARRAY_NORMAL] != null and entry.base_arrays[Mesh.ARRAY_NORMAL].size() == vertex_count
		# DefSwitch writes the object's morph weights; the weighted target mix is
		# the source surface the other deformers then displace.
		for descriptor in entry.effects:
			if descriptor.kind != "DefSwitch" or descriptor.state == null: continue
			if advancing: descriptor.state.update(geometry_delta)
			if geometry_ready:
				arrays[Mesh.ARRAY_VERTEX] = descriptor.state.blend(entry.morph_arrays, Mesh.ARRAY_VERTEX)
				var blended_normals = descriptor.state.blend(entry.morph_arrays, Mesh.ARRAY_NORMAL)
				if blended_normals != null: arrays[Mesh.ARRAY_NORMAL] = blended_normals
				changed = true
				deformed = true
		for descriptor in entry.effects:
			var a := _amplitude(descriptor.binding, band_a)
			match descriptor.kind:
				"DefOrbit", "DefRotate":
					if float(descriptor.preset.get("ResetMat", 0)) == 1: effect_transform = Transform3D.IDENTITY
					if descriptor.kind == "DefOrbit": effect_transform.origin += descriptor.state.orbit(dt, a, global_s)
					else:
						var axis := Vector3(float(descriptor.preset.get("Axis0", 0)), float(descriptor.preset.get("Axis1", 1)), float(descriptor.preset.get("Axis2", 0)))
						if axis.is_zero_approx(): axis = Vector3.UP
						var angle: float = descriptor.state.rotate(dt, a, global_s)
						effect_transform.basis *= Basis(axis.normalized(), angle)
						metrics.motion_radians = maxf(metrics.motion_radians, absf(angle))
				"DefAlpha", "DefCenter":
					var output: Dictionary = descriptor.state.update(dt, a, global_s)
					if descriptor.kind == "DefCenter":
						effect_transform = MatrixEffects.compose(effect_transform, output.transform)
						metrics.matrix_frames += 1
					elif geometry_ready:
						var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR] if arrays[Mesh.ARRAY_COLOR] != null else PackedColorArray()
						if colors.size() != arrays[Mesh.ARRAY_VERTEX].size():
							colors.resize(arrays[Mesh.ARRAY_VERTEX].size())
							colors.fill(_color(entry.record.material.get("color_bytes", [])))
						elif not absolute_vertex_colors:
							var diffuse := _color(entry.record.material.get("color_bytes", []))
							for i in range(colors.size()): colors[i] *= diffuse
						arrays[Mesh.ARRAY_COLOR] = descriptor.state.apply_alpha(colors)
						absolute_vertex_colors = true
						entry.material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
						changed = true
				"DefScale", "DefShear":
					var parent_entry := object_named(entry.record.get("parent", ""))
					var parent_effect = parent_entry.get("local_effect_transform", null)
					var matrix: Transform3D = descriptor.state.update(dt, a, global_s, parent_effect)
					effect_transform = MatrixEffects.compose(effect_transform, matrix)
					metrics.matrix_frames += 1
				"DefElastic":
					# Persistent elastic matrix (elastic_effect.gd); composed like DefShear.
					var elastic: Transform3D = descriptor.state.update(dt, a, global_s) if advancing else descriptor.state.transform()
					effect_transform = MatrixEffects.compose(effect_transform, elastic)
					metrics.matrix_frames += 1
				"DefTexScroll":
					if dt > 0:
						descriptor.state.texture_scale = entry.texture_context.repeat
						descriptor.state.texscroll(dt, a, global_s)
						entry.texture_context.repeat = descriptor.state.texture_scale
					if geometry_ready:
						repeat = entry.texture_context.repeat
						center = entry.texture_context.center
						var uvs := PackedVector2Array()
						for angular in entry.angular: uvs.append(Vector2(angular.y * repeat.x * 0.15915493667125702 + center.x, (3.1415927410125732 - angular.x) * repeat.y * 0.31830987334251404 + center.y))
						if uvs.size() == arrays[Mesh.ARRAY_VERTEX].size(): arrays[Mesh.ARRAY_TEX_UV] = uvs; changed = true
				"DefTexTranslate", "DefTexWave", "DefTexZoom":
					if dt > 0: descriptor.state.update(dt, a, global_s, entry.texture_context)
					if geometry_ready:
						repeat = entry.texture_context.repeat
						center = entry.texture_context.center
						var uvs: PackedVector2Array = descriptor.state.apply_uv(entry.angular, entry.texture_context, arrays[Mesh.ARRAY_TEX_UV])
						if uvs.size() == arrays[Mesh.ARRAY_VERTEX].size():
							arrays[Mesh.ARRAY_TEX_UV] = uvs
							changed = true
							metrics.texture_frames += 1
				"DefBump":
					if geometry_ready and entry.angular.size() == arrays[Mesh.ARRAY_VERTEX].size():
						if not absolute_vertex_colors and int(descriptor.preset.get("DoColor", 1)) != 0: _absolute_colors(arrays, _color(entry.record.material.get("color_bytes", [])))
						arrays = descriptor.state.deform(arrays, entry.angular, a, global_s, geometry_delta, float(entry.record.get("deformation_scale", 1)), _color(entry.record.material.get("color_bytes", [])))
						metrics.bump_frames += 1
						absolute_vertex_colors = absolute_vertex_colors or int(descriptor.preset.get("DoColor", 1)) != 0
						changed = true
						deformed = true
					elif advancing and not geometry_ready and deformable: descriptor.state.advance(a, geometry_delta, _color(entry.record.material.get("color_bytes", [])))
				"DefSuperBump":
					var super_color := int(descriptor.preset.get("DoColor", 1)) != 0
					if geometry_ready and entry.angular.size() == arrays[Mesh.ARRAY_VERTEX].size():
						if not absolute_vertex_colors and super_color: _absolute_colors(arrays, _color(entry.record.material.get("color_bytes", [])))
						arrays = descriptor.state.deform(arrays, entry.angular, a, global_s, geometry_delta, float(entry.record.get("deformation_scale", 1)), _color(entry.record.material.get("color_bytes", [])))
						metrics.bump_frames += 1
						absolute_vertex_colors = absolute_vertex_colors or super_color
						changed = true
						deformed = deformed or int(descriptor.state.parameters().get("DoAmp", 1)) == 1
					elif advancing and not geometry_ready and deformable: descriptor.state.advance(a, geometry_delta, _color(entry.record.material.get("color_bytes", [])), global_s)
				"DefShape":
					if geometry_ready and entry.morph_arrays.size() >= 2 and not entry.morph_arrays[0].is_empty() and not entry.morph_arrays[1].is_empty():
						var weights: PackedFloat32Array = descriptor.state.update(a, global_s, geometry_delta, entry.morph_arrays.size())
						var first: PackedVector3Array = entry.morph_arrays[0][Mesh.ARRAY_VERTEX]
						var second: PackedVector3Array = entry.morph_arrays[1][Mesh.ARRAY_VERTEX]
						if first.size() == second.size() and weights.size() >= 2:
							var positions := PackedVector3Array()
							positions.resize(first.size())
							for i in range(first.size()): positions[i] = first[i] * weights[0] + second[i] * weights[1]
							arrays[Mesh.ARRAY_VERTEX] = positions
							metrics.shape_frames += 1
							changed = true
							deformed = true
						else: _unsupported_effect(entry, "Incompatible Shape topology")
					elif advancing and entry.morph_arrays.size() >= 2 and not entry.morph_arrays[0].is_empty() and not entry.morph_arrays[1].is_empty(): descriptor.state.update(a, global_s, geometry_delta, entry.morph_arrays.size())
				"DefMorph":
					if descriptor.state != null and advancing and not geometry_ready: descriptor.state.update(geometry_delta, a, global_s)
					elif descriptor.state != null and geometry_ready:
						descriptor.state.update(geometry_delta, a, global_s)
						var targets := []
						for target in entry.morph_arrays: targets.append(target[Mesh.ARRAY_VERTEX])
						arrays[Mesh.ARRAY_VERTEX] = descriptor.state.blend_positions(targets)
						changed = true
						deformed = true
				"DefCos", "DefTexCos":
					if geometry_ready and entry.angular.size() == arrays[Mesh.ARRAY_VERTEX].size():
						if not absolute_vertex_colors and descriptor.kind == "DefCos" and int(descriptor.preset.get("DoColor", 0)) != 0: _absolute_colors(arrays, _color(entry.record.material.get("color_bytes", [])))
						arrays = descriptor.state.deform(arrays, entry.angular, a if descriptor.kind == "DefCos" else 0, global_s * float(entry.record.get("deformation_scale", 1)), geometry_delta, repeat.x, repeat.y, center, {"a": a, "s": global_s}, _color(entry.record.material.get("color_bytes", [])))
						changed = true
						deformed = deformed or descriptor.kind == "DefCos"
						absolute_vertex_colors = absolute_vertex_colors or (descriptor.kind == "DefCos" and int(descriptor.preset.get("DoColor", 0)) != 0)
					elif advancing and not geometry_ready and deformable: descriptor.state.advance(a if descriptor.kind == "DefCos" else 0, geometry_delta, {"a": a, "s": global_s}, _color(entry.record.material.get("color_bytes", [])))
				"DefRipple", "DefPools":
					if geometry_ready and entry.angular.size() == arrays[Mesh.ARRAY_VERTEX].size():
						if not absolute_vertex_colors and descriptor.kind == "DefPools" and int(descriptor.preset.get("DoColor", 1)) != 0: _absolute_colors(arrays, _color(entry.record.material.get("color_bytes", [])))
						arrays = descriptor.state.deform(arrays, entry.angular, a if descriptor.kind == "DefRipple" else 0, global_s, a if descriptor.kind == "DefPools" else 0, global_s, geometry_delta, float(entry.record.get("deformation_scale", 1)), _color(entry.record.material.get("color_bytes", [])))
						changed = true
						deformed = deformed or int(descriptor.preset.get("DoAmp", 1 if descriptor.kind == "DefRipple" else 0)) == 1
						absolute_vertex_colors = absolute_vertex_colors or (descriptor.kind == "DefPools" and int(descriptor.preset.get("DoColor", 1)) != 0)
					elif advancing and not geometry_ready and deformable: descriptor.state.advance(a if descriptor.kind == "DefRipple" else 0, a if descriptor.kind == "DefPools" else 0, global_s, geometry_delta, _color(entry.record.material.get("color_bytes", [])))
		if entry.hydra_motion != null and advancing:
			var hydra_parameters: Dictionary = entry.hydra_motion.advance(geometry_delta, bands)
			if geometry_ready:
				_assign_mesh(entry, entry.hydra_generator.mesh_from_preset(hydra_parameters))
				metrics.tree_size_change = maxf(metrics.tree_size_change, (entry.node.mesh.get_aabb().size - entry.initial_size).length())
		elif changed:
			entry.material.albedo_color = Color.WHITE if absolute_vertex_colors else _color(entry.record.material.get("color_bytes", []))
			if deformed and int(data.header.get("render_mode_raw", data.header.get("RenderStyle", "2"))) == 2:
				arrays[Mesh.ARRAY_NORMAL] = LegacyNormals.from_primitives(arrays[Mesh.ARRAY_VERTEX], [{"kind": 0, "indices": entry.normal_indices}], false)
				metrics.normal_updates += 1
			var mesh := ArrayMesh.new()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			_assign_mesh(entry, mesh)
		if entry.has("legacy_material"): LegacyLighting.sync(entry.legacy_material, entry.material)
		entry.local_effect_transform = effect_transform
		_apply_transform(entry, effect_transform)
		if entry.record.name == "Background" and entry.params.get("kind", "") == "TORUS" and float(entry.params.get("R1", 0)) == 26.0 and not inspection:
			var local: Vector3 = entry.node.global_transform.affine_inverse() * global_position
			metrics.maximum_torus_centerline_error = maxf(metrics.maximum_torus_centerline_error, absf(Vector2(local.x, local.z).length() - 26.0) + absf(local.y))
	if text_message != null: text_message.step(dt, band_a, global_s)
	if intro_screen != null: intro_screen.step(dt)
	if geometry_ready: metrics.geometry_frames += 1

func _apply_transform(entry: Dictionary, effect: Transform3D):
	if entry.node == null: return
	var record: Dictionary = entry.record
	var rotation := original_basis(record.engine_rotation_degrees)
	var scaling := Basis.from_scale(record.scale)
	entry.node.transform = Transform3D(rotation, record.engine_position) * effect * Transform3D(scaling, Vector3.ZERO)
	entry.sim_transform = entry.node.transform
	if inspection:
		var index := objects.find(entry)
		var bounds: AABB = entry.node.mesh.get_aabb()
		var fit := 2.8 / maxf(bounds.size.length(), 0.01)
		entry.node.basis = rotation * Basis.from_scale(Vector3.ONE * fit)
		entry.node.position = Vector3((index % 5) * 3.6 - 7.2, -(index / 5) * 3.6, 0) - entry.node.basis * bounds.get_center()

func _camera_look_at():
	var coordinates: Array = data.camera.get("LookAt", [0, 0, 0])
	var target := Vector3(coordinates[0], coordinates[1], coordinates[2])
	if camera.position.distance_squared_to(target) > 0.0001:
		camera.look_at_from_position(camera.global_position, to_global(target), Vector3.BACK if absf((target - camera.position).normalized().dot(Vector3.UP)) > 0.999 else Vector3.UP)

func set_inspection(value: bool):
	inspection = value
	if _world != null:
		for entry in objects:
			if entry.node != null and entry.node.get_parent() != _world: entry.node.reparent(_world, false)
		if not value:
			for link in data.links:
				var parent = object_named(link.parent)
				var child = object_named(link.child)
				if not parent.is_empty() and not child.is_empty() and parent.node != null and child.node != null and parent.node != child.node and not child.node.is_ancestor_of(parent.node): child.node.reparent(parent.node, false)
	if camera == null: return
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL if value else Camera3D.PROJECTION_PERSPECTIVE
	camera.size = maxf(18.0, ceilf(objects.size() / 5.0) * 3.6)
	camera.fov = float(data.camera.get("FOV", 45))
	camera.near = 0.05 if value else float(data.camera.get("NearClip", 1))
	camera.far = maxf(float(data.camera.get("FarClip", 200)), camera.near + 1)
	if value:
		for entry in objects: _apply_transform(entry, Transform3D.IDENTITY)
		camera.position = Vector3(0, -maxf(0, ceilf(objects.size() / 5.0) - 1) * 1.8, 40)
		camera.rotation = Vector3.ZERO
	else:
		camera.position = camera_runtime.position()
		_camera_current = camera.position
		_camera_look_at()
		step(0, [], 0)
		_snapshot_previous()

## Applies a special-effect preset (.lvm: "SD<object> <effect> <band> <preset>"
## lines). full_reset=true restarts the whole scene (preset dropdown);
## false rebinds only the named effects and keeps the scene running (F5-F8).
func apply_preset_file(filename: String, full_reset := true) -> Dictionary:
	var path := resource_path(filename)
	if path.is_empty(): return {"error": "Missing preset event file"}
	var applied := 0
	var unresolved := []
	var touched := []
	for line in FileAccess.get_file_as_string(path).replace("\\r", "").replace("\\n", "\n").replace("\r", "").split("\n"):
		var words := line.split(" ", false)
		if words.size() != 4: continue
		var entry := object_named(words[0].trim_prefix("SD"))
		if entry.is_empty(): unresolved.append(line); continue
		var found := false
		for index in entry.record.effects.size():
			var effect: Dictionary = entry.record.effects[index]
			if effect.name == words[1]:
				effect.band = int(words[2])
				effect.Input1Band = effect.band
				effect.preset = int(words[3])
				applied += 1
				found = true
				touched.append([entry, index])
		if not found: unresolved.append(line)
	if full_reset: reset()
	else:
		for item in touched: _rebind_effect(item[0], item[1])
		_apply_style()
	return {"applied": applied, "unresolved": unresolved}

func _rebind_effect(entry: Dictionary, index: int) -> void:
	if index >= entry.effects.size(): return
	var effect: Dictionary = entry.record.effects[index]
	var old: Dictionary = entry.effects[index]
	# Setter semantics for DefSwitch: NextShape starts a cross-fade from the
	# current shape (0x1000d409), so the running state is kept.
	if old.kind == "DefSwitch" and old.state != null:
		old.binding = effect
		old.preset = _preset(effect)
		old.state.apply_preset(old.preset)
		return
	entry.effects[index] = _make_descriptor(entry, effect)
# ---------------------------------------------------------------------------
# Engine API (docs/ENGINE_API.md). Safe to call from any UI or event bus.
# ---------------------------------------------------------------------------

func get_style_flags() -> int: return style_flags

func set_style_flags(mask: int) -> void:
	style_flags = mask & 0x3ff
	_apply_style()

func set_style_flag(flag: int, on: bool) -> void:
	set_style_flags((style_flags | flag) if on else (style_flags & ~flag))

## Original toggle helper LAVA.exe 0x40e96c (XOR of one bit). Returns new state.
func toggle_style_flag(flag: int) -> bool:
	set_style_flags(style_flags ^ flag)
	return (style_flags & flag) != 0

func style_flag_state() -> Dictionary: return StyleFlags.describe(style_flags)

## Responsivness (simulation-time multiplier, Lava3 0x10025aa5). null restores
## the scene header value. The original Response slider maps slider s to
## 2^(s*0.02-1) (SetSceneInfo 0x10015e95), i.e. 0.5..2.0 for s in 0..100.
func set_response(value) -> void:
	response_override = null if value == null else maxf(float(value), 0.0)

func get_response() -> float:
	return float(response_override) if response_override != null else float(data.get("header", {}).get("Responsivness", 1.0))

static func response_from_slider(slider: float) -> float: return pow(2.0, slider * 0.02 - 1.0)
static func slider_from_response(value: float) -> float: return (log(maxf(value, 1e-6)) / log(2.0) + 1.0) / 0.02

## Brightness = light ambient multiplier (light+0x2c, property 0x1c). The
## original Brightness slider maps s to s*0.01 (SetSceneInfo 0x10015e32).
func set_brightness(value) -> void:
	brightness_override = null if value == null else maxf(float(value), 0.0)
	_apply_lighting()

func get_brightness() -> float:
	return float(brightness_override) if brightness_override != null else float(data.get("header", {}).get("Brightness", 1.0))

static func brightness_from_slider(slider: float) -> float: return slider * 0.01

## Special-effect preset categories (EffectPresetCategoryInfo <name> <count>
## <current>, followed by that many EffectPreset lines).
func _parse_preset_categories() -> Array:
	var categories := []
	var pending := 0
	for line in data.get("commands", []):
		var words: PackedStringArray = str(line).replace("\t", " ").split(" ", false)
		if words.size() >= 4 and words[0] == "EffectPresetCategoryInfo":
			categories.append({"name": words[1], "count": int(words[2]), "current": int(words[3]), "presets": []})
			pending = int(words[2])
		elif words.size() >= 3 and words[0] == "EffectPreset" and pending > 0 and not categories.is_empty():
			categories[-1].presets.append({"file": words[1], "name": words[2]})
			pending -= 1
	return categories

## F5-F8 in the original (LAVA.exe 0x40e88a..0x40e8b7 -> SetPresetInfo
## 0x10017430 with index 0..3): CurrentPreset = (CurrentPreset+1) % count for
## category `index`, then that preset is applied. Returns {} when absent.
func trigger_effect_preset(index: int) -> Dictionary:
	if index < 0 or index >= preset_categories.size(): return {}
	var category: Dictionary = preset_categories[index]
	if category.presets.is_empty(): return {}
	category.current = (int(category.current) + 1) % maxi(int(category.count), 1)
	if category.current >= category.presets.size(): category.current = 0
	var preset: Dictionary = category.presets[category.current]
	var result := apply_preset_file(preset.file, false)
	result.category = category.name
	result.preset = preset.name
	result.current = category.current
	return result

## Intro screen (N in the original: WM_COMMAND 0x7d9).
func show_intro() -> bool:
	return intro_screen != null and intro_screen.show_intro()

func hide_intro() -> void:
	if intro_screen != null: intro_screen.hide_intro()

## 3D text message (M in the original: WM_COMMAND 0x7da toggles it).
func toggle_text_message() -> bool:
	if text_message == null: return false
	text_message.set_enabled(not text_message.enabled)
	return text_message.enabled

func set_text_message(text = null, enabled = null) -> void:
	if text_message == null: return
	if text != null: text_message.set_text(str(text))
	if enabled != null: text_message.set_enabled(bool(enabled))

func text_message_enabled() -> bool: return text_message != null and text_message.enabled

# ---------------------------------------------------------------------------
# Style application
# ---------------------------------------------------------------------------

func _apply_style() -> void:
	var textured := (style_flags & StyleFlags.TEXTURE) != 0
	var lights_on := (style_flags & StyleFlags.LIGHTS) != 0
	var flat := (style_flags & StyleFlags.FLAT_SHADING) != 0
	for entry in objects:
		if entry.node == null or entry.material == null: continue
		var texture = entry.get("texture")
		entry.material.albedo_texture = texture if textured else null
		var lit: bool = entry.get("lit", true) and lights_on
		entry.material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL if lit else BaseMaterial3D.SHADING_MODE_UNSHADED
		if entry.has("legacy_material"):
			entry.legacy_material.set_shader_parameter("has_texture", textured and texture != null)
			entry.legacy_material.set_shader_parameter("lighting_enabled", lit)
			entry.legacy_material.set_shader_parameter("flat_shading", flat)
		for descriptor in entry.effects: _sync_descriptor_do_color(descriptor)
		_refresh_flat(entry)
	if camera_runtime != null: camera_runtime.scene_style = style_flags
	if text_message != null: text_message.apply_style(style_flags)
	var wireframe := (style_flags & StyleFlags.WIREFRAME) != 0
	if wireframe != _applied_wireframe and is_inside_tree():
		get_viewport().debug_draw = Viewport.DEBUG_DRAW_WIREFRAME if wireframe else Viewport.DEBUG_DRAW_DISABLED
		_applied_wireframe = wireframe
	_apply_lighting()

## Dynamic Coloring: the original sets DoColor (0x82) = 1.0/0.0 on every
## effect of every object each frame (scene draw 0x10025c20..0x10025ca7), so the
## flag overrides the preset value for classes that accept DoColor.
func _sync_descriptor_do_color(descriptor: Dictionary) -> void:
	if descriptor.kind not in DO_COLOR_KINDS: return
	var value := 1 if (style_flags & StyleFlags.DYNAMIC_COLORING) != 0 else 0
	descriptor.preset["DoColor"] = value
	var state = descriptor.state
	if state == null: return
	match descriptor.kind:
		"DefBump": state._p["DoColor"] = value
		"DefCos": state._cos["DoColor"] = value
		"DefRipple": state._r["DoColor"] = value
		"DefPools": state._p["DoColor"] = value
		"DefSuperBump": state._p["DoColor"] = value
		_:
			if state.has_method("set_do_color"): state.set_do_color(value)

func _apply_lighting() -> void:
	if _environment == null: return
	var strobe := (style_flags & StyleFlags.STROBE) != 0
	var colored := (style_flags & StyleFlags.COLORED_LIGHTING) != 0
	var lights_on := (style_flags & StyleFlags.LIGHTS) != 0
	var brightness := get_brightness()
	var ambient := Color(0, 0, 0, 1)
	var first = null
	for light in _lights:
		var terms: Dictionary = light_fx.light_terms(light.color, brightness, strobe, colored)
		light.node.light_color = terms.diffuse
		light.node.visible = lights_on
		ambient.r += terms.ambient.r
		ambient.g += terms.ambient.g
		ambient.b += terms.ambient.b
		if first == null: first = terms
	var energy := maxf(ambient.r, maxf(ambient.g, ambient.b))
	_environment.ambient_light_energy = energy
	_environment.ambient_light_color = Color(ambient.r / energy, ambient.g / energy, ambient.b / energy) if energy > 0 else Color.BLACK
	if first == null: return
	for entry in objects:
		if entry.has("legacy_material"): LegacyLighting.set_light(entry.legacy_material, first.diffuse, first.ambient)
	if text_message != null: text_message.set_light(first.diffuse, first.ambient)

## Light terms currently submitted (tests, debug overlay).
func current_light_terms() -> Dictionary:
	if _lights.is_empty(): return {}
	return light_fx.light_terms(_lights[0].color, get_brightness(), (style_flags & StyleFlags.STROBE) != 0, (style_flags & StyleFlags.COLORED_LIGHTING) != 0)

## Flat shading on the StandardMaterial path: GL_FLAT has no Godot material
## switch, so meshes are de-indexed with per-face normals (approximation; the
## Triple Trance legacy shader uses a true flat-interpolated lit colour).
func _assign_mesh(entry: Dictionary, mesh: Mesh) -> void:
	entry.smooth_mesh = mesh
	if (style_flags & StyleFlags.FLAT_SHADING) != 0 and not entry.has("legacy_material") and mesh != null:
		entry.flat_mesh = _flat_mesh(mesh)
		entry.node.mesh = entry.flat_mesh
	else: entry.node.mesh = mesh

func _refresh_flat(entry: Dictionary) -> void:
	if entry.node == null or entry.has("legacy_material"): return
	var flat := (style_flags & StyleFlags.FLAT_SHADING) != 0
	var showing_flat: bool = entry.has("flat_mesh") and entry.node.mesh == entry.flat_mesh
	if flat and not showing_flat:
		entry.smooth_mesh = entry.node.mesh
		entry.flat_mesh = _flat_mesh(entry.node.mesh)
		entry.node.mesh = entry.flat_mesh
	elif not flat and showing_flat:
		entry.node.mesh = entry.get("smooth_mesh", entry.node.mesh)

static func _flat_mesh(mesh: Mesh) -> ArrayMesh:
	var result := ArrayMesh.new()
	if mesh == null or mesh.get_surface_count() == 0: return result
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals = arrays[Mesh.ARRAY_NORMAL]
	var uvs = arrays[Mesh.ARRAY_TEX_UV]
	var colors = arrays[Mesh.ARRAY_COLOR]
	var indices = arrays[Mesh.ARRAY_INDEX]
	if indices == null or indices.is_empty():
		indices = PackedInt32Array(range(vertices.size()))
	var out_vertices := PackedVector3Array()
	var out_normals := PackedVector3Array()
	var out_uvs := PackedVector2Array()
	var out_colors := PackedColorArray()
	var has_normals: bool = normals != null and normals.size() == vertices.size()
	var has_uvs: bool = uvs != null and uvs.size() == vertices.size()
	var has_colors: bool = colors != null and colors.size() == vertices.size()
	for t in range(0, indices.size() - 2, 3):
		var a: int = indices[t]
		var b: int = indices[t + 1]
		var c: int = indices[t + 2]
		var face := (vertices[b] - vertices[a]).cross(vertices[c] - vertices[a])
		if has_normals and face.dot(normals[a] + normals[b] + normals[c]) < 0.0: face = -face
		face = face.normalized()
		for i in [a, b, c]:
			out_vertices.append(vertices[i])
			out_normals.append(face)
			if has_uvs: out_uvs.append(uvs[i])
			if has_colors: out_colors.append(colors[i])
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = out_vertices
	out[Mesh.ARRAY_NORMAL] = out_normals
	if has_uvs: out[Mesh.ARRAY_TEX_UV] = out_uvs
	if has_colors: out[Mesh.ARRAY_COLOR] = out_colors
	if not out_vertices.is_empty(): result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out)
	return result
