extends RefCounted
## Offline tempo estimation, beat tracking and downbeat estimation.
## All functions are static and pure (safe on worker threads).
##
## - estimate_tempo(): autocorrelation (via FFT) of the onset envelope scored by
##   a 4-tap comb (lags L, 2L, 3L, 4L) plus half-beat taps (L/2, 3L/2) and a log-Gaussian tempo prior centred on
##   120 BPM, which resolves octave ambiguity towards the ~90-150 BPM range.
## - track_beats(): dynamic programming beat tracker (Ellis 2007), with
##   parabolic sub-frame refinement of each beat.
## - refine_bpm(): least-squares fit of beat time vs index over the longest
##   steady run (frame quantisation alone would give ~2.5% BPM error).
## - estimate_downbeats(): picks the 4/4 bar phase (0..3) maximising combined
##   low-frequency accent, spectral novelty at bar lines and energy change.

const FFT := preload("res://analysis/fft.gd")

const MIN_BPM := 60.0
const MAX_BPM := 200.0
const PRIOR_CENTER_BPM := 120.0
const PRIOR_OCTAVES := 0.9
const TIGHTNESS := 100.0

static func autocorrelate(env: PackedFloat32Array, max_lag: int) -> PackedFloat64Array:
	var n: int = env.size()
	var mean: float = 0.0
	for v in env:
		mean += v
	mean /= maxf(1.0, float(n))
	var size: int = 1
	while size < 2 * n:
		size <<= 1
	var re := PackedFloat64Array()
	var im := PackedFloat64Array()
	re.resize(size)
	im.resize(size)
	re.fill(0.0)
	im.fill(0.0)
	for i in n:
		re[i] = env[i] - mean
	var spec: Array = FFT.complex_transform(re, im, false)
	var sr: PackedFloat64Array = spec[0]
	var si: PackedFloat64Array = spec[1]
	for k in size:
		sr[k] = sr[k] * sr[k] + si[k] * si[k]
		si[k] = 0.0
	var back: Array = FFT.complex_transform(sr, si, true)
	var ac := PackedFloat64Array()
	var lags: int = mini(max_lag + 1, n)
	ac.resize(lags)
	var zero: float = maxf(1e-12, back[0][0])
	for lag in lags:
		# Unbiased-ish: compensate for the shrinking overlap.
		ac[lag] = back[0][lag] / zero * float(n) / float(maxi(1, n - lag))
	return ac

static func _interp(ac: PackedFloat64Array, x: float) -> float:
	var i: int = int(floor(x))
	if i < 0 or i + 1 >= ac.size():
		return 0.0
	var f: float = x - float(i)
	return ac[i] * (1.0 - f) + ac[i + 1] * f

static func tempo_prior(bpm: float) -> float:
	var o: float = log(bpm / PRIOR_CENTER_BPM) / log(2.0) / PRIOR_OCTAVES
	return exp(-0.5 * o * o)

## Returns {bpm, confidence, scores(PackedFloat32Array over bpm grid)}.
static func estimate_tempo(env: PackedFloat32Array, frame_rate: float) -> Dictionary:
	var max_lag: int = int(ceil(4.0 * 60.0 * frame_rate / MIN_BPM)) + 2
	var ac := autocorrelate(env, max_lag)
	var best_bpm: float = 120.0
	var best: float = -INF
	var scores := PackedFloat32Array()
	var bpm: float = MIN_BPM
	var sum_scores: float = 0.0
	while bpm <= MAX_BPM + 1e-6:
		var lag: float = 60.0 * frame_rate / bpm
		var s: float = 0.0
		for m in range(1, 5):
			s += _interp(ac, lag * float(m))
		# Half-beat subdivision support separates true tempi from 3:2 metrical
		# errors (e.g. 174 vs 116), whose half-lag falls between events.
		s += 0.5 * (_interp(ac, lag * 0.5) + _interp(ac, lag * 1.5))
		s = maxf(0.0, s) * tempo_prior(bpm)
		scores.append(s)
		sum_scores += s
		if s > best:
			best = s
			best_bpm = bpm
		bpm += 0.05
	# Parabolic refinement on the grid.
	var mean_score: float = sum_scores / maxf(1.0, float(scores.size()))
	var confidence: float = clampf((best - mean_score) / maxf(1e-9, best), 0.0, 1.0) if best > 0.0 else 0.0
	return {"bpm": best_bpm, "confidence": confidence, "scores": scores}

