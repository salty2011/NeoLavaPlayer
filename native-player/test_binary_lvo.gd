extends SceneTree
func _initialize():
	var importer = load("res://binary_lvo.gd").new()
	var inventory = JSON.parse_string(FileAccess.get_file_as_string("res://test-data/scene-inventory.json"))
	var checked = 0
	var failures = []
	for scene in inventory.scenes:
		for model in scene.models:
			if model.kind != "BINARY_MESH": continue
			var path = scene_dir(scene.path) + "/" + model.file
			var result = importer.read_file(path)
			checked += 1
			if result.has("error"):
				failures.append({"path": path, "error": result.error})
			elif result.vertices != model.vertices or result.faces != model.faces or result.mesh.get_surface_count() != 1:
				failures.append({"path": path, "error": "Count or surface mismatch"})
	# Concave five-vertex face must yield three triangles with original winding.
	var concave = PackedVector3Array([Vector3(0, 0, 0), Vector3(2, 0, 0), Vector3(2, 2, 0), Vector3(1, 1, 0), Vector3(0, 2, 0)])
	var triangle_ids = importer.triangulate(PackedInt32Array([0, 1, 2, 3, 4]), concave)
	if triangle_ids.size() != 9: failures.append({"error": "Concave polygon triangulation failed"})
	for i in range(0, triangle_ids.size(), 3):
		if (concave[triangle_ids[i + 1]] - concave[triangle_ids[i]]).cross(concave[triangle_ids[i + 2]] - concave[triangle_ids[i]]).z <= 0:
			failures.append({"error": "Polygon winding changed"})
	# Corrupt and truncated data must fail without partial meshes.
	for bytes in [PackedByteArray(), PackedByteArray([70, 0]), PackedByteArray([66, 77, 255, 255, 255, 127])]:
		if not importer.decode(bytes).has("error"): failures.append({"error": "Malformed payload accepted"})
	var report = {"binary_meshes_checked": checked, "failures": failures, "passed": checked == 258 and failures.is_empty()}
	var out = FileAccess.open(report_path("binary-lvo-test.json"), FileAccess.WRITE)
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
