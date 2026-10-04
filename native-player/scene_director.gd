extends Node
## Non-visual scene selection and multi-scene cycling. The visualiser loads
## whatever PlayerBus.scene_changed announces; any window selects through
## commands. Cycling follows the original LAVA.exe multi-scene options
## (Lava3.crl DLG 136, HKCU ...\LAVA Player\MultiScene {OnOff, Random, Time}):
## interval 30 s, 1, 2, 3, 5, 10, 30 min or 1 h; random or alphabetical order.
##
## Phase 4e additions (not in the original, which hard-switched on a timer;
## Oozic 3 had per-scene TFX transitions, see docs/TRANSITIONS.md):
## - cycle mode: "time" (the original timer), "track" (each new track moves to
##   the next scene) or "section" (a major section boundary, at most once per
##   SECTION_MIN_GAP seconds);
## - musical timing: a due automatic change waits for a downbeat or phrase
##   start (not mid-drop; a drop itself is a fine moment). A manual choice goes
##   on the next beat when one is under half a second away, else at once;
## - per-track pins: "Pin scene to this track" remembers a scene for a file.
##   Pins are stored with the playlist (AudioService) and beat the cycle mode.
const SceneCatalog = preload("res://scene_catalog.gd")
const AppSettings = preload("res://app_settings.gd")
const PlayerBusScript = preload("res://player_bus.gd")
const SceneTransition = preload("res://scene_transition.gd")
const INTERVALS := [30, 60, 120, 180, 300, 600, 1800, 3600]
const MODES := ["time", "track", "section"]
## Longest a due change waits for a musical boundary before it goes anyway.
const MAX_WAIT := 10.0
## A manual pick this close to the next beat waits for it.
const MANUAL_BEAT_WINDOW := 0.5
const SECTION_MIN_GAP := 60.0
const MAJOR_SECTIONS := ["build", "drop", "breakdown"]

var bus
var scenes: Array = []
var current := -1
var cycling := {"enabled": false, "interval": 60, "order": "random", "per_track": false, "mode": "time", "musical": true, "transition": "crossfade", "transition_seconds": 2.0}
var elapsed := 0.0
var rng := RandomNumberGenerator.new()
var settings_path := AppSettings.PATH
var persist := true
## Reactivity provider (object with `.frame` and `.hub`); the autoload when present, a stub in tests.
var rx = null
## A change waiting for its boundary: {index, reason, kind: "cycle"|"beat", waited, deadline}.
var pending := {}
var _section_connected := false

func _init(persistent := true):
	persist = persistent
	name = "SceneDirector"
	# Original multi-scene random order: srand(time(NULL)) in LAVA.exe.
	rng.randomize()
	# Tests build non-persistent directors and expect immediate, hard switches.
	if not persist:
		cycling.transition = "cut"
		cycling.musical = false

func _ready():
	bus = PlayerBusScript.instance()
	bus.command_requested.connect(_on_command)
	bus.track_changed.connect(_on_track_changed)
	scenes = SceneCatalog.load_catalog()
	if persist:
		var values := AppSettings.load_section(settings_path, "scenes")
		cycling = normalise_cycling({
			"enabled": values.get("cycle_enabled", cycling.enabled),
			"interval": values.get("cycle_interval", cycling.interval),
			"order": values.get("cycle_order", cycling.order),
			"per_track": values.get("cycle_per_track", cycling.per_track),
			"mode": values.get("cycle_mode", ""),
			"musical": values.get("cycle_musical", cycling.musical),
			"transition": values.get("transition_style", cycling.transition),
			"transition_seconds": values.get("transition_seconds", cycling.transition_seconds)})
	bus.publish_scenes(scenes)
	bus.publish_cycling(cycling)
	_connect_section()

## Index of the scene to show first: saved name, else Triple Trance (index 0).
func initial_index() -> int:
	if persist:
		var saved := str(AppSettings.load_section(settings_path, "scenes").get("last_scene", ""))
		for i in scenes.size():
			if scenes[i].path == saved: return i
	return 0

# --- Selecting ----------------------------------------------------------------

## Choose a scene. User picks go on the next beat if one is under half a second
## away (and musical timing is on), otherwise at once.
func select(index: int, reason := "user"):
	if scenes.is_empty(): return
	index = clampi(index, 0, scenes.size() - 1)
	cancel_pending()
	if reason == "user" and cycling.musical:
		var f := frame_view()
		if musical_ready(f):
			var wait := time_to_beat(f)
			if wait > 0.02 and wait < MANUAL_BEAT_WINDOW:
				pending = {"index": index, "reason": reason, "kind": "beat", "waited": 0.0, "deadline": MANUAL_BEAT_WINDOW + 0.2}
				bus.publish_scene_prepare(index)
				return
	commit(index, reason)

