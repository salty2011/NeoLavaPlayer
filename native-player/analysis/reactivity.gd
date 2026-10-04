extends Node
## Reactivity hub: one place scenes subscribe to for music-driven motion.
## Designed to become an autoload ("Reactivity"); works as a plain child Node now.
##
## Source-agnostic: set_source(x) where x is
##   - an Object with sample(time: float) -> Dictionary (TrackSource,
##     LiveAnalyzer, SyntheticSource, the mock feed...), optionally with
##     native_rate() -> float for frame-rate independent sub-stepping, or
##   - a Callable(time: float) -> Dictionary.
## Drive it with update_time(playback_position) (preferred; seeks handled) or
## update(delta). Each update publishes `frame` (a ReactFrame) via
## frame_updated and fires event signals. See docs/REACTIVITY_API.md.

const ReactFrame := preload("res://analysis/react_frame.gd")

signal frame_updated(frame)
signal beat(index: int, strength: float)
signal downbeat(bar: int)
signal onset(strength: float, band: int)
signal section_changed(type: String)
signal drop()
signal phrase(bars: int)
signal intensity_changed(tier: int)
signal big_moment(kind: String)

## Global sensitivity: >1 more reactive, <1 calmer. Applied as a gamma
## (v ^ (1/sensitivity)) to bands, energy and onset strengths.
@export_range(0.25, 4.0) var sensitivity: float = 1.0
## Per-band smoothing time constants (seconds): sub, bass, lowmid, mid, presence, high.
var band_attack := PackedFloat32Array([0.02, 0.02, 0.025, 0.03, 0.02, 0.015])
var band_release := PackedFloat32Array([0.30, 0.22, 0.18, 0.15, 0.12, 0.10])
var energy_attack: float = 0.3
var energy_release: float = 1.5
var flux_attack: float = 0.01
var flux_release: float = 0.12
## Intensity tiers: energy needed to enter normal / high / peak.
var tier_thresholds := PackedFloat32Array([0.30, 0.58, 0.82])
## Energy must fall this far below an entry threshold to drop a tier.
var tier_hysteresis: float = 0.1
## Minimum seconds between tier changes (peak entry on a big moment bypasses it).
var tier_min_dwell: float = 2.0
## How long after a big moment peak stays reachable without a drop section.
var peak_window: float = 8.0
var onset_threshold: float = 0.35
var min_onset_interval: float = 0.06
var min_big_interval: float = 4.0
var big_downbeat_confidence: float = 0.6
var big_downbeat_energy: float = 0.7
## A jump larger than this (or any backwards jump) is treated as a seek:
## state resyncs and no events fire for the skipped span.
var seek_threshold: float = 1.0
var max_substeps: int = 256
## When true, _process drives the hub using time_provider (if valid) or delta.
var auto_process: bool = false:
	set(v):
		auto_process = v
		set_process(v)
var time_provider: Callable

var frame = ReactFrame.new()

var _source = null
var _source_rate: float = 0.0
var _time: float = 0.0
var _started: bool = false
var _held: Dictionary = {}
var _cont: Dictionary = {}
var _prev_flags: Dictionary = {}
var _last: Dictionary = {}
var _last_onset_time: float = -INF
var _last_big_time: float = -INF
var _tier_time: float = -INF
var _has_sections: bool = false
var _blend_from = null
var _blend_t0: float = 0.0
var _blend_len: float = 0.0
var _last_beat_t: float = -INF
## Beats closer than this fraction of a beat period are ignored (guards the
## seam of a source swap, where two trackers may each report the same beat).
var min_beat_spacing: float = 0.4

func _ready() -> void:
	set_process(auto_process)

func _process(delta: float) -> void:
	if time_provider.is_valid():
		update_time(float(time_provider.call()), delta)
	else:
		update(delta)

## Replace the source. With blend <= 0 (or before the first update) the hub
## resyncs on the next update: smoothing snaps to the new source's values.
## With blend > 0 the swap is seamless: smoothing state is kept, event trackers
## re-baseline on the new source without firing, and the continuous inputs
## (bands, energy, flux, loudness, build_progress) cross-fade linearly from the
## previous source over `blend` seconds of hub time. hold_previous = true
## cross-fades from the last values the old source produced (a frozen copy)
## instead of keep sampling it; use it when the old source's clock no longer
## matches (track change, stop).
func set_source(source, blend: float = 0.0, hold_previous: bool = false) -> void:
	var previous = _source
	_source = source
	_source_rate = 0.0
	if source is Object and source.has_method("native_rate"):
		_source_rate = float(source.native_rate())
	if blend <= 0.0 or not _started or previous == null or source == null:
		_blend_from = null
		_started = false
		return
	_blend_from = HeldValues.new(_held) if hold_previous or _blend_from != null else previous
	_blend_t0 = _time
	_blend_len = blend
	_rebaseline(_time)

