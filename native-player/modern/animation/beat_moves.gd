extends RefCounted
## Beat-synced character moves (Phase 4d). Each move is a pure function of the
## beat position (beat index + phase) and bar phase, with its extreme exactly on
## a beat (phase 0), so motion peaks land on the beat at any frame rate.
## Output is in the character's rig frame:
##   lateral (sideways), up, inward (toward the scene centre), twist (radians).
## Amplitudes come from profile data ("animation.moves"); see
## docs/DIRECTOR_AND_ANIMATION.md.

const NAMES := ["bob", "hop", "sway", "twist", "lean_in"]

## Sharp beat-locked peak: 1 on the beat, 0 half a beat later, C1-continuous.
static func beat_peak(phase: float, sharpness: float = 2.0) -> float:
	return pow(0.5 + 0.5 * cos(TAU * phase), sharpness)

## Move value at beat position bp (= beat_index + beat_phase) and bar phase.
## Returns {lateral, up, inward, twist} for unit amplitude; `scalar` is the
## signed value the tests check for beat alignment.
static func evaluate(move: String, bp: float, bar_phase: float, amp: Dictionary) -> Dictionary:
	var phase := bp - floorf(bp)
	var out := {"lateral": 0.0, "up": 0.0, "inward": 0.0, "twist": 0.0, "scalar": 0.0}
	match move:
		"bob":   # nod down on every beat
			var v := -beat_peak(phase, 2.0)
			out.up = v * float(amp.get("amp", 0.05))
			out.scalar = v
		"hop":   # rise to the beat, sharper
			var v := beat_peak(phase, 3.0)
			out.up = v * float(amp.get("amp", 0.07))
			out.scalar = v
		"sway":  # side to side, a full swing every two beats, extremes on beats
			var v := cos(PI * bp)
			out.lateral = v * float(amp.get("amp", 0.07))
			out.up = -absf(v) * float(amp.get("amp", 0.07)) * 0.15
			out.scalar = v
		"twist": # turn left/right about the stem, extremes on beats
			var v := cos(PI * bp)
			out.twist = v * deg_to_rad(float(amp.get("amp_deg", 8.0)))
			out.scalar = v
		"lean_in": # lean toward the centre on the downbeat
			var v := beat_peak(bar_phase - floorf(bar_phase), 2.0)
			out.inward = v * float(amp.get("amp", 0.07))
			out.up = -v * float(amp.get("amp", 0.07)) * 0.3
			out.scalar = v
	return out
