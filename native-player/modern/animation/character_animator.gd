extends RefCounted
## Modern character animation (Phase 4d), layered on top of the recovered
## motion, never replacing it. Each render frame, after SceneRuntime.present()
## has written the simulated (Classic) transforms, this adds a display-only
## offset to each character and writes the result back to the nodes. The next
## present() overwrites it again, and the runtime never reads node transforms
## back (it keeps its own sim_transform), so the simulation is untouched.
##
## Layers per character (a head on a parent-attached stem, profile
## "animation.characters"):
##   1. beat moves (beat_moves.gd): bob / hop / sway / twist / lean_in, phase
##      locked to the beat grid, chosen per section every select_bars on the
##      downbeat, cross-faded over ramp_beats (0.5 beat) with smoothstep weights
##   2. idle: seeded smooth noise per character, stronger when calm
##   3. follow-through: an underdamped spring on the head offset (the head lags
##      and overshoots), kicked on accents (jiggle)
##   4. squash and stretch on accents: volume-preserving (sx = sz = 1/sqrt(sy)),
##      world-vertical about the head centre
## The stem stays planted on the platform: it is sheared and stretched from
## its base so its top follows the head, and twisted with it.
## Environment: the platform assembly (platform, stems, heads) floats and tilts
## very slightly, more when the music is calm, faster when it swells.
## Springs run on a fixed 240 Hz grid of the hub clock with interpolation.

const BeatMoves = preload("res://modern/animation/beat_moves.gd")
const ShotLibrary = preload("res://modern/director/shot_library.gd")
const RATE := 240.0

var config: Dictionary = {}
var seed_value := 1
var characters: Array = []
var platform: Array = []      # {node, base, written}
var platform_y := -1.0
var platform_center := Vector3(0, -1, 0)
var center := Vector3.ZERO
var ramp_beats := 0.5
var select_bars := 2
var follow := 0.6
var spring_omega := TAU * 2.6
var spring_zeta := 0.35
var jiggle := 0.25
var squash_amp := 0.07
var squash_decay := 0.16
var squash_period := 0.36
var idle_amp := 0.02
var idle_twist := deg_to_rad(2.0)
var float_amp := 0.035
var float_tilt := deg_to_rad(0.8)

var time := -1.0
var section := ""
var section_index := -2
var section_start_bar := 0
var last_bar := -1
var last_beat := -1
var accent_time := -INF
var accent_amp := 0.0
var _pending_accent := 0.0
var _float_phase := 0.0
var _calm := 0.0
var _clock := 0.0
var _ticks := 0
var _mapper = null
var _bar_beat := -INF
var _phase_origin := -INF
## Per frame, for tests: [{name, primary: Vector3, twist, squash, moves: {name: signed scalar*weight}}].
var debug: Array = []
var float_offset := Transform3D.IDENTITY

