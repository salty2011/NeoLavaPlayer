extends RefCounted
## Realtime analysis for streams without pre-analysis (e.g. AudioEffectCapture).
## Consumes PCM blocks and keeps the same output fields as TrackSource, but with
## no lookahead: `anticipation` is false, time_to_drop is INF, and sections are
## inferred causally (a drop is recognised when bass re-enters, not before).
##
## Implements the Reactivity source interface: sample(time) -> Dictionary.
## `time` is in this analyzer's stream clock (`stream_time`, seconds of audio
## consumed); pass the same clock to the hub (Reactivity.update_time).
##
##   var live = LiveAnalyzer.new(AudioServer.get_mix_rate())
##   live.push_frames(capture.get_buffer(capture.get_frames_available()))
##   hub.update_time(live.stream_time)

const FeatureExtractor := preload("res://analysis/feature_extractor.gd")
const TempoTracker := preload("res://analysis/tempo_tracker.gd")

const RATE := 22050.0
const ONSET_DELTA := 0.06
const MIN_ONSET_GAP := 0.03
const ENV_SECONDS := 8.0
const TEMPO_INTERVAL := 1.0
const AGC_RELEASE := 8.0
const AGC_RANGE_DB := 24.0
const PLL_PHASE_GAIN := 0.25
const PLL_PERIOD_GAIN := 0.03
const DROP_JUMP_DB := 5.0

var input_rate: float = 44100.0
var stream_time: float = 0.0
var frame_rate: float = 0.0

# Latest outputs.
var bands := PackedFloat32Array([0, 0, 0, 0, 0, 0])
var flux: float = 0.0
var energy: float = 0.0
var loudness_db: float = -70.0
var onset_index: int = -1
var onset_strength: float = 0.0
var onset_band: int = 0
var bpm: float = 0.0
var tempo_confidence: float = 0.0
var beat_index: int = -1
var beat_strength: float = 0.0
var last_beat_time: float = -1.0
var next_beat_time: float = INF
var bar_offset: int = 0
var downbeat_confidence: float = 0.0
var section: String = "quiet"
var section_index: int = 0
var build_progress: float = 0.0

var _fx
var _resample_frac: float = 0.0
var _prev_in: float = 0.0
var _prev_raw: float = 0.0
var _band_hi := PackedFloat32Array([-40, -40, -40, -40, -40, -40])
var _band_lo := PackedFloat32Array([-64, -64, -64, -64, -64, -64])
var _flux_peak: float = 1e-3
var _flux_hist := PackedFloat32Array() # normalised flux, recent frames
var _env := PackedFloat32Array()       # raw flux for tempo
var _since_tempo: float = 0.0
var _tempo_candidate: float = 0.0
var _tempo_votes: int = 0
var _period: float = 0.5
var _hits: float = 0.0
var _last_onset_frame: int = -1000
var _frame_count: int = 0
var _kp_mom: float = 0.0
var _kp_short: float = 0.0
var _e_hi: float = -30.0
var _bar_scores := PackedFloat32Array([0, 0, 0, 0])
var _interval_vec := PackedFloat32Array([0, 0, 0, 0, 0, 0])
var _interval_frames: int = 0
var _interval_low_pow: float = 0.0
var _interval_high_pow: float = 0.0
var _beat_low_db := PackedFloat32Array()
var _beat_high_db := PackedFloat32Array()
var _drop_low_db: float = -120.0
var _low_peak_db: float = -120.0
var _prev_vec := PackedFloat32Array()
var _accent: float = 0.0
var _beat_low := PackedFloat32Array() # per-beat mean low, recent
var _beat_energy := PackedFloat32Array()
var _bass_absent_beats: int = 0
var _section_beats: int = 0
var _had_high: bool = false

func _init(rate: float = 44100.0) -> void:
	input_rate = rate
	_fx = FeatureExtractor.new(RATE, 1024, 256)
	_fx.keep_history = false
	frame_rate = _fx.frame_rate

## Stereo frames as delivered by AudioEffectCapture.get_buffer().
func push_frames(frames: PackedVector2Array) -> void:
	var mono := PackedFloat32Array()
	mono.resize(frames.size())
	for i in frames.size():
		mono[i] = 0.5 * (frames[i].x + frames[i].y)
	push_mono(mono)