## True while a seamless set_source() cross-fade is running.
func is_blending() -> bool:
	return _blend_from != null

## Move the hub clock to `time` without resyncing smoothing (a known seek or a
## new track on the same clock). Event trackers re-baseline at the new time, so
## nothing fires for the skipped span and nothing jumps.
func rebase(time: float) -> void:
	if not _started or _source == null:
		_time = time
		return
	_time = time
	if _blend_from != null:
		_blend_t0 = time
	_rebaseline(time)

## Holds one sample dictionary; the cross-fade origin after a track change.
class HeldValues:
	var values: Dictionary
	func _init(d: Dictionary) -> void:
		values = d.duplicate()
	func sample(_t: float) -> Dictionary:
		return values

func get_source():
	return _source

func reset(time: float = 0.0) -> void:
	_started = false
	_time = time

## Advance by delta seconds of the hub's own clock.
func update(delta: float):
	return update_time((_time if _started else 0.0) + maxf(0.0, delta), delta)

## Advance to playback time `time` (seconds). Backwards jumps and jumps larger
## than seek_threshold resync without firing events.
func update_time(time: float, delta: float = -1.0):
	if _source == null:
		return frame
	_clear_frame_events()
	_cont = {}
	frame.delta = delta if delta >= 0.0 else maxf(0.0, time - _time)
	if not _started or time < _time - 1e-6 or time - _time > seek_threshold:
		_resync(time)
		_publish(time)
		return frame
	if _source_rate > 0.0:
		var k0: int = int(floor(_time * _source_rate)) + 1
		var k1: int = int(floor(time * _source_rate))
		if k1 - k0 + 1 > max_substeps:
			k0 = k1 - max_substeps + 1
		for k in range(k0, k1 + 1):
			var tk: float = float(k) / _source_rate
			if tk <= _time:
				continue
			_integrate(tk - _time)
			_time = tk
			_held = _mixed(tk)
			_events(tk)
		_integrate(time - _time)
		_time = time
		# Continuous fields (phases, countdowns) are read at the exact render
		# time so animation stays smooth between timeline frames; events and
		# smoothing above use only grid samples (frame-rate independent).
		if not is_equal_approx(time * _source_rate, round(time * _source_rate)):
			_cont = _mixed(time)
	else:
		_held = _mixed(time)
		_integrate(time - _time)
		_time = time
		_events(time)
	_publish(time)
	return frame

func _sample(t: float) -> Dictionary:
	return _sample_of(_source, t)

static func _sample_of(src, t: float) -> Dictionary:
	if src == null:
		return {}
	if src is Callable:
		return src.call(t)
	return src.sample(t)

const _BLEND_KEYS := ["energy", "flux", "loudness_db", "build_progress", "beat_strength"]

## Normalised sample of the current source, cross-faded from the previous one
## while a seamless swap is running. Discrete fields (indices, phases, section)
## always come from the new source.
func _mixed(t: float) -> Dictionary:
	var d: Dictionary = _normalise(_sample(t))
	if _blend_from == null:
		return d
	var w: float = clampf((t - _blend_t0) / maxf(_blend_len, 1e-6), 0.0, 1.0)
	if w >= 1.0:
		_blend_from = null
		return d
	var o: Dictionary = _normalise(_sample_of(_blend_from, t))
	var nb: PackedFloat32Array = d.bands
	var ob: PackedFloat32Array = o.bands
	var mb := PackedFloat32Array([0, 0, 0, 0, 0, 0])
	for b in 6:
		mb[b] = lerpf(ob[b], nb[b], w)
	d.bands = mb
	for k in _BLEND_KEYS:
		if d.has(k) or o.has(k):
			var dv: float = float(d.get(k, 0.0))
			var ov: float = float(o.get(k, dv))
			if is_finite(dv) and is_finite(ov):
				d[k] = lerpf(ov, dv, w)
	return d

# --- smoothing ---------------------------------------------------------------

func _shape(v: float) -> float:
	v = clampf(v, 0.0, 1.0)
	return v if is_equal_approx(sensitivity, 1.0) else pow(v, 1.0 / maxf(0.05, sensitivity))

static func _smooth(y: float, x: float, dt: float, attack: float, release: float) -> float:
	var tau: float = attack if x > y else release
	return x if tau <= 0.0 else y + (x - y) * (1.0 - exp(-dt / tau))

