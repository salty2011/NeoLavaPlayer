extends RefCounted
## Musicality layer: turns the hub's ReactFrame into a small set of reusable
## "reaction channels" (0..1) that scenes bind to instead of raw analysis.
## The goal is reactions that feel musical rather than twitchy: envelopes are
## locked to the beat grid, big reactions are rare and saved for big moments,
## and every channel has its own sensitivity and attack/release.
##
##   var m = ReactivityService.instance().mapper
##   mesh.scale = Vector3.ONE * (1.0 + 0.15 * m.effect("pulse"))
##   camera.fov = 70.0 + 8.0 * m.camera("impact") - 4.0 * m.camera("anticipation")
##
## Channels (see CHANNELS / docs/REACTIVITY_API.md):
##   pulse        beat-locked envelope; attack/decay scale with the beat period;
##                amplitude follows the intensity tier, so calm parts pulse gently
##   accent       downbeat envelope (bar length decay); phrase starts are stronger
##   impact       drops and gated big moments only; rate-limited and budgeted
##   anticipation build_progress / time-to-drop curve; rises before a drop and
##                releases quickly when it lands
##   swell        slow loudness/energy follower
##   calm         inverse of swell, for ambient/idle motion
##   sparkle      mid/high onsets (hi-hats, snares), short and rate-limited
##   sub bass lowmid mid presence high   per-band smoothed values
##
## Global settings (persisted by the service, see app_settings.gd):
##   sensitivity        multiplies every channel's own sensitivity (gain)
##   camera_intensity   scales camera(name); scenes use it for camera motion
##   effects_intensity  scales effect(name); scenes use it for everything else
##
## Jitter guards: confidence gates with hysteresis (pulse needs tempo
## confidence, accent needs downbeat confidence), minimum intervals per event
## channel, and an impact budget: drops always qualify; other big moments only
## at tier high/peak outside quiet/breakdown sections, at most one per
## `impact_budget_bars`, never while a drop is imminent; and never two impacts
## within `impact_min_interval`.
##
## Frame-rate independence: event envelopes are pure functions of
## (hub time - event time), with the event time taken from the hub's grid
## (frame.beat_time / frame.drop_time), and smoothing uses exp(-dt/tau).

const ReactFrame := preload("res://analysis/react_frame.gd")

signal pulse_fired(beat_index: int, amplitude: float)
signal accent_fired(bar: int, amplitude: float)
signal impact_fired(strength: float, kind: String)

const BAND_CHANNELS := ["sub", "bass", "lowmid", "mid", "presence", "high"]
const CHANNELS := ["pulse", "accent", "impact", "anticipation", "swell", "calm", "sparkle",
	"sub", "bass", "lowmid", "mid", "presence", "high"]
## Pulse/accent amplitude per intensity tier (calm, normal, high, peak).
const TIER_GAIN := [0.35, 0.6, 0.85, 1.0]

class Channel:
	var name: String
	var sensitivity: float = 1.0
	var attack: float = 0.0
	var release: float = 0.0
	var enabled: bool = true
	var value: float = 0.0
	var target: float = 0.0
	func _init(n: String, a: float, r: float) -> void:
		name = n
		attack = a
		release = r

var sensitivity: float = 1.0:
	set(v): sensitivity = clampf(v, 0.0, 3.0)
var camera_intensity: float = 1.0:
	set(v): camera_intensity = clampf(v, 0.0, 2.0)
var effects_intensity: float = 1.0:
	set(v): effects_intensity = clampf(v, 0.0, 2.0)

## Pulse: beats are followed only while tempo confidence is above pulse_conf_on
## (and until it falls below pulse_conf_off).
var pulse_conf_on: float = 0.45
var pulse_conf_off: float = 0.3
## Decay as a fraction of the beat period, clamped to [min, max] seconds.
var pulse_decay_beats: float = 0.35
var pulse_decay_min: float = 0.06
var pulse_decay_max: float = 0.3
var pulse_attack: float = 0.012
var accent_conf_on: float = 0.5
var accent_conf_off: float = 0.35
var accent_decay_bars: float = 0.25
var impact_min_interval: float = 8.0
## A non-drop impact needs this many bars since the previous impact.
var impact_budget_bars: int = 16
## No non-drop impact while a drop is due within this many bars.
var impact_drop_guard_bars: float = 2.0
var impact_hold: float = 0.08
var impact_decay: float = 1.2
## Anticipation reaches 1 at the drop; ramps over this window when time_to_drop is known.
var anticipation_window: float = 8.0
var sparkle_min_interval: float = 0.09
var sparkle_decay: float = 0.12

