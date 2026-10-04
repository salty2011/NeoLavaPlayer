extends RefCounted
## Offline analysis pipeline: file/PCM -> TrackAnalysis. Blocking and thread-safe
## (no scene tree, no shared mutable state except the cache directory), so run
## it inside a Thread (see analysis_job.gd) ahead of playback.
##
##   var analysis = TrackAnalyzer.analyze_file(path)          # uses cache
##   var analysis = TrackAnalyzer.analyze_pcm(mono, 44100.0)  # raw samples

const FeatureExtractor := preload("res://analysis/feature_extractor.gd")
const TempoTracker := preload("res://analysis/tempo_tracker.gd")
const StructureAnalyzer := preload("res://analysis/structure_analyzer.gd")
const TrackAnalysis := preload("res://analysis/track_analysis.gd")
const PcmDecoder := preload("res://analysis/pcm_decoder.gd")
const AnalysisCache := preload("res://analysis/analysis_cache.gd")

const RATE := 22050.0
const FFT_SIZE := 1024
## 256 @ 22.05 kHz = 86.13 frames/s (11.6 ms). Use 512 for ~2x faster analysis.
const HOP := 256
## Offset (s) subtracted from STFT frame centres so log-flux onset peaks line up
## with true note attacks. Calibrated on synthetic kicks (see test_music_analysis.gd).
const ONSET_LATENCY := -0.005
const ONSET_DELTA := 0.06
const MIN_ONSET_GAP := 0.03

static func analyze_file(path: String, use_cache: bool = true, hop: int = HOP) -> Dictionary:
	if use_cache:
		var cached = AnalysisCache.load_for(path)
		if cached != null:
			return {"analysis": cached, "cached": true}
	var t0: int = Time.get_ticks_usec()
	var decoded: Dictionary = PcmDecoder.decode_mono(path, int(RATE))
	if decoded.has("error"):
		return {"error": decoded.error}
	var decode_s: float = float(Time.get_ticks_usec() - t0) / 1e6
	var a = analyze_pcm(decoded.samples, float(decoded.rate), path, hop)
	if FeatureExtractor.abort:
		return {"error": "aborted"}
	if use_cache:
		AnalysisCache.save_for(path, a)
	return {"analysis": a, "cached": false, "decode_seconds": decode_s}