func _integrate(dt: float) -> void:
	if dt <= 0.0 or _held.is_empty():
		return
	var raw: PackedFloat32Array = _held.bands
	for b in 6:
		frame.bands[b] = _smooth(frame.bands[b], _shape(raw[b]), dt, band_attack[b], band_release[b])
	frame.energy = _smooth(frame.energy, _shape(_held.energy), dt, energy_attack, energy_release)
	frame.flux_smooth = _smooth(frame.flux_smooth, clampf(_held.flux, 0.0, 1.0), dt, flux_attack, flux_release)

# --- source normalisation ----------------------------------------------------

## Accepts the documented field set plus common aliases (bands of 3, named
## low/mid/treble scalars, boolean event flags) so ad-hoc feeds plug in.
func _normalise(d: Dictionary) -> Dictionary:
	var out: Dictionary = d.duplicate()
	var bands := PackedFloat32Array([0, 0, 0, 0, 0, 0])
	var src = d.get("bands", null)
	if src is PackedFloat32Array or src is Array:
		var n: int = src.size()
		if n >= 6:
			for b in 6:
				bands[b] = float(src[b])
		elif n > 0:
			for b in 6:
				bands[b] = float(src[mini(n - 1, int(float(b) * float(n) / 6.0))])
	else:
		var names := {"sub": 0, "bass": 1, "low": 1, "lowmid": 2, "low_mid": 2, "mid": 3, "presence": 4, "high_mid": 4, "high": 5, "treble": 5}
		for k in names:
			if d.has(k):
				bands[names[k]] = float(d[k])
		if not d.has("sub") and (d.has("bass") or d.has("low")):
			bands[0] = bands[1]
		if not d.has("lowmid") and not d.has("low_mid"):
			bands[2] = 0.5 * (bands[1] + bands[3])
		if not d.has("presence") and not d.has("high_mid"):
			bands[4] = 0.5 * (bands[3] + bands[5])
	out.bands = bands
	if not d.has("energy"):
		var e: float = 0.0
		for b in 6:
			e += bands[b]
		out.energy = e / 6.0
	out.flux = float(d.get("flux", d.get("onset_strength", 0.0)))
	return out

# --- events ------------------------------------------------------------------

func _edge(key: String) -> bool:
	var v = _held.get(key, false)
	var now: bool = v is bool and v
	var was: bool = bool(_prev_flags.get(key, false))
	_prev_flags[key] = now
	return now and not was

func _changed(key: String) -> bool:
	if not _held.has(key):
		return false
	var v = _held[key]
	var changed: bool = _last.has(key) and v != _last[key]
	var advanced: bool = changed and (not (v is int) or int(v) > int(_last[key]))
	_last[key] = v
	return advanced if v is int else changed

func _rebaseline(time: float) -> void:
	_held = _mixed(time)
	_last.clear()
	_prev_flags.clear()
	for k in ["beat_index", "bar_index", "onset_index", "section_index", "section", "phrase_index"]:
		if _held.has(k):
			_last[k] = _held[k]
	for k in ["beat", "downbeat", "onset", "drop"]:
		_prev_flags[k] = _held.get(k, false) is bool and bool(_held.get(k, false))
	_has_sections = _held.has("section")

func _resync(time: float) -> void:
	_started = true
	_time = time
	_blend_from = null
	_rebaseline(time)
	var raw: PackedFloat32Array = _held.bands
	for b in 6:
		frame.bands[b] = _shape(raw[b])
	frame.energy = _shape(_held.energy)
	frame.flux_smooth = clampf(_held.flux, 0.0, 1.0)
	frame.section = String(_held.get("section", "steady"))
	frame.section_index = int(_held.get("section_index", -1))
	_tier_time = -INF
	_update_tier(time, true)

