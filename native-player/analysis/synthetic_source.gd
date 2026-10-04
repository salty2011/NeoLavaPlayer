extends RefCounted
## Procedural Reactivity source (no audio at all): a 4/4 groove at `bpm` with a
## section schedule, producing the same fields as TrackSource. Used by tests and
## handy for scene development without music. Deterministic for a given seed.
## Time-addressed like TrackSource; native_rate() = 100 Hz (values are held
## per 10 ms step, so hub sub-stepping makes smoothing frame-rate independent).

const SCHEDULE := [
	{"type": "quiet", "bars": 8, "energy": 0.25, "bass": 0.1},
	{"type": "build", "bars": 8, "energy": 0.45, "bass": 0.15},
	{"type": "drop", "bars": 16, "energy": 0.9, "bass": 0.9},
	{"type": "breakdown", "bars": 8, "energy": 0.3, "bass": 0.05},
]

## Parse "quiet:8,build:8,drop:16,breakdown:8" into a schedule (energy and bass
## per type from TYPE_LEVELS). Returns SCHEDULE for an empty or invalid string.
const TYPE_LEVELS := {
	"quiet": [0.25, 0.1], "build": [0.45, 0.15], "drop": [0.9, 0.9],
	"breakdown": [0.3, 0.05], "steady": [0.6, 0.6],
}
static func parse_schedule(text: String) -> Array:
	var out: Array = []
	for part in text.split(",", false):
		var bits := part.strip_edges().split(":")
		var kind := bits[0].strip_edges().to_lower()
		var bars := int(bits[1]) if bits.size() > 1 else 8
		if not TYPE_LEVELS.has(kind) or bars <= 0:
			return SCHEDULE
		out.append({"type": kind, "bars": bars, "energy": TYPE_LEVELS[kind][0], "bass": TYPE_LEVELS[kind][1]})
	return out if not out.is_empty() else SCHEDULE

var bpm: float = 128.0
var schedule: Array = SCHEDULE
var seed_value: int = 7
var rate: float = 100.0
var loop: bool = true

func _init(tempo: float = 128.0, sections: Array = SCHEDULE) -> void:
	bpm = tempo
	schedule = sections

func native_rate() -> float:
	return rate

func total_bars() -> int:
	var n: int = 0
	for s in schedule:
		n += int(s.bars)
	return n

func _hash01(i: int, salt: int) -> float:
	var h: int = (i * 73856093) ^ (salt * 19349663) ^ (seed_value * 83492791)
	h = (h ^ (h >> 13)) * 1274126177
	return float((h >> 8) & 0xffff) / 65535.0

func sample(t: float) -> Dictionary:
	t = floor(maxf(t, 0.0) * rate) / rate
	var beat_len: float = 60.0 / bpm
	var bar_len: float = beat_len * 4.0
	var span: float = float(total_bars()) * bar_len
	var lt: float = fposmod(t, span) if loop else minf(t, span - 1e-4)
	var loops: int = int(floor(t / span)) if loop else 0
	var bar_f: float = lt / bar_len
	var bar_in_loop: int = int(floor(bar_f))
	var si: int = 0
	var start_bar: int = 0
	for i in schedule.size():
		if bar_in_loop < start_bar + int(schedule[i].bars):
			si = i
			break
		start_bar += int(schedule[i].bars)
	var s: Dictionary = schedule[si]
	var progress: float = (bar_f - float(start_bar)) / float(s.bars)
	var beat_index: int = int(floor(t / beat_len))
	var beat_phase: float = fposmod(t / beat_len, 1.0)
	var kick: float = exp(-beat_phase * 6.0)
	var e: float = float(s.energy)
	if String(s.type) == "build":
		e = lerpf(e, 0.75, progress)
	var jitter: float = 0.05 * (_hash01(int(t * rate), 1) - 0.5)
	var bass: float = float(s.bass)
	var bands := PackedFloat32Array([
		clampf(bass * (0.4 + 0.6 * kick) + jitter, 0, 1),
		clampf(bass * (0.5 + 0.5 * kick) + 0.2 * e + jitter, 0, 1),
		clampf(0.5 * e + jitter, 0, 1),
		clampf(0.6 * e + jitter, 0, 1),
		clampf(0.5 * e + 0.3 * exp(-fposmod(beat_phase + 0.5, 1.0) * 10.0) + jitter, 0, 1),
		clampf(0.4 * e + (0.4 * progress if String(s.type) == "build" else 0.0) + jitter, 0, 1),
	])
	# Time to next drop (lookahead, like TrackSource).
	var ttd: float = INF
	var start_acc: int = 0
	for k in schedule.size() * 2:
		var idx: int = k % schedule.size()
		var bar_start: float = float(start_acc) * bar_len
		if String(schedule[idx].type) == "drop" and bar_start > lt + 1e-6:
			ttd = bar_start - lt
			break
		start_acc += int(schedule[idx].bars)
	if not loop and ttd > span:
		ttd = INF
	var section_index: int = loops * schedule.size() + si
	var bp: float = progress if String(s.type) == "build" else 0.0
	return {
		"bands": bands, "flux": kick * (0.3 + 0.7 * e), "energy": clampf(e + jitter, 0, 1),
		"loudness_db": -30.0 + 20.0 * e,
		"beat_index": beat_index, "beat_phase": beat_phase, "beat_strength": 0.5 + 0.5 * e,
		"bar_index": int(floor(t / bar_len)), "bar_phase": fposmod(t / bar_len, 1.0),
		"onset_index": beat_index, "onset_strength": 0.4 + 0.5 * e, "onset_band": 0,
		"bpm": bpm, "confidence": 0.95, "downbeat_confidence": 0.95,
		"section": String(s.type), "section_index": section_index,
		"phrase_index": int(floor(t / (bar_len * 4.0))),
		"phrase_bars": 16 if int(floor(t / bar_len)) % 16 == 0 else (8 if int(floor(t / bar_len)) % 8 == 0 else 4),
		"build_progress": bp, "time_to_drop": ttd,
		"time_to_next_beat": beat_len * (1.0 - beat_phase),
		"anticipation": true,
	}
