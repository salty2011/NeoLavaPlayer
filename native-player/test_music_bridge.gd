extends SceneTree
## Apple Music integration against a FAKE helper (tools/fake_music_helper.sh,
## selected with $OOZIC_MUSIC_HELPER): library parse + cache, track_meta,
## library commands, playlist/M3U URI round trips, streaming transport (watch
## JSON -> bus state, commands -> control args), end-of-track advance, tap PCM
## -> analysis input, exit-code statuses and the synthetic fallback, process
## cleanup, and the runtime helper install. Never touches the Music app.
## Run: Godot --headless --audio-driver Dummy --path native-player --script res://test_music_bridge.gd
const AudioService = preload("res://audio_service.gd")
const MusicBridge = preload("res://music_bridge.gd")
const AppleMusicStream = preload("res://apple_music_stream.gd")
const Queue = preload("res://playback_queue.gd")
const ReactivityServiceScript = preload("res://analysis/reactivity_service.gd")
const Fmt = preload("res://player/player_format.gd")
const MusicLog = preload("res://music_log.gd")

const A1 := "0000000000000001"
const A2 := "0000000000000002"
const F3 := "0000000000000003"
const P4 := "0000000000000004"
const OTHER := "00000000000000FF"
const MP3 := "res://test-media/DemoBeat.mp3"

var audio
var bus
var bridge
var music
var log_path := ""

func _initialize(): call_deferred("run")

func log_lines() -> PackedStringArray:
	if not FileAccess.file_exists(log_path): return PackedStringArray()
	var out := PackedStringArray()
	for line in FileAccess.get_file_as_string(log_path).split("\n"):
		if not line.strip_edges().is_empty(): out.append(line.strip_edges())
	return out

func clear_log() -> void:
	if FileAccess.file_exists(log_path): DirAccess.remove_absolute(log_path)

## Waits (bounded) until the helper log has `line`.
func wait_log(line: String, frames := 300) -> bool:
	for i in frames:
		if log_lines().has(line): return true
		await process_frame
	print("missing log line: ", line, " in ", log_lines())
	return false

## Process liveness without OS.is_process_running (which errors once Godot
## has reaped a killed child).
static func alive(pid: int) -> bool:
	return OS.execute("/bin/kill", PackedStringArray(["-0", str(pid)])) == 0

func wait_until(condition: Callable, frames := 300) -> bool:
	for i in frames:
		if condition.call(): return true
		await process_frame
	return false

## f32le stereo bytes of a sine (amplitude 0.5) at `rate`.
static func sine_bytes(rate: int, seconds: float, freq := 440.0) -> PackedByteArray:
	var floats := PackedFloat32Array()
	var n := int(rate * seconds)
	floats.resize(n * 2)
	for i in n:
		var v := 0.5 * sin(TAU * freq * float(i) / float(rate))
		floats[2 * i] = v
		floats[2 * i + 1] = v
	return floats.to_byte_array()

func watch(id: String, state: String, position: float, duration: float, running := true, volume := 100) -> void:
	music.fake_now += 1000
	music.apply_watch({"running": running, "state": state, "id": id, "title": "", "artist": "", "album": "", "position": position, "duration": duration, "volume": volume})

## Helper log lines starting with `prefix`.
func count_log(prefix: String) -> int:
	var n := 0
	for line in log_lines():
		if line.begins_with(prefix): n += 1
	return n

## (mtime, size) of a file, (0, -1) when missing.
static func file_state(path: String) -> Array:
	if path.is_empty() or not FileAccess.file_exists(path): return [0, -1]
	var f := FileAccess.open(path, FileAccess.READ)
	return [FileAccess.get_modified_time(path), f.get_length() if f != null else -1]

static func write_bytes(path: String, bytes: PackedByteArray) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(bytes)

