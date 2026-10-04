extends Node
## Non-visual playback service: owns the AudioStreamPlayer, the analysis
## capture bus, decoding, the playlist and the queue. Lives under the root
## node, not in either window, so both windows (or none) can drive it through
## PlayerBus commands. Publishes transport/track/position/playlist/volume state.
##
## The playlist persists automatically to user://playlist.json (paths, current
## index). The original kept an MFC-serialised Lava.mvl next to LavaPlay.exe;
## we use JSON plus .m3u import/export (the original had no M3U support).
##
## Playlist entries are file paths or "applemusic:<ID>" (docs/APPLE_MUSIC.md):
## those play in the Music app through AppleMusicStream, and the analysis is
## fed from the helper's audio tap instead of the SceneAnalysis capture bus.
const FlacDecoder = preload("res://flac_decoder.gd")
const AudioInputs = preload("res://audio_inputs.gd")
const PlaybackQueue = preload("res://playback_queue.gd")
const AppSettings = preload("res://app_settings.gd")
const PlayerBusScript = preload("res://player_bus.gd")
const ReactivityServiceScript = preload("res://analysis/reactivity_service.gd")
const MusicBridge = preload("res://music_bridge.gd")
const AppleMusicStream = preload("res://apple_music_stream.gd")
const MockAudioFeed = preload("res://mock_audio_feed.gd")
const MAX_MP3_BYTES = 100 * 1024 * 1024
const AUDIO_EXTENSIONS := PlayerBusScript.AUDIO_EXTENSIONS
const APPLE_MUSIC_PREFIX := PlayerBusScript.APPLE_MUSIC_PREFIX
const PLAYLIST_PATH := "user://playlist.json"
const PROTECTED_TEXT := "Protected (.m4p) purchases can't be decoded here. Add them from the Music library instead; the Music app plays them."
const FORMATS_TEXT := "Choose audio files (MP3, FLAC, AAC/M4A, ALAC, AIFF, WAV or CAF)."
## BPM of the synthetic beat used when the Apple Music tap is unavailable.
const FALLBACK_BPM := 120.0

var bus
var player: AudioStreamPlayer
var capture: AudioEffectCapture
var inputs
## App-wide reactivity layer (autoload); fed with the same captured PCM.
var reactivity
var queue = PlaybackQueue.new()
var playlist: PackedStringArray = PackedStringArray()
var track_index := -1
var loading_audio := false
var pending_advance := false
var flac_thread: Thread
var captured_frames := 0
var maximum_s := 0.0
var maximum_a := 0.0
var volume := 1.0
var muted := false
## Persistence targets; tests point these at scratch files or clear them.
var playlist_path := PLAYLIST_PATH
var settings_path := AppSettings.PATH
var persist := true
## Apple Music: helper plumbing + library (MusicBridge) and the Music-app player.
var music_bridge
var music
## Synthetic feed for the classic scenes while the Apple Music tap is down.
var fallback_feed = null
var _fallback_reactivity := false

func _init(persistent := true):
	persist = persistent
	name = "AudioService"

func _ready():
	bus = PlayerBusScript.instance()
	bus.command_requested.connect(_on_command)
	bus.scene_pins_changed.connect(save_playlist_file)
	# The bridge first: its cached library gives restored entries their titles.
	music_bridge = MusicBridge.new(persist)
	add_child(music_bridge)
	music = AppleMusicStream.new()
	music.bridge = music_bridge
	add_child(music)
	music.state_changed.connect(_on_music_state)
	music.ended.connect(func(): advance_track(true))
	music.tap_health.connect(func(ok, _reason): _set_fallback(not ok))
	music.status.connect(status)
	_build_audio()
	reactivity = ReactivityServiceScript.instance()
	if reactivity != null: reactivity.attach_audio(self)
	if persist:
		var values := AppSettings.load_section(settings_path, "player")
		volume = clampf(float(values.get("volume", 1.0)), 0.0, 1.0)
		muted = bool(values.get("muted", false))
		queue.set_shuffle(bool(values.get("shuffle", false)))
		queue.repeat_mode = clampi(int(values.get("repeat", PlaybackQueue.Repeat.ALL)), 0, 2)
		load_playlist_file()
	_apply_volume()
	bus.publish_modes(queue.shuffle, queue.repeat_mode)
	_publish_playlist()

