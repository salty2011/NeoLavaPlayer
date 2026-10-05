extends Node
## PlayerBus: the only link between the control window, the visualiser window
## and the non-visual services. Registered as the autoload "PlayerBus".
##
## Two halves:
## - State model: plain properties, written by the owning service through the
##   publish_* methods, which emit the matching *_changed signal. Windows read
##   state and listen to signals; they never reference each other's nodes.
## - Commands: any window calls command(name, args). Services connect to
##   command_requested and handle the names they own (see docs/WINDOWS_AND_BUS.md
##   for the table). Unknown commands are ignored, so a window can run without
##   the service that would answer it (scene-only mode has no controller).
##
## Scripts run with `--script` (tests) have no autoload globals, so code reaches
## the bus through PlayerBus.instance() / `preload("res://player_bus.gd").instance()`
## instead of the global name.

signal command_requested(name: StringName, args: Dictionary)
signal transport_changed(state: String)
signal track_changed(index: int, title: String)
signal position_changed(position: float, duration: float)
signal playlist_changed()
signal volume_changed(volume: float, muted: bool)
signal modes_changed(shuffle: bool, repeat_mode: int)
signal scene_list_changed()
signal scene_changed(index: int)
## The director has chosen the next scene but is waiting for a musical boundary:
## the visualiser may build it offscreen now (index -1 = cancelled). Phase 4e.
signal scene_prepare(index: int)
## Per-track scene pins changed (stored with the playlist by AudioService).
signal scene_pins_changed()
signal cycling_changed()
signal tuning_changed(response: float, brightness: float)
signal analysis_frame(signals: Dictionary)
signal status_changed(text: String)
signal windows_changed()
## The player's render scale (pixels per base unit) changed; the visualiser
## frame draws its chrome at the same scale.
signal player_scale_changed(scale: float)
## Per-loaded-scene facts from the visualiser: {presets: PackedStringArray,
## preset_index: int, tuning_supported: bool}.
signal scene_info_changed()
## Reactivity layer state changed (settings or source; see `reactivity`).
signal reactivity_changed()
## Classic/Modern render state (Phase 4c): see publish_render.
signal render_changed()
## Scene input source chosen by the visualiser: "real" or "mock" (+ bpm, schedule).
signal analysis_source_changed(source: String)
## Apple Music library data or its state changed (see `library`, `library_state`).
signal library_changed()

## Playlist entry prefix for a track the Music app plays (streaming, cloud or
## protected): "applemusic:<16 hex persistent ID>". See docs/APPLE_MUSIC.md.
const APPLE_MUSIC_PREFIX := "applemusic:"
## Local files AudioService can play (MP3 natively, the rest via Core Audio).
const AUDIO_EXTENSIONS := ["flac", "mp3", "m4a", "aac", "aiff", "aif", "wav", "caf", "alac"]
## FileDialog.filters for "add files" pickers.
const AUDIO_FILE_FILTERS := ["*.flac,*.mp3,*.m4a,*.aac,*.aiff,*.aif,*.wav,*.caf,*.alac,*.m3u,*.m3u8 ; Audio files and M3U playlists", "*.m3u,*.m3u8 ; M3U playlists"]

