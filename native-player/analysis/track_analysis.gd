extends RefCounted
## Result of offline pre-analysis of one track: a compact time-indexed timeline
## plus event lists, with lookahead queries. Plain data; safe to build on a worker
## thread and hand to the main thread. Serialises to a Dictionary of packed
## arrays (see to_dict/from_dict) for the user:// analysis cache.
##
## Timeline frame i covers time time0 + i / frame_rate (zero-order hold).

const VERSION := 3
const NUM_BANDS := 6
const BAND_NAMES := ["sub", "bass", "lowmid", "mid", "presence", "high"]

var source_path: String = ""
var duration: float = 0.0
var frame_rate: float = 86.1328125
var time0: float = 0.0
var num_frames: int = 0
## frames * 6, track-normalised 0..1 (percentile normalisation in dB).
var bands := PackedFloat32Array()
## Normalised spectral flux 0..1 (1 = 99th percentile).
var flux := PackedFloat32Array()
## Overall energy 0..1 (track-relative momentary loudness).
var energy := PackedFloat32Array()
## Short-term (3 s) LUFS-like loudness, dB.
var loudness := PackedFloat32Array()
## Momentary RMS dBFS.
var rms_db := PackedFloat32Array()
var beats := PackedFloat32Array()
var beat_strengths := PackedFloat32Array()
## Beat index (into `beats`) of the first downbeat; bar position = (i - first_downbeat) mod 4.
var first_downbeat: int = 0
var downbeats := PackedFloat32Array()
var onsets := PackedFloat32Array()
var onset_strengths := PackedFloat32Array()
var onset_bands := PackedInt32Array()
## Array of {type, start, end, start_bar, bars, energy}.
var sections: Array = []
var section_starts := PackedFloat32Array()
var phrase_times := PackedFloat32Array()
var phrase_bars := PackedInt32Array()
var bpm: float = 0.0
var tempo_confidence: float = 0.0
var downbeat_confidence: float = 0.0
var analysis_seconds: float = 0.0
var beats_per_bar: int = 4

# --- timeline -------------------------------------------------------------

func frame_index(t: float) -> int:
	return clampi(int(floor((t - time0) * frame_rate)), 0, maxi(0, num_frames - 1))

func band_values(t: float) -> PackedFloat32Array:
	var i: int = frame_index(t) * NUM_BANDS
	if num_frames == 0:
		var z := PackedFloat32Array()
		z.resize(NUM_BANDS)
		return z
	return bands.slice(i, i + NUM_BANDS)

func energy_at(t: float) -> float:
	return energy[frame_index(t)] if num_frames > 0 else 0.0

# --- beats ----------------------------------------------------------------

## Index of the last beat at or before t (-1 before the first beat).
func beat_index_at(t: float) -> int:
	return beats.bsearch(t, false) - 1

func beat_phase(t: float) -> float:
	var i: int = beat_index_at(t)
	var period: float = 60.0 / maxf(1.0, bpm)
	if i < 0:
		return 0.0 if beats.is_empty() else fposmod(1.0 - (beats[0] - t) / period, 1.0)
	var next_t: float = beats[i + 1] if i + 1 < beats.size() else beats[i] + period
	return clampf((t - beats[i]) / maxf(1e-4, next_t - beats[i]), 0.0, 0.9999)

## Position of beat i inside its bar, 0 = downbeat.
func beat_in_bar(i: int) -> int:
	return posmod(i - first_downbeat, beats_per_bar)

func bar_index_at(t: float) -> int:
	return downbeats.bsearch(t, false) - 1

func bar_phase(t: float) -> float:
	var i: int = beat_index_at(t)
	if i < 0:
		return 0.0
	return (float(beat_in_bar(i)) + beat_phase(t)) / float(beats_per_bar)

func time_to_next_beat(t: float) -> float:
	var i: int = beats.bsearch(t, false)
	return beats[i] - t if i < beats.size() else INF