func _build_audio():
	AudioServer.add_bus()
	var index := AudioServer.bus_count - 1
	AudioServer.set_bus_name(index, "SceneAnalysis")
	AudioServer.set_bus_send(index, "Master")
	capture = AudioEffectCapture.new()
	capture.buffer_length = 0.5
	AudioServer.add_bus_effect(index, capture)
	inputs = AudioInputs.new(AudioServer.get_mix_rate())
	player = AudioStreamPlayer.new()
	player.bus = "SceneAnalysis"
	add_child(player)
	player.finished.connect(advance_track.bind(true))

func configure_bands(bands: Array):
	inputs.configure(AudioServer.get_mix_rate(), bands)
	capture.clear_buffer()

func _on_command(command: StringName, args: Dictionary):
	match command:
		&"play_pause": toggle_play()
		&"play":
			if not is_playing(): toggle_play()
		&"pause":
			if is_playing(): toggle_play()
		&"stop": stop_play()
		&"next": advance_track()
		&"previous": previous_track()
		&"seek":
			if has_media(): seek_to(float(args.get("seconds", 0.0)))
		&"seek_fraction":
			if has_media(): seek_to(float(args.get("fraction", 0.0)) * media_length())
		&"seek_relative":
			if has_media(): seek_to(current_position() + float(args.get("seconds", 0.0)))
		&"set_volume": set_volume(float(args.get("value", volume)))
		&"volume_step": set_volume(volume + float(args.get("delta", 0.0)))
		&"toggle_mute": set_muted(not muted)
		&"toggle_shuffle": toggle_shuffle()
		&"cycle_repeat": cycle_repeat()
		&"add_paths": add_tracks(PackedStringArray(args.get("paths", [])), bool(args.get("play", true)))
		&"add_directory_path": add_directory(str(args.get("path", "")), bool(args.get("recursive", true)))
		&"play_index": play_track(int(args.get("index", -1)))
		&"remove_index": remove_track(int(args.get("index", -1)))
		&"move_index": move_track(int(args.get("from", -1)), int(args.get("to", -1)))
		&"clear_playlist": clear_playlist()
		&"import_m3u": import_m3u(str(args.get("path", "")))
		&"export_m3u": export_m3u(str(args.get("path", "")))
		&"add_library_tracks": add_library_tracks(args.get("ids", []), bool(args.get("play", true)))
		&"add_library_playlist": add_library_playlist(str(args.get("id", "")), bool(args.get("play", true)))

func is_playing() -> bool:
	if music != null and music.is_playing(): return true
	return player != null and player.playing and not player.stream_paused

static func is_apple_music(path: String) -> bool:
	return path.begins_with(APPLE_MUSIC_PREFIX)

## True while the current entry plays in the Music app.
func streaming() -> bool:
	return music != null and music.active()

## Something is loaded (a decoded stream, or a Music-app track).
func has_media() -> bool:
	return player.stream != null or streaming()

func media_length() -> float:
	if streaming(): return music.duration
	return player.stream.get_length() if player.stream else 0.0

func current_position() -> float:
	if streaming(): return music.playback_time()
	return player.get_playback_position() if player.stream else 0.0

## Sample rate of the PCM pushed to the analysers (tap rate while streaming).
func pcm_rate() -> float:
	return float(music.tap_rate) if streaming() else AudioServer.get_mix_rate()

func status(text: String):
	bus.publish_status(text)

# --- Playlist -------------------------------------------------------------

func _publish_playlist():
	var failed: Array[int] = []
	failed.assign(queue.failed)
	bus.publish_playlist(playlist, track_index, failed)