func commit(index: int, reason: String):
	pending = {}
	current = clampi(index, 0, scenes.size() - 1)
	elapsed = 0.0
	if persist: AppSettings.save_section(settings_path, "scenes", {"last_scene": scenes[current].path})
	bus.publish_scene(current, reason)
	if reason != "user": bus.publish_status("Scene: " + bus.scene_title(current) + (" (pinned)" if reason == "pin" else ""))

func cancel_pending():
	if pending.is_empty(): return
	pending = {}
	bus.publish_scene_prepare(-1)

func _on_command(command: StringName, args: Dictionary):
	match command:
		&"select_scene": select(int(args.get("index", 0)))
		&"next_scene": select(step_index(current, scenes, "alphabetical", 1, rng))
		&"previous_scene": select(step_index(current, scenes, "alphabetical", -1, rng))
		&"set_cycling": set_cycling(args)
		&"pin_scene": pin_current_scene()
		&"unpin_scene": unpin_current_track()

func set_cycling(changes: Dictionary):
	var incoming := changes.duplicate()
	var merged := cycling.duplicate()
	# Older callers send per_track; it maps onto the cycle mode.
	if incoming.has("per_track"):
		if not incoming.has("mode"): incoming["mode"] = "track" if bool(incoming.per_track) else ("time" if str(merged.mode) == "track" else merged.mode)
		incoming.erase("per_track")
	merged.merge(incoming, true)
	cycling = normalise_cycling(merged)
	elapsed = 0.0
	cancel_pending()
	bus.publish_cycling(cycling)
	_connect_section()
	if persist: AppSettings.save_section(settings_path, "scenes", {"cycle_enabled": cycling.enabled, "cycle_interval": cycling.interval, "cycle_order": cycling.order, "cycle_per_track": cycling.per_track, "cycle_mode": cycling.mode, "cycle_musical": cycling.musical, "transition_style": cycling.transition, "transition_seconds": cycling.transition_seconds})

# --- Tracks and pins -----------------------------------------------------------

func track_path(index := -1) -> String:
	var i: int = bus.track_index if index < 0 else index
	return str(bus.playlist[i]) if i >= 0 and i < bus.playlist.size() else ""

func _on_track_changed(index: int, _title: String):
	if index < 0 or scenes.is_empty(): return
	var pinned := pinned_scene_index(track_path(index))
	if pinned >= 0:
		if pinned != current: commit(pinned, "pin")
		return
	# A restored playlist announces its track while nothing plays: not a new track.
	if cycling.enabled and cycling.mode == "track" and bus.transport != "stopped" and scenes.size() > 1: cycle_now("track")

func pinned_scene_index(path: String) -> int:
	if path.is_empty() or not bus.scene_pins.has(path): return -1
	var folder := str(bus.scene_pins[path])
	for i in scenes.size():
		if scenes[i].path == folder: return i
	return -1

func pin_current_scene():
	var path := track_path()
	if path.is_empty() or current < 0:
		bus.publish_status("Nothing to pin: play a track first.")
		return
	var pins: Dictionary = bus.scene_pins.duplicate()
	pins[path] = scenes[current].path
	bus.publish_scene_pins(pins)
	bus.publish_status("Pinned %s to %s" % [bus.scene_title(current), path.get_file()])

func unpin_current_track():
	var path := track_path()
	if path.is_empty() or not bus.scene_pins.has(path):
		bus.publish_status("This track has no pinned scene.")
		return
	var pins: Dictionary = bus.scene_pins.duplicate()
	pins.erase(path)
	bus.publish_scene_pins(pins)
	bus.publish_status("Unpinned the scene from " + path.get_file())

# --- Cycling -------------------------------------------------------------------

func cycle_now(reason := "cycle"):
	commit(step_index(current, scenes, cycling.order, 1, rng), reason)

## Advance the cycling timer; returns true when it switched scene.
func tick(delta: float) -> bool:
	elapsed += delta
	if not pending.is_empty(): return _tick_pending(delta)
	if not cycling.enabled or scenes.size() < 2 or cycling.mode != "time": return false
	if elapsed < float(cycling.interval): return false
	var f := frame_view()
	if cycling.musical and musical_ready(f):
		# Choose now and let the visualiser build it while we wait for the boundary.
		var target := step_index(current, scenes, cycling.order, 1, rng)
		pending = {"index": target, "reason": "cycle", "kind": "cycle", "waited": 0.0}
		bus.publish_scene_prepare(target)
		return _tick_pending(0.0)
	cycle_now()
	return true

func _tick_pending(delta: float) -> bool:
	pending["waited"] = float(pending.waited) + delta
	var f := frame_view()
	var go := false
	if pending.kind == "beat":
		go = bool(f.get("beat", false)) or float(pending.waited) >= float(pending.deadline)
	else:
		go = not musical_ready(f) or boundary_ok(f, float(pending.waited))
	if not go: return false
	commit(int(pending.index), str(pending.reason))
	return true

