extends RefCounted
## Scene list with display titles. The title is the scene's 3D-text message
## from the lava.ashex header (e.g. LVT2 "Dancing Well", LVT3 "Triple Trance"),
## which is how the original identified scenes; the folder name is the fallback
## (Oozic 3 .lvc-only packages such as AK1200, Keoki EFX, Mind's Eye).
const AppSettings = preload("res://app_settings.gd")
const RECONSTRUCTION_ROOT := "res://modern_assets/reconstructions"
const CATALOG_PATH := "res://scene-catalog.json"

## [{name, title, version, path}] in catalog order.
static func load_catalog(path: String = CATALOG_PATH) -> Array:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	var list: Array = []
	if not parsed is Array: return list
	for entry in parsed:
		var item: Dictionary = entry.duplicate()
		item.title = read_title(str(entry.path), str(entry.name))
		var use_recon := true
		var settings = AppSettings.new()
		settings.load_settings()
		use_recon = settings.use_reconstructions
		mark_reconstructed(item, use_recon)
		list.append(item)
	return list

## ASHEX header: 9 lines (version .. band count), 2 lines per band, then the
## message block whose first line is the on/off flag and second the text.
static func read_title(folder: String, fallback: String) -> String:
	var path := folder.path_join("lava.ashex")
	if not FileAccess.file_exists(path): return fallback
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return fallback
	var lines := PackedStringArray()
	while not file.eof_reached() and lines.size() < 64: lines.append(file.get_line())
	if lines.size() < 9 or not lines[8].strip_edges().is_valid_int(): return fallback
	var text_line := 9 + 2 * int(lines[8]) + 1
	if text_line >= lines.size(): return fallback
	var title := clean_title(lines[text_line])
	return title if not title.is_empty() else fallback

## "H   Y   D   R   O   I   D" -> "HYDROID"; "Gus Gus      Polyesterday" ->
## "Gus Gus · Polyesterday"; trims trailing spaces.
static func clean_title(raw: String) -> String:
	var text := raw.strip_edges()
	if text.is_empty(): return ""
	var groups := []
	var regex := RegEx.create_from_string("\\s{3,}")
	for group in regex.sub(text, "\u0001", true).split("\u0001"):
		var words := group.strip_edges().split(" ", false)
		groups.append(words)
	var single_letters := true
	for words in groups:
		for word in words:
			if word.length() > 1: single_letters = false
	if single_letters: return "".join(PackedStringArray(groups.map(func(w): return "".join(w))))
	return " · ".join(PackedStringArray(groups.map(func(w): return " ".join(w))))

## Display label: title, the folder when it differs, and the product.
static func label(entry: Dictionary) -> String:
	var title := display_title(entry)
	var extra := ""
	if str(entry.get("name", "")) != str(entry.get("title", entry.get("name", ""))): extra = " (" + str(entry.name) + ")"
	return title + extra + (" · Oozic 3" if entry.get("version", "") == "oozic30" else " · LAVA 2.5")


## A scene that has reconstructed textures is never shown as fully original.
## entry.reconstructed = reconstructions exist for the scene and are enabled.
static func mark_reconstructed(entry: Dictionary, enabled: bool) -> void:
	var folder := RECONSTRUCTION_ROOT.path_join(str(entry.get("name", "")))
	entry["reconstructed"] = enabled and DirAccess.dir_exists_absolute(folder)

static func display_title(entry: Dictionary) -> String:
	var title := str(entry.get("title", entry.get("name", "")))
	return title + " (partly reconstructed)" if entry.get("reconstructed", false) else title
