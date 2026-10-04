extends RefCounted
## Silent synthetic analysis feed. sample(t) is a pure function of time, so the
## same tick times always produce the same inputs (determinism tests, silent QA).
## Output matches what SceneRuntime.step consumes: band_a (0..1 per band) and
## global_s (0..1), plus beat/onset flags and the current section name.
## Structure: 4/4 at bpm, looping the same section schedule as the Reactivity
## SyntheticSource (analysis/synthetic_source.gd SCHEDULE: 8 bars quiet,
## 8 bars build, 16 bars drop, 8 bars breakdown), so the classic scene input and
## the reactivity layer agree on beats and sections in mock mode
## (reactivity_source() builds the matching source). Schedules are configurable
## (--mock-sections=quiet:8,build:8,drop:16,breakdown:8).
## Low band: kick on every beat (build/drop). High band: hi-hat on off-beats.
## Middle bands: smooth pads. Kick peaks clamp to exactly 1.0 for ~15 ms, which
## exercises the original camera's A==1 counter.
const SyntheticSource = preload("res://analysis/synthetic_source.gd")
var bpm := 128.0
var band_count := 3
var schedule: Array = SyntheticSource.SCHEDULE

func _init(beats_per_minute: float = 128.0, bands: int = 3, sections: Array = []):
	bpm = clampf(beats_per_minute, 30.0, 300.0)
	band_count = maxi(bands, 1)
	if not sections.is_empty(): schedule = sections

func beat_length() -> float: return 60.0 / bpm

## Reactivity source with the same tempo, phase and section schedule.
func reactivity_source():
	return SyntheticSource.new(bpm, schedule)

func cycle_bars() -> int:
	var total := 0
	for entry in schedule: total += int(entry.bars)
	return maxi(total, 1)

## [section type, bar position within that section (fractional), section bars].
func _section_at(t: float) -> Array:
	var bar_position := fposmod(maxf(t, 0.0) / (beat_length() * 4.0), float(cycle_bars()))
	var start := 0.0
	for entry in schedule:
		if bar_position < start + float(entry.bars): return [String(entry.type), bar_position - start, float(entry.bars)]
		start += float(entry.bars)
	return [String(schedule[-1].type), 0.0, float(schedule[-1].bars)]

func section(t: float) -> String:
	return _section_at(t)[0]

func sample(t: float) -> Dictionary:
	t = maxf(t, 0.0)
	var beat := beat_length()
	var since_beat := fmod(t, beat)
	var since_offbeat := fmod(t + beat * 0.5, beat)
	var where := _section_at(t)
	var name: String = where[0]
	# Section energy: quiet floor, linear build ramp, full drop.
	var energy := 0.25
	var kick_level := 0.0
	var hat_level := 0.15
	if name == "build":
		var ramp: float = where[1] / where[2]
		energy = 0.35 + 0.45 * ramp
		kick_level = 0.6 + 0.3 * ramp
		hat_level = 0.3 + 0.5 * ramp
	elif name == "steady":
		energy = 0.6
		kick_level = 0.8
		hat_level = 0.5
	elif name == "drop":
		energy = 0.9
		kick_level = 1.0
		hat_level = 0.85
	var kick := clampf(1.15 * kick_level * exp(-since_beat / 0.11), 0.0, 1.0)
	var hat := clampf(1.1 * hat_level * exp(-since_offbeat / 0.05), 0.0, 1.0)
	var values := PackedFloat32Array()
	values.resize(band_count)
	for b in band_count:
		var value: float
		if b == 0: value = maxf(kick, 0.15 * energy)
		elif b == band_count - 1 and band_count > 1: value = maxf(hat, 0.1 * energy)
		else:
			# Pads: slow sine swells, a different phase per band.
			var swell := 0.5 + 0.5 * sin(TAU * t / (beat * 8.0) + float(b) * 1.7)
			value = clampf(energy * (0.35 + 0.45 * swell) + 0.25 * kick * energy, 0.0, 1.0)
		values[b] = value
	var global_s := clampf(energy * (0.85 + 0.15 * kick), 0.0, 1.0)
	return {"band_a": values, "global_s": global_s, "beat": since_beat < 0.06 and kick_level > 0.0, "onset": since_beat < 0.06 or since_offbeat < 0.03, "section": name}