var channels: Dictionary = {}

var _pulse_gate: bool = false
var _accent_gate: bool = false
var _pulse_t: float = -INF
var _pulse_amp: float = 0.0
var _pulse_decay: float = 0.15
var _accent_t: float = -INF
var _accent_amp: float = 0.0
var _accent_decay: float = 0.5
var _impact_t: float = -INF
var _impact_amp: float = 0.0
var _impact_bar: int = -1000000
var _sparkle_t: float = -INF
var _sparkle_amp: float = 0.0
var _time: float = 0.0
## Counters for tests and the debug overlay.
var impacts: int = 0
var impacts_suppressed: int = 0
var last_impact_kind: String = ""

func _init() -> void:
	_add("pulse", 0.0, 0.0)
	_add("accent", 0.0, 0.0)
	_add("impact", 0.0, 0.0)
	_add("anticipation", 0.4, 0.25)
	_add("swell", 1.2, 2.5)
	_add("calm", 2.0, 1.0)
	_add("sparkle", 0.0, 0.0)
	var atk := [0.04, 0.04, 0.05, 0.06, 0.05, 0.04]
	var rel := [0.45, 0.35, 0.3, 0.25, 0.2, 0.18]
	for b in 6:
		_add(BAND_CHANNELS[b], atk[b], rel[b])

func _add(n: String, a: float, r: float) -> void:
	channels[n] = Channel.new(n, a, r)

func channel(n: String) -> Channel:
	return channels.get(n)

## Raw channel value 0..1 (sensitivity applied, intensity settings not).
func value(n: String) -> float:
	var c: Channel = channels.get(n)
	return c.value if c != null else 0.0

## Channel scaled by camera_intensity: use for camera moves, shakes, FOV.
func camera(n: String) -> float:
	return value(n) * camera_intensity

## Channel scaled by effects_intensity: use for geometry, colour, particles.
func effect(n: String) -> float:
	return value(n) * effects_intensity

func set_channel(n: String, settings: Dictionary) -> void:
	var c: Channel = channels.get(n)
	if c == null:
		return
	for k in ["sensitivity", "attack", "release", "enabled"]:
		if settings.has(k):
			c.set(k, settings[k])

func reset() -> void:
	for c in channels.values():
		c.value = 0.0
		c.target = 0.0
	_pulse_t = -INF
	_accent_t = -INF
	_impact_t = -INF
	_sparkle_t = -INF
	_impact_bar = -1000000
	_pulse_gate = false
	_accent_gate = false

