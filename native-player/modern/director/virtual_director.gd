extends RefCounted
## Modern virtual director (Phase 4d): picks shots from the scene profile's
## shot library and edits them to the music, then hands the pose to the
## comfort rig. Pure logic (no nodes): ModernLayer feeds it the hub frame, the
## mapper and the scene context each render frame and applies the result.
##
## Editing grammar (profile "director.grammar", per section type):
##   - shot changes only on downbeats; phrase starts (8/4 bars into the section)
##     are preferred, plain downbeats only by explicit probability
##   - every shot lasts at least max(min_bars, min_seconds) (default 2 bars, 4 s)
##     and a section's own min_bars; max_bars forces a change
##   - no immediate repeats (the current and previous shot are excluded)
##   - weighted random choice, seeded: the draw for bar N is hash(seed, N, salt),
##     so the same music gives the same edit at any frame rate
##   - quiet / breakdown: long shots, slow pace, glides (smooth moves) preferred;
##     breakdown enters on a wide shot
##   - build: push-in proportional to build_progress / anticipation; no cut is
##     allowed if it would leave less than the minimum before a known drop
##   - drop: a cut to an energetic shot on the drop downbeat, then faster pace
##     ("boost") for one phrase
##   - 30-degree rule: a cut turns the view at least min_turn degrees
## Modes: "director", "original" (no override: the recovered camera exactly),
## "locked" (static wide framing). See docs/DIRECTOR_AND_ANIMATION.md.

const ShotLibrary = preload("res://modern/director/shot_library.gd")
const CameraComfort = preload("res://modern/director/camera_comfort.gd")

const MODES := ["director", "original", "locked"]
const DEFAULT_GRAMMAR := {"min_bars": 4, "max_bars": 8, "phrase8": 1.0, "phrase4": 0.5, "downbeat": 0.0, "glide": 0.3, "pace": 1.0, "omega": 2.2, "shots": {"original": 1.0}}

var mode := "director"
var config: Dictionary = {}
var shots: Dictionary = {}
var grammar: Dictionary = {}
var seed_value := 1
var min_bars := 2
var min_seconds := 4.0
var min_turn := 35.0
var push_max := 0.28
var impact_fov := 3.5
var boost_pace := 0.6
var glide_omega := 1.1
var glide_seconds := 3.0
var glide_max_turn := 90.0
var _glide_from: Dictionary = {}
var comfort = CameraComfort.new()

# --- State ---------------------------------------------------------------
var time := -1.0
var shot: Dictionary = {}
var shot_name := ""
var previous_name := ""
var shot_start_bar := 0
var shot_start_time := 0.0
var shot_u := 0.0
var transition_kind := ""
var transition_time := -INF
var pace := 1.0
var boost := 0.0
var boost_until_bar := -1
var push := 0.0
var section := ""
var section_index := -2
var section_start_bar := 0
var last_bar := -1
var pending_energetic := false
var cuts := 0
## Every shot change: {time, bar, bar_time, kind ("cut"|"glide"|"start"), shot, section, reason}.
var cut_log: Array = []
## True on the frame a cut happened (the pose jumped on purpose).
var cut_this_frame := false
var target_pose: Dictionary = {}
var _snap_next := false
var _timeout := 0.0
var _locked_pose: Dictionary = {}

func configure(profile_director: Dictionary, scene_seed: int = 1) -> void:
	config = profile_director
	seed_value = int(config.get("seed", scene_seed))
	shots = config.get("shots", {})
	grammar = config.get("grammar", {})
	min_bars = int(config.get("min_shot_bars", min_bars))
	min_seconds = float(config.get("min_shot_seconds", min_seconds))
	min_turn = float(config.get("min_turn_deg", min_turn))
	push_max = float(config.get("push_in", push_max))
	impact_fov = float(config.get("impact_fov", impact_fov))
	boost_pace = float(config.get("boost_pace", boost_pace))
	glide_omega = float(config.get("glide_omega", glide_omega))
	glide_seconds = float(config.get("glide_seconds", glide_seconds))
	glide_max_turn = float(config.get("glide_max_turn_deg", glide_max_turn))
	comfort.configure(config.get("comfort", {}))
	reset()