## "stopped" | "playing" | "paused" | "loading"
var transport := "stopped"
var track_index := -1
var track_title := ""
var position := 0.0
var duration := 0.0
var playlist: PackedStringArray = PackedStringArray()
## Indices that failed to decode (shown dimmed).
var failed_tracks: Array[int] = []
var volume := 1.0
var muted := false
var shuffle := false
## PlaybackQueue.Repeat: 0 OFF, 1 ALL, 2 ONE.
var repeat_mode := 1
## [{name, title, version, path}]
var scenes: Array = []
var scene_index := -1
## mode: "time" | "track" | "section"; musical: switch on a downbeat/phrase;
## transition: cut | crossfade | dip | iris; transition_seconds: blend length.
## per_track is kept as an alias of mode == "track".
var cycling := {"enabled": false, "interval": 60, "order": "random", "per_track": false, "mode": "time", "musical": true, "transition": "crossfade", "transition_seconds": 2.0}
## Why the last scene change happened: "user" | "cycle" | "pin" | "track" | "section".
var scene_reason := "user"
## Track path -> scene folder path chosen with "Pin scene to this track".
var scene_pins := {}
var response := 1.0
var brightness := 1.0
var status := ""
var last_analysis: Dictionary = {}
var scene_info: Dictionary = {"presets": PackedStringArray(), "preset_index": 0, "tuning_supported": false}
## Published by ReactivityService: {sensitivity, camera_intensity,
## effects_intensity, prefetch, source ("pre-analysed" | "live" | "mock" |
## "idle"), analysing (path being analysed or ""), track_bpm}.
var reactivity: Dictionary = {}
## {mode, effective, scene_override, modern_available, modern_active, quality,
##  effects}; commands: toggle_render_mode {scope: "global"|"scene"},
## set_render_mode {mode, scope}, set_modern_quality {quality},
## set_modern_effects {particles?, trails?, dof?, post?}.
var render: Dictionary = {}
## Published by the visualiser: "real" | "mock".
var analysis_source := "real"
## Apple Music library, published by MusicBridge (empty until loaded):
## {tracks: {id: track}, order: [id], playlists: [{id, name, track_ids}],
##  artists: {name: [id]}, albums: {"<artist> — <album>": {title, artist, track_ids}},
##  by_location: {file path: id}, count: int, updated: unix seconds}.
## Each track is the helper's JSON object plus `entry` (the playlist entry it adds).
var library: Dictionary = {}
## "empty" | "cached" | "refreshing" | "ready" | "error"
var library_state := "empty"
## Mock feed parameters when analysis_source == "mock": {bpm, schedule}.
var mock_params: Dictionary = {}
var visualiser_visible := true
var visualiser_fullscreen := false
var controller_present := false
var controller_visible := true
var drawer_open := false
## Set by the player window: the library browser panel is shown (LIB lit).
var library_open := false
## Pixels per base unit of the player windows (PlayerWindow.ui_scale).
var player_scale := 2.0
## Set by the main composer: true when there is no control window.
var scene_only := false
## Set by the visualiser: Callable(event: InputEventKey) -> bool. Plain
## (unmodified) keys go here first, so the scene runtime can claim original
## style toggles (T/W/S/L/C/P/F3, M/N, F5-F8) before player hotkeys run.
var scene_key_handler: Callable

static func instance() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: return null
	var node := tree.root.get_node_or_null("PlayerBus")
	if node != null: return node
	# No autoload (--script tests): create one; usable before the deferred add lands.
	if tree.root.has_meta("player_bus"): return tree.root.get_meta("player_bus")
	node = load("res://player_bus.gd").new()
	node.name = "PlayerBus"
	tree.root.set_meta("player_bus", node)
	tree.root.add_child.call_deferred(node)
	return node

func command(name: StringName, args: Dictionary = {}) -> void:
	command_requested.emit(name, args)

func publish_transport(state: String) -> void:
	if state == transport: return
	transport = state
	transport_changed.emit(state)

func publish_track(index: int, title: String) -> void:
	track_index = index
	track_title = title
	track_changed.emit(index, title)

func publish_position(seconds: float, length: float) -> void:
	position = seconds
	duration = length
	position_changed.emit(seconds, length)

func publish_playlist(paths: PackedStringArray, current: int, failed: Array[int] = []) -> void:
	playlist = paths
	track_index = current
	failed_tracks = failed.duplicate()
	playlist_changed.emit()

func publish_volume(value: float, is_muted: bool) -> void:
	volume = clampf(value, 0.0, 1.0)
	muted = is_muted
	volume_changed.emit(volume, muted)

func publish_modes(is_shuffle: bool, mode: int) -> void:
	shuffle = is_shuffle
	repeat_mode = mode
	modes_changed.emit(shuffle, repeat_mode)

