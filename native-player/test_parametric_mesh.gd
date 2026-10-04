extends SceneTree
func _initialize():
	var importer = load("res://parametric_mesh.gd").new()
	var inventory = JSON.parse_string(FileAccess.get_file_as_string("res://test-data/scene-inventory.json"))
	var checked = 0
	var failures = []
	var kinds = {}
	for scene in inventory.scenes:
		for model in scene.models:
			if model.kind == "BINARY_MESH" or model.kind == "BLOB": continue
			var path = scene_dir(scene.path) + "/" + model.file
			var definition = importer.read_definition(path)
			var mesh = importer.mesh_for(definition)
			checked += 1
			kinds[model.kind] = kinds.get(model.kind, 0) + 1
			if mesh == null:
				failures.append({"path": path, "error": importer.last_error})
				continue
			var arrays = mesh.surface_get_arrays(0)
			if arrays[Mesh.ARRAY_VERTEX].size() != (int(definition.NX) + 1) * (int(definition.NY) + 1): failures.append({"path": path, "error": "Wrong grid count"})
			if arrays[Mesh.ARRAY_INDEX].size() != int(definition.NX) * int(definition.NY) * 6: failures.append({"path": path, "error": "Wrong triangle count"})
			for normal in arrays[Mesh.ARRAY_NORMAL]:
				if abs(normal.length() - 1.0) > 0.0001:
					failures.append({"path": path, "error": "Invalid normal"})
					break
	# Principal coordinates/normals/UVs independently specified from original x87 traces.
	var d = {"kind": "CYLINDER", "NX": 4, "NY": 2, "R1": 1.0, "R2": 3.0, "R3": 2.0}
	var point = importer.sample(d, 0.0, 0.0)
	if not point.position.is_equal_approx(Vector3(0, 2, -1)) or not point.normal.is_equal_approx(Vector3(0, 0.5, -1).normalized()): failures.append({"error": "Cylinder top/reference mismatch"})
	point = importer.sample(d, 0.25, 1.0)
	if not point.position.is_equal_approx(Vector3(-3, -2, 0)) or not point.uv.is_equal_approx(Vector2(0.25, 0)): failures.append({"error": "Cylinder bottom/reference mismatch"})
	d = {"kind": "SHEET", "NX": 4, "NY": 2, "R1": 2.0, "R2": 3.0, "Inside": 1}
	point = importer.sample(d, 0, 0)
	if point.position != Vector3(-2, 3, 0) or point.normal != Vector3(0, 0, -1) or point.uv != Vector2.ONE: failures.append({"error": "Sheet reference mismatch"})
	d = {"kind": "DISK", "NX": 4, "NY": 1, "R1": 0.0, "R2": 2.0, "R3": -1.0}
	point = importer.sample(d, 0, 1)
	if point.position != Vector3(0, 0, -2) or point.normal != Vector3.UP or point.uv != Vector2(0.5, 1): failures.append({"error": "Disk planar UV/reference mismatch"})
	point = importer.sample(d, 0, 0)
	if point.uv != Vector2(0.5, 0.5): failures.append({"error": "Disk center UV mismatch"})
	if importer.mesh_for({"kind": "BLOB"}) != null or importer.decode_definition(PackedByteArray([66, 77, 255, 255, 255, 127])).has("kind"): failures.append({"error": "Unsupported/truncated definition accepted"})
	var report = {"parametric_models_checked": checked, "kinds": kinds, "failures": failures, "passed": checked == 147 and failures.is_empty()}
	var out = FileAccess.open(report_path("parametric-mesh-test.json"), FileAccess.WRITE)
	out.store_string(JSON.stringify(report, "\t") + "\n")
	print(JSON.stringify(report))
	quit(0 if report.passed else 1)


## Scene folder for an inventory path ("assets/lava25/scenes/X" -> res://scenes/lava25/X).
static func scene_dir(inventory_path: String) -> String:
	return "res://scenes/" + inventory_path.trim_prefix("assets/").replace("/scenes/", "/")

## JSON reports go to research/ in the full recovery checkout, else user://.
static func report_path(file_name: String) -> String:
	var proof := "res://../research/oozic/proof/scene-inventory"
	return proof.path_join(file_name) if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(proof)) else "user://" + file_name