func setup(runtime, profile_animation: Dictionary, scene_center: Vector3, scene_seed: int = 1) -> bool:
	config = profile_animation
	seed_value = int(config.get("seed", scene_seed))
	center = scene_center
	ramp_beats = float(config.get("ramp_beats", ramp_beats))
	select_bars = int(config.get("select_bars", select_bars))
	var secondary: Dictionary = config.get("secondary", {})
	follow = float(secondary.get("follow", follow))
	spring_omega = TAU * float(secondary.get("frequency", 2.6))
	spring_zeta = float(secondary.get("damping", spring_zeta))
	jiggle = float(secondary.get("jiggle", jiggle))
	var squash: Dictionary = config.get("squash", {})
	squash_amp = float(squash.get("amp", squash_amp))
	squash_decay = float(squash.get("decay", squash_decay))
	squash_period = float(squash.get("period", squash_period))
	var idle: Dictionary = config.get("idle", {})
	idle_amp = float(idle.get("amp", idle_amp))
	idle_twist = deg_to_rad(float(idle.get("twist_deg", 2.0)))
	var env: Dictionary = config.get("environment", {})
	float_amp = float(env.get("float", float_amp))
	float_tilt = deg_to_rad(float(env.get("tilt_deg", 0.8)))
	characters.clear()
	platform.clear()
	var index := 0
	for item in config.get("characters", []):
		var head: Dictionary = runtime.object_named(str(item.get("head", "")))
		if head.is_empty() or head.node == null: continue
		var stem: Dictionary = runtime.object_named(str(item.get("stem", "")))
		var character := {"name": str(item.head), "index": index, "head": _slot(head.node),
			"stem": _slot(stem.node) if not stem.is_empty() and stem.node != null and stem.node.get_parent() == head.node else {},
			"amp_scale": 0.85 + 0.3 * _rand(index, 0, 1), "sway_sign": -1.0 if _rand(index, 0, 2) < 0.5 else 1.0,
			"moves": {}, "current": "rest", "y": Vector3.ZERO, "v": Vector3.ZERO, "prev_y": Vector3.ZERO, "primary": Vector3.ZERO}
		characters.append(character)
		index += 1
	for object_name in env.get("platform", []):
		var entry: Dictionary = runtime.object_named(str(object_name))
		if entry.is_empty() or entry.node == null: continue
		platform.append(_slot(entry.node))
		var top: AABB = entry.node.global_transform * entry.node.mesh.get_aabb()
		if str(object_name) == str(env.get("platform", [""])[0]):
			platform_y = top.end.y
			platform_center = top.get_center()
	return not characters.is_empty()

## Smooth beat position at render time: beat index + time since the exact grid
## beat (frame.beat_time), so moves stay continuous at any frame rate (the
## hub's beat_phase can be quantised to the source's 10 ms grid).
func beat_position(frame, now: float, bpm: float) -> float:
	var period := 60.0 / bpm
	var since := now - float(frame.beat_time)
	if is_finite(since) and since >= -0.02 and since < period * 1.5:
		_phase_origin = -INF
		return float(frame.beat_index) + since / period
	# No exact beat time yet (just after a resync): run on our own clock from
	# the hub's phase, re-anchored only if it drifts by more than 0.1 beat.
	var coarse := float(frame.beat_index) + float(frame.beat_phase)
	if _phase_origin == -INF or absf((now - _phase_origin) / period - coarse) > 0.1: _phase_origin = now - coarse * period
	return (now - _phase_origin) / period

func _rebase() -> void:
	_bar_beat = -INF
	_phase_origin = -INF
	time = -1.0
	section = ""
	section_index = -2
	last_bar = -1
	last_beat = -1
	accent_time = -INF
	accent_amp = 0.0
	_pending_accent = 0.0
	_clock = 0.0
	_ticks = 0
	for character in characters:
		character.moves = {}
		character.current = "rest"
		character.y = Vector3.ZERO
		character.v = Vector3.ZERO
		character.prev_y = Vector3.ZERO
		character.erase("last_goal")

func _slot(node: Node3D) -> Dictionary:
	return {"node": node, "base": node.transform, "written": null}

func connect_mapper(mapper) -> void:
	disconnect_mapper()
	_mapper = mapper
	if mapper != null and not mapper.accent_fired.is_connected(_on_accent): mapper.accent_fired.connect(_on_accent)

func disconnect_mapper() -> void:
	if _mapper != null and _mapper.accent_fired.is_connected(_on_accent): _mapper.accent_fired.disconnect(_on_accent)
	_mapper = null

func _on_accent(_bar: int, amplitude: float) -> void:
	_pending_accent = amplitude

## Restore the simulated transforms (detach).
func restore() -> void:
	for character in characters:
		for key in ["head", "stem"]:
			var slot: Dictionary = character[key]
			if not slot.is_empty() and is_instance_valid(slot.node):
				_capture(slot)
				slot.node.transform = slot.base
				slot.written = null
	for slot in platform:
		if is_instance_valid(slot.node):
			_capture(slot)
			slot.node.transform = slot.base
			slot.written = null
	disconnect_mapper()

