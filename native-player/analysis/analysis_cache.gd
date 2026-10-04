extends RefCounted
## Disk cache for TrackAnalysis: <dir>/<md5(path|size|mtime|version)>.anl
## Stored with FileAccess.store_var (binary Variant, objects disallowed), so a
## cache file can never instantiate scripts when read back. Writes go to a temp
## file then rename, so concurrent workers never see partial files.

const TrackAnalysis := preload("res://analysis/track_analysis.gd")

static var dir: String = "user://analysis-cache"

static func key_for(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	var size: int = f.get_length() if f != null else 0
	var mtime: int = FileAccess.get_modified_time(path)
	return ("%s|%d|%d|v%d" % [ProjectSettings.globalize_path(path), size, mtime, TrackAnalysis.VERSION]).md5_text()

static func path_for(path: String) -> String:
	var key := key_for(path)
	return "" if key.is_empty() else dir.path_join(key + ".anl")

static func load_for(path: String):
	var p := path_for(path)
	if p.is_empty() or not FileAccess.file_exists(p):
		return null
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return null
	var data = f.get_var(false)
	if not (data is Dictionary):
		return null
	return TrackAnalysis.from_dict(data)

static func save_for(path: String, analysis) -> bool:
	var p := path_for(path)
	if p.is_empty() or analysis == null:
		return false
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var tmp := p + ".%d.tmp" % Time.get_ticks_usec()
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_var(analysis.to_dict(), false)
	f.close()
	return DirAccess.rename_absolute(ProjectSettings.globalize_path(tmp), ProjectSettings.globalize_path(p)) == OK
