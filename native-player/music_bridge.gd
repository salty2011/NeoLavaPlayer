extends Node
## MusicBridge: Godot's side of native-player/bin/oozic-music-helper (contract:
## docs/MUSIC_HELPER.md; how it is used: docs/APPLE_MUSIC.md).
##
## Owned by AudioService (a child node, not an autoload): the helper processes
## are playback resources, so they start and die with the service that plays
## through them, and tests get a bridge with every AudioService they build.
## Windows never touch it; they read `PlayerBus.library` and send
## `library_refresh` / `open_library` commands.
##
## - Locates the helper: an override (property or $OOZIC_MUSIC_HELPER), the repo
##   file in the editor, or in an exported app a copy of res://bin/… installed to
##   user://bin/ (a binary cannot run from inside the .pck).
## - Wraps OS.execute_with_pipe processes (HelperProcess, non-blocking reads
##   polled per frame) and kills them all when it leaves the tree.
## - `control` commands run one at a time, in order, without blocking a frame.
## - The library is read on a Thread, cached in user://music-library.json and
##   published as PlayerBus.library (+ library_changed).

const PlayerBusScript = preload("res://player_bus.gd")
const HELPER_RES := "res://bin/oozic-music-helper"
const HELPER_USER := "user://bin/oozic-music-helper"
const CACHE_PATH := "user://music-library.json"
const CONTROL_TIMEOUT_MS := 20000
const PRIVACY := "System Settings › Privacy & Security › "

## Tests (or $OOZIC_MUSIC_HELPER) point this at a fake helper.
var helper_override := ""
var cache_path := CACHE_PATH
## False: no cache writes and no automatic library refresh (tests, --no-persist).
var persist := true
var bus
## Live HelperProcess objects; all are killed on exit.
var processes: Array = []
var _helper_path := ""
var _library_thread: Thread
var _refreshed := false
var _controls: Array = []
var _control = null
## Smoke/diagnostic CLI flags (exported builds): print and quit.
var _report_library := false

## One helper child process with non-blocking pipes, polled by its owner.
class HelperProcess extends RefCounted:
	var pid := -1
	var args := PackedStringArray()
	var stdio: FileAccess
	var stderr: FileAccess
	var running := false
	var exit_code := -1
	## Raw stdout (binary mode) or partial line buffers (text mode).
	var binary := false
	var _out := ""
	var _err := ""

	func start(path: String, arguments: PackedStringArray, is_binary := false) -> bool:
		args = arguments
		binary = is_binary
		var info := OS.execute_with_pipe(path, arguments, false)
		if info.is_empty(): return false
		pid = int(info.pid)
		stdio = info.stdio
		stderr = info.stderr
		running = true
		return true

	## Reads everything available. Returns {out: PackedByteArray (binary) or
	## Array[String] lines, err: Array[String] lines, exited: bool}.
	func poll() -> Dictionary:
		var result := {"out": PackedByteArray() if binary else [], "err": [], "exited": false}
		if pid < 0: return result
		var alive := running and OS.is_process_running(pid)
		var raw := _drain(stdio)
		var err_raw := _drain(stderr)
		if running and not alive:
			# Exited: whatever it wrote before exiting is still in the pipes.
			raw.append_array(_drain(stdio))
			err_raw.append_array(_drain(stderr))
			running = false
			exit_code = OS.get_process_exit_code(pid)
			result.exited = true
		if binary: result.out = raw
		else:
			_out += raw.get_string_from_utf8()
			result.out = _lines("_out", result.exited)
		_err += err_raw.get_string_from_utf8()
		result.err = _lines("_err", result.exited)
		return result

	func kill() -> void:
		if running and pid > 0 and OS.is_process_running(pid): OS.kill(pid)
		running = false
		stdio = null
		stderr = null

	static func _drain(file: FileAccess) -> PackedByteArray:
		var all := PackedByteArray()
		if file == null: return all
		while true:
			var chunk := file.get_buffer(1 << 16)
			if chunk.is_empty(): break
			all.append_array(chunk)
			if chunk.size() < (1 << 16): break
		return all

	func _lines(buffer: String, flush: bool) -> Array:
		var text: String = get(buffer)
		var parts := text.split("\n")
		var tail := parts[parts.size() - 1]
		parts.remove_at(parts.size() - 1)
		if flush and not tail.strip_edges().is_empty():
			parts.append(tail)
			tail = ""
		set(buffer, tail)
		var out := []
		for line in parts:
			if not line.strip_edges().is_empty(): out.append(line.strip_edges())
		return out