## Ellis DP beat tracker. Returns {frames: PackedFloat32Array (fractional frame
## positions), strengths: PackedFloat32Array (0..1)}.
static func track_beats(env: PackedFloat32Array, frame_rate: float, bpm: float) -> Dictionary:
	var n: int = env.size()
	var period: float = 60.0 * frame_rate / bpm
	# Normalise by standard deviation.
	var mean: float = 0.0
	for v in env:
		mean += v
	mean /= maxf(1.0, float(n))
	var var_: float = 0.0
	for v in env:
		var_ += (v - mean) * (v - mean)
	var sd: float = sqrt(var_ / maxf(1.0, float(n - 1)))
	if sd <= 1e-9 or n < int(period * 4.0):
		return {"frames": PackedFloat32Array(), "strengths": PackedFloat32Array()}
	# Local score: onset envelope convolved with a narrow Gaussian (sigma = period/32).
	var sigma: float = maxf(0.75, period / 32.0)
	var radius: int = int(ceil(3.0 * sigma))
	var kern := PackedFloat32Array()
	for k in range(-radius, radius + 1):
		kern.append(exp(-0.5 * pow(float(k) / sigma, 2.0)))
	var local := PackedFloat32Array()
	local.resize(n)
	for i in n:
		var acc: float = 0.0
		for k in range(-radius, radius + 1):
			var j: int = i + k
			if j >= 0 and j < n:
				acc += env[j] / sd * kern[k + radius]
		local[i] = acc
	# DP.
	var lo_off: int = int(round(period / 2.0))
	var hi_off: int = int(round(period * 2.0))
	var penalty := PackedFloat32Array()
	penalty.resize(hi_off + 1)
	for d in range(1, hi_off + 1):
		var l: float = log(float(d) / period)
		penalty[d] = -TIGHTNESS * l * l
	var cum := PackedFloat32Array()
	cum.resize(n)
	var back := PackedInt32Array()
	back.resize(n)
	var first: bool = true
	for i in n:
		var best: float = -INF
		var arg: int = -1
		var d0: int = lo_off
		var d1: int = mini(hi_off, i)
		for d in range(d0, d1 + 1):
			var c: float = cum[i - d] + penalty[d]
			if c > best:
				best = c
				arg = i - d
		if arg < 0 or (first and best < 0.0 and i < hi_off):
			cum[i] = local[i]
			back[i] = -1
		else:
			cum[i] = local[i] + best
			back[i] = arg
			first = false
	# Last beat: final local maximum of cum above half the median of maxima.
	var maxima := PackedFloat32Array()
	for i in range(1, n - 1):
		if cum[i] > cum[i - 1] and cum[i] >= cum[i + 1]:
			maxima.append(cum[i])
	if maxima.is_empty():
		return {"frames": PackedFloat32Array(), "strengths": PackedFloat32Array()}
	var sorted := maxima.duplicate()
	sorted.sort()
	var thresh: float = 0.5 * sorted[sorted.size() / 2]
	var last: int = -1
	for i in range(n - 2, 0, -1):
		if cum[i] > cum[i - 1] and cum[i] >= cum[i + 1] and cum[i] >= thresh:
			last = i
			break
	var idx := PackedInt32Array()
	var b: int = last
	while b >= 0:
		idx.append(b)
		b = back[b]
	idx.reverse()
	# Trim weak leading/trailing beats (silence before/after music).
	var rms: float = 0.0
	for i in idx:
		rms += local[i] * local[i]
	rms = sqrt(rms / maxf(1.0, float(idx.size())))
	var s0: int = 0
	var s1: int = idx.size()
	while s0 < s1 and local[idx[s0]] < 0.25 * rms:
		s0 += 1
	while s1 > s0 and local[idx[s1 - 1]] < 0.25 * rms:
		s1 -= 1
	var frames := PackedFloat32Array()
	var strengths := PackedFloat32Array()
	var peak: float = 0.0
	for i in range(s0, s1):
		peak = maxf(peak, local[idx[i]])
	for i in range(s0, s1):
		var f: int = idx[i]
		var pos: float = float(f)
		# Snap to the local peak of the onset local score within +-2 frames, then
		# parabolic sub-frame interpolation.
		var bf: int = f
		for k in range(-2, 3):
			var j: int = f + k
			if j > 0 and j < n - 1 and local[j] > local[bf]:
				bf = j
		if bf > 0 and bf < n - 1:
			var y0: float = local[bf - 1]
			var y1: float = local[bf]
			var y2: float = local[bf + 1]
			var den: float = y0 - 2.0 * y1 + y2
			pos = float(bf)
			if absf(den) > 1e-9 and y1 >= y0 and y1 >= y2:
				pos += clampf(0.5 * (y0 - y2) / den, -0.5, 0.5)
		# Only accept the snap when there is a real onset; else keep the DP grid position.
		if local[bf] < 0.25 * rms:
			pos = float(f)
		frames.append(pos)
		strengths.append(clampf(local[f] / maxf(1e-9, peak), 0.0, 1.0))
	return {"frames": frames, "strengths": strengths}