func _process(delta):
	tick(delta)

## Section boundary (hub.section_changed): major sections move to the next scene
## in "section" mode, at most once per SECTION_MIN_GAP.
func on_section_changed(type: String):
	if not cycling.enabled or cycling.mode != "section" or scenes.size() < 2: return
	if not MAJOR_SECTIONS.has(type) or elapsed < SECTION_MIN_GAP: return
	cycle_now("section")

func _connect_section():
	if _section_connected or cycling.mode != "section": return
	var provider = _reactivity()
	if provider == null or provider.get("hub") == null: return
	provider.hub.section_changed.connect(on_section_changed)
	_section_connected = true

## The reactivity service if the app has one; never created just for the director.
func _reactivity():
	if rx != null: return rx
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null and tree.root != null and tree.root.has_node("ReactivityService"): rx = tree.root.get_node("ReactivityService")
	return rx

# --- Musical timing ------------------------------------------------------------

## The fields the scheduler reads from the current ReactFrame, as a Dictionary.
func frame_view() -> Dictionary:
	var provider = _reactivity()
	var frame = provider.frame if provider != null else null
	if frame == null: return {}
	var out := {}
	for key in ["bpm", "confidence", "beat", "downbeat", "phrase", "drop", "section", "time_to_drop", "time_to_next_beat", "beat_phase"]:
		var value = frame.get(key)
		if value != null: out[key] = value
	return out

## True when the frame carries a usable tempo.
static func musical_ready(f: Dictionary) -> bool:
	return float(f.get("bpm", 0.0)) >= 40.0 and float(f.get("confidence", 0.0)) >= 0.3

## Seconds to the next beat: the lookahead field when finite, else from the beat phase.
static func time_to_beat(f: Dictionary) -> float:
	var ahead := float(f.get("time_to_next_beat", INF))
	if is_finite(ahead): return ahead
	var bpm := float(f.get("bpm", 0.0))
	return (1.0 - float(f.get("beat_phase", 0.0))) * 60.0 / bpm if bpm > 0.0 else INF

## Should a due automatic change fire on this frame? A downbeat or phrase start
## qualifies; inside a drop only a phrase start does; the frame a drop begins
## qualifies (the new scene arrives with the drop); a drop under a bar away
## holds the change for that frame; MAX_WAIT forces it.
static func boundary_ok(f: Dictionary, waited: float) -> bool:
	if waited >= MAX_WAIT: return true
	if bool(f.get("drop", false)): return true
	var phrase_start := int(f.get("phrase", 0)) > 0
	if str(f.get("section", "")) == "drop": return phrase_start
	var bar := 240.0 / maxf(float(f.get("bpm", 120.0)), 1.0)
	if float(f.get("time_to_drop", INF)) < bar: return false
	return bool(f.get("downbeat", false)) or phrase_start

static func normalise_cycling(values: Dictionary) -> Dictionary:
	var interval := int(values.get("interval", 60))
	var nearest: int = INTERVALS[0]
	for choice in INTERVALS:
		if absi(choice - interval) < absi(nearest - interval): nearest = choice
	var mode := str(values.get("mode", ""))
	if not MODES.has(mode): mode = "track" if bool(values.get("per_track", false)) else "time"
	return {"enabled": bool(values.get("enabled", false)), "interval": nearest,
		"order": "alphabetical" if str(values.get("order", "random")) == "alphabetical" else "random",
		"per_track": mode == "track", "mode": mode, "musical": bool(values.get("musical", true)),
		"transition": SceneTransition.normalise_style(values.get("transition", SceneTransition.DEFAULT_STYLE)),
		"transition_seconds": SceneTransition.normalise_duration(values.get("transition_seconds", SceneTransition.DEFAULT_DURATION))}

static func interval_label(seconds: int) -> String:
	if seconds < 60: return "%d seconds" % seconds
	if seconds < 3600: return "%d minute%s" % [seconds / 60, "" if seconds == 60 else "s"]
	return "1 hour"

## Next scene: alphabetical by title (wrapping, direction ±1), or a random
## scene other than the current one.
static func step_index(from: int, list: Array, order: String, direction: int, generator: RandomNumberGenerator) -> int:
	if list.size() < 2: return maxi(from, 0)
	if order == "random":
		var pick := generator.randi_range(0, list.size() - 2)
		return pick + 1 if pick >= from and from >= 0 else pick
	var sorted := range(list.size())
	sorted.sort_custom(func(a, b):
		var ta := str(list[a].get("title", "")).to_lower()
		var tb := str(list[b].get("title", "")).to_lower()
		return ta < tb if ta != tb else a < b)
	var position := sorted.find(from)
	if position < 0: return sorted[0]
	return sorted[posmod(position + direction, sorted.size())]
