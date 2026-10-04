extends RefCounted
## Offline section segmentation, classification and phrase grid. Static + pure.
##
## Works on bar-level features (bars from the downbeat grid):
##   E    mean overall energy (0..1, track-relative loudness)
##   LOW  mean of normalised sub+bass       HIGH mean of presence+high
##   MID  mean of lowmid+mid                ONS  mean normalised spectral flux
## Segmentation: novelty = weighted distance between mean features of the w
## bars before and after each bar line (w <= 4), peak-picked with an adaptive
## threshold, min section length 4 bars, snapped to the 4-bar grid when the
## grid line is nearly as novel.
## Classification heuristics (relative to the track):
##   build      energy/high band rises across the section, not already at peak
##   drop       high energy with sub/bass present, entered from a lower or
##              bass-less section (bass re-entry)
##   breakdown  after a high-energy section: low energy or bass absent
##   quiet      low energy with no preceding high-energy section (intro/outro)
##   steady     everything else

const TYPES := ["quiet", "breakdown", "build", "drop", "steady"]
const FEATURE_WEIGHTS := [1.0, 1.3, 1.0, 0.6, 0.6]
const MIN_SECTION_BARS := 4

## bar_times: bar start times (downbeats) in seconds; frame_rate/time0 map frames to time.
## bands: frames*6 normalised; energy, flux: frames (0..1).
static func analyse(bar_times: PackedFloat32Array, duration: float, frame_rate: float, time0: float, bands: PackedFloat32Array, energy: PackedFloat32Array, flux: PackedFloat32Array) -> Dictionary:
	var bars := PackedFloat32Array()
	# Leading partial bar merges into the first bar.
	if bar_times.is_empty():
		var t: float = 0.0
		while t < duration:
			bars.append(t)
			t += 2.0
	else:
		bars = bar_times.duplicate()
	if bars[0] > 0.0:
		bars[0] = 0.0
	var nbars: int = bars.size()
	var feats: Array = [] # Array of PackedFloat32Array(5)
	var nf: int = energy.size()
	for k in nbars:
		var t0: float = bars[k]
		var t1: float = bars[k + 1] if k + 1 < nbars else duration
		var f0: int = clampi(int(floor((t0 - time0) * frame_rate)), 0, maxi(0, nf - 1))
		var f1: int = clampi(int(floor((t1 - time0) * frame_rate)), f0 + 1, nf)
		var v := PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0])
		for f in range(f0, f1):
			v[0] += energy[f]
			v[1] += 0.5 * (bands[f * 6] + bands[f * 6 + 1])
			v[2] += 0.5 * (bands[f * 6 + 4] + bands[f * 6 + 5])
			v[3] += 0.5 * (bands[f * 6 + 2] + bands[f * 6 + 3])
			v[4] += flux[f]
		var cnt: float = float(maxi(1, f1 - f0))
		for j in 5:
			v[j] /= cnt
		feats.append(v)
	# Novelty per bar line.
	var nov := PackedFloat32Array()
	nov.resize(nbars)
	nov.fill(0.0)
	for k in range(1, nbars):
		var w: int = mini(4, mini(k, nbars - k))
		if w < 1:
			continue
		var d: float = 0.0
		for j in 5:
			var a: float = 0.0
			var b: float = 0.0
			for i in w:
				a += feats[k - 1 - i][j]
				b += feats[k + i][j]
			var diff: float = (b - a) / float(w)
			d += FEATURE_WEIGHTS[j] * diff * diff
		# Short windows at the edges are less reliable.
		nov[k] = sqrt(d) * (0.6 if w < 2 else 1.0)
	var mean: float = 0.0
	for v in nov:
		mean += v
	mean /= maxf(1.0, float(nbars))
	var sd: float = 0.0
	for v in nov:
		sd += (v - mean) * (v - mean)
	sd = sqrt(sd / maxf(1.0, float(nbars)))
	var thresh: float = maxf(0.06, mean + 0.5 * sd)
	var cands: Array = []
	for k in range(1, nbars):
		var is_peak: bool = nov[k] >= thresh
		for o in range(-2, 3):
			var j: int = k + o
			if o != 0 and j > 0 and j < nbars and nov[j] > nov[k]:
				is_peak = false
		if is_peak:
			# Snap to the 4-bar grid when that line is nearly as novel.
			var kk: int = k
			var g: int = int(round(float(k) / 4.0)) * 4
			if g != k and g > 0 and g < nbars and absi(g - k) <= 1 and nov[g] >= 0.6 * nov[k]:
				kk = g
			cands.append([nov[k], kk])
	cands.sort_custom(func(x, y): return x[0] > y[0])
	var chosen: Array = []
	for c in cands:
		var k: int = c[1]
		if k < MIN_SECTION_BARS or nbars - k < 2:
			continue
		var ok: bool = true
		for other in chosen:
			if absi(other - k) < MIN_SECTION_BARS:
				ok = false
		if ok:
			chosen.append(k)
	chosen.sort()
	var bounds: Array = [0]
	bounds.append_array(chosen)
	bounds.append(nbars)
	# Track-level references.
	var bar_e := PackedFloat32Array()
	var bar_low := PackedFloat32Array()
	for f in feats:
		bar_e.append(f[0])
		bar_low.append(f[1])
	var e_lo: float = _percentile(bar_e, 0.1)
	var e_hi: float = _percentile(bar_e, 0.9)
	var low_hi: float = maxf(0.05, _percentile(bar_low, 0.9))
	var sections: Array = []
	for si in bounds.size() - 1:
		var b0: int = bounds[si]
		var b1: int = bounds[si + 1]
		var sum_e: float = 0.0
		var sum_low: float = 0.0
		var sum_high: float = 0.0
		var ys_e := PackedFloat32Array()
		var ys_h := PackedFloat32Array()
		for k in range(b0, b1):
			sum_e += feats[k][0]
			sum_low += feats[k][1]
			sum_high += feats[k][2]
			ys_e.append(feats[k][0])
			ys_h.append(feats[k][2])
		var n: float = float(b1 - b0)
		var rel: float = clampf((sum_e / n - e_lo) / maxf(1e-3, e_hi - e_lo), 0.0, 1.2)
		sections.append({
			"start_bar": b0, "bars": b1 - b0,
			"start": bars[b0], "end": bars[b1] if b1 < nbars else duration,
			"energy": rel, "low": (sum_low / n) / low_hi, "high": sum_high / n,
			"rise_e": _slope(ys_e) * maxf(1.0, n - 1.0), "rise_h": _slope(ys_h) * maxf(1.0, n - 1.0),
			"type": "steady",
		})
	_classify(sections)
	sections = _merge(sections)
	# Phrase grid: every 4 bars from each section start; size = 16/8/4 by alignment.
	var phrase_times := PackedFloat32Array()
	var phrase_bars := PackedInt32Array()
	for s in sections:
		var off: int = 0
		while off < int(s.bars):
			var k: int = int(s.start_bar) + off
			if k < nbars:
				phrase_times.append(bars[k])
				phrase_bars.append(16 if off % 16 == 0 else (8 if off % 8 == 0 else 4))
			off += 4
	return {"sections": sections, "phrase_times": phrase_times, "phrase_bars": phrase_bars, "novelty": nov, "bar_times": bars}