## Mono samples at input_rate.
func push_mono(samples: PackedFloat32Array) -> void:
	var ratio: float = input_rate / RATE
	var out := PackedFloat32Array()
	if absf(ratio - 1.0) < 1e-6:
		out = samples
	else:
		var filt: bool = ratio > 1.4
		var frac: float = _resample_frac
		var prev: float = _prev_in
		var raw_prev: float = _prev_raw
		for x0 in samples:
			var x: float = 0.5 * (x0 + raw_prev) if filt else x0
			raw_prev = x0
			while frac <= 1.0:
				out.append(prev + (x - prev) * frac)
				frac += ratio
			frac -= 1.0
			prev = x
		_resample_frac = frac
		_prev_in = prev
		_prev_raw = raw_prev
	stream_time += float(samples.size()) / input_rate
	var n: int = _fx.push(out)
	for i in n:
		_on_frame(i)

func _on_frame(i: int) -> void:
	var dt: float = 1.0 / frame_rate
	var tf: float = float(_frame_count) / frame_rate + 0.5 * 1024.0 / RATE + 0.005
	_frame_count += 1
	var rel: float = 1.0 - exp(-dt / AGC_RELEASE)
	for b in 6:
		var db: float = _fx.band_db[i * 6 + b]
		if db > _band_hi[b]:
			_band_hi[b] = db
		else:
			_band_hi[b] += (db - _band_hi[b]) * rel
		if db < _band_lo[b]:
			_band_lo[b] = maxf(db, -100.0)
		else:
			_band_lo[b] += (db - _band_lo[b]) * rel
		var lo: float = minf(_band_lo[b], _band_hi[b] - AGC_RANGE_DB)
		bands[b] = clampf((db - lo) / (_band_hi[b] - lo), 0.0, 1.0)
	# Loudness / energy.
	var kp: float = _fx.kpow[i]
	_kp_mom += (kp - _kp_mom) * (1.0 - exp(-dt / 0.4))
	_kp_short += (kp - _kp_short) * (1.0 - exp(-dt / 3.0))
	var mom_db: float = -0.691 + 10.0 * log(_kp_mom + 1e-12) / log(10.0)
	loudness_db = -0.691 + 10.0 * log(_kp_short + 1e-12) / log(10.0)
	if mom_db > _e_hi:
		_e_hi = mom_db
	else:
		_e_hi += (mom_db - _e_hi) * (1.0 - exp(-dt / 30.0))
	energy = clampf((mom_db - (_e_hi - 20.0)) / 20.0, 0.0, 1.0)
	# Flux + onsets (peak picked with one frame latency).
	var raw: float = _fx.flux[i]
	_flux_peak = maxf(raw, _flux_peak + (raw - _flux_peak) * (1.0 - exp(-dt / 5.0)))
	_flux_peak = maxf(_flux_peak, 1e-4)
	flux = clampf(raw / (0.8 * _flux_peak), 0.0, 1.0)
	_flux_hist.append(flux)
	if _flux_hist.size() > 16:
		_flux_hist = _flux_hist.slice(_flux_hist.size() - 16)
	var hn: int = _flux_hist.size()
	if hn >= 4:
		var cand: float = _flux_hist[hn - 2]
		var mean: float = 0.0
		for k in hn:
			mean += _flux_hist[k]
		mean /= float(hn)
		if cand > _flux_hist[hn - 3] and cand >= _flux_hist[hn - 1] and cand >= mean + ONSET_DELTA and _frame_count - _last_onset_frame >= int(MIN_ONSET_GAP * frame_rate) + 1:
			_last_onset_frame = _frame_count
			onset_index += 1
			onset_strength = cand
			var best: float = -1.0
			for b in 6:
				var bv: float = _fx.band_flux[i * 6 + b] / maxf(1e-6, raw)
				# Weight towards low bands: fewer log bands cover them.
				bv *= [3.0, 2.0, 1.5, 1.0, 0.8, 0.8][b]
				if bv > best:
					best = bv
					onset_band = b
			_on_onset(tf - dt, cand)
	# Tempo.
	_env.append(raw)
	var max_env: int = int(ENV_SECONDS * frame_rate)
	if _env.size() > max_env:
		_env = _env.slice(_env.size() - max_env)
	_since_tempo += dt
	if _since_tempo >= TEMPO_INTERVAL and _env.size() >= int(4.0 * frame_rate):
		_since_tempo = 0.0
		_update_tempo()
	# Beat-interval accumulators for downbeat + sections.
	for b in 6:
		_interval_vec[b] += bands[b]
	_interval_low_pow += pow(10.0, _fx.band_db[i * 6] / 10.0) + pow(10.0, _fx.band_db[i * 6 + 1] / 10.0)
	_interval_high_pow += pow(10.0, _fx.band_db[i * 6 + 4] / 10.0) + pow(10.0, _fx.band_db[i * 6 + 5] / 10.0)
	_interval_frames += 1
	if _interval_frames <= 4:
		_accent = maxf(_accent, 0.5 * (bands[0] + bands[1]))
	# Predicted beats.
	while bpm > 0.0 and tf >= next_beat_time:
		_fire_beat(next_beat_time)

