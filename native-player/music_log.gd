extends RefCounted
## MusicLog: the Apple Music diagnostics log (docs/APPLE_MUSIC.md,
## "Troubleshooting"). One line per event:
##   2026-10-05 14:03:07.412 control {"args":["play-id","…"],"code":0,…}
## Written by the real app only, to ~/Library/Logs/NeoLavaPlayer/music.log
## (outside user://, which `--script` test runs share with the app because
## they use the same project name). Tests, tools and --no-persist runs get a
## disabled log (path ""). Rotation: at MAX_BYTES the file becomes music.1.log
## (replacing the previous one), so at most 2 x 1 MB is kept.

const MAX_BYTES := 1 << 20
const LOG_DIR := "Library/Logs/NeoLavaPlayer"
const LOG_FILE := "music.log"

## Absolute log path; "" disables logging.
var path := ""
var max_bytes := MAX_BYTES

func _init(file_path := "") -> void:
	path = file_path

## ~/Library/Logs/NeoLavaPlayer/music.log ("" without $HOME).
static func default_path() -> String:
	var home := OS.get_environment("HOME")
	return "" if home.is_empty() else home.path_join(LOG_DIR).path_join(LOG_FILE)

## True for a real app run: a persistent service and not a `--script` run
## (every test and tool is one). `args` is OS.get_cmdline_args().
static func app_mode(persistent: bool, args: PackedStringArray) -> bool:
	if not persistent: return false
	for arg in args:
		if arg == "--script" or arg == "-s": return false
	return true

func enabled() -> bool:
	return not path.is_empty()

## Previous log after rotation.
func rotated_path() -> String:
	return path.get_basename() + ".1." + path.get_extension()

static func timestamp() -> String:
	var now := Time.get_unix_time_from_system()
	var ms := int(fmod(now, 1.0) * 1000.0)
	return Time.get_datetime_string_from_unix_time(int(now) + Time.get_time_zone_from_system().bias * 60, true) + ".%03d" % ms

## Appends one event line (no-op when disabled).
func write(event: String, data := {}) -> void:
	if path.is_empty(): return
	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir) and DirAccess.make_dir_recursive_absolute(dir) != OK: return
	var file: FileAccess = null
	if FileAccess.file_exists(path):
		file = FileAccess.open(path, FileAccess.READ_WRITE)
		if file != null and file.get_length() >= max_bytes:
			file = null
			if FileAccess.file_exists(rotated_path()): DirAccess.remove_absolute(rotated_path())
			DirAccess.rename_absolute(path, rotated_path())
			file = FileAccess.open(path, FileAccess.WRITE)
		elif file != null: file.seek_end()
	else: file = FileAccess.open(path, FileAccess.WRITE)
	if file == null: return
	file.store_line("%s %s %s" % [timestamp(), event, JSON.stringify(data)])

## Makes sure the file exists (so Finder can reveal it); false when disabled.
func touch() -> bool:
	if path.is_empty(): return false
	if not FileAccess.file_exists(path): write("log_created", {})
	return FileAccess.file_exists(path)