## A node still holding what we wrote last frame was not re-presented (paused
## or no tick): keep the stored base. Anything else is a fresh sim transform.
func _capture(slot: Dictionary) -> void:
	if slot.written == null or slot.node.transform != slot.written: slot.base = slot.node.transform

func _rand(a: int, b: int, salt: int) -> float:
	var h: int = (a * 73856093) ^ (b * 19349663) ^ (salt * 83492791) ^ (seed_value * 2654435761)
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return float(h & 0xffffff) / 16777216.0

func _section_config(kind: String) -> Dictionary:
	var sections: Dictionary = config.get("sections", {})
	return sections.get(kind, sections.get("steady", {"moves": {"bob": 1.0}, "amp": 0.6}))

static func _smooth(x: float) -> float:
	var t := clampf(x, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)

func _weight(move: Dictionary, bp: float) -> float:
	return lerpf(float(move.from), float(move.to), _smooth((bp - float(move.start)) / maxf(float(move.get("dur", ramp_beats)), 0.01)))

## Move one weight to `to`, continuously from its current value. Ramps are
## placed so peaks stay on beats: a fade-out starts now (right after the beat,
## while the move's shape falls toward zero at the half beat); a fade-in ends
## exactly on the next beat (on the next downbeat for bar-locked lean_in), so
## the weight is steady (zero slope) when the move peaks.
func _ramp(move: Dictionary, name: String, to: float, bp: float, bar_bp: float) -> void:
	var now := _weight(move, bp)
	move.from = now
	move.to = to
	move.dur = ramp_beats
	if to <= now:
		move.start = bp
	elif name == "lean_in":
		move.start = bar_bp + 4.0 * ceilf((bp + ramp_beats - bar_bp) / 4.0 - 1e-6) - ramp_beats
	else:
		move.start = ceilf(bp + ramp_beats - 1e-6) - ramp_beats

## Retarget a character's moves: the chosen one to `amplitude`, the rest to 0.
func _retarget(character: Dictionary, chosen: String, amplitude: float, bp: float, bar_bp: float) -> void:
	var moves: Dictionary = character.moves
	if chosen != "rest" and not moves.has(chosen): moves[chosen] = {"from": 0.0, "to": 0.0, "start": bp, "dur": ramp_beats}
	for name in moves: _ramp(moves[name], name, amplitude if name == chosen else 0.0, bp, bar_bp)
	character.current = chosen

func _select(bar: int, bp: float, bar_bp: float, build_progress: float) -> void:
	var sc := _section_config(section)
	var table: Dictionary = sc.get("moves", {"rest": 1.0})
	var names := table.keys()
	names.sort()
	var previous_pick := ""
	for character in characters:
		var pick := _weighted(names, table, _rand(bar, int(character.index), 3))
		if pick == previous_pick and _rand(bar, int(character.index), 4) < 0.6:
			pick = _weighted(names, table, _rand(bar, int(character.index), 5))
		previous_pick = pick
		_retarget(character, pick, _amplitude(sc, character, build_progress), bp, bar_bp)

func _amplitude(sc: Dictionary, character: Dictionary, build_progress: float) -> float:
	var amplitude := float(sc.get("amp", 0.6)) * float(character.amp_scale)
	if sc.has("build_gain"): amplitude *= 1.0 + float(sc.build_gain) * build_progress
	return amplitude

static func _weighted(names: Array, table: Dictionary, r: float) -> String:
	var total := 0.0
	for name in names: total += float(table[name])
	var x := r * total
	for name in names:
		x -= float(table[name])
		if x < 0.0: return str(name)
	return str(names[names.size() - 1])