## Least-squares tempo over the longest run of steady inter-beat intervals.
static func refine_bpm(beat_times: PackedFloat32Array, fallback: float) -> float:
	var n: int = beat_times.size()
	if n < 8:
		return fallback
	var ibis := PackedFloat32Array()
	for i in range(1, n):
		ibis.append(beat_times[i] - beat_times[i - 1])
	var sorted := ibis.duplicate()
	sorted.sort()
	var med: float = sorted[sorted.size() / 2]
	var best_s: int = 0
	var best_len: int = 0
	var cur_s: int = 0
	for i in ibis.size() + 1:
		var ok: bool = i < ibis.size() and absf(ibis[i] - med) < 0.12 * med
		if not ok:
			if i - cur_s > best_len:
				best_len = i - cur_s
				best_s = cur_s
			cur_s = i + 1
	if best_len < 6:
		return 60.0 / med
	# Fit t = a + b*k over beats best_s .. best_s+best_len.
	var sx: float = 0.0
	var sy: float = 0.0
	var sxx: float = 0.0
	var sxy: float = 0.0
	var cnt: float = float(best_len + 1)
	for k in best_len + 1:
		var x: float = float(k)
		var y: float = beat_times[best_s + k]
		sx += x
		sy += y
		sxx += x * x
		sxy += x * y
	var slope: float = (cnt * sxy - sx * sy) / maxf(1e-12, cnt * sxx - sx * sx)
	return 60.0 / slope if slope > 0.0 else fallback

## Returns {phase: int (beat index of the first downbeat, 0..3), confidence: 0..1, scores}.
## band_norm: frames*6 normalised bands; logspec: frames*nlog; energy: frames.
static func estimate_downbeats(beat_frames: PackedFloat32Array, band_norm: PackedFloat32Array, nbands: int, logspec: PackedFloat32Array, nlog: int, energy: PackedFloat32Array) -> Dictionary:
	var nb: int = beat_frames.size()
	var nf: int = energy.size()
	if nb < 8:
		return {"phase": 0, "confidence": 0.0, "scores": [0.0, 0.0, 0.0, 0.0]}
	var low := PackedFloat32Array()
	var nov := PackedFloat32Array()
	var echg := PackedFloat32Array()
	low.resize(nb)
	nov.resize(nb)
	echg.resize(nb)
	var prev_vec := PackedFloat32Array()
	var beat_energy := PackedFloat32Array()
	beat_energy.resize(nb)
	for b in nb:
		var f0: int = clampi(int(round(beat_frames[b])), 0, nf - 1)
		var f1: int = clampi(int(round(beat_frames[b + 1])) if b + 1 < nb else f0 + 40, f0 + 1, nf)
		# Low-frequency accent just after the beat.
		var la: float = 0.0
		for f in range(maxi(0, f0 - 1), mini(nf, f0 + 4)):
			la = maxf(la, 0.5 * (band_norm[f * nbands] + band_norm[f * nbands + 1]))
		low[b] = la
		var vec := PackedFloat32Array()
		vec.resize(nlog)
		vec.fill(0.0)
		var e: float = 0.0
		for f in range(f0, f1):
			e += energy[f]
			for j in nlog:
				vec[j] += logspec[f * nlog + j]
		var cnt: float = float(maxi(1, f1 - f0))
		beat_energy[b] = e / cnt
		var d: float = 0.0
		for j in nlog:
			vec[j] /= cnt
			if not prev_vec.is_empty():
				d += absf(vec[j] - prev_vec[j])
		nov[b] = d
		prev_vec = vec
	for b in nb:
		var before: float = 0.0
		var after: float = 0.0
		var cb: int = 0
		var ca: int = 0
		for k in range(1, 5):
			if b - k >= 0:
				before += beat_energy[b - k]
				cb += 1
			if b + k - 1 < nb:
				after += beat_energy[b + k - 1]
				ca += 1
		echg[b] = absf(after / maxf(1.0, float(ca)) - before / maxf(1.0, float(cb))) if cb > 0 and ca > 0 else 0.0
	var feats := [_zscore(low), _zscore(nov), _zscore(echg)]
	var weights := [0.8, 1.0, 0.7]
	var scores := [0.0, 0.0, 0.0, 0.0]
	var counts := [0, 0, 0, 0]
	for b in nb:
		var s: float = 0.0
		for fi in feats.size():
			s += weights[fi] * feats[fi][b]
		scores[b % 4] += s
		counts[b % 4] += 1
	var best: int = 0
	for p in 4:
		scores[p] /= maxf(1.0, float(counts[p]))
		if scores[p] > scores[best]:
			best = p
	var second: float = -INF
	for p in 4:
		if p != best:
			second = maxf(second, scores[p])
	var margin: float = scores[best] - second
	var confidence: float = clampf(1.0 - exp(-margin / 0.25), 0.0, 1.0)
	return {"phase": best, "confidence": confidence, "scores": scores}

static func _zscore(a: PackedFloat32Array) -> PackedFloat32Array:
	var n: int = a.size()
	var m: float = 0.0
	for v in a:
		m += v
	m /= maxf(1.0, float(n))
	var s: float = 0.0
	for v in a:
		s += (v - m) * (v - m)
	s = sqrt(s / maxf(1.0, float(n)))
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		out[i] = (a[i] - m) / s if s > 1e-9 else 0.0
	return out
