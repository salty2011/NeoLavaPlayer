extends SceneTree
func _initialize(): call_deferred("run")
func run():
	var runtime = load("res://scene_runtime.gd").new()
	root.add_child(runtime)
	var inventory = JSON.parse_string(FileAccess.get_file_as_string("res://test-data/scene-inventory.json"))
	var results = []
	var failures = []
	for entry in inventory.scenes:
		var summary = runtime.load_scene(scene_dir(entry.path))
		var expected = runtime.data.objects.size() - (1 if entry.name == "AK1200" else 0)
		if summary.loaded_objects != expected or not summary.errors.is_empty(): failures.append({"scene": entry.name, "summary": summary})
		for object in runtime.objects:
			if object.morph_meshes.size() != object.record.morphs.size(): failures.append({"scene": entry.name, "error": "Lost morph slots"})
		var initial_generator = runtime.object_named("Hydra").get("hydra_generator") if entry.name in ["Hydroid", "LVT4"] else null
		for i in range(3): runtime.step(0.05, [0.4, 0.3, 0.7], 0.6)
		if entry.name == "Hydroid":
			var hydra = runtime.object_named("Hydra")
			if hydra.hydra_generator != initial_generator or hydra.hydra_generator.get("_position_grids").is_empty(): failures.append({"error": "Hydra generator/grids not retained across frames"})
			if hydra.node.position != Vector3(0, -1.7, 0): failures.append({"error": "Hydra placement incorrect"})
			if runtime.metrics.maximum_torus_centerline_error > 0.001: failures.append({"error": "Hydroid torus centerline error", "value": runtime.metrics.maximum_torus_centerline_error})
			if runtime.metrics.normal_updates <= 0: failures.append({"error": "Original deformation normals were not updated"})
			var board_normals = runtime.object_named("Surfboard").node.mesh.surface_get_arrays(0)[Mesh.ARRAY_NORMAL]
			var board_base = runtime.object_named("Surfboard").base_arrays[Mesh.ARRAY_NORMAL]
			var normal_changed = false
			for vertex in range(board_normals.size()):
				if board_normals[vertex].distance_to(board_base[vertex]) > 0.01: normal_changed = true; break
			if not normal_changed: failures.append({"error": "Original area-weighted normals were replaced by base unit normals"})
			if runtime.data.bands.size() != 3: failures.append({"error": "Hydroid band ranges lost"})
			if runtime.metrics.tree_size_change <= 0: failures.append({"error": "Hydra motion did not update mesh"})
			var base_position = hydra.node.position
			runtime.set_inspection(true)
			runtime.set_inspection(false)
			if hydra.node.position != base_position: failures.append({"error": "Inspector did not restore composed scene"})
			var preset = runtime.apply_preset_file("species2.lvm")
			if preset.get("applied", 0) != 4 or not preset.get("unresolved", []).is_empty(): failures.append({"error": "Species preset bindings incomplete"})
			if hydra.params.get("TreeSize", -1) != hydra.record.effects[0].definition.presets[2].parameters.TreeSize: failures.append({"error": "Species creation preset did not update Hydra geometry"})
			runtime.reset()
			if runtime.metrics.tree_size_change != 0: failures.append({"error": "Reset did not clear dynamic state"})
		results.append({"version": entry.version, "scene": entry.name, "loaded_objects": summary.loaded_objects, "total_objects": summary.total_objects, "missing_resources": summary.missing_resources, "effect_coverage": summary.effect_coverage, "unsupported": summary.unsupported, "metrics": runtime.metrics.duplicate(true)})
	# Actual scene texture families must execute, not just count as loaded.
	for result in results:
		if result.scene in ["Aqua Boogie", "AK1200"] and result.metrics.texture_frames == 0: failures.append({"error": "Scene texture effects never executed", "scene": result.scene})
	for result in results:
		if result.scene in ["LVT5", "Triple Trance"] and result.metrics.matrix_frames == 0: failures.append({"error": "Scene matrix effects never executed", "scene": result.scene})
	for scene_name in ["Triple Trance", "Music Metropolis"]:
		var textured = runtime.load_scene("res://scenes/lava25/" + scene_name)
		if not textured.missing_resources.is_empty(): failures.append({"error": "Recovered same-stem textures unresolved", "scene": scene_name, "missing": textured.missing_resources})
		if textured.resource_aliases.is_empty(): failures.append({"error": "Image aliases not reported", "scene": scene_name})
	runtime.load_scene("res://scenes/lava25/Triple Trance")
	var original_environment
	var original_light
	for child in runtime.get("_world").get_children():
		if child is WorldEnvironment: original_environment = child.environment
		if child is OmniLight3D: original_light = child
	if original_environment == null or not is_equal_approx(original_environment.ambient_light_energy, 0.75): failures.append({"error": "Triple Trance Brightness light ambient incorrect"})
	if original_light == null or original_light.position != Vector3(0, 2, 0) or original_light.omni_attenuation != 0: failures.append({"error": "Triple Trance point light/constant attenuation incorrect"})
	var shape_object = runtime.object_named("Mushroom")
	var ShapeWeights = load("res://shape_weights.gd")
	var isolated_shape = ShapeWeights.new()
	isolated_shape.reset({"CreationLevel": 0, "AmpScale": 1})
	shape_object.effects = [{"kind": "DefShape", "state": isolated_shape, "preset": {}, "binding": {"Input1Band": 0}}]
	runtime.step(0.0399, [1.0], 0.5)
	var shape_vertices = shape_object.node.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var first_shape = shape_object.morph_arrays[0][Mesh.ARRAY_VERTEX]
	var second_shape = shape_object.morph_arrays[1][Mesh.ARRAY_VERTEX]
	for vertex in [0, first_shape.size() / 2, first_shape.size() - 1]:
		if shape_vertices[vertex].distance_to((first_shape[vertex] + second_shape[vertex]) * 0.5) > 0.0001: failures.append({"error": "Runtime Shape did not blend first two attachments", "vertex": vertex})
	var colored_sphere = runtime.object_named("Sphere")
	if colored_sphere.material.albedo_color != Color.WHITE: failures.append({"error": "Cos absolute vertex palette multiplied original diffuse twice"})
	for unsupported in runtime.summary().unsupported:
		if unsupported.get("kind", "") == "DefCos color interpolation": failures.append({"error": "Implemented Cos color remains unsupported"})
	if runtime.metrics.bump_frames == 0: failures.append({"error": "Triple Trance original Bump did not execute"})
	var cadence_start = runtime.metrics.geometry_frames
	for i in range(10): runtime.step(0.0399, [0.2, 0.3, 0.4], 0.5)
	if runtime.metrics.geometry_frames - cadence_start != 10: failures.append({"error": "Composed scene skipped geometry on render frames just below FPS interval"})
	# Two recovered-object matrix bindings prove left multiplication and ResetMat
	# retention: original Scale/Shear never inspect their stored ResetMat field.
	runtime.load_scene("res://scenes/Hydroid")
	var matrix_board = runtime.object_named("Surfboard")
	var MatrixEffects = load("res://matrix_effects.gd")
	var first_scale = MatrixEffects.new()
	first_scale.configure("DefScale", {"CreationLevel": 0, "AmpScale": 1, "AxisMin": 1, "ResetMat": 1})
	var second_scale = MatrixEffects.new()
	second_scale.configure("DefScale", {"CreationLevel": 0, "AmpScale": 1, "AxisMin": 0, "AxisMax": 1, "ResetMat": 1})
	first_scale.random_source = func(): return 0.5
	second_scale.random_source = func(): return 0.5
	matrix_board.effects = [{"kind": "DefScale", "state": first_scale, "preset": first_scale.parameters, "binding": {"Input1Band": 0}}, {"kind": "DefScale", "state": second_scale, "preset": second_scale.parameters, "binding": {"Input1Band": 0}}]
	runtime.step(0.01, [1.0], 1.0)
	var expected_basis = Basis.from_scale(Vector3(1.0 / sqrt(2.0), 2, 1.0 / sqrt(2.0))) * Basis.from_scale(Vector3(2, 1.0 / sqrt(2.0), 1.0 / sqrt(2.0)))
	if not matrix_board.local_effect_transform.basis.is_equal_approx(expected_basis): failures.append({"error": "Scale binding order or invented ResetMat reset"})
	var parent_entry = runtime.object_named("Background")
	var parent_scale = MatrixEffects.new()
	parent_scale.configure("DefScale", {"CreationLevel": 2})
	parent_entry.effects = []
	# Parent local effect differs deliberately from its node/world placement.
	parent_entry.local_effect_transform = Transform3D(Basis.IDENTITY, Vector3(2, 4, 6))
	var shear = MatrixEffects.new()
	shear.configure("DefShear", {"FollowParent": 1, "Height": 2, "Base": 1})
	matrix_board.record.parent = "Background"
	# Only execute child here so its explicit parent effect fixture is retained.
	var saved_objects = runtime.objects
	runtime.objects = [matrix_board]
	# FollowParent is resolved by object_named; include parent but temporarily omit node.
	var parent_node = parent_entry.node
	parent_entry.node = null
	runtime.objects.append(parent_entry)
	matrix_board.effects = [{"kind": "DefShear", "state": shear, "preset": shear.parameters, "binding": {"Input1Band": 0}}]
	runtime.step(0.01, [0.0], 0.0)
	var expected_shear = shear.update(0, 0, 0, Transform3D(Basis.IDENTITY, Vector3(2, 4, 6)))
	if not matrix_board.local_effect_transform.is_equal_approx(expected_shear): failures.append({"error": "FollowParent used node/world transform instead of local effect matrix"})
	parent_entry.node = parent_node
	runtime.objects = saved_objects
	runtime.load_scene("res://scenes/Hydroid")
	var alpha_board = runtime.object_named("Surfboard")
	var AlphaCenter = load("res://alpha_center_effects.gd")
	var alpha_effect = AlphaCenter.new()
	alpha_effect.configure("DefAlpha", {"Alpha": 0.8, "AlphaVelocityMin": 0.2, "CreationLevel": 2})
	alpha_board.effects = [{"kind": "DefAlpha", "state": alpha_effect, "preset": alpha_effect.parameters, "binding": {"Input1Band": 0}}]
	runtime.step(0.1, [0.0], 0.0)
	if alpha_board.material.albedo_color != Color.WHITE: failures.append({"error": "Alpha absolute colors still tinted by material diffuse"})
	var alpha_colors = alpha_board.node.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	if absf(alpha_colors[0].a - 0.78) > 1.0 / 255.0: failures.append({"error": "Runtime Alpha did not overwrite vertex alpha"})
	var center_effect = AlphaCenter.new()
	center_effect.configure("DefCenter", {"CreationLevel": 0, "RMax": 0, "ZMax": 0.5, "AmpScale": 2})
	center_effect.random_source = func(): return 0.5
	alpha_board.effects = [{"kind": "DefCenter", "state": center_effect, "preset": center_effect.parameters, "binding": {"Input1Band": 0}}]
	runtime.step(0.1, [1.0], 0.5)
	if not alpha_board.local_effect_transform.origin.is_equal_approx(Vector3(0, 0.5, 0)): failures.append({"error": "Runtime Center local offset mismatch"})
	# Controlled inputs on a recovered mesh test context order and absolute UV writes.
	runtime.load_scene("res://scenes/Hydroid")
	var board = runtime.object_named("Surfboard")
	var TextureEffects = load("res://texture_effects.gd")
	var translate = TextureEffects.new()
	translate.configure("DefTexTranslate", {"VXDir": 1, "VYDir": 1, "VXMin": 1, "VXMax": 1, "VYMin": 0, "VYMax": 0, "CreationLevel": 2})
	board.effects = [{"kind": "DefTexTranslate", "state": translate, "preset": {}, "binding": {"Input1Band": 2}}]
	board.texture_context = {"repeat": Vector2(2, 3), "center": Vector2.ZERO}
	runtime.step(0.1, [0, 0, 0], 0.5)
	var uv = board.node.mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV][0]
	if not uv.is_equal_approx(Vector2(0.9, 3.0)): failures.append({"error": "Translate absolute repeat/context mismatch", "uv": str(uv)})
	runtime.step(0.1, [0, 0, 0], 0.5)
	if not is_equal_approx(board.texture_context.center.x, 0.8): failures.append({"error": "Texture context did not persist across frames"})
	var wave = TextureEffects.new()
	wave.configure("DefTexWave", {"CreationLevel": 2, "MMin": 4, "Mmax": 4, "PhaseVMin": 0, "PhaseVMax": 0, "PhaseMin": 0, "PhaseMax": 0, "CosDepth": 2, "Direction": 1, "AmpScale": 7.5})
	board.effects = [{"kind": "DefTexWave", "state": wave, "preset": {}, "binding": {"Input1Band": 0}}]
	board.texture_context = {"repeat": Vector2.ONE, "center": Vector2.ZERO}
	runtime.step(0.1, [0, 0, 0], 0.5)
	uv = board.node.mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV][0]
	if not uv.is_equal_approx(Vector2(0, 1.0 - 3.75 / 180.0)): failures.append({"error": "Wave angular UV displacement mismatch", "uv": str(uv)})
	var zoom = TextureEffects.new()
	zoom.configure("DefTexZoom", {"CreationLevel": 2, "DoRestore": 0})
	zoom.zoom_repeat = Vector2(2, 3)
	zoom.zoom_center = Vector2(3.1415927410125732 * 1.5, 3.1415927410125732 * 1.25)
	board.effects = [{"kind": "DefTexZoom", "state": zoom, "preset": {}, "binding": {"Input1Band": 0}}]
	runtime.step(0.1, [0, 0, 0], 0.0)
	uv = board.node.mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV][0]
	if not uv.is_equal_approx(Vector2(0.25, 3.5)): failures.append({"error": "Zoom center clamp/absolute repeat mismatch", "uv": str(uv)})
	if runtime.resource_path("wAVY.JPG") != "res://scenes/shared-textures/Wavy.jpg": failures.append({"error": "Shared texture case resolver failed"})
	var snapshot = runtime.summary()
	if not snapshot.has("metrics") or snapshot.loaded_objects != 3: failures.append({"error": "Public runtime summary missing live state"})
	# Mount scene geometry/text plus imported textures without JPG source files.
	var pack_path = "user://scene-runtime-fixture.pck"
	var packer = PCKPacker.new()
	packer.pck_start(pack_path)
	var source = "res://scenes/Hydroid"
	var source_dir = DirAccess.open(source)
	for filename in source_dir.get_files():
		if filename.get_extension() in ["ashex", "lvd", "lvo", "lvm"]:
			packer.add_file("res://runtime-fixture/Hydroid/" + filename, source.path_join(filename))
		elif filename.ends_with(".import"):
			packer.add_file("res://runtime-fixture/Hydroid/" + filename, source.path_join(filename))
			var import_config = ConfigFile.new()
			if import_config.load(source.path_join(filename)) == OK:
				for destination in import_config.get_value("deps", "dest_files", []): packer.add_file(destination, destination)
	if packer.flush() != OK or not ProjectSettings.load_resource_pack(pack_path): failures.append({"error": "Cannot mount runtime PCK fixture"})
	else:
		var packed_summary = runtime.load_scene("res://runtime-fixture/Hydroid")
		if packed_summary.loaded_objects != 3 or not packed_summary.errors.is_empty(): failures.append({"error": "Packed runtime scene failed"})
		for object in runtime.objects:
			if object.node != null and object.material.albedo_texture == null: failures.append({"error": "Texture import remap failed in packed fixture", "object": object.record.name})
		runtime.step(0.1, [0.5, 0.5, 0.5], 0.7)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(pack_path))
	var report = {"passed": failures.is_empty() and results.size() == 29, "scenes_checked": results.size(), "failures": failures, "scenes": results}
	FileAccess.open(report_path("scene-runtime-test.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "\t") + "\n")
	print(JSON.stringify({"passed": report.passed, "scenes": results.size(), "failures": failures}))
	runtime.free()
	quit(0 if report.passed else 1)


## Scene folder for an inventory path ("assets/lava25/scenes/X" -> res://scenes/lava25/X).
static func scene_dir(inventory_path: String) -> String:
	return "res://scenes/" + inventory_path.trim_prefix("assets/").replace("/scenes/", "/")

## JSON reports go to research/ in the full recovery checkout, else user://.
static func report_path(file_name: String) -> String:
	var proof := "res://../research/oozic/proof/scene-inventory"
	return proof.path_join(file_name) if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(proof)) else "user://" + file_name