## One render frame: compute the layers and write the display transforms.
func update(frame, mapper) -> void:
	var now := float(frame.time)
	# The music jumped back (seek, restart, new track): re-baseline the beat bookkeeping.
	if time >= 0.0 and now < time - 0.25: _rebase()
	var dt := clampf(now - time, 0.0, 0.1) if time >= 0.0 else 0.0
	time = now
	for slot in platform: _capture(slot)
	for character in characters:
		if is_instance_valid(character.head.node): _capture(character.head)
		if not character.stem.is_empty(): _capture(character.stem)
	var intensity := float(mapper.effects_intensity) if mapper != null else 1.0
	var calm := float(mapper.value("calm")) if mapper != null else 0.0
	var swell := float(mapper.value("swell")) if mapper != null else 0.0
	var impact := float(mapper.value("impact")) if mapper != null else 0.0
	var bpm := float(frame.bpm) if float(frame.bpm) > 1.0 else 120.0
	var bar_len := 240.0 / bpm
	var has_grid := int(frame.beat_index) >= 0
	var bp := beat_position(frame, now, bpm) if has_grid else now * bpm / 60.0
	if int(frame.bar_index) != last_bar and int(frame.bar_index) >= 0 and has_grid: _bar_beat = roundf(bp - float(frame.bar_phase) * 4.0)
	var bar_bp := _bar_beat if _bar_beat > -INF else bp - float(frame.bar_phase) * 4.0
	var bar_phase := clampf((bp - bar_bp) / 4.0, 0.0, 1.0)
	# Sections and selection (downbeats, every select_bars, and section entry).
	var entered := false
	if int(frame.section_index) != section_index:
		entered = section_index != -2
		section_index = int(frame.section_index)
		section = str(frame.section)
		section_start_bar = maxi(int(frame.bar_index), 0)
		if not entered: _select(maxi(int(frame.bar_index), 0), bp, bar_bp, float(frame.build_progress))
	var bar := int(frame.bar_index)
	if bar > last_bar and bar >= 0:
		if last_bar >= 0 or entered:
			if entered or (bar - section_start_bar) % maxi(select_bars, 1) == 0: _select(bar, bp, bar_bp, float(frame.build_progress))
			# Accent: squash timing comes from the exact bar time.
			if _pending_accent > 0.0:
				accent_time = now - float(frame.bar_phase) * bar_len
				accent_amp = _pending_accent * (1.0 + 0.8 * impact)
				_pending_accent = 0.0
				for character in characters:
					var kick := Vector3(0, -1, 0) * jiggle * accent_amp * float(character.amp_scale)
					character.v += kick
		last_bar = bar
	elif not has_grid:
		for character in characters:
			if character.current != "rest": _retarget(character, "rest", 0.0, bp, bar_bp)
	var beat := int(frame.beat_index)
	if beat != last_beat:
		# Build: amplitude grows with build_progress, retargeted just after each beat.
		if beat > last_beat and last_beat >= 0 and section == "build" and _section_config(section).has("build_gain"):
			var sc := _section_config(section)
			for character in characters:
				if character.current != "rest":
					_ramp(character.moves[character.current], character.current, _amplitude(sc, character, float(frame.build_progress)), bp, bar_bp)
		last_beat = beat
	# Environment float.
	_calm = calm
	_float_phase += dt * float(config.get("environment", {}).get("frequency", 0.07)) * (1.0 + 0.8 * swell)
	var float_gain := float_amp * (0.35 + 0.65 * calm) * intensity
	var lift := ShotLibrary.noise1(_float_phase * 4.0, seed_value + 31) * float_gain
	var tilt_x := ShotLibrary.noise1(_float_phase * 3.0 + 7.0, seed_value + 32) * float_tilt * (0.35 + 0.65 * calm) * intensity
	var tilt_z := ShotLibrary.noise1(_float_phase * 3.0 + 19.0, seed_value + 33) * float_tilt * (0.35 + 0.65 * calm) * intensity
	var tilt := Basis(Vector3.RIGHT, tilt_x) * Basis(Vector3.BACK, tilt_z)
	float_offset = Transform3D(Basis.IDENTITY, platform_center + Vector3(0, lift, 0)) * Transform3D(tilt, Vector3.ZERO) * Transform3D(Basis.IDENTITY, -platform_center)
	# Primary moves.
	var amps: Dictionary = config.get("moves", {})
	debug.clear()
	for character in characters:
		var c_info := {"name": character.name, "moves": {}}
		var lateral := 0.0
		var up := 0.0
		var inward := 0.0
		var twist := 0.0
		for name in character.moves:
			var w := _weight(character.moves[name], bp)
			if absf(w) < 1e-6: continue
			var m := BeatMoves.evaluate(name, bp, bar_phase, amps.get(name, {}))
			var sign := float(character.sway_sign) if name in ["sway", "twist"] else 1.0
			lateral += w * float(m.lateral) * sign
			up += w * float(m.up)
			inward += w * float(m.inward)
			twist += w * float(m.twist) * sign
			c_info.moves[name] = w * float(m.scalar)
		var n_t := now * float(config.get("idle", {}).get("frequency", 0.22))
		var s := seed_value * 7 + int(character.index) * 101
		var idle := idle_amp * (0.4 + 0.6 * calm)
		lateral += ShotLibrary.noise1(n_t, s) * idle
		inward += ShotLibrary.noise1(n_t + 13.1, s) * idle * 0.6
		up += ShotLibrary.noise1(n_t + 27.7, s) * idle * 0.3
		twist += ShotLibrary.noise1(n_t * 0.7 + 3.9, s) * idle_twist * (0.4 + 0.6 * calm)
		character.twist = twist * intensity
		character.lateral = lateral
		character.up = up
		character.inward = inward
		c_info.twist = character.twist
		debug.append(c_info)
	# Follow-through springs (fixed substeps of the hub clock).
	_clock += dt
	var target_ticks := int(floor(_clock * RATE + 1e-7))
	if target_ticks - _ticks > 48: _ticks = target_ticks - 48
	var due := target_ticks - _ticks
	var h := 1.0 / RATE
	var frames := []
	for character in characters: frames.append(_rig_frame(character))
	var start := _clock - dt
	for i in due:
		var f := clampf((float(_ticks + 1) / RATE - start) / dt, 0.0, 1.0) if dt > 0.0 else 1.0
		for k in characters.size():
			var character: Dictionary = characters[k]
			# First-order hold across this frame's substeps (render-rate independent).
			var now_goal: Vector3 = _primary_world(character, frames[k]) * intensity
			var goal: Vector3 = Vector3(character.get("last_goal", now_goal)).lerp(now_goal, f)
			character.prev_y = character.y
			var a: Vector3 = (goal - character.y) * spring_omega * spring_omega - character.v * 2.0 * spring_zeta * spring_omega
			character.v += a * h
			character.y += character.v * h
		_ticks += 1
	for k in characters.size(): characters[k].last_goal = _primary_world(characters[k], frames[k]) * intensity
	var alpha := clampf(_clock * RATE - float(_ticks), 0.0, 1.0)
	# Squash (volume-preserving, decaying oscillation after the accent).
	var tau := now - accent_time
	var squash_base := 0.0
	if tau >= 0.0 and tau < 2.0:
		squash_base = -squash_amp * accent_amp * exp(-tau / squash_decay) * cos(TAU * tau / squash_period) * intensity
	# Write.
	for k in characters.size():
		var character: Dictionary = characters[k]
		var primary: Vector3 = _primary_world(character, frames[k]) * intensity
		var spring: Vector3 = Vector3(character.prev_y).lerp(character.y, alpha)
		var offset: Vector3 = primary + (spring - primary) * follow
		character.primary = primary
		character.offset = offset
		var sq := clampf(squash_base * float(character.amp_scale), -0.15, 0.15)
		character.squash = sq
		debug[k].primary = primary
		debug[k].squash = sq
		_write_character(character, offset, float(character.twist), sq)
	for slot in platform:
		var parent_global: Transform3D = slot.node.get_parent().global_transform
		var t: Transform3D = parent_global.affine_inverse() * float_offset * parent_global * slot.base
		slot.node.transform = t
		slot.written = t

