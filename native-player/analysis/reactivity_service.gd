extends Node
## ReactivityService: the app-wide reactivity layer, registered as the autoload
## "ReactivityService". Every scene and window reads the same data from it:
##
##   var rx = preload("res://analysis/reactivity_service.gd").instance()
##   rx.frame              # ReactFrame (hub output, updated once per render frame)
##   rx.mapper.effect("pulse"), rx.mapper.camera("impact")   # reaction channels
##   rx.hub.beat.connect(...)   rx.mapper.impact_fired.connect(...)
##
## It owns one Reactivity hub and one ReactivityMapper and picks the hub's
## source on its own:
##   - track starts (AudioService.stream_started): the analysis cache (memory,
##     then disk) is checked synchronously; a hit drives the hub from the
##     pre-analysed TrackSource at once. On a miss an AnalysisJob starts on a
##     low-priority worker thread and a LiveAnalyzer runs on the PCM that
##     AudioService captures from the SceneAnalysis bus until the job finishes;
##     then the hub cross-fades to the TrackSource over SWAP_BLEND seconds
##     (no jumps in smoothed values; events re-baseline without firing).
##   - seeks rebase the hub clock (no events for the skipped span, no snapping);
##     pause freezes hub and channels; stop cross-fades to silence so channels
##     release gently; a track change cross-fades from the last values.
##   - mock mode (Settings > Scene input "Synthetic beat", --mock-audio): the
##     hub runs the SyntheticSource that matches the visualiser's mock feed
##     (same BPM, phase and section schedule) on its own clock.
##   - after the current track, the next 1-2 playlist entries are pre-analysed
##     in the background (setting "prefetch"; sequential order only, since
##     shuffle picks at random when the track ends).
##
## Classic scenes are unaffected: they keep the original audio_inputs.gd path.
## Scripts run with --script (tests) have no autoloads; instance() creates one.
## See docs/REACTIVITY_API.md.

const Reactivity := preload("res://analysis/reactivity.gd")
const ReactivityMapper := preload("res://analysis/reactivity_mapper.gd")
const TrackSource := preload("res://analysis/track_source.gd")
const LiveAnalyzer := preload("res://analysis/live_analyzer.gd")
const SyntheticSource := preload("res://analysis/synthetic_source.gd")
const AnalysisJob := preload("res://analysis/analysis_job.gd")
const AnalysisCache := preload("res://analysis/analysis_cache.gd")
const FeatureExtractor := preload("res://analysis/feature_extractor.gd")
const AppSettings := preload("res://app_settings.gd")
const PlayerBusScript := preload("res://player_bus.gd")

signal source_changed(kind: String)
signal analysis_ready(path: String, analysis)

## Cross-fade lengths (seconds of hub time).
const SWAP_BLEND := 2.0
const TRACK_BLEND := 0.75
const STOP_BLEND := 0.6
const SOURCE_BLEND := 0.5
## The service clock follows the audio clock smoothly; larger errors snap.
const CLOCK_SNAP := 0.25
const CLOCK_GAIN := 4.0
const MEMORY_SLOTS := 3
const PREFETCH_COUNT := 2

var hub
var mapper
var frame:
	get: return hub.frame
## "idle" | "live" | "pre-analysed" | "mock"
var source_kind := "idle"
## TrackAnalysis of the current track once available (else null).
var analysis = null
var current_path := ""
var settings := AppSettings.REACTIVITY_DEFAULTS.duplicate()
var settings_path := AppSettings.PATH
var persist := true
## Hub clock: playback position while playing, own clock in mock/idle.
var clock := 0.0
## False: the owner calls tick(delta) itself (tests).
var auto_tick := true:
	set(v):
		auto_tick = v
		set_process(v)
var audio
var bus
var live = null
var _live_clock = null
var _mock = null
var _job = null
var _job_path := ""
var _retired: Array = []
var _queue: PackedStringArray = PackedStringArray()
var _memory := {}
var _memory_order: Array = []
var _stopped := true
var _silent := func(_t): return {"bands": PackedFloat32Array([0, 0, 0, 0, 0, 0]), "energy": 0.0, "flux": 0.0}
var _settings_loaded := false

