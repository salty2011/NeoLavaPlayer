extends RefCounted
## One published reactivity frame. The hub reuses a single instance and
## overwrites it every update: read it during the frame, or call snapshot()
## if you need to keep values. Ranges are documented in docs/REACTIVITY_API.md.

enum Tier { CALM, NORMAL, HIGH, PEAK }
const TIER_NAMES := ["calm", "normal", "high", "peak"]
const BAND_NAMES := ["sub", "bass", "lowmid", "mid", "presence", "high"]

var time: float = 0.0
var delta: float = 0.0
## Smoothed bands 0..1 (per-band attack/release, sensitivity applied).
var bands := PackedFloat32Array([0, 0, 0, 0, 0, 0])
## Unsmoothed bands 0..1 (sensitivity applied).
var bands_raw := PackedFloat32Array([0, 0, 0, 0, 0, 0])
var flux: float = 0.0          # raw spectral flux 0..1
var flux_smooth: float = 0.0   # smoothed flux 0..1
var onset: float = 0.0         # strength of an onset fired this frame, else 0
var onset_band: int = -1       # band index of that onset, else -1
var beat: bool = false
var beat_index: int = -1
var beat_strength: float = 0.0
## Estimated exact time of the most recent beat (the grid sample minus the
## source's beat phase); stays set between beats.
var beat_time: float = -INF
var downbeat: bool = false
var bar_index: int = -1
var beat_phase: float = 0.0    # 0..1 within the current beat
var bar_phase: float = 0.0     # 0..1 within the current 4/4 bar
var bpm: float = 0.0
var confidence: float = 0.0    # tempo/beat confidence 0..1
var downbeat_confidence: float = 0.0
var loudness_db: float = -70.0 # short-term LUFS-like
var energy: float = 0.0        # smoothed overall energy 0..1
var energy_raw: float = 0.0
var intensity: int = Tier.CALM
var intensity_name: String = "calm"
var section: String = "steady"
var section_index: int = -1
var section_changed: bool = false
var drop: bool = false         # a drop started this frame
var drop_time: float = -INF    # hub time of the most recent drop
var phrase: int = 0            # bars of a phrase starting this frame (16/8/4), else 0
var big_moment: bool = false
var big_kind: String = ""      # "drop" | "downbeat"
var build_progress: float = 0.0
var time_to_drop: float = INF
var time_to_next_beat: float = INF
var time_to_next_downbeat: float = INF
var next_section: String = ""
var anticipation: bool = false # false = live source, lookahead fields unavailable

func band(name: String) -> float:
	var i: int = BAND_NAMES.find(name)
	return bands[i] if i >= 0 else 0.0

func snapshot() -> Dictionary:
	var d: Dictionary = {}
	for p in get_property_list():
		if p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
			var v = get(p.name)
			d[p.name] = v.duplicate() if v is PackedFloat32Array else v
	return d