## A queued `control` command; `finished` carries the result dictionary.
class ControlJob extends RefCounted:
	signal finished(result: Dictionary)
	var args := PackedStringArray()
	var key := ""
	var proc = null
	var started_ms := 0
	var lines: Array = []
	var done := false
	var result := {}
	func finish(r: Dictionary) -> void:
		done = true
		result = r
		finished.emit(r)

func _init(persistent := true) -> void:
	persist = persistent
	name = "MusicBridge"

func _ready() -> void:
	bus = PlayerBusScript.instance()
	bus.command_requested.connect(_on_command)
	var user_args := OS.get_cmdline_user_args()
	if "--music-permissions-report" in user_args:
		print("MUSIC_PERMISSIONS ", JSON.stringify(permissions()))
		get_tree().quit()
		return
	if "--music-library-report" in user_args:
		_report_library = true
		refresh_library()
		return
	if not persist: return
	load_cache()
	# Refresh in the background when the user already uses the library (a
	# cache exists or Media access is granted); otherwise wait for the first
	# open_library / library_refresh so the Media prompt appears in context.
	if bus.library_state == "cached" or str(permissions().get("media_library", "")) == "granted":
		refresh_library()

func _on_command(command: StringName, _args: Dictionary) -> void:
	match command:
		&"library_refresh": refresh_library()
		&"open_library":
			if not _refreshed: refresh_library()

# --- Helper location ------------------------------------------------------

## Absolute path of a runnable helper, or "" (not macOS, missing).
func helper_path() -> String:
	if not helper_override.is_empty(): return helper_override
	var env := OS.get_environment("OOZIC_MUSIC_HELPER")
	if not env.is_empty(): return env
	if not _helper_path.is_empty(): return _helper_path
	if OS.get_name() != "macOS": return ""
	if OS.has_feature("editor"):
		var repo := ProjectSettings.globalize_path(HELPER_RES)
		_helper_path = repo if FileAccess.file_exists(repo) else ""
	else:
		_helper_path = install_helper(HELPER_RES, HELPER_USER)
	return _helper_path

## Copies `source` (inside the .pck) to `target` when missing or different
## (size, then MD5), marks it executable and returns its absolute path.
static func install_helper(source: String, target: String) -> String:
	if not FileAccess.file_exists(source): return ""
	var absolute := ProjectSettings.globalize_path(target)
	var same := FileAccess.file_exists(absolute)
	if same:
		var a := FileAccess.open(source, FileAccess.READ)
		var b := FileAccess.open(absolute, FileAccess.READ)
		same = a != null and b != null and a.get_length() == b.get_length()
		a = null
		b = null
		same = same and FileAccess.get_md5(source) == FileAccess.get_md5(absolute)
	if not same:
		DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
		var data := FileAccess.get_file_as_bytes(source)
		var temp := absolute + ".tmp"
		var file := FileAccess.open(temp, FileAccess.WRITE)
		if file == null or data.is_empty(): return ""
		file.store_buffer(data)
		file = null
		if DirAccess.rename_absolute(temp, absolute) != OK: return ""
	if OS.execute("/bin/chmod", PackedStringArray(["755", absolute])) != 0: return ""
	return absolute

# --- Processes ------------------------------------------------------------

## Starts `helper <args>`; null when the helper is unavailable.
func spawn(args: PackedStringArray, binary := false) -> HelperProcess:
	var path := helper_path()
	if path.is_empty(): return null
	var proc := HelperProcess.new()
	if not proc.start(path, args, binary): return null
	processes.append(proc)
	return proc

func release(proc) -> void:
	if proc == null: return
	proc.kill()
	processes.erase(proc)

func kill_all() -> void:
	for proc in processes: proc.kill()
	processes.clear()
	if _control != null:
		_control.finish({"code": -1, "ok": false, "error": "cancelled"})
		_control = null
	for job in _controls: job.finish({"code": -1, "ok": false, "error": "cancelled"})
	_controls.clear()

## Synchronous `permissions` (never prompts; fast). {} when unavailable.
func permissions() -> Dictionary:
	var path := helper_path()
	if path.is_empty(): return {}
	var out := []
	if OS.execute(path, PackedStringArray(["permissions"]), out, false) != 0 or out.is_empty(): return {}
	var parsed = JSON.parse_string(str(out[0]).strip_edges())
	return parsed if parsed is Dictionary else {}

# --- control --------------------------------------------------------------