static func _classify(sections: Array) -> void:
	var prev_high: bool = false
	for i in sections.size():
		var s: Dictionary = sections[i]
		var prev: Dictionary = sections[i - 1] if i > 0 else {}
		var nxt: Dictionary = sections[i + 1] if i + 1 < sections.size() else {}
		var rel: float = s.energy
		var rising: bool = (s.rise_e >= 0.12 or s.rise_h >= 0.18) and rel < 0.85
		var bass_on: bool = s.low >= 0.55
		var t: String = "steady"
		if rising and (nxt.is_empty() or nxt.energy > rel + 0.1 or nxt.low > s.low + 0.2):
			t = "build"
		elif rel >= 0.6 and bass_on and (prev.is_empty() == false) and (prev.energy < rel - 0.15 or prev.low < 0.6 * s.low or prev.type == "build"):
			t = "drop"
		elif prev_high and (rel < 0.45 or s.low < 0.35):
			t = "breakdown"
		elif rel < 0.3:
			t = "quiet"
		elif rising:
			t = "build"
		s.type = t
		if t == "drop" or (rel >= 0.6 and bass_on):
			prev_high = true
		elif t == "quiet":
			prev_high = prev_high and rel > 0.2

static func _merge(sections: Array) -> Array:
	var out: Array = []
	for s in sections:
		if not out.is_empty():
			var last: Dictionary = out[-1]
			var same: bool = last.type == s.type and s.type != "drop"
			# A steady high section right after a drop at similar energy continues the drop.
			var drop_cont: bool = last.type == "drop" and s.type == "steady" and absf(float(s.energy) - float(last.energy)) < 0.2 and s.low >= 0.55
			if same or drop_cont:
				var total: float = float(last.bars + s.bars)
				last.energy = (float(last.energy) * last.bars + float(s.energy) * s.bars) / total
				last.low = (float(last.low) * last.bars + float(s.low) * s.bars) / total
				last.bars = int(last.bars) + int(s.bars)
				last.end = s.end
				continue
		out.append(s)
	return out

static func _slope(y: PackedFloat32Array) -> float:
	var n: int = y.size()
	if n < 2:
		return 0.0
	var sx: float = 0.0
	var sy: float = 0.0
	var sxx: float = 0.0
	var sxy: float = 0.0
	for i in n:
		sx += float(i)
		sy += y[i]
		sxx += float(i * i)
		sxy += float(i) * y[i]
	var den: float = float(n) * sxx - sx * sx
	return (float(n) * sxy - sx * sy) / den if den > 0.0 else 0.0

static func _percentile(a: PackedFloat32Array, q: float) -> float:
	if a.is_empty():
		return 0.0
	var s := a.duplicate()
	s.sort()
	return s[clampi(int(q * float(s.size() - 1)), 0, s.size() - 1)]