func add_tracks(paths: PackedStringArray, play_first := true) -> int:
	var first := playlist.size()
	var protected := 0
	for path in paths:
		var extension := path.get_extension().to_lower()
		if is_apple_music(path): playlist.append(path)
		elif extension == "m3u" or extension == "m3u8": import_m3u(path, false)
		elif extension in AUDIO_EXTENSIONS: playlist.append(path)
		elif extension == "m4p": protected += 1
		elif DirAccess.dir_exists_absolute(path): _collect_directory(path, true)
	var added := playlist.size() - first
	if added > 0:
		queue.configure(playlist.size())
		_playlist_edited()
		if play_first: play_track(first)
		if protected > 0: status(PROTECTED_TEXT)
	else: status(PROTECTED_TEXT if protected > 0 else FORMATS_TEXT)
	return added

## Adds Apple Music library tracks by persistent ID (PlayerBus.library):
## playable local files by path, everything else as applemusic:<ID>.
func add_library_tracks(ids: Array, play_first := true) -> int:
	var entries := PackedStringArray()
	for id in ids:
		var entry: String = music_bridge.entry_for_id(str(id))
		if not entry.is_empty(): entries.append(entry)
	if entries.is_empty():
		status("Those tracks aren't in the Music library (refresh the library and try again).")
		return 0
	return add_tracks(entries, play_first)

func add_library_playlist(id: String, play_first := true) -> int:
	for item in bus.library.get("playlists", []):
		if str(item.get("id", "")) == id:
			if item.track_ids.is_empty():
				status("“%s” has no tracks." % item.name)
				return 0
			return add_library_tracks(item.track_ids, play_first)
	status("That playlist isn't in the Music library (refresh the library and try again).")
	return 0

func add_directory(path: String, recursive := true) -> int:
	if path.is_empty() or not DirAccess.dir_exists_absolute(path):
		status("Couldn't open that folder.")
		return 0
	var first := playlist.size()
	_collect_directory(path, recursive)
	var added := playlist.size() - first
	if added > 0:
		queue.configure(playlist.size())
		_playlist_edited()
		if not is_playing(): play_track(first)
	else: status("No playable audio files in that folder.")
	return added

func _collect_directory(path: String, recursive: bool):
	var directory := DirAccess.open(path)
	if directory == null: return
	var files := Array(directory.get_files())
	files.sort_custom(func(a, b): return a.naturalnocasecmp_to(b) < 0)
	for file in files:
		if file.get_extension().to_lower() in AUDIO_EXTENSIONS: playlist.append(path.path_join(file))
	if recursive:
		var folders := Array(directory.get_directories())
		folders.sort_custom(func(a, b): return a.naturalnocasecmp_to(b) < 0)
		for folder in folders: _collect_directory(path.path_join(folder), true)

func remove_track(index: int) -> bool:
	if index < 0 or index >= playlist.size(): return false
	var removing_current := index == track_index
	playlist.remove_at(index)
	var remap := func(i): return -1 if i == index else (i - 1 if i > index else i)
	if removing_current:
		if has_media(): stop_play()
		_leave_music()
		player.stream = null
		bus.publish_track(-1, "")
		bus.publish_position(0.0, 0.0)
	_reindex_queue(remap, -1 if removing_current else remap.call(track_index))
	_playlist_edited()
	return true

func move_track(from: int, to: int) -> bool:
	if from < 0 or from >= playlist.size() or to < 0 or to >= playlist.size() or from == to: return false
	var path := playlist[from]
	playlist.remove_at(from)
	playlist.insert(to, path)
	var remap := func(i):
		if i == from: return to
		if from < to and i > from and i <= to: return i - 1
		if from > to and i >= to and i < from: return i + 1
		return i
	_reindex_queue(remap, remap.call(track_index) if track_index >= 0 else -1)
	_playlist_edited()
	return true

## Keep the queue's failed/history indices pointing at the same files.
func _reindex_queue(remap: Callable, new_current: int):
	var mapped_failed: Array[int] = []
	for i in queue.failed:
		var m: int = remap.call(i)
		if m >= 0: mapped_failed.append(m)
	var mapped_history: Array[int] = []
	for i in queue.history:
		var m: int = remap.call(i)
		if m >= 0: mapped_history.append(m)
	track_index = new_current
	queue.current = new_current
	queue.configure(playlist.size())
	queue.failed = mapped_failed
	queue.history = mapped_history