## Blocking `control <args>` (quit path only): exit code, -1 without a helper.
func control_sync(args: PackedStringArray) -> int:
	var path := helper_path()
	if path.is_empty(): return -1
	return OS.execute(path, PackedStringArray(["control"]) + args, [], false)

## Queues `control <args>`; await the result: {code, ok, command, error?, message?}.
## A non-empty `key` replaces a not-yet-started job with the same key (volume
## drags, repeated seeks); the replaced job finishes with {ok: true, coalesced: true}.
func control(args: PackedStringArray, key := "") -> Dictionary:
	var job := queue_control(args, key)
	if job.done: return job.result
	return await job.finished

func queue_control(args: PackedStringArray, key := "") -> ControlJob:
	var job := ControlJob.new()
	job.args = args
	job.key = key
	if not key.is_empty():
		for old in _controls.duplicate():
			if old.key == key:
				_controls.erase(old)
				old.finish({"code": 0, "ok": true, "coalesced": true, "command": key})
	_controls.append(job)
	_pump_controls()
	return job

## True when no control command is running or queued.
func controls_idle() -> bool:
	return _control == null and _controls.is_empty()

func _pump_controls() -> void:
	if _control != null:
		var polled: Dictionary = _control.proc.poll()
		_control.lines.append_array(polled.out)
		if polled.exited: _finish_control(_control.proc.exit_code)
		elif Time.get_ticks_msec() - _control.started_ms > CONTROL_TIMEOUT_MS:
			release(_control.proc)
			_finish_control(-2)
		else: return
	while _control == null and not _controls.is_empty():
		var job = _controls.pop_front()
		job.proc = spawn(PackedStringArray(["control"]) + job.args)
		if job.proc == null:
			job.finish({"code": -1, "ok": false, "error": "no_helper", "command": job.args[0] if not job.args.is_empty() else ""})
			continue
		job.started_ms = Time.get_ticks_msec()
		_control = job

func _finish_control(code: int) -> void:
	var job = _control
	_control = null
	processes.erase(job.proc)
	var result := {}
	for line in job.lines:
		var parsed = JSON.parse_string(line)
		if parsed is Dictionary: result = parsed
	result.code = code
	result.ok = code == 0 and bool(result.get("ok", true))
	if code == -2: result.error = "timeout"
	if not result.has("command"): result.command = job.args[0] if not job.args.is_empty() else ""
	job.finish(result)

# --- Library --------------------------------------------------------------

## Starts a background `library` read. False when one is running or no helper.
func refresh_library() -> bool:
	if _library_thread != null: return false
	var path := helper_path()
	if path.is_empty():
		bus.publish_status("Apple Music needs macOS and the oozic-music-helper tool, which wasn't found.")
		if _report_library: _print_library_report(-1)
		return false
	_refreshed = true
	bus.publish_library(bus.library, "refreshing")
	_library_thread = Thread.new()
	_library_thread.start(_library_worker.bind(path), Thread.PRIORITY_LOW)
	return true

func is_refreshing() -> bool: return _library_thread != null

## Thread body: run the helper, parse and index. Touches no nodes.
static func _library_worker(path: String) -> Dictionary:
	var out := []
	var code := OS.execute(path, PackedStringArray(["library"]), out, false)
	var text: String = str(out[0]) if not out.is_empty() else ""
	var data := build_library(text) if code == 0 else {}
	return {"code": code, "text": text, "library": data}

func _poll_library() -> void:
	if _library_thread == null or _library_thread.is_alive(): return
	var result: Dictionary = _library_thread.wait_to_finish()
	_library_thread = null
	var code: int = result.code
	var data: Dictionary = result.library
	if code == 0 and not data.is_empty():
		data.updated = int(Time.get_unix_time_from_system())
		if persist and not cache_path.is_empty():
			var file := FileAccess.open(cache_path, FileAccess.WRITE)
			if file != null: file.store_string(str(result.text).strip_edges())
		bus.publish_library(data, "ready")
		bus.publish_status("Music library: %d tracks, %d playlists." % [data.count, data.playlists.size()])
	else:
		bus.publish_library(bus.library, "error")
		bus.publish_status(status_for("library", code if code != 0 else 2))
	if _report_library: _print_library_report(code)

func _print_library_report(code: int) -> void:
	var lib: Dictionary = bus.library
	var playable := 0
	for id in lib.get("tracks", {}):
		if bool(lib.tracks[id].get("playable_file", false)): playable += 1
	print("MUSIC_LIBRARY ", JSON.stringify({"exit": code, "state": bus.library_state, "tracks": lib.get("count", 0),
		"playlists": lib.get("playlists", []).size(), "artists": lib.get("artists", {}).size(), "albums": lib.get("albums", {}).size(),
		"playable_files": playable, "streaming": int(lib.get("count", 0)) - playable, "status": bus.status}))
	get_tree().quit()