func publish_scenes(list: Array) -> void:
	scenes = list
	scene_list_changed.emit()

func publish_scene(index: int, reason := "user") -> void:
	scene_index = index
	scene_reason = reason
	scene_changed.emit(index)

func publish_scene_prepare(index: int) -> void:
	scene_prepare.emit(index)

func publish_scene_pins(pins: Dictionary) -> void:
	scene_pins = pins.duplicate()
	scene_pins_changed.emit()

func publish_cycling(settings: Dictionary) -> void:
	cycling = settings.duplicate()
	cycling_changed.emit()

func publish_tuning(response_scale: float, brightness_scale: float) -> void:
	response = response_scale
	brightness = brightness_scale
	tuning_changed.emit(response, brightness)

func publish_scene_info(info: Dictionary) -> void:
	scene_info = info
	scene_info_changed.emit()

func publish_analysis(signals: Dictionary) -> void:
	last_analysis = signals
	analysis_frame.emit(signals)

func publish_reactivity(state: Dictionary) -> void:
	reactivity = state
	reactivity_changed.emit()

func publish_render(state: Dictionary) -> void:
	render = state
	render_changed.emit()

func publish_analysis_source(source: String, params: Dictionary = {}) -> void:
	analysis_source = source
	mock_params = params
	analysis_source_changed.emit(source)

func publish_library(data: Dictionary, state: String) -> void:
	library = data
	library_state = state
	library_changed.emit()

## Display metadata for a playlist entry (file path or applemusic:<ID>):
## {title, artist, album, duration (seconds, 0 = unknown), source: "file" | "applemusic"}.
## Library lookups first; otherwise the title is the file name without extension.
func track_meta(path: String) -> Dictionary:
	var apple := path.begins_with(APPLE_MUSIC_PREFIX)
	var id := path.trim_prefix(APPLE_MUSIC_PREFIX) if apple else str(library.get("by_location", {}).get(path, ""))
	var track: Dictionary = library.get("tracks", {}).get(id, {})
	var fallback := "Apple Music track" if apple else path.get_file().get_basename()
	if not track.is_empty():
		var title := str(track.get("title", ""))
		return {"title": title if not title.is_empty() else fallback, "artist": str(track.get("artist", "")), "album": str(track.get("album", "")),
			"duration": float(track.get("duration_ms", 0)) / 1000.0, "source": "applemusic" if apple else "file"}
	return {"title": fallback, "artist": "", "album": "", "duration": 0.0, "source": "applemusic" if apple else "file"}

func publish_status(text: String) -> void:
	status = text
	status_changed.emit(text)

func publish_windows(visualiser_shown: bool, fullscreen: bool, controller_shown: bool, drawer: bool) -> void:
	visualiser_visible = visualiser_shown
	visualiser_fullscreen = fullscreen
	controller_visible = controller_shown
	drawer_open = drawer
	windows_changed.emit()

func publish_player_scale(scale: float) -> void:
	player_scale = scale
	player_scale_changed.emit(scale)

func scene_title(index: int = -1) -> String:
	var i := scene_index if index < 0 else index
	if i < 0 or i >= scenes.size(): return ""
	var title := str(scenes[i].get("title", scenes[i].get("name", "")))
	return title + " (partly reconstructed)" if scenes[i].get("reconstructed", false) else title

## Route a key press from any window. Returns true when consumed.
## source: "visualiser" | "controller" (passed on as args.source).
func handle_key(event: InputEventKey, source: String = "") -> bool:
	if not event.pressed: return false
	if Hotkeys.scene_may_claim(event) and scene_key_handler.is_valid() and not event.echo:
		if bool(scene_key_handler.call(event)): return true
	var action := Hotkeys.action_for(event)
	if action.name == &"": return false
	if event.echo and not Hotkeys.REPEATABLE.has(action.name): return true
	var args: Dictionary = action.args.duplicate()
	args.source = source
	command(action.name, args)
	return true

const Hotkeys = preload("res://hotkeys.gd")