func time_to_next_downbeat(t: float) -> float:
	var i: int = downbeats.bsearch(t, false)
	return downbeats[i] - t if i < downbeats.size() else INF

func time_to_next_phrase(t: float) -> float:
	var i: int = phrase_times.bsearch(t, false)
	return phrase_times[i] - t if i < phrase_times.size() else INF

func phrase_index_at(t: float) -> int:
	return phrase_times.bsearch(t, false) - 1

func onset_index_at(t: float) -> int:
	return onsets.bsearch(t, false) - 1

# --- sections -------------------------------------------------------------

func section_index_at(t: float) -> int:
	return maxi(0, section_starts.bsearch(t, false) - 1) if not sections.is_empty() else -1

func section_at(t: float) -> Dictionary:
	var i: int = section_index_at(t)
	return sections[i] if i >= 0 else {}

func section_type_at(t: float) -> String:
	var s: Dictionary = section_at(t)
	return String(s.get("type", "steady"))

## Next section starting after t ({} if none). Includes "time_until".
func next_section(t: float) -> Dictionary:
	var i: int = section_starts.bsearch(t, false)
	if i >= sections.size():
		return {}
	var s: Dictionary = sections[i].duplicate()
	s["time_until"] = float(s.start) - t
	return s

## Seconds until the next drop section starts (INF if none ahead).
func time_to_drop(t: float) -> float:
	for i in range(section_starts.bsearch(t, false), sections.size()):
		if String(sections[i].type) == "drop":
			return float(sections[i].start) - t
	return INF

func upcoming_drop_in(t: float, seconds: float) -> bool:
	return time_to_drop(t) <= seconds

## 0..1 progress of a build towards the drop. Inside a "build" section this is
## the position within the section; additionally ramps over the last 4 bars
## before any drop (covers drops without a detected build).
func build_progress(t: float) -> float:
	var p: float = 0.0
	var s: Dictionary = section_at(t)
	if not s.is_empty() and String(s.type) == "build":
		p = clampf((t - float(s.start)) / maxf(0.01, float(s.end) - float(s.start)), 0.0, 1.0)
	var ttd: float = time_to_drop(t)
	if ttd < INF:
		var window: float = 4.0 * float(beats_per_bar) * 60.0 / maxf(1.0, bpm)
		p = maxf(p, clampf(1.0 - ttd / window, 0.0, 1.0))
	return p

# --- serialisation ----------------------------------------------------------

func to_dict() -> Dictionary:
	return {
		"version": VERSION, "source_path": source_path, "duration": duration,
		"frame_rate": frame_rate, "time0": time0, "num_frames": num_frames,
		"bands": bands, "flux": flux, "energy": energy, "loudness": loudness, "rms_db": rms_db,
		"beats": beats, "beat_strengths": beat_strengths, "first_downbeat": first_downbeat,
		"downbeats": downbeats, "onsets": onsets, "onset_strengths": onset_strengths,
		"onset_bands": onset_bands, "sections": sections, "phrase_times": phrase_times,
		"phrase_bars": phrase_bars, "bpm": bpm, "tempo_confidence": tempo_confidence,
		"downbeat_confidence": downbeat_confidence, "analysis_seconds": analysis_seconds,
	}

static func from_dict(d: Dictionary):
	if int(d.get("version", -1)) != VERSION:
		return null
	var a = load("res://analysis/track_analysis.gd").new()
	for key in d.keys():
		if key != "version" and key in a:
			a.set(key, d[key])
	a.rebuild_indices()
	return a

func rebuild_indices() -> void:
	section_starts = PackedFloat32Array()
	for s in sections:
		section_starts.append(float(s.start))

func summary() -> String:
	var types: Array = []
	for s in sections:
		types.append("%s@%.1fs(%d bars)" % [s.type, float(s.start), int(s.bars)])
	return "bpm=%.2f conf=%.2f beats=%d downbeat_conf=%.2f sections=[%s] analysis=%.2fs" % [bpm, tempo_confidence, beats.size(), downbeat_confidence, ", ".join(types), analysis_seconds]