func run():
	var fake := ProjectSettings.globalize_path("res://tools/fake_music_helper.sh")
	OS.execute("/bin/chmod", PackedStringArray(["+x", fake]))
	log_path = OS.get_temp_dir().path_join("oozic-fake-helper-%d.log" % OS.get_process_id())
	OS.set_environment("OOZIC_MUSIC_HELPER", fake)
	OS.set_environment("FAKE_HELPER_LOG", log_path)
	clear_log()
	# The user's real diagnostics log must not be touched by test runs.
	var real_log := MusicLog.default_path()
	var real_log_before := [file_state(real_log), file_state(real_log.get_basename() + ".1.log")]
	audio = AudioService.new(false)
	root.add_child(audio)
	await process_frame
	bus = audio.bus
	bridge = audio.music_bridge
	music = audio.music
	assert(bridge.helper_path() == fake)
	var settings_path := OS.get_temp_dir().path_join("oozic-test-music-settings.cfg")
	audio.settings_path = settings_path

	# --- Diagnostics log: app runs only ----------------------------------------------
	assert(not bridge.diagnostics.enabled() and not music.volume_link)
	assert(MusicLog.app_mode(true, PackedStringArray(["--path", "native-player"])))
	assert(not MusicLog.app_mode(true, PackedStringArray(["--headless", "--script", "res://test_music_bridge.gd"])))
	assert(not MusicLog.app_mode(false, PackedStringArray()))
	assert(not MusicLog.app_mode(true, OS.get_cmdline_args()))
	assert(real_log.ends_with("Library/Logs/NeoLavaPlayer/music.log"))
	bus.command(&"reveal_diagnostics")
	assert(bus.status.contains("off in test"))
	# An app-mode log (here at a scratch path): event lines, rotation at the cap.
	var diag_path := OS.get_temp_dir().path_join("oozic-test-diag-%d/music.log" % OS.get_process_id())
	var diag_log = MusicLog.new(diag_path)
	diag_log.max_bytes = 600
	diag_log.write("control", {"args": ["play-id", A1], "code": 0})
	var first_line := FileAccess.get_file_as_string(diag_path).strip_edges()
	assert(first_line.contains(" control {") and JSON.parse_string(first_line.substr(first_line.find("{"))).args == ["play-id", A1])
	for i in 20: diag_log.write("level", {"peak_db": -20.0 - i})
	assert(FileAccess.file_exists(diag_log.rotated_path()) and FileAccess.get_file_as_string(diag_path).length() < 1200)
	DirAccess.remove_absolute(diag_log.rotated_path())
	DirAccess.remove_absolute(diag_path)
	# The test's bridge logs to the scratch path from here on (app-mode behaviour).
	bridge.diagnostics = MusicLog.new(diag_path)

	# --- Library: parse, indexes, cache -------------------------------------
	var changes := [0]
	bus.library_changed.connect(func(): changes[0] += 1)
	bridge.persist = true
	bridge.cache_path = "user://test-music-library.json"
	assert(bridge.refresh_library() and bridge.is_refreshing() and bus.library_state == "refreshing")
	assert(not bridge.refresh_library())
	assert(await wait_until(func(): return not bridge.is_refreshing()))
	var lib: Dictionary = bus.library
	assert(bus.library_state == "ready" and lib.count == 4 and changes[0] == 2)
	assert(lib.order == [A1, A2, F3, P4])
	assert(lib.tracks[A1].entry == "applemusic:" + A1 and lib.tracks[F3].entry == "/Music/Local Song.mp3" and lib.tracks[P4].entry == "applemusic:" + P4)
	assert(lib.playlists.size() == 1 and lib.playlists[0].name == "Mix" and lib.playlists[0].track_ids == [A2, F3])
	assert(lib.artists["Artist One"] == [A1, A2] and lib.artists.has("Local Artist"))
	assert(lib.albums["Artist One — First Album"].track_ids == [A2, A1] and lib.albums.has("Various — Shop") and lib.albums.size() == 2)
	assert(lib.by_location["/Music/Local Song.mp3"] == F3 and lib.updated > 0)
	assert(bus.status.contains("4 tracks") and FileAccess.file_exists("user://test-music-library.json"))
	bus.publish_library({}, "empty")
	assert(bridge.load_cache() and bus.library_state == "cached" and bus.library.count == 4 and bus.library.playlists[0].track_ids == [A2, F3])
	assert(MusicBridge.build_library("not json").is_empty() and MusicBridge.build_library("{\"tracks\":3}").is_empty())
	# Exit 2 (Media & Apple Music denied): error state, cached data kept, clear status.
	OS.set_environment("FAKE_LIBRARY_EXIT", "2")
	assert(bridge.refresh_library())
	assert(await wait_until(func(): return not bridge.is_refreshing()))
	OS.unset_environment("FAKE_LIBRARY_EXIT")
	assert(bus.library_state == "error" and bus.library.count == 4 and bus.status.contains("Media & Apple Music"))
	bridge.persist = false
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test-music-library.json"))
	# permissions() parses the helper's JSON.
	var perms: Dictionary = bridge.permissions()
	assert(perms.media_library == "granted" and perms.audio_capture == "denied" and perms.music_running)

	# --- track_meta ------------------------------------------------------------
	var meta: Dictionary = bus.track_meta("applemusic:" + A1)
	assert(meta == {"title": "Alpha", "artist": "Artist One", "album": "First Album", "duration": 200.0, "source": "applemusic"})
	meta = bus.track_meta("/Music/Local Song.mp3")
	assert(meta.title == "Local Song" and meta.artist == "Local Artist" and is_equal_approx(meta.duration, 95.0) and meta.source == "file")
	assert(bus.track_meta("/x/Unknown Thing.flac") == {"title": "Unknown Thing", "artist": "", "album": "", "duration": 0.0, "source": "file"})
	assert(bus.track_meta("applemusic:DEADBEEF00000000").title == "Apple Music track" and bus.track_meta("applemusic:DEADBEEF00000000").source == "applemusic")
	assert(audio.display_title("applemusic:" + A1) == "Alpha — Artist One" and audio.display_title(MP3) == "DemoBeat")
	# The player UI's single formatting point uses the same metadata.
	assert(Fmt.display_title("applemusic:" + A1) == "Artist One - Alpha" and Fmt.display_title("/Music/Local Song.mp3") == "Local Artist - Local Song")
	assert(Fmt.display_title("applemusic:DEADBEEF00000000") == "Apple Music track" and Fmt.display_title("applemusic:1|Label") == "Label")
	assert(Fmt.display_title("/x/01 - Unknown Thing.flac") == "Unknown Thing" and Fmt.format_tag("/x/a.m4a") == "M4A")

	# --- Library commands, playlist URIs, persistence, M3U -----------------------
	bus.command(&"add_library_tracks", {"ids": [A1, F3, "NOPE"], "play": false})
	assert(audio.playlist == PackedStringArray(["applemusic:" + A1, "/Music/Local Song.mp3"]))
	bus.command(&"add_library_playlist", {"id": "00000000000000AA", "play": false})
	assert(audio.playlist.size() == 4 and audio.playlist[2] == "applemusic:" + A2 and bus.playlist.size() == 4)
	assert(audio.add_tracks(PackedStringArray(["/x/Old.m4p"]), false) == 0 and bus.status.contains(".m4p"))
	assert(audio.add_tracks(PackedStringArray(["applemusic:" + P4, "/x/a.m4a", "/x/b.aiff", "/x/c.caf", "/x/d.wav"]), false) == 5)
	var saved := OS.get_temp_dir().path_join("oozic-test-music-playlist.json")
	audio.persist = true
	audio.playlist_path = saved
	audio.track_index = 0
	assert(audio.save_playlist_file())
	var before: PackedStringArray = audio.playlist.duplicate()
	audio.playlist = PackedStringArray()
	assert(audio.load_playlist_file() and audio.playlist == before and bus.track_title == "Alpha — Artist One")
	var m3u := OS.get_temp_dir().path_join("oozic-test-music.m3u")
	assert(audio.export_m3u(m3u) and FileAccess.get_file_as_string(m3u).contains("\napplemusic:" + A1 + "\n"))
	audio.playlist = PackedStringArray()
	assert(audio.import_m3u(m3u, false) == before.size() and audio.playlist == before)
	audio.persist = false
	DirAccess.remove_absolute(saved)
	DirAccess.remove_absolute(m3u)

	# --- Streaming: play-id, watch, tap, PCM -> analysis ---------------------------
	var rate := int(audio.inputs.sample_rate)
	var pcm_path := OS.get_temp_dir().path_join("oozic-test-tap.f32")
	var pcm_file := FileAccess.open(pcm_path, FileAccess.WRITE)
	pcm_file.store_buffer(sine_bytes(rate, 0.5))
	pcm_file = null
	OS.set_environment("FAKE_TAP_PCM", pcm_path)
	audio.playlist = PackedStringArray(["applemusic:" + A1, "applemusic:" + A2, MP3])
	audio.queue = Queue.new()
	audio.queue.configure(3)
	audio.queue.repeat_mode = Queue.Repeat.ALL
	audio.player.stream = null
	clear_log()
	music.fake_now = Time.get_ticks_msec() + 100000
	assert(await audio.play_track(0))
	# Transport truth: play-id succeeded, but Music hasn't confirmed yet.
	assert(audio.streaming() and music.id == A1 and music.state == "starting" and bus.transport == "loading" and bus.track_title == "Alpha — Artist One")
	assert(not audio.is_playing() and is_equal_approx(music.duration, 200.0) and audio.player.stream == null)
	watch(OTHER, "playing", 1.0, 150.0)  # a stale line from before play-id
	assert(music.state == "starting" and bus.transport == "loading")
	watch(A1, "paused", 0.0, 200.0)  # Music has our track but isn't playing yet
	assert(music.state == "starting")
	watch(A1, "playing", 0.0, 200.0)
	assert(music.state == "playing" and bus.transport == "playing" and audio.is_playing())
	assert(log_lines()[0] == "control play-id " + A1)
	assert(await wait_log("watch --interval 0.25"))
	assert(await wait_log("tap --app com.apple.Music --rate %d --backend tap" % rate))
	# Volume link off (default): Oozic never sends `control volume`.
	assert(await wait_until(bridge.controls_idle))
	assert(count_log("control volume") == 0)
	# The tap's f32le stereo reaches the classic inputs and the live analyser
	# at the analysers' own rate; no pre-analysis job for a stream.
	var reactivity = ReactivityServiceScript.instance()
	assert(await wait_until(func(): return audio.captured_frames >= int(rate * 0.5)))
	assert(audio.captured_frames == int(rate * 0.5) and audio.pcm_rate() == float(rate))
	var signals: Dictionary = audio.sample(0.0)
	assert(signals.global_s > 0.0)
	assert(reactivity.current_path == "applemusic:" + A1 and reactivity.source_kind == "live" and reactivity._job_path != "applemusic:" + A1)
	# (The next playlist entry, an MP3, may be pre-analysing in the background.)
	assert(reactivity.live != null and is_equal_approx(reactivity.live.input_rate, float(rate)) and absf(reactivity.live.stream_time - 0.5) < 0.01)
	assert(not reactivity.has_analysis("applemusic:" + A1) and audio.upcoming_paths(2) == PackedStringArray([MP3]))
	# pcm_to_frames and partial-frame carry.
	var two := PackedFloat32Array([0.5, -0.25, 0.125, 1.0]).to_byte_array()
	assert(AppleMusicStream.pcm_to_frames(two) == PackedVector2Array([Vector2(0.5, -0.25), Vector2(0.125, 1.0)]))
	music.take_frames()
	music.push_pcm_bytes(two.slice(0, 5))
	assert(music.take_frames().is_empty())
	music.push_pcm_bytes(two.slice(5))
	assert(music.take_frames() == PackedVector2Array([Vector2(0.5, -0.25), Vector2(0.125, 1.0)]))

	# --- watch JSON -> bus state -------------------------------------------------------
	music.fake_now += 2000
	watch(A1, "playing", 12.5, 201.0)
	audio._process(0.016)
	assert(is_equal_approx(music.position, 12.5) and is_equal_approx(bus.position, 12.5) and is_equal_approx(bus.duration, 201.0))
	music.fake_now += 500
	assert(is_equal_approx(audio.playback_time(), 13.0))
	# Paused from outside Oozic (Music, a headset button, another app): reflected, with a status.
	watch(A1, "paused", 13.0, 201.0)
	assert(bus.transport == "paused" and not audio.is_playing() and bus.status.contains("not from Oozic"))
	# ...and resumed from outside.
	watch(A1, "playing", 13.0, 201.0)
	assert(bus.transport == "playing")
	watch(A1, "paused", 13.5, 201.0)
	assert(bus.transport == "paused")

	# --- bus commands -> control args ----------------------------------------------------
	clear_log()
	bus.command(&"play_pause")
	assert(bus.transport == "playing")
	assert(await wait_log("control play"))
	bus.command(&"pause")
	assert(bus.transport == "paused")
	assert(await wait_log("control pause"))
	bus.command(&"seek", {"seconds": 30.0})
	assert(is_equal_approx(bus.position, 30.0))
	assert(await wait_log("control seek 30.000"))
	bus.command(&"seek_fraction", {"fraction": 0.5})
	assert(await wait_log("control seek 100.500"))
	# Volume policy. Link off (default): Oozic's volume/mute never reach Music;
	# one status explains it.
	bus.command(&"set_volume", {"value": 0.8})
	bus.command(&"toggle_mute")
	bus.command(&"toggle_mute")
	assert(bus.status.contains("doesn't change the Music app"))
	assert(await wait_until(bridge.controls_idle))
	assert(count_log("control volume") == 0)
	# Link on: explicit changes are sent; mute sends 0, unmute restores.
	bus.command(&"set_music_volume_link", {"on": true})
	assert(music.volume_link and await wait_log("control volume 80"))
	bus.command(&"set_volume", {"value": 0.5})
	assert(await wait_log("control volume 50"))
	bus.command(&"toggle_mute")
	assert(await wait_log("control volume 0") and music.music_muted_by_oozic())
	clear_log()
	bus.command(&"toggle_mute")
	assert(await wait_log("control volume 50") and not music.music_muted_by_oozic())
	# Unlinking while muted puts Music's volume back (never left at 0).
	bus.command(&"toggle_mute")
	assert(await wait_log("control volume 0"))
	clear_log()
	bus.command(&"set_music_volume_link", {"on": false})
	assert(await wait_log("control volume 50") and not music.music_muted_by_oozic())
	bus.command(&"toggle_mute")
	assert(not audio.muted)
	bus.command(&"stop")
	assert(bus.transport == "stopped" and music.state == "stopped")
	assert(await wait_log("control stop"))
	# Play after Stop restarts our track (Music forgot it): loading until confirmed.
	clear_log()
	bus.command(&"play_pause")
	assert(bus.transport == "loading" and music.state == "starting")
	assert(await wait_log("control play-id " + A1))
	watch(A1, "playing", 0.0, 200.0)
	assert(bus.transport == "playing")
	# Volume drags coalesce: a queued volume is replaced by the newest one.
	assert(await wait_until(bridge.controls_idle))
	clear_log()
	var j1 = bridge.queue_control(PackedStringArray(["volume", "10"]), "volume")
	var j2 = bridge.queue_control(PackedStringArray(["volume", "20"]), "volume")
	var j3 = bridge.queue_control(PackedStringArray(["volume", "30"]), "volume")
	assert(j2.done and j2.result.coalesced and not j3.done)
	var r3: Dictionary = await j3.finished
	assert(r3.ok and r3.code == 0 and j1.done and log_lines() == PackedStringArray(["control volume 10", "control volume 30"]))

	# --- End of track -> our playlist advances ---------------------------------------------
	watch(A1, "playing", 5.0, 200.0)
	watch(A1, "playing", 198.5, 200.0)
	clear_log()
	watch(OTHER, "playing", 0.2, 150.0)  # Music's own auto-advance
	assert(await wait_until(func(): return audio.track_index == 1 and not audio.loading_audio))
	assert(music.id == A2 and log_lines()[0] == "control play-id " + A2 and bus.track_title == "Beta — Artist One")
	# Repeat One + "stopped" right after the end: the same entry again.
	audio.queue.repeat_mode = Queue.Repeat.ONE
	watch(A2, "playing", 178.0, 180.0)
	clear_log()
	watch(A2, "stopped", 0.0, 180.0)
	assert(await wait_log("control play-id " + A2))
	assert(await wait_until(func(): return not audio.loading_audio))
	assert(audio.track_index == 1 and audio.queue.current == 1)
	audio.queue.repeat_mode = Queue.Repeat.ALL
	# Music switched elsewhere mid-track (user choice): stop following, no advance.
	watch(A2, "playing", 10.0, 180.0)
	watch(OTHER, "playing", 3.0, 150.0)
	assert(bus.transport == "stopped" and audio.track_index == 1 and bus.status.contains("switched"))
	# Not confirmed yet: other ids are ignored until the timeout.
	music.resume()
	watch(OTHER, "playing", 3.0, 150.0)
	assert(music.state == "starting" and bus.transport == "loading")
	music.fake_now += AppleMusicStream.CONFIRM_TIMEOUT_MS
	watch(OTHER, "playing", 3.0, 150.0)
	assert(music.state == "stopped" and bus.status.contains("didn't start"))
	# Music has our track but never starts it (network/account): paused, with a status.
	music.resume()
	watch(A2, "paused", 0.0, 180.0)
	assert(music.state == "starting")
	music.fake_now += AppleMusicStream.CONFIRM_TIMEOUT_MS
	watch(A2, "paused", 0.0, 180.0)
	assert(music.state == "paused" and bus.transport == "paused" and bus.status.contains("hasn't started"))
	music.stop()
	# Music quit.
	music.resume()
	watch(A2, "playing", 1.0, 180.0)
	watch("", "stopped", 0.0, 0.0, false)
	assert(bus.transport == "stopped" and bus.status.contains("quit"))

	# --- Streaming -> file entry pauses Music and stops watch/tap ------------------------------
	music.resume()
	watch(A2, "playing", 2.0, 180.0)
	var watch_pid: int = music.watch_proc.pid
	var tap_pid: int = music.tap_proc.pid
	assert(alive(watch_pid) and alive(tap_pid))
	clear_log()
	assert(await audio.play_track(2))
	assert(not audio.streaming() and audio.player.playing and music.watch_proc == null and music.tap_proc == null)
	assert(await wait_log("control pause"))
	assert(await wait_until(func(): return not alive(watch_pid) and not alive(tap_pid)))
	assert(audio.pcm_rate() == AudioServer.get_mix_rate())
	audio.stop_play()

	# --- Last entry ends with Repeat Off: playlist finishes, Music paused -------------------
	audio.playlist = PackedStringArray(["applemusic:" + A1])
	audio.queue = Queue.new()
	audio.queue.configure(1)
	audio.queue.repeat_mode = Queue.Repeat.OFF
	assert(await audio.play_track(0))
	watch(A1, "playing", 199.0, 200.0)
	clear_log()
	watch(OTHER, "playing", 0.1, 150.0)
	assert(await wait_until(func(): return bus.transport == "stopped"))
	assert(not audio.streaming() and bus.status.contains("Playlist finished"))
	assert(await wait_log("control pause"))

	# --- Exit codes -> statuses ---------------------------------------------------------------
	audio.queue = Queue.new()
	audio.queue.configure(1)
	assert(await wait_until(bridge.controls_idle))
	for case in [[5, "isn't in your Music library"], [3, "Automation"], [4, "isn't running"], [6, "fake failure"]]:
		OS.set_environment("FAKE_CONTROL_EXIT", str(case[0]))
		assert(not await audio.play_track(0))
		assert(bus.status.contains(case[1]) and audio.queue.failed.has(0) and not audio.streaming())
	OS.unset_environment("FAKE_CONTROL_EXIT")
	assert(MusicBridge.status_for("library", 2).contains("Media & Apple Music"))
	assert(MusicBridge.status_for("tap", 3).contains("Screen & System Audio Recording"))
	assert(MusicBridge.status_for("watch", 3).contains("Automation"))
	assert(MusicBridge.status_for("control", -1).contains("wasn't found"))
	# Tap exit 3: permission status, synthetic fallback for classic scenes and
	# the reactivity layer (no freeze); no restart loop.
	OS.set_environment("FAKE_TAP_EXIT", "3")
	assert(await audio.play_track(0))
	assert(await wait_until(func(): return music.tap_reason == "permission"))
	OS.unset_environment("FAKE_TAP_EXIT")
	assert(not music.tap_ok and audio.fallback_feed != null and reactivity.is_mock() and reactivity.source_kind == "mock")
	assert(bus.status.contains("Screen & System Audio Recording"))
	var fallback: Dictionary = audio.sample(1.0)
	assert(fallback.has("band_a") and fallback.has("section") and music.tap_proc == null)
	for i in 10: await process_frame
	assert(music.tap_proc == null)
	# A stall (no PCM while playing) falls back; real sound again recovers.
	music.fake_now = Time.get_ticks_msec() + 500000
	music._set_tap(true, "")
	audio._set_fallback(false)
	assert(not reactivity.is_mock() and reactivity.source_kind == "live")
	watch(A1, "playing", 3.0, 200.0)
	music._last_bytes_ms = music.fake_now
	music.fake_now += AppleMusicStream.STALL_MS + 100
	music._check_tap_health(music.now())
	assert(music.tap_reason == "stalled" and audio.fallback_feed != null and reactivity.is_mock())
	music.push_pcm_bytes(sine_bytes(rate, 0.05))
	assert(music.tap_ok and audio.fallback_feed == null and not reactivity.is_mock())
	# Digital silence for SILENT_MS while playing (and not muted) falls back too.
	music._last_bytes_ms = music.fake_now
	music._last_sound_ms = music.fake_now
	music.fake_now += AppleMusicStream.SILENT_MS + 100
	music.push_pcm_bytes(PackedFloat32Array([0.0, 0.0, 0.0, 0.0]).to_byte_array())
	music._check_tap_health(music.now())
	assert(music.tap_reason == "silent" and bus.status.contains("Screen & System Audio Recording"))
	music.push_pcm_bytes(sine_bytes(rate, 0.05))
	assert(music.tap_ok)

	# --- Tap retry with backoff: silent -> retry 2 s, 5 s -> real audio again ----------------
	# Real tap processes from here: start 1 and 2 deliver digital silence, start 3 sound.
	var scratch := OS.get_temp_dir().path_join("oozic-test-tap-%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(scratch)
	var zeros_path := scratch.path_join("zeros.f32")
	var sound_path := scratch.path_join("sound.f32")
	var counter_path := scratch.path_join("count")
	var events_path := scratch.path_join("events.jsonl")
	var zeros := PackedFloat32Array()
	zeros.resize(int(rate * 0.2) * 2)
	write_bytes(zeros_path, zeros.to_byte_array())
	write_bytes(sound_path, sine_bytes(rate, 0.2))
	var events := FileAccess.open(events_path, FileAccess.WRITE)
	events.store_string("{\"event\":\"attached\",\"backend\":\"tap\",\"source\":\"app\",\"pids\":[4242]}\n{\"event\":\"device\",\"reason\":\"default_output_changed\",\"output\":\"Headphones\"}\n{\"event\":\"rebuilt\",\"reason\":\"default_output_changed\",\"pids\":[4242]}\n{\"event\":\"output\",\"running\":true,\"pids\":[4242],\"others\":[]}\n")
	events = null
	OS.unset_environment("FAKE_TAP_PCM")
	OS.set_environment("FAKE_TAP_COUNTER", counter_path)
	OS.set_environment("FAKE_TAP_EVENTS", events_path)
	OS.set_environment("FAKE_TAP_PCM_1", zeros_path)
	OS.set_environment("FAKE_TAP_PCM_2", zeros_path)
	OS.set_environment("FAKE_TAP_PCM_3", sound_path)
	OS.set_environment("FAKE_TAP_PCM_5", sound_path)  # start 4 delivers nothing (stall)
	clear_log()
	music._tap_denied = false
	music._tap_restart_at = 0
	music.bytes_total = 0
	var tap_line := "tap --app com.apple.Music --rate %d --backend tap" % rate
	assert(await wait_until(func(): return music.bytes_total > 0 and music.tap_rebuilds >= 1))
	# The helper's rebuild/device/output events are parsed (and logged).
	assert(count_log(tap_line) == 1 and music.music_output == true and music.tap_ok and music.state == "playing")
	assert(music.debug_line().begins_with("music: playing · tap tap pid ") and music.debug_line().contains("· level -120 dB · ok") and music.debug_line().contains("1 helper rebuild"))
	assert(audio.music_debug_line() == music.debug_line())
	# (A real tap streams continuously; the fake wrote its block once, so
	# the zeros "keep arriving" by hand while fake time advances.)
	music.fake_now += AppleMusicStream.SILENT_MS + 100
	music.push_pcm_bytes(zeros.to_byte_array().slice(0, 64))
	assert(await wait_until(func(): return music.tap_reason == "silent"))
	assert(audio.fallback_feed != null and reactivity.is_mock() and bus.status.contains("Retrying"))
	assert(music.debug_line().ends_with("· silent, 1 helper rebuild"))
	# First retry after 2 s (not before).
	music.fake_now += 1900
	for i in 5: await process_frame
	assert(count_log(tap_line) == 1)
	music.fake_now += 100
	assert(await wait_until(func(): return count_log(tap_line) == 2 and music.retry_count == 1))
	assert(music.debug_line().contains("retrying 1 (silent)"))
	# Second retry 5 s later; that tap delivers real sound -> back to live analysis.
	music.fake_now += 4900
	for i in 5: await process_frame
	assert(count_log(tap_line) == 2 and not music.tap_ok)
	music.fake_now += 100
	assert(await wait_until(func(): return music.tap_ok))
	assert(count_log(tap_line) == 3 and music.retry_count == 0 and audio.fallback_feed == null and not reactivity.is_mock())

	# --- Stalled (no bytes at all) -> retry -> recovery ------------------------------------------
	bridge.release(music.tap_proc)
	music.tap_proc = null
	music._tap_restart_at = 0
	assert(await wait_until(func(): return count_log(tap_line) == 4 and music.tap_proc != null))
	music.fake_now += AppleMusicStream.STALL_MS + 100
	assert(await wait_until(func(): return music.tap_reason == "stalled"))
	assert(bus.status.contains("capture stalled") and audio.fallback_feed != null)
	music.fake_now += AppleMusicStream.RETRY_DELAYS_MS[0]
	assert(await wait_until(func(): return music.tap_ok))
	assert(count_log(tap_line) == 5 and audio.fallback_feed == null)
	assert(AppleMusicStream.RETRY_DELAYS_MS == [2000, 5000, 10000, 30000])
	for name in ["FAKE_TAP_COUNTER", "FAKE_TAP_EVENTS", "FAKE_TAP_PCM_1", "FAKE_TAP_PCM_2", "FAKE_TAP_PCM_3", "FAKE_TAP_PCM_5"]: OS.unset_environment(name)

	# --- Speakers silent while "playing": Music not outputting / Music volume 0 --------------
	var statuses := []
	music.status.connect(func(text): statuses.append(text))
	music.music_output = false
	music.fake_now += AppleMusicStream.SILENT_MS + 100
	assert(await wait_until(func(): return statuses.any(func(s): return s.contains("isn't producing any audio"))))
	assert(music.debug_line().contains("Music not outputting"))
	music.music_output = true
	watch(A1, "playing", 20.0, 200.0, true, 0)
	assert(statuses.any(func(s): return s.contains("own volume is at 0")) and music.state == "playing")

	# --- Diagnostics: the app-mode log recorded controls, watch, state and tap events --------
	var diag_text := FileAccess.get_file_as_string(diag_path)
	for needle in [" control {\"args\":[\"play-id\"", " watch {", " state {", " tap_header {", " tap_rebuilt {", " tap_device {", " tap_health {", " tap_retry {", " spawn {", " volume_link {", " status {"]:
		if not diag_text.contains(needle): print("diagnostics log lacks: ", needle)
		assert(diag_text.contains(needle))

	# --- Quit while muted with the volume link on: pause and restore Music's volume ------------
	bus.command(&"set_music_volume_link", {"on": true})
	bus.command(&"set_volume", {"value": 0.6})
	bus.command(&"toggle_mute")
	assert(await wait_log("control volume 0") and music.music_muted_by_oozic())
	# A new start while muted never sends 0 implicitly.
	assert(await wait_until(bridge.controls_idle))
	clear_log()
	assert(await audio.play_track(0))
	watch(A1, "playing", 0.0, 200.0)
	assert(await wait_until(bridge.controls_idle))
	assert(count_log("control volume") == 0 and bus.transport == "playing")
	# (play() leaves the earlier zeroing recorded, so quitting restores it.)
	assert(music.music_muted_by_oozic())

	# --- Cleanup: freeing the service kills every helper process ----------------------------
	var pids: Array = []
	for proc in bridge.processes: pids.append(proc.pid)
	assert(pids.size() >= 1)
	clear_log()
	audio.queue_free()
	await process_frame
	await process_frame
	for pid in pids: assert(not alive(pid))
	# Quitting while a Music track plays pauses Music (synchronously) and puts
	# back the volume Oozic's mute had zeroed.
	assert(log_lines().has("control pause") and log_lines().has("control volume 60"))
	DirAccess.remove_absolute(diag_path)
	DirAccess.remove_absolute(diag_path.get_base_dir())
	for file in ["zeros.f32", "sound.f32", "count", "events.jsonl"]: DirAccess.remove_absolute(scratch.path_join(file))
	DirAccess.remove_absolute(scratch)
	# Nothing in this run wrote the user's real diagnostics log.
	assert([file_state(real_log), file_state(real_log.get_basename() + ".1.log")] == real_log_before)

	# --- Runtime install of the real helper (exported-build path) ---------------------------
	var target := "user://test-bin/oozic-music-helper"
	var installed := MusicBridge.install_helper(MusicBridge.HELPER_RES, target)
	assert(installed == ProjectSettings.globalize_path(target))
	var out := []
	assert(OS.execute(installed, PackedStringArray(["version"]), out) == 0 and str(out[0]).contains("version"))
	var damaged := FileAccess.open(installed, FileAccess.WRITE)
	damaged.store_string("x")
	damaged = null
	assert(MusicBridge.install_helper(MusicBridge.HELPER_RES, target) == installed)
	assert(FileAccess.get_md5(installed) == FileAccess.get_md5(MusicBridge.HELPER_RES))
	assert(MusicBridge.install_helper("res://bin/missing-helper", target).is_empty())
	DirAccess.remove_absolute(installed)
	DirAccess.remove_absolute(installed.get_base_dir())

	for name in ["OOZIC_MUSIC_HELPER", "FAKE_HELPER_LOG", "FAKE_TAP_PCM"]: OS.unset_environment(name)
	clear_log()
	DirAccess.remove_absolute(pcm_path)
	DirAccess.remove_absolute(settings_path)
	print("PASS: library parse/indexes/cache/exit 2, permissions, track_meta (applemusic, library file, unknown file), add_library_tracks/playlist, .m4p rejected, playlist.json + M3U applemusic: round trip, play-id/watch/tap/volume spawn args, tap f32le -> classic inputs + live analyser at tap rate (no pre-analysis), partial-frame carry, watch -> position/duration/transport, play/pause/seek/seek_fraction/volume/mute/stop/replay -> control args, volume coalescing, end-of-track advance (auto-advance id, stopped near end, repeat one, repeat off finish), external switch/timeout/quit, file after stream pauses Music and kills watch/tap, control exit 3/4/5/6 statuses, tap exit 3 + stall + silence -> synthetic fallback and recovery, transport loading until watch confirms the id, external pause/resume reflected, Music-has-track-but-never-starts, volume link off by default / on / unlink restores / no implicit 0 / quit restores, tap retry backoff silent -> 2 s -> 5 s -> real audio, stalled -> retry -> recovery, helper rebuilt/device/output events, Music not outputting + Music volume 0 statuses, F3 music line, diagnostics log (app mode only, rotation, events; real log untouched), process cleanup + pause on exit, runtime helper install")
	quit()