func _update_tempo() -> void:
	var est: Dictionary = TempoTracker.estimate_tempo(_env, frame_rate)
	var cand: float = est.bpm
	if bpm <= 0.0:
		bpm = cand
		_period = 60.0 / bpm
		tempo_confidence = est.confidence * 0.5
		return
	if absf(cand - bpm) / bpm < 0.04:
		bpm = lerpf(bpm, cand, 0.3)
		_tempo_votes = 0
	else:
		if _tempo_candidate > 0.0 and absf(cand - _tempo_candidate) / _tempo_candidate < 0.04:
			_tempo_votes += 1
		else:
			_tempo_candidate = cand
			_tempo_votes = 1
		var ratio: float = cand / bpm
		var octave: bool = absf(ratio - 2.0) < 0.1 or absf(ratio - 0.5) < 0.05
		if _tempo_votes >= (5 if octave else 3):
			bpm = cand
			_tempo_votes = 0
	_period = clampf(_period, 60.0 / bpm * 0.97, 60.0 / bpm * 1.03)
	if absf(_period - 60.0 / bpm) > 0.03 * 60.0 / bpm:
		_period = 60.0 / bpm
	tempo_confidence = clampf(0.5 * est.confidence + 0.5 * _hits, 0.0, 1.0)

func _on_onset(t: float, strength: float) -> void:
	if bpm <= 0.0:
		return
	if beat_index < 0 or next_beat_time == INF:
		if strength > 0.5:
			next_beat_time = t
		return
	var prev_t: float = next_beat_time - _period
	var e_next: float = t - next_beat_time
	var e_prev: float = t - prev_t
	var e: float = e_prev if absf(e_prev) < absf(e_next) else e_next
	if absf(e) < 0.2 * _period:
		var w: float = clampf(strength, 0.0, 1.0)
		next_beat_time += PLL_PHASE_GAIN * w * e
		_period += PLL_PERIOD_GAIN * w * e
		_hits += (1.0 - _hits) * 0.1 * w
	else:
		_hits += (0.0 - _hits) * 0.05 * clampf(strength, 0.0, 1.0)

func _fire_beat(t: float) -> void:
	# Close the previous beat interval: downbeat evidence and section stats.
	if _interval_frames > 0 and beat_index >= 0:
		var vec := PackedFloat32Array()
		vec.resize(6)
		var low: float = 0.0
		for b in 6:
			vec[b] = _interval_vec[b] / float(_interval_frames)
		low = 0.5 * (vec[0] + vec[1])
		var nov: float = 0.0
		if _prev_vec.size() == 6:
			for b in 6:
				nov += absf(vec[b] - _prev_vec[b])
		_prev_vec = vec
		var pos: int = posmod(beat_index, 4)
		for p in 4:
			_bar_scores[p] *= 0.97
		_bar_scores[pos] += _accent + 2.0 * nov
		var best: int = bar_offset
		for p in 4:
			if _bar_scores[p] > _bar_scores[best] * 1.1:
				best = p
		bar_offset = best
		var total: float = 0.0
		for p in 4:
			total += _bar_scores[p]
		downbeat_confidence = clampf((_bar_scores[bar_offset] / maxf(1e-6, total) - 0.25) / 0.25, 0.0, 1.0)
		_beat_low.append(low)
		_beat_energy.append(energy)
		_beat_low_db.append(10.0 * log(_interval_low_pow / float(_interval_frames) + 1e-12) / log(10.0))
		_beat_high_db.append(10.0 * log(_interval_high_pow / float(_interval_frames) + 1e-12) / log(10.0))
		if _beat_low.size() > 32:
			_beat_low = _beat_low.slice(1)
			_beat_energy = _beat_energy.slice(1)
			_beat_low_db = _beat_low_db.slice(1)
			_beat_high_db = _beat_high_db.slice(1)
		_update_section(low)
	for b in 6:
		_interval_vec[b] = 0.0
	_interval_low_pow = 0.0
	_interval_high_pow = 0.0
	_interval_frames = 0
	_accent = 0.0
	beat_index += 1
	last_beat_time = t
	beat_strength = clampf(flux, 0.0, 1.0)
	next_beat_time = t + _period