## Maps playback time onto a LiveAnalyzer's stream clock.
class LiveClock:
	var live
	var offset := 0.0
	func _init(analyzer, start: float) -> void:
		live = analyzer
		offset = start
	func sample(t: float) -> Dictionary:
		return live.sample(t - offset)

static func instance() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: return null
	var node := tree.root.get_node_or_null("ReactivityService")
	if node != null: return node
	if tree.root.has_meta("reactivity_service"): return tree.root.get_meta("reactivity_service")
	node = load("res://analysis/reactivity_service.gd").new()
	tree.root.set_meta("reactivity_service", node)
	tree.root.add_child.call_deferred(node)
	return node

func _init() -> void:
	name = "ReactivityService"
	process_priority = -50
	hub = Reactivity.new()
	hub.name = "Hub"
	add_child(hub)
	mapper = ReactivityMapper.new()
	hub.set_source(_silent)

func _ready() -> void:
	# Wired here, not in _init: autoloads are all constructed before any is
	# added to the tree, so PlayerBus is only reachable from _ready on.
	bus = PlayerBusScript.instance()
	if bus != null:
		bus.command_requested.connect(_on_command)
		bus.transport_changed.connect(_on_transport)
		bus.analysis_source_changed.connect(_on_analysis_source)
	set_process(auto_tick)
	if not _settings_loaded: load_settings()
	if bus != null and bus.analysis_source == "mock" and _mock == null: _on_analysis_source("mock")

func load_settings() -> void:
	_settings_loaded = true
	settings = AppSettings.load_reactivity(settings_path) if persist else AppSettings.REACTIVITY_DEFAULTS.duplicate()
	_apply_settings()
	_publish()

## Merge {sensitivity?, camera_intensity?, effects_intensity?, prefetch?},
## apply, persist ([reactivity] in settings.cfg) and publish on the bus.
func set_reactivity(changes: Dictionary) -> void:
	var merged := settings.duplicate()
	for key in changes:
		if merged.has(key): merged[key] = changes[key]
	settings = AppSettings.sanitize_reactivity(merged)
	_apply_settings()
	if persist and not settings_path.is_empty(): AppSettings.save_reactivity(settings_path, settings)
	if bool(settings.prefetch): _schedule_prefetch()
	_publish()

func _apply_settings() -> void:
	mapper.sensitivity = float(settings.sensitivity)
	mapper.camera_intensity = float(settings.camera_intensity)
	mapper.effects_intensity = float(settings.effects_intensity)

func _on_command(command: StringName, args: Dictionary) -> void:
	if command == &"set_reactivity": set_reactivity(args)

# --- Audio wiring -------------------------------------------------------------

## Called by AudioService._ready. The service listens for stream starts and
## seeks, reads the playback clock, and receives captured PCM via push_pcm().
func attach_audio(service) -> void:
	audio = service
	persist = bool(service.persist)
	settings_path = service.settings_path
	if not _settings_loaded: load_settings()
	service.stream_started.connect(track_started)
	service.seeked.connect(seeked)
	service.tree_exiting.connect(func(): if audio == service: audio = null)

## Rate of the PCM AudioService pushes (the Apple Music tap rate while the
## Music app plays; the mix rate otherwise).
func _pcm_rate() -> float:
	return float(audio.pcm_rate()) if audio != null and audio.has_method("pcm_rate") else AudioServer.get_mix_rate()

## Entries that can only be analysed live: Apple Music tracks are DRM-protected
## streams played by the Music app, never decoded (docs/APPLE_MUSIC.md).
static func is_live_only(path: String) -> bool:
	return path.begins_with("applemusic:")

## Captured stereo PCM from the analysis bus (AudioService._process).
func push_pcm(frames: PackedVector2Array) -> void:
	if live != null and frames.size() > 0 and (source_kind == "live" or hub.is_blending()):
		live.push_frames(frames)

