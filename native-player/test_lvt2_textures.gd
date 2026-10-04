extends SceneTree
## LVT2 "Dancing Well": lost flower textures resolve to labelled reconstructions
## (setting ON) or are reported missing (OFF); recovered bluesky is always used.
const SceneCatalog = preload("res://scene_catalog.gd")
func _initialize(): call_deferred("run")
func run():
	var failures := []
	for set_name in ["lava25", "oozic30"]:
		var runtime = load("res://scene_runtime.gd").new()
		root.add_child(runtime)
		var folder := "res://scenes/%s/LVT2" % set_name
		runtime.use_reconstructions = true
		var on: Dictionary = runtime.load_scene(folder)
		if not on.missing_resources.is_empty(): failures.append({"set": set_name, "on_missing": on.missing_resources})
		if on.loaded_objects != on.total_objects: failures.append({"set": set_name, "error": "objects not all loaded"})
		var expected := ["rainbowflowers.bmp", "waterflowers.bmp", "rainbowflowerwater.bmp"]
		var got: Array = on.reconstructed_textures.duplicate()
		got.sort(); expected.sort()
		if got != expected: failures.append({"set": set_name, "reconstructed": got})
		if on.recovered_textures != ["bluesky.bmp"]: failures.append({"set": set_name, "recovered": on.recovered_textures})
		if on.texture_provenance.get("bluesky.bmp", {}).get("provenance", "") != "recovered-original": failures.append({"set": set_name, "error": "bluesky provenance"})
		for name in expected:
			if on.texture_provenance.get(name, {}).get("provenance", "") != "reconstruction": failures.append({"set": set_name, "error": "provenance " + name})
		for object_name in ["WaterSurface", "Ground", "Background"]:
			var entry: Dictionary = runtime.object_named(object_name)
			if entry.is_empty() or entry.material == null: failures.append({"set": set_name, "error": "no material " + object_name})
			elif entry.material.albedo_texture == null: failures.append({"set": set_name, "error": "untextured " + object_name})
		runtime.use_reconstructions = false
		var off: Dictionary = runtime.load_scene(folder)
		var off_missing: Array = off.missing_resources.duplicate()
		off_missing.sort()
		if off_missing != expected: failures.append({"set": set_name, "off_missing": off_missing})
		if not off.reconstructed_textures.is_empty(): failures.append({"set": set_name, "error": "reconstruction used while off"})
		if off.recovered_textures != ["bluesky.bmp"]: failures.append({"set": set_name, "error": "recovered original dropped when off"})
		runtime.queue_free()
	# Title suffix: reconstructed scenes are never shown as fully original.
	var entry := {"name": "LVT2", "title": "Dancing Well"}
	SceneCatalog.mark_reconstructed(entry, true)
	if SceneCatalog.display_title(entry) != "Dancing Well (partly reconstructed)": failures.append({"error": "title suffix", "got": SceneCatalog.display_title(entry)})
	SceneCatalog.mark_reconstructed(entry, false)
	if SceneCatalog.display_title(entry) != "Dancing Well": failures.append({"error": "title suffix when off"})
	var other := {"name": "LVT3", "title": "Triple Trance"}
	SceneCatalog.mark_reconstructed(other, true)
	if SceneCatalog.display_title(other) != "Triple Trance": failures.append({"error": "unrelated scene suffixed"})
	print(JSON.stringify({"failures": failures}))
	quit(0 if failures.is_empty() else 1)