func clear_playlist():
	stop_play()
	_leave_music()
	player.stream = null
	playlist = PackedStringArray()
	track_index = -1
	queue = _fresh_queue()
	bus.publish_track(-1, "")
	bus.publish_position(0.0, 0.0)
	_playlist_edited()
	status("Playlist cleared.")

func _fresh_queue():
	var fresh = PlaybackQueue.new()
	fresh.set_shuffle(queue.shuffle)
	fresh.repeat_mode = queue.repeat_mode
	return fresh

func _playlist_edited():
	_publish_playlist()
	save_playlist_file()

func save_playlist_file() -> bool:
	if not persist or playlist_path.is_empty(): return false
	var file := FileAccess.open(playlist_path, FileAccess.WRITE)
	if file == null: return false
	file.store_string(JSON.stringify({"format": "oozic-playlist/1", "tracks": Array(playlist), "current": track_index, "scene_pins": bus.scene_pins}, "\t"))
	return true

func load_playlist_file() -> bool:
	if playlist_path.is_empty() or not FileAccess.file_exists(playlist_path): return false
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(playlist_path))
	if not parsed is Dictionary or not parsed.get("tracks") is Array: return false
	playlist = PackedStringArray()
	for path in parsed.tracks:
		if is_apple_music(str(path)) or str(path).get_extension().to_lower() in AUDIO_EXTENSIONS: playlist.append(str(path))
	queue.configure(playlist.size())
	track_index = clampi(int(parsed.get("current", -1)), -1, playlist.size() - 1)
	queue.current = track_index
	# Per-track scene pins (Phase 4e) live with the playlist.
	var pins := {}
	if parsed.get("scene_pins") is Dictionary:
		for key in parsed.scene_pins: pins[str(key)] = str(parsed.scene_pins[key])
	bus.publish_scene_pins(pins)
	if track_index >= 0:
		bus.publish_track(track_index, display_title(playlist[track_index]))
		status("Playlist restored · %d track%s. Press Play." % [playlist.size(), "" if playlist.size() == 1 else "s"])
	return true