func reset() -> void:
	time = -1.0
	shot = {}
	shot_name = ""
	previous_name = ""
	shot_u = 0.0
	pace = 1.0
	boost = 0.0
	boost_until_bar = -1
	push = 0.0
	section = ""
	section_index = -2
	last_bar = -1
	pending_energetic = false
	cuts = 0
	cut_log = []
	_snap_next = false
	_locked_pose = {}
	var guard: Dictionary = comfort.guard
	comfort = CameraComfort.new()
	comfort.configure(config.get("comfort", {}))
	comfort.guard = guard

## Deterministic draw in [0, 1) for a bar and a salt.
func _rand(bar: int, salt: int) -> float:
	var h: int = (bar * 73856093) ^ (salt * 19349663) ^ (seed_value * 83492791)
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return float(h & 0xffffff) / 16777216.0

func _grammar(kind: String) -> Dictionary:
	var g: Dictionary = DEFAULT_GRAMMAR.duplicate()
	g.merge(grammar.get("steady", {}), true)
	if grammar.has(kind): g.merge(grammar[kind], true)
	return g

func _bar_seconds(frame) -> float:
	return 240.0 / (float(frame.bpm) if float(frame.bpm) > 1.0 else 120.0)

## One render frame. ctx: {center, targets{name: Vector3}, original{position,
## target, fov}}. Returns {} in "original" mode (leave the camera alone), else
## {position, target, fov, focus, subject, shot}.
func update(frame, mapper, ctx: Dictionary) -> Dictionary:
	cut_this_frame = false
	if mode == "original": return {}
	if mode == "locked": return _locked(ctx)
	var now := float(frame.time)
	# The music jumped back (seek, restart, new track): start editing afresh.
	if time >= 0.0 and now < time - 0.25: reset()
	var dt := clampf(now - time, 0.0, 0.1) if time >= 0.0 else 0.0
	time = now
	var bar_len := _bar_seconds(frame)
	var intensity := float(mapper.camera_intensity) if mapper != null else 1.0
	# Wait (up to 1 s) for the first section so the opening shot fits it.
	if shot.is_empty() and int(frame.section_index) < 0 and now < 1.0: return {}
	var entered := false
	if int(frame.section_index) != section_index:
		entered = section_index >= 0
		section_index = int(frame.section_index)
		section = str(frame.section)
		section_start_bar = maxi(int(frame.bar_index), 0)
	if shot.is_empty(): _start(frame, ctx)
	var bar := int(frame.bar_index)
	if bar > last_bar and bar >= 0:
		var bar_time := _bar_time(frame, bar_len)
		if last_bar >= 0: _on_downbeat(frame, bar, bar_time, entered, bar_len, ctx)
		last_bar = bar
		_timeout = 0.0
	elif bar < 0:
		# No beat grid (silence, no confidence): no cuts; glide on a long timeout.
		_timeout += dt
		if _timeout > float(config.get("no_grid_timeout", 24.0)):
			_timeout = 0.0
			_change(-1 - cuts, now, _grammar(section).shots, "glide", "timeout", bar_len, ctx)
	# Musical modulation.
	var g := _grammar(section)
	var boost_goal := 1.0 if boost_until_bar >= 0 else 0.0
	boost = _approach(boost, boost_goal, dt, 0.4 if boost_goal > boost else 2.5)
	var pace_goal := float(g.pace) * (1.0 + boost * boost_pace * intensity)
	pace = _approach(pace, pace_goal, dt, 1.0)
	shot_u += dt * pace
	var anticipation := float(mapper.value("anticipation")) if mapper != null else 0.0
	var build := float(frame.build_progress) if section == "build" else 0.0
	# Push in while the drop approaches; never once it has landed.
	var push_goal := 0.0 if section == "drop" else clampf(maxf(build, anticipation), 0.0, 1.0) * push_max * intensity
	push = _approach(push, push_goal, dt, 0.5)
	var c := ctx.duplicate()
	c.push = push
	c.noise_gain = intensity * (1.0 + 0.5 * boost)
	target_pose = ShotLibrary.pose(shot, shot_u, c)
	if transition_kind == "glide" and not _glide_from.is_empty() and now - transition_time < glide_seconds:
		target_pose = ShotLibrary.glide(_glide_from, target_pose, smoothstep(0.0, 1.0, (now - transition_time) / glide_seconds), c.get("center", Vector3.ZERO))
	if mapper != null: target_pose.fov = float(target_pose.fov) - impact_fov * float(mapper.camera("impact"))
	var omega := float(g.omega) * (1.0 + 0.3 * boost)
	if transition_kind == "glide" and now - transition_time < glide_seconds: omega = minf(omega, glide_omega)
	comfort.omega = omega
	if _snap_next:
		comfort.snap(target_pose)
		_snap_next = false
		cut_this_frame = true
	var out: Dictionary = comfort.step(target_pose, dt).duplicate()
	var subject := str(target_pose.get("subject", ""))
	out.subject = subject
	out.focus = out.position.distance_to(ctx.targets[subject]) if not subject.is_empty() and ctx.get("targets", {}).has(subject) else -1.0
	out.shot = shot_name
	return out