static func analyze_pcm(pcm: PackedFloat32Array, rate: float, source_path: String = "", hop: int = HOP):
	var started: int = Time.get_ticks_usec()
	var samples := PcmDecoder.resample(pcm, rate, RATE)
	var fx = FeatureExtractor.new(RATE, FFT_SIZE, hop)
	fx.keep_logspec = true
	var nf: int = fx.process_all(samples)
	var a = TrackAnalysis.new()
	a.source_path = source_path
	a.duration = float(samples.size()) / RATE
	a.frame_rate = fx.frame_rate
	a.time0 = fx.frame_time(0) - ONSET_LATENCY
	a.num_frames = nf
	var fr: float = fx.frame_rate
	if nf < 8:
		a.analysis_seconds = float(Time.get_ticks_usec() - started) / 1e6
		return a
	# Band normalisation: global per-band percentiles in dB.
	var bands := PackedFloat32Array()
	bands.resize(nf * 6)
	for b in 6:
		var col := PackedFloat32Array()
		col.resize(nf)
		for f in nf:
			col[f] = fx.band_db[f * 6 + b]
		var lo: float = _pct(col, 0.10)
		var hi: float = _pct(col, 0.995)
		lo = minf(lo, hi - 24.0)
		var inv: float = 1.0 / (hi - lo)
		for f in nf:
			bands[f * 6 + b] = clampf((col[f] - lo) * inv, 0.0, 1.0)
	a.bands = bands
	# Flux normalisation.
	var raw_flux: PackedFloat32Array = fx.flux
	var p99: float = maxf(1e-6, _pct(raw_flux, 0.99))
	var flux := PackedFloat32Array()
	flux.resize(nf)
	for f in nf:
		flux[f] = clampf(raw_flux[f] / p99, 0.0, 1.0)
	a.flux = flux
	# Loudness: K-weighted-ish mean square -> momentary (0.4 s) and short-term (3 s).
	var mom := _moving_mean(fx.kpow, maxi(1, int(round(0.4 * fr))))
	var short := _moving_mean(fx.kpow, maxi(1, int(round(3.0 * fr))))
	var loud := PackedFloat32Array()
	var mom_db := PackedFloat32Array()
	loud.resize(nf)
	mom_db.resize(nf)
	for f in nf:
		loud[f] = -0.691 + 10.0 * log(short[f] + 1e-12) / log(10.0)
		mom_db[f] = -0.691 + 10.0 * log(mom[f] + 1e-12) / log(10.0)
	a.loudness = loud
	a.rms_db = fx.rms_db
	var e_lo: float = _pct(mom_db, 0.05)
	var e_hi: float = _pct(mom_db, 0.98)
	e_lo = minf(e_lo, e_hi - 20.0)
	var energy := PackedFloat32Array()
	energy.resize(nf)
	for f in nf:
		energy[f] = clampf((mom_db[f] - e_lo) / (e_hi - e_lo), 0.0, 1.0)
	a.energy = energy
	# Onsets: local max over +-3 frames above a moving-mean adaptive threshold.
	var bf_norm := PackedFloat32Array()
	bf_norm.resize(6)
	for b in 6:
		var col := PackedFloat32Array()
		col.resize(nf)
		for f in nf:
			col[f] = fx.band_flux[f * 6 + b]
		bf_norm[b] = 1.0 / maxf(1e-6, _pct(col, 0.98))
	var avg := _moving_mean_centered(flux, int(round(0.1 * fr)), int(round(0.07 * fr)))
	var min_gap: int = maxi(1, int(round(MIN_ONSET_GAP * fr)))
	var last_onset: int = -min_gap
	for f in range(1, nf - 1):
		var v: float = flux[f]
		if v < avg[f] + ONSET_DELTA or f - last_onset < min_gap:
			continue
		var is_max: bool = true
		for k in range(maxi(0, f - 3), mini(nf, f + 4)):
			if flux[k] > v:
				is_max = false
				break
		if not is_max:
			continue
		last_onset = f
		var best_b: int = 0
		var best_v: float = -1.0
		for b in 6:
			var bv: float = fx.band_flux[f * 6 + b] * bf_norm[b]
			if bv > best_v:
				best_v = bv
				best_b = b
		a.onsets.append(a.time0 + float(f) / fr)
		a.onset_strengths.append(v)
		a.onset_bands.append(best_b)
	# Tempo and beats.
	var tempo: Dictionary = TempoTracker.estimate_tempo(raw_flux, fr)
	var tracked: Dictionary = TempoTracker.track_beats(raw_flux, fr, tempo.bpm)
	var beat_frames: PackedFloat32Array = tracked.frames
	var beats := PackedFloat32Array()
	for bf in beat_frames:
		beats.append(a.time0 + bf / fr)
	a.beats = beats
	a.beat_strengths = tracked.strengths
	a.bpm = TempoTracker.refine_bpm(beats, tempo.bpm)
	var on_beat: float = 0.0
	for s in tracked.strengths:
		on_beat += 1.0 if s > 0.2 else 0.0
	var beat_fraction: float = on_beat / maxf(1.0, float(tracked.strengths.size()))
	a.tempo_confidence = clampf(0.5 * tempo.confidence + 0.5 * beat_fraction, 0.0, 1.0) if beats.size() >= 8 else 0.0
	# Downbeats.
	var db: Dictionary = TempoTracker.estimate_downbeats(beat_frames, bands, 6, fx.logspec, FeatureExtractor.NLOG, energy)
	a.first_downbeat = int(db.phase)
	a.downbeat_confidence = float(db.confidence)
	var downbeats := PackedFloat32Array()
	for i in range(a.first_downbeat, beats.size(), 4):
		downbeats.append(beats[i])
	a.downbeats = downbeats
	# Structure.
	var st: Dictionary = StructureAnalyzer.analyse(downbeats, a.duration, fr, a.time0, bands, energy, flux)
	a.sections = st.sections
	for s in a.sections:
		# Keep cache JSON/Variant-friendly and compact.
		for k in ["low", "high", "rise_e", "rise_h"]:
			s.erase(k)
	a.phrase_times = st.phrase_times
	a.phrase_bars = st.phrase_bars
	a.rebuild_indices()
	a.analysis_seconds = float(Time.get_ticks_usec() - started) / 1e6
	return a

static func _pct(a: PackedFloat32Array, q: float) -> float:
	if a.is_empty():
		return 0.0
	var s := a.duplicate()
	s.sort()
	return s[clampi(int(q * float(s.size() - 1)), 0, s.size() - 1)]

## Trailing moving mean over `w` frames (causal, like a loudness meter).
static func _moving_mean(x: PackedFloat32Array, w: int) -> PackedFloat32Array:
	var n: int = x.size()
	var out := PackedFloat32Array()
	out.resize(n)
	var acc: float = 0.0
	for i in n:
		acc += x[i]
		if i >= w:
			acc -= x[i - w]
		out[i] = acc / float(mini(i + 1, w))
	return out

static func _moving_mean_centered(x: PackedFloat32Array, pre: int, post: int) -> PackedFloat32Array:
	var n: int = x.size()
	var cum := PackedFloat64Array()
	cum.resize(n + 1)
	cum[0] = 0.0
	for i in n:
		cum[i + 1] = cum[i] + x[i]
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var a: int = maxi(0, i - pre)
		var b: int = mini(n, i + post + 1)
		out[i] = (cum[b] - cum[a]) / float(b - a)
	return out