## Loads user://music-library.json (instant) and publishes it as "cached".
func load_cache() -> bool:
	if cache_path.is_empty() or not FileAccess.file_exists(cache_path): return false
	var data := build_library(FileAccess.get_file_as_string(cache_path))
	if data.is_empty(): return false
	data.updated = FileAccess.get_modified_time(cache_path)
	bus.publish_library(data, "cached")
	return true

## Parses `library` JSON into the PlayerBus.library shape; {} on bad input.
static func build_library(text: String) -> Dictionary:
	var json := JSON.new()
	var parsed = json.data if json.parse(text) == OK else null
	if not parsed is Dictionary or not parsed.get("tracks") is Array: return {}
	var tracks := {}
	var order := []
	var artists := {}
	var albums := {}
	var by_location := {}
	for raw in parsed.tracks:
		if not raw is Dictionary or str(raw.get("id", "")).is_empty(): continue
		var track: Dictionary = raw
		var id := str(track.id)
		var location = track.get("location")
		track.entry = str(location) if bool(track.get("playable_file", false)) and location is String else PlayerBusScript.APPLE_MUSIC_PREFIX + id
		if location is String: by_location[str(location)] = id
		tracks[id] = track
		order.append(id)
		var artist := str(track.get("artist", ""))
		if artist.is_empty(): artist = "Unknown Artist"
		if not artists.has(artist): artists[artist] = []
		artists[artist].append(id)
		var album := str(track.get("album", ""))
		if not album.is_empty():
			var album_artist := str(track.get("album_artist", ""))
			if album_artist.is_empty(): album_artist = artist
			var key := album_artist + " — " + album
			if not albums.has(key): albums[key] = {"title": album, "artist": album_artist, "track_ids": []}
			albums[key].track_ids.append(id)
	for key in albums:
		albums[key].track_ids.sort_custom(func(a, b):
			var ta: Dictionary = tracks[a]
			var tb: Dictionary = tracks[b]
			var da := int(ta.get("disc_number", 0)) * 1000 + int(ta.get("track_number", 0))
			var db := int(tb.get("disc_number", 0)) * 1000 + int(tb.get("track_number", 0))
			return da < db)
	var playlists := []
	if parsed.get("playlists") is Array:
		for raw in parsed.playlists:
			if not raw is Dictionary: continue
			var ids := []
			for tid in raw.get("track_ids", []):
				if tracks.has(str(tid)): ids.append(str(tid))
			playlists.append({"id": str(raw.get("id", "")), "name": str(raw.get("name", "")), "track_ids": ids})
	return {"tracks": tracks, "order": order, "playlists": playlists, "artists": artists, "albums": albums,
		"by_location": by_location, "count": tracks.size(), "updated": 0}

## The playlist entry for a library track id ("" when unknown).
func entry_for_id(id: String) -> String:
	var track: Dictionary = bus.library.get("tracks", {}).get(id, {})
	return str(track.get("entry", "")) if not track.is_empty() else ""

# --- Status texts -----------------------------------------------------------

## User-facing text for a helper exit code. `sub`: library | tap | watch | control.
static func status_for(sub: String, code: int, message := "") -> String:
	match code:
		-1: return "Apple Music needs the oozic-music-helper tool, which wasn't found."
		-2: return "The Music app didn't respond in time."
		1: return "Apple Music helper: unsupported request%s." % ((": " + message) if not message.is_empty() else "")
		2: return "Couldn't read your Music library. Allow Oozic under " + PRIVACY + "Media & Apple Music."
		3:
			if sub == "tap": return "To visualise Apple Music, allow Oozic under " + PRIVACY + "Screen & System Audio Recording. Using the synthetic beat meanwhile."
			return "To control Music, allow Oozic under " + PRIVACY + "Automation › Music."
		4: return "The Music app isn't running."
		5: return "That track isn't in your Music library any more."
		6: return "Music reported an error%s." % ((": " + message) if not message.is_empty() else "")
	return "Apple Music helper failed (%s exit %d)." % [sub, code]

# --- Lifetime ---------------------------------------------------------------

func _process(_delta: float) -> void:
	_poll_library()
	_pump_controls()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		for proc in processes: proc.kill()
		processes.clear()

func _exit_tree() -> void:
	kill_all()
	if _library_thread != null:
		_library_thread.wait_to_finish()
		_library_thread = null
