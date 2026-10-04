extends RefCounted
## Deterministic synthetic dance-track generator for tests (never played aloud).
##
## generate() renders mono PCM with a 4/4 kick/hat/bass arrangement and returns
## the ground truth: beat times, downbeat times and section spans.
## Default layout (the test track): quiet intro 8 bars -> build 8 bars (rising
## noise + snare roll) -> drop 16 bars (kick, offbeat bass, crash) -> breakdown 8
## bars (pad, hats, claps, no kick/bass).

const DEFAULT_LAYOUT := [
	{"type": "quiet", "bars": 8},
	{"type": "build", "bars": 8},
	{"type": "drop", "bars": 16},
	{"type": "breakdown", "bars": 8},
]
## Bass root per bar (Hz): A1, F1, C2, G1 progression.
const BASS_NOTES := [55.0, 43.65, 65.41, 49.0]

static func generate(bpm: float = 128.0, rate: float = 22050.0, layout: Array = DEFAULT_LAYOUT, seed_value: int = 1234, lead_in: float = 0.0) -> Dictionary:
	var beat_len: float = 60.0 / bpm
	var bar_len: float = beat_len * 4.0
	var total_bars: int = 0
	for s in layout:
		total_bars += int(s.bars)
	var duration: float = lead_in + float(total_bars) * bar_len + 1.0
	var n: int = int(duration * rate)
	var out := PackedFloat32Array()
	out.resize(n)
	out.fill(0.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var noise := PackedFloat32Array()
	noise.resize(int(rate * 1.2))
	for i in noise.size():
		noise[i] = rng.randf_range(-1.0, 1.0)
	var beats := PackedFloat32Array()
	var downbeats := PackedFloat32Array()
	var sections: Array = []
	var bar: int = 0
	for s in layout:
		var sec_start: float = lead_in + float(bar) * bar_len
		sections.append({"type": s.type, "start": sec_start, "end": sec_start + float(s.bars) * bar_len, "start_bar": bar, "bars": int(s.bars)})
		for b in int(s.bars):
			var bar_t: float = lead_in + float(bar + b) * bar_len
			var progress: float = float(b) / float(s.bars)
			downbeats.append(bar_t)
			var note: float = BASS_NOTES[(bar + b) % BASS_NOTES.size()]
			for q in 4:
				var t: float = bar_t + float(q) * beat_len
				beats.append(t)
				match String(s.type):
					"quiet":
						_kick(out, rate, t, 0.22)
						_hat(out, rate, t + beat_len * 0.5, 0.035, noise, rng)
					"build":
						_kick(out, rate, t, 0.32)
						_hat(out, rate, t + beat_len * 0.5, 0.05, noise, rng)
						# Snare roll accelerates: 4ths -> 8ths -> 16ths.
						var div: int = 1 if progress < 0.5 else (2 if progress < 0.75 else 4)
						for r in div:
							_snare(out, rate, t + beat_len * float(r) / float(div), 0.05 + 0.18 * progress, noise, rng)
					"drop":
						_kick(out, rate, t, 0.6)
						_hat(out, rate, t + beat_len * 0.5, 0.09, noise, rng)
						_hat(out, rate, t, 0.04, noise, rng)
						_bass(out, rate, t + beat_len * 0.5, beat_len * 0.45, note, 0.32)
						if q == 0 and b % 4 == 0:
							_crash(out, rate, t, 0.12, noise, rng)
					"breakdown":
						_hat(out, rate, t, 0.05, noise, rng)
						_hat(out, rate, t + beat_len * 0.5, 0.025, noise, rng)
						if q == 1 or q == 3:
							_snare(out, rate, t, 0.1, noise, rng)
			if String(s.type) == "breakdown" or String(s.type) == "quiet":
				_pad(out, rate, bar_t, bar_len, note * 4.0, 0.05 if String(s.type) == "breakdown" else 0.025)
		if String(s.type) == "build":
			_riser(out, rate, sec_start, float(s.bars) * bar_len, 0.35, rng)
		bar += int(s.bars)
	return {"pcm": out, "rate": rate, "bpm": bpm, "beats": beats, "downbeats": downbeats, "sections": sections, "bar_len": bar_len, "duration": duration}

static func _kick(out: PackedFloat32Array, rate: float, t: float, amp: float) -> void:
	var s0: int = int(t * rate)
	var len: int = int(0.3 * rate)
	var phase: float = 0.0
	for i in len:
		var idx: int = s0 + i
		if idx < 0 or idx >= out.size():
			continue
		var tt: float = float(i) / rate
		var f: float = 50.0 + 110.0 * exp(-tt / 0.03)
		phase += TAU * f / rate
		out[idx] += amp * sin(phase) * exp(-tt / 0.12)

static func _hat(out: PackedFloat32Array, rate: float, t: float, amp: float, noise: PackedFloat32Array, rng: RandomNumberGenerator) -> void:
	var s0: int = int(t * rate)
	var len: int = int(0.05 * rate)
	var off: int = rng.randi_range(0, noise.size() - len - 2)
	for i in len:
		var idx: int = s0 + i
		if idx < 0 or idx >= out.size():
			continue
		# First difference = crude high-pass.
		var v: float = noise[off + i + 1] - noise[off + i]
		out[idx] += amp * v * exp(-float(i) / rate / 0.012)

static func _snare(out: PackedFloat32Array, rate: float, t: float, amp: float, noise: PackedFloat32Array, rng: RandomNumberGenerator) -> void:
	var s0: int = int(t * rate)
	var len: int = int(0.12 * rate)
	var off: int = rng.randi_range(0, noise.size() - len - 1)
	for i in len:
		var idx: int = s0 + i
		if idx < 0 or idx >= out.size():
			continue
		var tt: float = float(i) / rate
		out[idx] += amp * (0.8 * noise[off + i] + 0.4 * sin(TAU * 190.0 * tt)) * exp(-tt / 0.045)

static func _crash(out: PackedFloat32Array, rate: float, t: float, amp: float, noise: PackedFloat32Array, rng: RandomNumberGenerator) -> void:
	var s0: int = int(t * rate)
	var len: int = int(1.1 * rate)
	for i in len:
		var idx: int = s0 + i
		if idx < 0 or idx >= out.size() or i + 1 >= noise.size():
			continue
		out[idx] += amp * (noise[i + 1] - noise[i]) * exp(-float(i) / rate / 0.4)

static func _bass(out: PackedFloat32Array, rate: float, t: float, dur: float, freq: float, amp: float) -> void:
	var s0: int = int(t * rate)
	var len: int = int(dur * rate)
	for i in len:
		var idx: int = s0 + i
		if idx < 0 or idx >= out.size():
			continue
		var tt: float = float(i) / rate
		var env: float = minf(1.0, tt / 0.005) * minf(1.0, (dur - tt) / 0.02)
		out[idx] += amp * env * (sin(TAU * freq * tt) + 0.5 * sin(TAU * 2.0 * freq * tt) + 0.25 * sin(TAU * 3.0 * freq * tt))

static func _pad(out: PackedFloat32Array, rate: float, t: float, dur: float, freq: float, amp: float) -> void:
	var s0: int = int(t * rate)
	var len: int = int(dur * rate)
	for i in len:
		var idx: int = s0 + i
		if idx < 0 or idx >= out.size():
			continue
		var tt: float = float(i) / rate
		var env: float = minf(1.0, tt / 0.3) * minf(1.0, (dur - tt) / 0.3)
		out[idx] += amp * env * (sin(TAU * freq * tt) + sin(TAU * freq * 1.26 * tt) + sin(TAU * freq * 1.5 * tt))

static func _riser(out: PackedFloat32Array, rate: float, t: float, dur: float, amp: float, rng: RandomNumberGenerator) -> void:
	var s0: int = int(t * rate)
	var len: int = int(dur * rate)
	var lp: float = 0.0
	var prev: float = 0.0
	for i in len:
		var idx: int = s0 + i
		if idx < 0 or idx >= out.size():
			continue
		var p: float = float(i) / float(len)
		# One-pole low-pass opening up over the build, then high-passed.
		var a: float = 0.05 + 0.9 * p
		var w: float = rng.randf_range(-1.0, 1.0)
		lp += a * (w - lp)
		var hp: float = lp - prev
		prev = lp
		out[idx] += amp * p * p * (0.5 * lp + hp)