## Causal section state machine, evaluated once per beat on raw (un-AGC'd)
## band levels so slow gain changes can't fake or hide a drop:
##   drop       low band jumps >= DROP_JUMP_DB above the previous ~8 beats with
##              high energy (bass/kick re-entry) - recognised on the first beat
##   breakdown  low band falls >= 8 dB below the drop level for 4 beats
##   build      high band (or energy) rising steadily over the last 16 beats
##   quiet      low energy before any high-energy section
func _update_section(_low: float) -> void:
	_section_beats += 1
	var nb: int = _beat_low_db.size()
	var cur_low: float = _beat_low_db[nb - 1]
	var ref_low: float = cur_low
	if nb >= 6:
		ref_low = 0.0
		var cnt: int = 0
		for k in range(maxi(0, nb - 10), nb - 2):
			ref_low += _beat_low_db[k]
			cnt += 1
		ref_low /= float(maxi(1, cnt))
	var e_slope: float = _slope_tail(_beat_energy, 16)
	var h_slope: float = _slope_tail(_beat_high_db, 16)
	# Slow-decaying peak of the per-beat low level (~0.1 dB per beat).
	_low_peak_db = maxf(cur_low, _low_peak_db - 0.1)
	var t: String = section
	if section != "drop" and nb >= 6 and cur_low - ref_low >= DROP_JUMP_DB and cur_low >= _low_peak_db - 6.0 and energy >= 0.55:
		t = "drop"
		_drop_low_db = cur_low
	elif section == "drop":
		_drop_low_db = maxf(_drop_low_db - 0.05, cur_low)
		if cur_low < _drop_low_db - 8.0:
			_bass_absent_beats += 1
		else:
			_bass_absent_beats = 0
		if _bass_absent_beats >= 4:
			t = "breakdown" if energy < 0.6 else "steady"
	elif (h_slope > 0.3 or e_slope > 0.01) and nb >= 12:
		t = "build"
	elif _had_high and cur_low < _drop_low_db - 8.0:
		t = "breakdown"
	elif energy < 0.3:
		t = "breakdown" if _had_high else "quiet"
	elif section == "build" or _section_beats >= 8:
		t = "steady"
	if t == "drop":
		_had_high = true
	if t != section and (_section_beats >= 4 or t == "drop"):
		section = t
		section_index += 1
		_section_beats = 0
		_bass_absent_beats = 0
	build_progress = clampf(float(_section_beats) / 32.0, 0.0, 1.0) if section == "build" else 0.0

static func _slope_tail(a: PackedFloat32Array, count: int) -> float:
	var n: int = mini(count, a.size())
	if n < 8:
		return 0.0
	var sx: float = 0.0
	var sy: float = 0.0
	var sxx: float = 0.0
	var sxy: float = 0.0
	for k in n:
		var y: float = a[a.size() - n + k]
		sx += k
		sy += y
		sxx += k * k
		sxy += k * y
	return (n * sxy - sx * sy) / maxf(1e-9, n * sxx - sx * sx)

## Reactivity source interface.
func sample(t: float) -> Dictionary:
	var phase: float = 0.0
	if beat_index >= 0 and _period > 0.0:
		phase = clampf((t - last_beat_time) / _period, 0.0, 0.9999)
	var in_bar: int = posmod(beat_index - bar_offset, 4) if beat_index >= 0 else 0
	return {
		"bands": bands.duplicate(), "flux": flux, "energy": energy, "loudness_db": loudness_db,
		"beat_index": beat_index, "beat_phase": phase, "beat_strength": beat_strength,
		"bar_index": int(floor(float(beat_index - bar_offset) / 4.0)) if beat_index >= 0 else -1,
		"bar_phase": (float(in_bar) + phase) / 4.0,
		"onset_index": onset_index, "onset_strength": onset_strength, "onset_band": onset_band,
		"bpm": bpm, "confidence": tempo_confidence, "downbeat_confidence": downbeat_confidence,
		"section": section, "section_index": section_index, "build_progress": build_progress,
		"time_to_drop": INF, "time_to_next_beat": maxf(0.0, next_beat_time - t),
		"anticipation": false,
	}