func export_m3u(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		status("Couldn't write that playlist file.")
		return false
	var lines := PackedStringArray(["#EXTM3U"])
	for track in playlist:
		lines.append("#EXTINF:-1," + display_title(track))
		lines.append(ProjectSettings.globalize_path(track) if not track.begins_with("res://") and not is_apple_music(track) else track)
	file.store_string("\n".join(lines) + "\n")
	status("Saved playlist: " + path.get_file())
	return true

func import_m3u(path: String, play_first := true) -> int:
	if not FileAccess.file_exists(path):
		status("Couldn't open that playlist file.")
		return 0
	var base := path.get_base_dir()
	var found := PackedStringArray()
	for raw_line in FileAccess.get_file_as_string(path).split("\n"):
		var line := raw_line.strip_edges()
		if line.is_empty() or line.begins_with("#"): continue
		if is_apple_music(line):
			found.append(line)
			continue
		if line.begins_with("file://"): line = line.trim_prefix("file://").uri_decode()
		if not line.is_absolute_path(): line = base.path_join(line)
		if line.get_extension().to_lower() in AUDIO_EXTENSIONS: found.append(line)
	if found.is_empty():
		status("No playable entries in " + path.get_file())
		return 0
	var first := playlist.size()
	playlist.append_array(found)
	queue.configure(playlist.size())
	_playlist_edited()
	if play_first: play_track(first)
	return found.size()

static func title_for(path: String) -> String:
	return path.get_file().get_basename()

## "Title — Artist" when the library knows the entry, else the file name.
func display_title(path: String) -> String:
	var meta: Dictionary = bus.track_meta(path)
	return meta.title if str(meta.artist).is_empty() else "%s — %s" % [meta.title, meta.artist]

# --- Transport ------------------------------------------------------------

func toggle_shuffle():
	queue.set_shuffle(not queue.shuffle)
	_modes_changed()

func cycle_repeat():
	queue.repeat_mode = (queue.repeat_mode + 1) % 3
	_modes_changed()

func _modes_changed():
	bus.publish_modes(queue.shuffle, queue.repeat_mode)
	if persist: AppSettings.save_section(settings_path, "player", {"shuffle": queue.shuffle, "repeat": queue.repeat_mode})

func set_volume(value: float):
	volume = clampf(value, 0.0, 1.0)
	_apply_volume()
	if persist: AppSettings.save_section(settings_path, "player", {"volume": volume, "muted": muted})

func set_muted(value: bool):
	muted = value
	_apply_volume()
	if persist: AppSettings.save_section(settings_path, "player", {"volume": volume, "muted": muted})

## Volume/mute act on the Master bus, after the SceneAnalysis capture, so
## muting or turning down never starves the scene of analysis input.
func _apply_volume():
	var master := AudioServer.get_bus_index("Master")
	AudioServer.set_bus_volume_db(master, linear_to_db(maxf(volume, 0.0001)))
	AudioServer.set_bus_mute(master, muted or volume <= 0.0)
	# The Music app's own volume while one of its tracks is current (the tap
	# captures after it, so the analysers' adaptive levels absorb it).
	if music != null: music.set_volume(volume, muted)
	bus.publish_volume(volume, muted)

func advance_track(finished := false):
	if loading_audio:
		# End of track during a load: resolve once the load completes (see play_track).
		if finished: pending_advance = true
		return
	# Undecodable entries are marked failed and skipped; one pass bounds the search.
	var skipped := 0
	for attempt in playlist.size():
		var next: int = queue.next_index(finished)
		if next < 0: break
		if await play_track(next):
			if skipped > 0: status(bus.status + "  ·  skipped %d unplayable track%s" % [skipped, "" if skipped == 1 else "s"])
			return
		if loading_audio: return
		skipped += 1
	if finished:
		# Music has auto-advanced past our last track: pause it.
		_leave_music()
		bus.publish_transport("stopped")
		if skipped == 0: status("Playlist finished. Press Play to play this track again.")
		else: status("Playback stopped: %d unplayable track%s skipped. %s" % [skipped, "" if skipped == 1 else "s", bus.status])

func previous_track():
	if loading_audio: return
	if has_media() and current_position() > 3:
		seek_to(0)
		return
	var previous: int = queue.previous_index()
	if previous >= 0: await play_track(previous, true)

func play_track(index, previous := false) -> bool:
	if index < 0 or index >= playlist.size(): return false
	if loading_audio:
		status("Please wait for the current track to load.")
		return false
	var loaded: bool = await load_audio(playlist[index])
	var resume := pending_advance
	pending_advance = false
	if not loaded:
		queue.mark_failed(index)
		# A track ended while this load ran and nothing new is playing: continue.
		if resume and not is_playing(): advance_track.call_deferred(true)
		_publish_playlist()
		return false
	track_index = index
	if queue.count != playlist.size(): queue.configure(playlist.size())
	if previous: queue.commit_previous(index)
	else: queue.commit(index)
	_publish_playlist()
	save_playlist_file()
	bus.publish_track(index, display_title(playlist[index]))
	var shown: String = display_title(playlist[index]) if is_apple_music(playlist[index]) else playlist[index].get_file()
	status("%s  ·  Track %d of %d" % [shown, index + 1, playlist.size()])
	return true

func load_audio(path) -> bool:
	if loading_audio:
		status("Please wait for the current track to load.")
		return false
	if is_apple_music(path): return await load_apple_music(path)
	var extension: String = path.get_extension().to_lower()
	if extension == "m4p":
		status(PROTECTED_TEXT)
		return false
	if not extension in FlacDecoder.EXTENSIONS: return load_mp3(path)
	loading_audio = true
	bus.publish_transport("loading")
	status("Loading %s…" % path.get_file())
	flac_thread = Thread.new()
	var error := flac_thread.start(FlacDecoder.decode.bind(ProjectSettings.globalize_path(path)))
	if error != OK:
		loading_audio = false
		flac_thread = null
		_restore_transport()
		status("Couldn't start decoding.")
		return false
	while flac_thread.is_alive(): await get_tree().process_frame
	var decoded: Dictionary = flac_thread.wait_to_finish()
	flac_thread = null
	loading_audio = false
	if decoded.has("error"):
		_restore_transport()
		status(decoded.error)
		return false
	start_stream(decoded.stream, path)
	return true

## Starts an applemusic:<ID> entry in the Music app (await; false on failure).
func load_apple_music(path: String) -> bool:
	var id := path.trim_prefix(APPLE_MUSIC_PREFIX)
	loading_audio = true
	bus.publish_transport("loading")
	status("Starting %s in Music…" % display_title(path))
	player.stop()
	player.stream_paused = false
	# Ask the tap for exactly the analysers' rate: no resampling needed.
	music.tap_rate = int(inputs.sample_rate)
	music.volume = volume
	music.muted = muted
	var result: Dictionary = await music.play(id, float(bus.track_meta(path).duration))
	loading_audio = false
	if not result.get("ok", false):
		_restore_transport()
		status(MusicBridge.status_for("control", int(result.get("code", -1)), str(result.get("message", ""))))
		return false
	player.stream = null
	inputs.reset()
	capture.clear_buffer()
	stream_started.emit(path)
	bus.publish_transport("playing")
	bus.publish_position(0.0, music.duration)
	return true

func _restore_transport():
	if is_playing(): bus.publish_transport("playing")
	elif (player.stream and player.stream_paused) or (streaming() and music.state == "paused"): bus.publish_transport("paused")
	else: bus.publish_transport("stopped")

func load_mp3(path) -> bool:
	if path.get_extension().to_lower() != "mp3":
		status(FORMATS_TEXT)
		return false
	var stream: AudioStreamMP3
	if path.begins_with("res://") and ResourceLoader.exists(path): stream = load(path) as AudioStreamMP3
	else:
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			status("Couldn't open that MP3.")
			return false
		if file.get_length() > MAX_MP3_BYTES:
			status("Choose an MP3 smaller than 100 MB.")
			return false
		stream = AudioStreamMP3.load_from_buffer(file.get_buffer(file.get_length()))
	if stream == null or stream.get_length() <= 0:
		status("Couldn't decode that MP3.")
		return false
	start_stream(stream, path)
	return true

## Emitted before a new stream starts so the visualiser can reset its scene.
signal stream_started(path: String)
## Emitted after a seek with the new position (the reactivity layer rebases).
signal seeked(position: float)

func start_stream(stream: AudioStream, path: String):
	# A file entry after a Music-app entry: pause Music, stop following it.
	_leave_music()
	player.stop()
	inputs.reset()
	capture.clear_buffer()
	stream_started.emit(path)
	player.stream = stream
	player.stream_paused = false
	player.play()
	bus.publish_transport("playing")
	bus.publish_position(0.0, stream.get_length())
	status(path.get_file())

## Stops following the Music app (pausing it) and drops the tap fallback.
func _leave_music():
	if streaming(): music.deactivate(true)
	_set_fallback(false)

func toggle_play():
	if streaming():
		if music.state == "playing": music.pause()
		else: music.resume()
		return
	if not player.stream:
		if not playlist.is_empty() and not loading_audio: play_track(maxi(track_index, 0))
		return
	# A paused player reports playing == false (Godot 4), so resume must clear
	# stream_paused rather than call play(), which would restart from 0.
	if player.stream_paused: player.stream_paused = false
	elif not player.playing: player.play()
	else: player.stream_paused = true
	bus.publish_transport("paused" if player.stream_paused else "playing")

func stop_play():
	if streaming(): music.stop()
	player.stop()
	player.stream_paused = false
	capture.clear_buffer()
	inputs.reset()
	bus.publish_transport("stopped")
	bus.publish_position(0.0, media_length())
	status("Stopped.")

func seek_to(seconds):
	var target := clampf(seconds, 0.0, media_length())
	if streaming(): music.seek(target)
	else: player.seek(target)
	inputs.reset()
	capture.clear_buffer()
	bus.publish_position(current_position(), media_length())
	seeked.emit(target)

## Audible playback position (s): the mixed position plus time since the last
## mix, minus output latency. Used as the reactivity clock. While the Music app
## plays, its watched position extrapolated between watch lines.
func playback_time() -> float:
	if streaming(): return music.playback_time()
	if player == null or player.stream == null: return 0.0
	var t := player.get_playback_position() + AudioServer.get_time_since_last_mix() - AudioServer.get_output_latency()
	return clampf(t, 0.0, player.stream.get_length())

## Next `count` playlist paths in sequential order (for background
## pre-analysis). Empty while shuffling: the next pick is random. Apple Music
## entries are skipped: they can't be decoded, only analysed live.
func upcoming_paths(count: int) -> PackedStringArray:
	var out := PackedStringArray()
	if queue.shuffle or playlist.is_empty() or track_index < 0: return out
	var index := track_index
	for step in playlist.size() - 1:
		index += 1
		if index >= playlist.size():
			if queue.repeat_mode == PlaybackQueue.Repeat.OFF: break
			index = 0
		if index == track_index or queue.failed.has(index) or is_apple_music(playlist[index]): continue
		out.append(playlist[index])
		if out.size() >= count: break
	return out

func _on_music_state(state: String):
	# During a load, play_track/load_apple_music publish the outcome.
	if not loading_audio: bus.publish_transport(state)

## Tap unavailable (permission, stall, silence): classic scenes sample a
## synthetic beat and the reactivity layer runs its synthetic source, unless the
## user already chose the synthetic input (then nothing changes).
func _set_fallback(on: bool):
	if on:
		if fallback_feed == null: fallback_feed = MockAudioFeed.new(FALLBACK_BPM, maxi(inputs.band_a.size(), 1))
		if reactivity != null and not reactivity.is_mock() and bus.analysis_source != "mock":
			reactivity.set_mock(FALLBACK_BPM)
			_fallback_reactivity = true
	else:
		fallback_feed = null
		if _fallback_reactivity and reactivity != null:
			_fallback_reactivity = false
			if bus.analysis_source != "mock": reactivity.clear_mock()

# --- Analysis -------------------------------------------------------------

## Per render frame: move captured PCM into the analysis (consumed per scene
## tick). Music-app entries feed the helper's tap PCM instead of the capture bus.
func _process(delta):
	if player == null: return
	if streaming():
		capture.clear_buffer()
		music.poll()
		var frames: PackedVector2Array = music.take_frames()
		if not streaming() or not music.is_playing(): return
		captured_frames += frames.size()
		inputs.push(frames, delta)
		if reactivity != null and not frames.is_empty(): reactivity.push_pcm(frames)
		bus.publish_position(music.playback_time(), music.duration)
		return
	if is_playing():
		var samples := capture.get_buffer(capture.get_frames_available())
		captured_frames += samples.size()
		inputs.push(samples, delta)
		if reactivity != null: reactivity.push_pcm(samples)
		bus.publish_position(player.get_playback_position(), player.stream.get_length())
	else: capture.clear_buffer()

## Scene sampler (Callable for SceneRuntime.advance) for real music analysis.
## While the Apple Music tap is down, a synthetic beat stands in (fallback_feed).
func sample(time: float) -> Dictionary:
	if fallback_feed != null and streaming():
		inputs.consume()
		return fallback_feed.sample(time)
	var signals = inputs.consume()
	maximum_s = maxf(maximum_s, signals.global_s)
	for value in signals.band_a: maximum_a = maxf(maximum_a, value)
	return signals

func _exit_tree():
	# Quitting while a Music-app track plays: pause it (synchronously; the
	# bridge kills its processes as it leaves the tree).
	if streaming() and music.state == "playing": music_bridge.control_sync(PackedStringArray(["pause"]))
	if flac_thread != null and flac_thread.is_started(): flac_thread.wait_to_finish()
	if player:
		player.stop()
		player.stream = null
	var index := AudioServer.get_bus_index("SceneAnalysis")
	if index >= 0: AudioServer.remove_bus(index)