## Call once per hub update with the hub frame. `active` false (paused) freezes
## the channels.
func update(f, dt: float, active: bool = true) -> void:
	if not active:
		return
	var t: float = f.time
	_time = t
	var beat_len: float = 60.0 / f.bpm if f.bpm > 1.0 else 0.5
	var bar_len: float = beat_len * 4.0
	var tier_gain: float = TIER_GAIN[clampi(f.intensity, 0, 3)]
	# --- gates (hysteresis) ---
	_pulse_gate = f.confidence >= (pulse_conf_off if _pulse_gate else pulse_conf_on)
	_accent_gate = f.downbeat_confidence >= (accent_conf_off if _accent_gate else accent_conf_on)
	# --- pulse ---
	if f.beat and _pulse_gate and (f.beat_time - _pulse_t) >= 0.5 * beat_len:
		_pulse_t = f.beat_time if is_finite(f.beat_time) else t
		_pulse_amp = clampf(0.5 + 0.5 * f.beat_strength, 0.0, 1.0) * tier_gain
		_pulse_decay = clampf(pulse_decay_beats * beat_len, pulse_decay_min, pulse_decay_max)
		pulse_fired.emit(f.beat_index, _pulse_amp)
	_set_target("pulse", _pulse_amp * _envelope(t - _pulse_t, pulse_attack, 0.0, _pulse_decay) if _pulse_gate or t - _pulse_t < 1.0 else 0.0)
	# --- accent ---
	if f.downbeat and _accent_gate and (t - _accent_t) >= 0.9 * bar_len:
		_accent_t = f.beat_time if is_finite(f.beat_time) and t - f.beat_time < 0.1 else t
		_accent_amp = (1.0 if f.phrase >= 8 else 0.7) * maxf(tier_gain, 0.5)
		_accent_decay = accent_decay_bars * bar_len
		accent_fired.emit(f.bar_index, _accent_amp)
	_set_target("accent", _accent_amp * _envelope(t - _accent_t, 0.01, 0.0, _accent_decay))
	# --- impact ---
	if f.drop or f.big_moment:
		var kind: String = "drop" if f.drop else String(f.big_kind)
		if _impact_allowed(f, kind, t, bar_len):
			_impact_t = f.drop_time if f.drop and is_finite(f.drop_time) else t
			_impact_amp = 1.0 if kind == "drop" else 0.6
			_impact_bar = f.bar_index
			impacts += 1
			last_impact_kind = kind
			impact_fired.emit(_impact_amp, kind)
		else:
			impacts_suppressed += 1
	_set_target("impact", _impact_amp * _envelope(t - _impact_t, 0.0, impact_hold, impact_decay))
	# --- anticipation ---
	var ant: float = smoothstep(0.0, 1.0, clampf(f.build_progress, 0.0, 1.0))
	if f.anticipation and is_finite(f.time_to_drop) and f.time_to_drop < anticipation_window:
		var x: float = 1.0 - clampf(f.time_to_drop / anticipation_window, 0.0, 1.0)
		ant = maxf(ant, x * x)
	if f.drop or t - f.drop_time < 0.25:
		ant = 0.0
	_set_target("anticipation", ant)
	# --- swell / calm ---
	_set_target("swell", clampf(f.energy_raw, 0.0, 1.0))
	var sw: Channel = channels.swell
	_set_target("calm", 1.0 - smoothstep(0.2, 0.6, sw.value), true)
	# --- sparkle ---
	if f.onset > 0.0 and f.onset_band >= 3 and t - _sparkle_t >= sparkle_min_interval:
		_sparkle_t = t
		_sparkle_amp = clampf(f.onset, 0.0, 1.0) * (0.5 + 0.5 * float(f.intensity) / 3.0)
	_set_target("sparkle", _sparkle_amp * _envelope(t - _sparkle_t, 0.0, 0.0, sparkle_decay))
	# --- bands ---
	for b in 6:
		_set_target(BAND_CHANNELS[b], f.bands_raw[b])
	# --- smoothing ---
	for c in channels.values():
		var x: float = c.target if c.enabled else 0.0
		var tau: float = c.attack if x > c.value else c.release
		if tau <= 0.0:
			c.value = x
		elif dt > 0.0:
			c.value += (x - c.value) * (1.0 - exp(-dt / tau))
		c.value = clampf(c.value, 0.0, 1.0)

func _set_target(n: String, v: float, unscaled: bool = false) -> void:
	var c: Channel = channels[n]
	c.target = clampf(v if unscaled else v * c.sensitivity * sensitivity, 0.0, 1.0)

## Attack ramp, optional hold, then exponential decay. `since` < 0 -> 0.
static func _envelope(since: float, attack: float, hold: float, decay: float) -> float:
	if since < 0.0 or not is_finite(since):
		return 0.0
	if since < attack:
		return since / attack
	since -= attack
	if since < hold:
		return 1.0
	return exp(-(since - hold) / maxf(decay, 1e-4))

func _impact_allowed(f, kind: String, t: float, bar_len: float) -> bool:
	if t - _impact_t < impact_min_interval:
		return false
	if kind == "drop":
		return true
	# Non-drop big moments only while the music is already big.
	if f.intensity < ReactFrame.Tier.HIGH or f.section in ["quiet", "breakdown"]:
		return false
	if f.bar_index - _impact_bar < impact_budget_bars:
		return false
	if f.anticipation and is_finite(f.time_to_drop) and f.time_to_drop < impact_drop_guard_bars * bar_len:
		return false
	return true

func snapshot() -> Dictionary:
	var d: Dictionary = {}
	for n in CHANNELS:
		d[n] = channels[n].value
	return d