func _events(t: float) -> void:
	_has_sections = _has_sections or _held.has("section")
	var is_beat: bool = _changed("beat_index") or _edge("beat")
	var bpm_now: float = float(_held.get("bpm", 0.0))
	var period: float = 60.0 / bpm_now if bpm_now > 1.0 else 0.0
	if is_beat and period > 0.0 and t >= _last_beat_t and t - _last_beat_t < min_beat_spacing * period:
		is_beat = false
	var is_bar: bool = _changed("bar_index") or _edge("downbeat")
	var is_onset: bool = _changed("onset_index") or _edge("onset")
	var sec_changed: bool = _changed("section_index") if _held.has("section_index") else _changed("section")
	var is_phrase: bool = _changed("phrase_index")
	if is_phrase:
		frame.phrase = int(_held.get("phrase_bars", 4))
		phrase.emit(frame.phrase)
	if sec_changed:
		frame.section_changed = true
		frame.section = String(_held.get("section", "steady"))
		frame.section_index = int(_held.get("section_index", frame.section_index + 1))
		section_changed.emit(frame.section)
	var is_drop: bool = (sec_changed and String(_held.get("section", "")) == "drop") or _edge("drop")
	if is_drop:
		frame.drop = true
		frame.drop_time = t
		drop.emit()
		_fire_big("drop", t)
	if is_beat:
		frame.beat = true
		frame.beat_index = int(_held.get("beat_index", frame.beat_index + 1))
		frame.beat_strength = clampf(float(_held.get("beat_strength", 1.0)), 0.0, 1.0)
		var ph: float = float(_held.get("beat_phase", 0.0))
		frame.beat_time = t - ph * period if period > 0.0 and ph < 0.5 else t
		_last_beat_t = t
		beat.emit(frame.beat_index, frame.beat_strength)
	if is_bar and (is_beat or not _held.has("beat_index")):
		frame.downbeat = true
		frame.bar_index = int(_held.get("bar_index", frame.bar_index + 1))
		downbeat.emit(frame.bar_index)
		var confident: bool = float(_held.get("downbeat_confidence", _held.get("confidence", 0.0))) >= big_downbeat_confidence
		var phrase_start: bool = is_phrase and int(_held.get("phrase_bars", 0)) >= 8 if _held.has("phrase_index") else frame.bar_index % 4 == 0
		if confident and phrase_start and frame.energy >= big_downbeat_energy and t - _last_big_time >= min_big_interval:
			_fire_big("downbeat", t)
	if is_onset:
		var s: float = _shape(float(_held.get("onset_strength", _held.get("flux", 1.0))))
		if s >= onset_threshold and t - _last_onset_time >= min_onset_interval:
			_last_onset_time = t
			frame.onset = maxf(frame.onset, s)
			frame.onset_band = int(_held.get("onset_band", 0))
			onset.emit(s, frame.onset_band)

func _fire_big(kind: String, t: float) -> void:
	_last_big_time = t
	frame.big_moment = true
	frame.big_kind = kind
	big_moment.emit(kind)

func _update_tier(t: float, force: bool = false) -> void:
	var e: float = frame.energy
	var cur: int = frame.intensity
	var target: int = cur
	while target < 3 and e >= tier_thresholds[target]:
		target += 1
	while target > 0 and e < tier_thresholds[target - 1] - tier_hysteresis:
		target -= 1
	if target == ReactFrame.Tier.PEAK:
		var section_ok: bool = String(_held.get("section", "")) == "drop" if _has_sections else e >= 0.92
		if not (section_ok or t - _last_big_time < peak_window):
			target = ReactFrame.Tier.HIGH
	if target == cur:
		return
	var bypass: bool = force or (target == ReactFrame.Tier.PEAK and frame.big_moment)
	if not bypass and t - _tier_time < tier_min_dwell:
		return
	frame.intensity = target
	frame.intensity_name = ReactFrame.TIER_NAMES[target]
	_tier_time = t
	if not force:
		intensity_changed.emit(target)

func _clear_frame_events() -> void:
	frame.beat = false
	frame.downbeat = false
	frame.onset = 0.0
	frame.onset_band = -1
	frame.section_changed = false
	frame.drop = false
	frame.phrase = 0
	frame.big_moment = false
	frame.big_kind = ""

func _publish(t: float) -> void:
	var h: Dictionary = _held
	frame.time = t
	var raw: PackedFloat32Array = h.get("bands", PackedFloat32Array([0, 0, 0, 0, 0, 0]))
	for b in 6:
		frame.bands_raw[b] = _shape(raw[b])
	frame.flux = clampf(float(h.get("flux", 0.0)), 0.0, 1.0)
	frame.energy_raw = _shape(float(h.get("energy", 0.0)))
	frame.beat_index = int(h.get("beat_index", frame.beat_index))
	frame.bar_index = int(h.get("bar_index", frame.bar_index))
	var c: Dictionary = _cont if not _cont.is_empty() else h
	frame.beat_phase = float(c.get("beat_phase", 0.0))
	frame.bar_phase = float(c.get("bar_phase", 0.0))
	frame.bpm = float(h.get("bpm", 0.0))
	frame.confidence = float(h.get("confidence", 0.0))
	frame.downbeat_confidence = float(h.get("downbeat_confidence", frame.confidence))
	frame.loudness_db = float(h.get("loudness_db", -70.0))
	frame.section = String(h.get("section", frame.section))
	frame.build_progress = float(c.get("build_progress", 0.0))
	frame.time_to_drop = float(c.get("time_to_drop", INF))
	frame.time_to_next_beat = float(c.get("time_to_next_beat", INF))
	frame.time_to_next_downbeat = float(c.get("time_to_next_downbeat", INF))
	frame.next_section = String(h.get("next_section", ""))
	frame.anticipation = bool(h.get("anticipation", false))
	_update_tier(t)
	frame_updated.emit(frame)
