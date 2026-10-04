extends SceneTree
## Dumps every catalog scene's objects/materials/effects/lights as JSON (Phase 4f survey).
##   Godot --headless --audio-driver Dummy --path native-player --script res://tools/scene_survey.gd -- --out=/abs/file.json
const SceneRuntime = preload("res://scene_runtime.gd")
const SceneCatalog = preload("res://scene_catalog.gd")
var out := ""
func _initialize():
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="): out = arg.trim_prefix("--out=")
	call_deferred("run")
func run():
	var report := []
	for entry in SceneCatalog.load_catalog():
		var runtime = SceneRuntime.new()
		root.add_child(runtime)
		runtime.load_scene(entry.path)
		var objs := []
		for o in runtime.objects:
			var node = o.node
			var rec: Dictionary = o.record
			var tex = o.get("texture")
			objs.append({"name": rec.name, "texture": str(rec.material.get("texture", "")), "tex_loaded": tex != null,
				"color": rec.material.get("color_bytes", []), "gloss": rec.material.get("gloss", 0), "culling": rec.material.get("culling", "back"),
				"lit": o.get("lit", true), "visible": rec.get("Visible", "1"), "parent": rec.get("parent", ""),
				"effects": o.effects.map(func(d): return d.kind),
				"size": var_to_str(node.mesh.get_aabb().size) if node != null else "", "pos": var_to_str(node.position) if node != null else "",
				"alpha": o.material.albedo_color.a if o.material != null else 1.0})
		report.append({"name": entry.name, "folder": str(runtime.data.get("folder", "")), "objects": objs,
			"lights": runtime.data.get("lighting", []).map(func(c): return "%s %s %s" % [c.index, c.property, c.value]),
			"camera": runtime.data.get("camera", {}), "flags": runtime.default_style_flags})
		runtime.queue_free()
		await process_frame
	FileAccess.open(out, FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	quit()
