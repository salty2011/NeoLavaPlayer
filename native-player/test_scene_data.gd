extends SceneTree
func _initialize():
	var loader = load("res://scene_data.gd").new()
	var inventory = JSON.parse_string(FileAccess.get_file_as_string("res://test-data/scene-inventory.json"))
	var results = []
	var errors = []
	for entry in inventory.scenes:
		var scene = loader.read_scene(scene_dir(entry.path))
		var count = int(scene.header.get("NumObjects", 0))
		if scene.objects.size() != count: scene.errors.append("Object count mismatch")
		if scene.camera.is_empty(): scene.errors.append("Missing original camera fields")
		for object in scene.objects:
			if object.name.is_empty(): scene.errors.append("Empty object name")
			if object.morphs.size() != object.num_morphs: scene.errors.append("Morph count mismatch: " + object.name)
			for effect in object.effects:
				if effect.file.is_empty() or effect.definition.get("type", "").is_empty(): scene.errors.append("Missing effect definition: " + object.name)
		if entry.name == "Hydroid":
			if scene.objects.size() != 3 or scene.objects[0].name != "Surfboard" or scene.objects[2].effects.size() != 4: scene.errors.append("Hydroid content mismatch")
			if not is_equal_approx(scene.camera.get("FOV", -1.0), 45.0): scene.errors.append("Hydroid camera FOV mismatch")
			var hydra = scene.objects[2]
			if hydra.object_type != 1 or hydra.engine_position.z != 0 or hydra.engine_rotation_degrees != Vector3(-90, 0, 0): scene.errors.append("Hydra legacy OType transform mismatch")
			if hydra.effects[1].Input1Band != 2 or hydra.effects[1].Input2Type != 1: scene.errors.append("Hydra effect selector mismatch")
		if entry.name == "Cyber Diva (Hi-res)" and scene.objects.size() != 59: scene.errors.append("Cyber Diva count mismatch")
		results.append({"version": entry.version, "scene": entry.name, "objects": scene.objects.size(), "errors": scene.errors, "unsupported": scene.unsupported, "warnings": scene.warnings})
		errors.append_array(scene.errors)
	# A mounted resource pack exercises the same virtual filesystem as exports.
	var packer = PCKPacker.new()
	var pack_path = "user://scene-parser-fixture.pck"
	var pack_error = packer.pck_start(pack_path)
	var source_folder = ProjectSettings.globalize_path("res://scenes/lava25/Hydroid").simplify_path()
	var source_dir = DirAccess.open(source_folder)
	for filename in source_dir.get_files():
		if filename.get_extension() in ["ashex", "lvd", "lvo", "lvm"]:
			pack_error = packer.add_file("res://parser-fixture/Hydroid/" + filename, source_folder.path_join(filename))
			if pack_error != OK: errors.append("Could not add resource pack fixture")
	if packer.flush() != OK or not ProjectSettings.load_resource_pack(pack_path): errors.append("Could not mount resource pack fixture")
	else:
		var packed_scene = loader.read_scene("res://parser-fixture/Hydroid")
		if packed_scene.objects.size() != 3 or not packed_scene.errors.is_empty() or packed_scene.objects[2].effects.size() != 4:
			errors.append("Mounted PCK Hydroid parse mismatch")
		if not packed_scene.folder.begins_with("res://"): errors.append("PCK path was globalized")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(pack_path))
	var report = {"scenes_checked": results.size(), "passed": results.size() == 29 and errors.is_empty(), "scenes": results, "packed_resource_fixture": true, "errors": errors}
	var out = FileAccess.open(report_path("scene-data-test.json"), FileAccess.WRITE)
	out.store_string(JSON.stringify(report, "\t") + "\n")
	print(JSON.stringify({"scenes": results.size(), "errors": errors, "passed": report.passed}))
	quit(0 if report.passed else 1)


## Scene folder for an inventory path ("assets/lava25/scenes/X" -> res://scenes/lava25/X).
static func scene_dir(inventory_path: String) -> String:
	return "res://scenes/" + inventory_path.trim_prefix("assets/").replace("/scenes/", "/")

## JSON reports go to research/ in the full recovery checkout, else user://.
static func report_path(file_name: String) -> String:
	var proof := "res://../research/oozic/proof/scene-inventory"
	return proof.path_join(file_name) if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(proof)) else "user://" + file_name