func track_started(path: String, position: float = 0.0) -> void:
	current_path = path
	analysis = null
	_stopped = false
	clock = position
	live = LiveAnalyzer.new(_pcm_rate())
	_live_clock = LiveClock.new(live, position)
	if _mock != null:
		_request(path, true)
		return
	var cached = _lookup(path)
	if cached != null:
		_use_analysis(cached, TRACK_BLEND, true)
	else:
		hub.set_source(_live_clock, TRACK_BLEND, true)
		_set_kind("live")
		_request(path, true)
	hub.rebase(position)
	_schedule_prefetch()

func seeked(position: float) -> void:
	clock = position
	if live != null and _live_clock != null: _live_clock.offset = position - live.stream_time
	if _mock == null: hub.rebase(position)

func _on_transport(state: String) -> void:
	if state == "playing" and _stopped and not current_path.is_empty():
		# Play after Stop restarts the same stream without a stream_started.
		_stopped = false
		live = LiveAnalyzer.new(_pcm_rate())
		_live_clock = LiveClock.new(live, audio.playback_time() if audio != null else 0.0)
		if _mock == null: _reselect(SOURCE_BLEND)
	elif state == "stopped" and not _stopped:
		_stopped = true
		live = null
		if _mock == null:
			hub.set_source(_silent, STOP_BLEND, true)
			_set_kind("idle")

func _on_analysis_source(source: String) -> void:
	if source == "mock":
		var params: Dictionary = bus.mock_params if bus != null else {}
		set_mock(float(params.get("bpm", 128.0)), params.get("schedule", SyntheticSource.SCHEDULE))
	else:
		clear_mock()

## Drive the hub from the synthetic source (restarts its clock at 0, as the
## visualiser restarts the scene and its mock feed).
func set_mock(bpm: float, schedule: Array = SyntheticSource.SCHEDULE) -> void:
	_mock = SyntheticSource.new(bpm, schedule)
	clock = 0.0
	hub.set_source(_mock)
	mapper.reset()
	_set_kind("mock")

func clear_mock() -> void:
	if _mock == null: return
	_mock = null
	if not _stopped and not current_path.is_empty():
		_reselect(SOURCE_BLEND)
	else:
		hub.set_source(_silent, SOURCE_BLEND, true)
		_set_kind("idle")

## Back to the current track's best source (pre-analysed, else live) at the
## audio clock, cross-fading from the last values.
func _reselect(blend: float) -> void:
	clock = audio.playback_time() if audio != null else clock
	if analysis == null: analysis = _lookup(current_path)
	if analysis != null: _use_analysis(analysis, blend, true)
	elif _live_clock != null:
		hub.set_source(_live_clock, blend, true)
		_set_kind("live")
		_request(current_path, true)
	hub.rebase(clock)

func is_mock() -> bool: return _mock != null

# --- Per frame ------------------------------------------------------------------

func _process(delta: float) -> void:
	tick(delta)

func tick(delta: float) -> void:
	_poll_job()
	if _mock != null:
		clock += delta
		hub.update_time(clock, delta)
		mapper.update(hub.frame, delta)
		return
	var playing: bool = audio != null and audio.is_playing()
	if playing and not _stopped:
		var raw: float = audio.playback_time()
		var next := clock + delta
		var err := raw - next
		if absf(err) > CLOCK_SNAP:
			clock = raw
			hub.rebase(raw)
		else:
			clock = maxf(clock, next + err * minf(1.0, delta * CLOCK_GAIN))
		hub.update_time(clock, delta)
		mapper.update(hub.frame, delta)
		if source_kind == "pre-analysed" and live != null and not hub.is_blending(): live = null
	elif _stopped:
		clock += delta
		hub.update_time(clock, delta)
		mapper.update(hub.frame, delta)
	# else paused (or loading with nothing playing): hub and channels hold.

# --- Pre-analysis ---------------------------------------------------------------

func _use_analysis(a, blend: float, hold: bool) -> void:
	analysis = a
	hub.set_source(TrackSource.new(a), blend, hold)
	if hold: live = null
	_set_kind("pre-analysed")

