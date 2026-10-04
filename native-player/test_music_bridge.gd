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

func watch(id: String, state: String, position: float, duration: float, running := true) -> void:
	music.fake_now += 1000
	music.apply_watch({"running": running, "state": state, "id": id, "title": "", "artist": "", "album": "", "position": position, "duration": duration, "volume": 100})

func run():
	var fake := ProjectSettings.globalize_path("res://tools/fake_music_helper.sh")
	OS.execute("/bin/chmod", PackedStringArray(["+x", fake]))
	log_path = OS.get_temp_dir().path_join("oozic-fake-helper-%d.log" % OS.get_process_id())
	OS.set_environment("OOZIC_MUSIC_HELPER", fake)
	OS.set_environment("FAKE_HELPER_LOG", log_path)
	clear_log()
	audio = AudioService.new(false)
	root.add_child(audio)
	await process_frame
	bus = audio.bus
	bridge = audio.music_bridge
	music = audio.music
	assert(bridge.helper_path() == fake)
	var settings_path := OS.get_temp_dir().path_join("oozic-test-music-settings.cfg")
	audio.settings_path = settings_path

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
	assert(await audio.play_track(0))
	assert(audio.streaming() and music.id == A1 and bus.transport == "playing" and bus.track_title == "Alpha — Artist One")
	assert(is_equal_approx(music.duration, 200.0) and audio.is_playing() and audio.player.stream == null)
	assert(log_lines()[0] == "control play-id " + A1)
	assert(await wait_log("watch --interval 0.25"))
	assert(await wait_log("tap --app com.apple.Music --rate %d --backend tap" % rate))
	assert(await wait_log("control volume 100"))
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
	music.fake_now = Time.get_ticks_msec() + 100000
	watch(A1, "playing", 12.5, 201.0)
	audio._process(0.016)
	assert(is_equal_approx(music.position, 12.5) and is_equal_approx(bus.position, 12.5) and is_equal_approx(bus.duration, 201.0))
	music.fake_now += 500
	assert(is_equal_approx(audio.playback_time(), 13.0))
	watch(A1, "paused", 13.0, 201.0)
	assert(bus.transport == "paused" and not audio.is_playing())

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
	bus.command(&"set_volume", {"value": 0.5})
	assert(await wait_log("control volume 50"))
	bus.command(&"toggle_mute")
	assert(await wait_log("control volume 0"))
	clear_log()
	bus.command(&"toggle_mute")
	assert(await wait_log("control volume 50"))
	bus.command(&"stop")
	assert(bus.transport == "stopped" and music.state == "stopped")
	assert(await wait_log("control stop"))
	# Play after Stop restarts our track (Music forgot it).
	clear_log()
	bus.command(&"play_pause")
	assert(bus.transport == "playing")
	assert(await wait_log("control play-id " + A1))
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
	assert(music.state == "playing")
	music.fake_now += AppleMusicStream.CONFIRM_TIMEOUT_MS
	watch(OTHER, "playing", 3.0, 150.0)
	assert(music.state == "stopped" and bus.status.contains("didn't start"))
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

	# --- Cleanup: freeing the service kills every helper process ----------------------------
	var pids: Array = []
	for proc in bridge.processes: pids.append(proc.pid)
	assert(pids.size() >= 1)
	clear_log()
	audio.queue_free()
	await process_frame
	await process_frame
	for pid in pids: assert(not alive(pid))
	# Quitting while a Music track plays pauses Music (synchronously).
	assert(log_lines().has("control pause"))

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
	print("PASS: library parse/indexes/cache/exit 2, permissions, track_meta (applemusic, library file, unknown file), add_library_tracks/playlist, .m4p rejected, playlist.json + M3U applemusic: round trip, play-id/watch/tap/volume spawn args, tap f32le -> classic inputs + live analyser at tap rate (no pre-analysis), partial-frame carry, watch -> position/duration/transport, play/pause/seek/seek_fraction/volume/mute/stop/replay -> control args, volume coalescing, end-of-track advance (auto-advance id, stopped near end, repeat one, repeat off finish), external switch/timeout/quit, file after stream pauses Music and kills watch/tap, control exit 3/4/5/6 statuses, tap exit 3 + stall + silence -> synthetic fallback and recovery, process cleanup + pause on exit, runtime helper install")
	quit()