## Exact time of the downbeat just crossed: the hub's grid beat time (the
## latest beat is the downbeat for the whole first beat of the bar).
static func _bar_time(frame, bar_len: float) -> float:
	var beat_time := float(frame.beat_time)
	var since := float(frame.time) - beat_time
	if is_finite(beat_time) and since >= -1e-6 and since < bar_len * 0.25 + 1e-6: return beat_time
	return float(frame.time) - float(frame.bar_phase) * bar_len

static func _approach(value: float, goal: float, dt: float, tau: float) -> float:
	if dt <= 0.0: return value
	return goal + (value - goal) * exp(-dt / maxf(tau, 1e-4))

func _start(frame, ctx: Dictionary) -> void:
	var g := _grammar(str(frame.section))
	var bar := maxi(int(frame.bar_index), 0)
	var bar_len := _bar_seconds(frame)
	var pool: Dictionary = g.get("start_shots", g.shots)
	_change(bar, _bar_time(frame, bar_len) if int(frame.bar_index) >= 0 else float(frame.time), pool, "start", "start", bar_len, ctx)

func _on_downbeat(frame, bar: int, bar_time: float, entered: bool, bar_len: float, ctx: Dictionary) -> void:
	var g := _grammar(section)
	if boost_until_bar >= 0 and bar >= boost_until_bar: boost_until_bar = -1
	var bars_in := bar - shot_start_bar
	var hard_ok := bars_in >= min_bars and bar_time - shot_start_time >= min_seconds - 1e-3
	if entered and section == "drop":
		boost_until_bar = bar + int(g.get("boost_bars", 8))
		if hard_ok: _change(bar, bar_time, g.get("drop_shots", g.shots), "cut", "drop", bar_len, ctx)
		else: pending_energetic = true
		return
	# Never leave less than the minimum shot before a known drop: the drop cut must stay legal.
	if bool(frame.anticipation) and float(frame.time_to_drop) < INF:
		var to_drop := float(frame.time_to_drop) + (float(frame.time) - bar_time)
		if to_drop > 1e-3 and to_drop < maxf(min_seconds, float(min_bars) * bar_len) - 1e-3: return
	if not hard_ok: return
	var pool: Dictionary = g.shots
	var reason := ""
	var want := false
	var phrase_pos := bar - section_start_bar
	var section_min := maxi(min_bars, int(g.min_bars))
	if pending_energetic:
		want = true
		reason = "drop-late"
		pool = g.get("drop_shots", g.shots)
	elif entered:
		want = true
		reason = "section"
		pool = g.get("enter_shots", g.shots)
	elif bars_in >= section_min:
		if bars_in >= int(g.max_bars):
			want = true
			reason = "max"
		elif phrase_pos % 8 == 0:
			want = _rand(bar, 11) < float(g.phrase8)
			reason = "phrase8"
		elif phrase_pos % 4 == 0:
			want = _rand(bar, 11) < float(g.phrase4)
			reason = "phrase4"
		else:
			want = _rand(bar, 11) < float(g.downbeat)
			reason = "downbeat"
	if not want: return
	var kind := "glide" if _rand(bar, 12) < float(g.get("enter_glide" if entered else "glide", g.glide)) else "cut"
	_change(bar, bar_time, pool, kind, reason, bar_len, ctx)