func _rig_frame(character: Dictionary) -> Dictionary:
	var head: Dictionary = character.head
	var parent_global: Transform3D = head.node.get_parent().global_transform
	var h0: Transform3D = parent_global * head.base
	var c: Vector3 = h0 * head.node.mesh.get_aabb().get_center() if head.node.mesh != null else h0.origin
	var inward := Vector3(center.x - c.x, 0.0, center.z - c.z)
	inward = inward.normalized() if inward.length_squared() > 1e-6 else Vector3.FORWARD
	# Pivot: the stem's simulated base (bottom centre); the platform under the head without a stem.
	var b := Vector3(c.x, platform_y, c.z)
	var stem: Dictionary = character.stem
	if not stem.is_empty() and stem.node.mesh != null:
		var box: AABB = stem.node.mesh.get_aabb()
		b = (h0 * stem.base) * Vector3(box.get_center().x, box.position.y, box.get_center().z)
	return {"parent": parent_global, "h0": h0, "c": c, "b": b, "inward": inward, "lateral": Vector3.UP.cross(inward)}

func _primary_world(character: Dictionary, rig: Dictionary) -> Vector3:
	return rig.lateral * float(character.lateral) + Vector3.UP * float(character.up) + rig.inward * float(character.inward)

## Head: rig offset, tilt toward the stem lean, twist, squash about its centre.
## Stem: sheared/stretched from its base on the platform so its top follows.
func _write_character(character: Dictionary, offset: Vector3, twist: float, sq: float) -> void:
	var head: Dictionary = character.head
	var rig := _rig_frame(character)
	var c: Vector3 = rig.c
	var b: Vector3 = rig.b
	var height := maxf(c.y - b.y, 0.3)
	var lean_dir := Vector3(offset.x, height + offset.y, offset.z).normalized()
	var tilt := Basis(Quaternion(Vector3.UP, lean_dir))
	# Twist turns head and stem together about the stem's vertical axis.
	var spin_about_b := Transform3D(Basis.IDENTITY, b) * Transform3D(Basis(Vector3.UP, twist), Vector3.ZERO) * Transform3D(Basis.IDENTITY, -b)
	var k := 1.0 / sqrt(1.0 + sq)
	var squash := Basis.from_scale(Vector3(k, 1.0 + sq, k))
	var h_new: Transform3D = float_offset * Transform3D(Basis.IDENTITY, offset) * spin_about_b * Transform3D(Basis.IDENTITY, c) * Transform3D(tilt * squash, Vector3.ZERO) * Transform3D(Basis.IDENTITY, -c) * rig.h0
	var head_local: Transform3D = Transform3D(rig.parent).affine_inverse() * h_new
	head.node.transform = head_local
	head.written = head_local
	character.head_global = h_new
	character.base_point = float_offset * b
	if character.stem.is_empty(): return
	var stem: Dictionary = character.stem
	var s0: Transform3D = Transform3D(rig.h0) * stem.base
	var shear := Basis(Vector3(1, 0, 0), Vector3(offset.x / height, 1.0 + offset.y / height, offset.z / height), Vector3(0, 0, 1))
	var s_new: Transform3D = float_offset * Transform3D(Basis.IDENTITY, b) * Transform3D(shear, Vector3.ZERO) * Transform3D(Basis.IDENTITY, -b) * spin_about_b * s0
	var stem_local: Transform3D = h_new.affine_inverse() * s_new
	stem.node.transform = stem_local
	stem.written = stem_local
	character.stem_global = s_new

## Head centres from the simulated (pre-animation) transforms, for the director.
func sim_centers() -> Dictionary:
	var out := {}
	for character in characters:
		var head: Dictionary = character.head
		if not is_instance_valid(head.node): continue
		_capture(head)
		var h0: Transform3D = head.node.get_parent().global_transform * head.base
		out[character.name] = h0 * head.node.mesh.get_aabb().get_center() if head.node.mesh != null else h0.origin
	return out
