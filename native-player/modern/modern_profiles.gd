extends RefCounted
## Modern scene profiles: res://modern/profiles/*.json, matched by the scene
## folder's "<set>/<scene>" suffix (e.g. "lava25/Triple Trance"). A scene with
## no profile renders Classic even in Modern mode (see docs/MODERN_RENDERING.md).

const PROFILE_DIR := "res://modern/profiles"
const TEMPLATE_DIR := "res://modern/profiles/templates"
const MANIFEST_PATH := "res://modern_assets/manifest.json"

static var _profiles: Array = []
static var _manifest: Dictionary = {}
static var _templates: Dictionary = {}

static func all() -> Array:
	if not _profiles.is_empty(): return _profiles
	var directory := DirAccess.open(PROFILE_DIR)
	if directory == null: return _profiles
	for file in directory.get_files():
		var name := str(file).trim_suffix(".import").trim_suffix(".remap")
		if name.get_extension() != "json": continue
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(PROFILE_DIR.path_join(name)))
		if parsed is Dictionary:
			parsed = resolve(parsed)
			parsed["_file"] = name
			_profiles.append(parsed)
	return _profiles

## Profile templates (profiles/templates/<name>.json). A profile (or another
## template) with `"extends": "<name>"` (or a list, applied in order) starts
## from the template and overrides it: dictionaries merge key by key, arrays
## and scalars replace. Unknown template names are ignored.
static func template(name: String) -> Dictionary:
	if _templates.is_empty():
		_templates = {"_": {}}
		var directory := DirAccess.open(TEMPLATE_DIR)
		if directory != null:
			for file in directory.get_files():
				var clean := str(file).trim_suffix(".import").trim_suffix(".remap")
				if clean.get_extension() != "json": continue
				var parsed = JSON.parse_string(FileAccess.get_file_as_string(TEMPLATE_DIR.path_join(clean)))
				if parsed is Dictionary: _templates[clean.get_basename()] = parsed
	if _templates.has(name): return _templates[name]
	# A profile may also extend another full profile (e.g. LVT3 is Triple Trance).
	var path := PROFILE_DIR.path_join(name + ".json")
	if FileAccess.file_exists(path):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed is Dictionary: return parsed
	return {}

static func resolve(profile: Dictionary, depth := 0) -> Dictionary:
	var bases = profile.get("extends", [])
	if bases is String: bases = [bases]
	if bases.is_empty() or depth > 4: return profile
	var merged := {}
	for base in bases:
		merged = merge(merged, resolve(template(str(base)).duplicate(true), depth + 1))
	merged = merge(merged, profile)
	merged.erase("extends")
	return merged

static func merge(base: Dictionary, overlay: Dictionary) -> Dictionary:
	var result := base.duplicate(true)
	for key in overlay:
		if result.get(key) is Dictionary and overlay[key] is Dictionary: result[key] = merge(result[key], overlay[key])
		else: result[key] = overlay[key].duplicate(true) if overlay[key] is Array or overlay[key] is Dictionary else overlay[key]
	return result

## Profile for a scene folder (res://scenes/<set>/<scene>), or {}.
static func for_folder(folder: String) -> Dictionary:
	var clean := folder.trim_suffix("/")
	var key := clean.get_base_dir().get_file() + "/" + clean.get_file()
	for profile in all():
		for match_folder in profile.get("folders", []):
			if str(match_folder).to_lower() == key.to_lower(): return profile
	return {}

static func has_profile(folder: String) -> bool:
	return not for_folder(folder).is_empty()

## Derived maps (modern_assets/manifest.json) for an original texture path:
## {albedo, normal, roughness, height} as res:// paths; {} when not derived.
static func derived_maps(texture_path: String) -> Dictionary:
	if _manifest.is_empty():
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH)) if FileAccess.file_exists(MANIFEST_PATH) else null
		_manifest = parsed.get("textures", {}) if parsed is Dictionary else {"_": {}}
	var key := "native-player/" + texture_path.trim_prefix("res://")
	var record: Dictionary = _manifest.get(key, {})
	if record.has("duplicate_of"): record = _manifest.get(str(record.duplicate_of), {})
	if str(record.get("status", "")) != "ok" or not record.has("dir"): return {}
	var base := "res://" + str(record.dir).trim_prefix("native-player/")
	var maps := {}
	for kind in record.get("maps", {}):
		var path := base.path_join(str(record.maps[kind]))
		if ResourceLoader.exists(path) or FileAccess.file_exists(path): maps[kind] = path
	return maps