func _pick(pool: Dictionary, bar: int, ctx: Dictionary) -> String:
	var names: Array = []
	var weights: Array = []
	var keys := pool.keys()
	keys.sort()
	for key in keys:
		var matches: Array = []
		if str(key).ends_with("*"):
			for name in shots:
				if str(name).begins_with(str(key).trim_suffix("*")): matches.append(name)
			matches.sort()
		elif shots.has(key): matches.append(key)
		for name in matches:
			if name == shot_name or name == previous_name: continue
			var target := str(shots[name].get("target", "@center"))
			if target != "@center" and not ctx.get("targets", {}).has(target): continue
			names.append(name)
			weights.append(float(pool[key]) / float(matches.size()))
	if names.is_empty():
		for name in shots:
			if name != shot_name: return name
		return shot_name
	var total := 0.0
	for w in weights: total += w
	var r := _rand(bar, 7) * total
	for i in names.size():
		r -= weights[i]
		if r < 0.0: return names[i]
	return names[names.size() - 1]

func _change(bar: int, bar_time: float, pool: Dictionary, kind: String, reason: String, bar_len: float, ctx: Dictionary) -> void:
	var name := _pick(pool, bar, ctx)
	var from_az := 0.0
	if comfort.is_ready():
		from_az = ShotLibrary.azimuth_of(comfort.output.position, comfort.output.target)
	else:
		var original: Dictionary = ctx.get("original", {})
		from_az = ShotLibrary.azimuth_of(original.get("position", Vector3(0, 0, 1)), original.get("target", Vector3.ZERO))
	var salt_bar := bar
	shot = ShotLibrary.resolve(shots[name], func(salt): return _rand(salt_bar, 100 + salt), bar_len, from_az, min_turn, glide_max_turn if kind == "glide" else 180.0 - min_turn * 0.25)
	_glide_from = comfort.output.duplicate() if kind == "glide" and comfort.is_ready() else {}
	previous_name = shot_name
	shot_name = name
	shot_start_bar = bar
	shot_start_time = bar_time
	pace = float(_grammar(section).pace)
	shot_u = maxf(time - bar_time, 0.0) * pace
	transition_kind = kind
	transition_time = time
	pending_energetic = false
	if kind != "glide":
		_snap_next = true
		push = 0.0
	cuts += 1
	cut_log.append({"time": time, "bar": bar, "bar_time": bar_time, "kind": kind, "shot": name, "section": section, "reason": reason})

func _locked(ctx: Dictionary) -> Dictionary:
	if _locked_pose.is_empty():
		var locked: Dictionary = config.get("locked", {})
		var center: Vector3 = ctx.get("center", Vector3.ZERO)
		var position := center + ShotLibrary._spherical(float(locked.get("azimuth", 20.0)), float(locked.get("elevation", 18.0)), float(locked.get("distance", 7.5)))
		_locked_pose = {"position": comfort.resolve_position(position), "target": center, "fov": float(locked.get("fov", 45.0)), "focus": -1.0, "subject": "", "shot": "locked"}
	return _locked_pose

func describe() -> Dictionary:
	return {"mode": mode, "shot": shot_name, "section": section, "pace": pace, "boost": boost, "push": push, "cuts": cuts}
