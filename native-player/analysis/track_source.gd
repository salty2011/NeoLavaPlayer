extends RefCounted
## Reactivity source backed by an offline TrackAnalysis (full lookahead).
## sample(t) is a pure lookup: any t, any order, so seeking just works.
## native_rate() lets the hub sub-step at the timeline rate, which makes the
## smoothed output independent of the render frame rate.

var analysis

func _init(track_analysis = null) -> void:
	analysis = track_analysis

func native_rate() -> float:
	return analysis.frame_rate if analysis != null else 0.0

func sample(t: float) -> Dictionary:
	var a = analysis
	if a == null or a.num_frames == 0:
		return {}
	var f: int = a.frame_index(t)
	var bi: int = a.beat_index_at(t)
	var oi: int = a.onset_index_at(t)
	var si: int = a.section_index_at(t)
	var pi: int = a.phrase_index_at(t)
	var sec: Dictionary = a.sections[si] if si >= 0 else {}
	var nxt: Dictionary = a.next_section(t)
	return {
		"bands": a.bands.slice(f * 6, f * 6 + 6),
		"flux": a.flux[f],
		"energy": a.energy[f],
		"loudness_db": a.loudness[f],
		"beat_index": bi,
		"beat_phase": a.beat_phase(t),
		"beat_strength": a.beat_strengths[bi] if bi >= 0 and bi < a.beat_strengths.size() else 0.0,
		"bar_index": a.bar_index_at(t),
		"bar_phase": a.bar_phase(t),
		"onset_index": oi,
		"onset_strength": a.onset_strengths[oi] if oi >= 0 else 0.0,
		"onset_band": a.onset_bands[oi] if oi >= 0 else 0,
		"bpm": a.bpm,
		"confidence": a.tempo_confidence,
		"downbeat_confidence": a.downbeat_confidence,
		"section": String(sec.get("type", "steady")),
		"section_index": si,
		"next_section": String(nxt.get("type", "")),
		"time_to_next_section": float(nxt.get("time_until", INF)),
		"phrase_index": pi,
		"phrase_bars": a.phrase_bars[pi] if pi >= 0 else 0,
		"build_progress": a.build_progress(t),
		"time_to_drop": a.time_to_drop(t),
		"time_to_next_beat": a.time_to_next_beat(t),
		"time_to_next_downbeat": a.time_to_next_downbeat(t),
		"time_to_next_phrase": a.time_to_next_phrase(t),
		"anticipation": true,
	}