func _lookup(path: String):
	if _memory.has(path):
		_touch(path)
		return _memory[path]
	var a = AnalysisCache.load_for(path) if not is_live_only(path) and FileAccess.file_exists(path) else null
	if a != null: _remember(path, a)
	return a

func _remember(path: String, a) -> void:
	_memory[path] = a
	_touch(path)
	while _memory_order.size() > MEMORY_SLOTS:
		var victim = _memory_order[0]
		if victim == current_path and _memory_order.size() > 1: victim = _memory_order[1]
		_memory_order.erase(victim)
		_memory.erase(victim)

func _touch(path: String) -> void:
	_memory_order.erase(path)
	_memory_order.append(path)

## True when `path` has an analysis in memory or in the disk cache.
func has_analysis(path: String) -> bool:
	if _memory.has(path): return true
	if is_live_only(path): return false
	var p := AnalysisCache.path_for(path)
	return not p.is_empty() and FileAccess.file_exists(p)

func _request(path: String, front: bool) -> void:
	if path.is_empty() or is_live_only(path) or _memory.has(path) or path == _job_path: return
	var i := _queue.find(path)
	if i >= 0: _queue.remove_at(i)
	if front: _queue.insert(0, path)
	else: _queue.append(path)
	_start_next()

func _start_next() -> void:
	if _job != null or _queue.is_empty(): return
	var path := _queue[0]
	_queue.remove_at(0)
	var job = AnalysisJob.new()
	if job.start(path):
		_job = job
		_job_path = path
		# Keep the job alive until its deferred `finished` fires.
		_retired.append(job)
		job.finished.connect(func(_r): _retired.erase(job))
	_publish()

func _poll_job() -> void:
	if _job == null or not _job.is_done(): return
	var result: Dictionary = _job.take_result()
	var path := _job_path
	_job = null
	_job_path = ""
	if result.has("analysis"):
		_remember(path, result.analysis)
		analysis_ready.emit(path, result.analysis)
		if path == current_path and _mock == null and not _stopped and source_kind != "pre-analysed":
			# Hot swap: keep feeding the live analyzer while the cross-fade runs.
			_use_analysis(result.analysis, SWAP_BLEND, false)
		elif path == current_path:
			analysis = result.analysis
	_start_next()
	_publish()

## Background pre-analysis of the next PREFETCH_COUNT playlist entries.
func _schedule_prefetch() -> void:
	if not bool(settings.prefetch) or audio == null or not audio.has_method("upcoming_paths"): return
	for path in audio.upcoming_paths(PREFETCH_COUNT):
		if path != current_path and not has_analysis(path): _request(path, false)

## Blocks until the running job (if any) finishes; used by tests.
func wait_for_analysis() -> void:
	while _job != null:
		_job.take_result()
		_poll_job()

func is_analysing() -> bool: return _job != null

func _exit_tree() -> void:
	if _job != null:
		FeatureExtractor.abort = true
		_job.take_result()
		FeatureExtractor.abort = false
		_job = null

# --- Publishing -------------------------------------------------------------------

func _set_kind(kind: String) -> void:
	if kind == source_kind: return
	source_kind = kind
	source_changed.emit(kind)
	_publish()

func _publish() -> void:
	if bus == null: return
	var state := settings.duplicate()
	state.source = source_kind
	state.analysing = _job_path.get_file()
	state.track_bpm = analysis.bpm if analysis != null else 0.0
	bus.publish_reactivity(state)

## Everything the F3 overlay shows about the reactivity layer.
func debug_info() -> Dictionary:
	var f = hub.frame
	return {
		"source": source_kind, "analysing": _job_path.get_file(), "bands": f.bands.duplicate(),
		"beat": f.beat, "downbeat": f.downbeat, "bpm": f.bpm, "confidence": f.confidence,
		"section": f.section, "build_progress": f.build_progress, "time_to_drop": f.time_to_drop,
		"intensity": f.intensity_name, "energy": f.energy, "time": f.time,
		"channels": mapper.snapshot(), "blending": hub.is_blending(),
	}
