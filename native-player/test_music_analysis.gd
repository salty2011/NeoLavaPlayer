extends SceneTree
## Music-reactivity analysis tests. Silent: no audio output, run with
##   Godot --headless --audio-driver Dummy --path native-player --script res://test_music_analysis.gd
## Only preloads res://analysis/* so unrelated in-progress files can't break it.
## Real-file and perf sections print measurements; the real-file section SKIPs
## (not fails) when afconvert can't decode (e.g. in a sandbox without Core Audio codecs).

const Synth := preload("res://analysis/synthetic_track.gd")
const Analyzer := preload("res://analysis/track_analyzer.gd")
const TrackAnalysis := preload("res://analysis/track_analysis.gd")
const TrackSource := preload("res://analysis/track_source.gd")
const SyntheticSource := preload("res://analysis/synthetic_source.gd")
const LiveAnalyzer := preload("res://analysis/live_analyzer.gd")
const Reactivity := preload("res://analysis/reactivity.gd")
const AnalysisCache := preload("res://analysis/analysis_cache.gd")
const PcmDecoder := preload("res://analysis/pcm_decoder.gd")
const AnalysisJob := preload("res://analysis/analysis_job.gd")

const REAL_FILE := "res://test-media/DemoBeat.mp3"

var failures: Array = []
var passes: int = 0

func check(ok: bool, label: String) -> void:
	if ok:
		passes += 1
		print("  ok   ", label)
	else:
		failures.append(label)
		print("  FAIL ", label)

func _initialize() -> void:
	var scratch := "user://test-music-analysis"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(scratch))
	PcmDecoder.temp_dir = scratch
	AnalysisCache.dir = scratch.path_join("cache")
	print("== synthetic 128 BPM track: offline analysis")
	var g: Dictionary = Synth.generate(128.0, 22050.0)
	var a = Analyzer.analyze_pcm(g.pcm, g.rate, "synthetic")
	print("  ", a.summary())
	test_offline(a, g)
	test_hub_on_track(a, g)
	test_smoothing_invariance(a)
	test_mock_adapter()
	test_cache(a)
	test_thread(g)
	test_live(g)
	test_real_file()
	test_perf()
	print("\n%d checks passed, %d failed" % [passes, failures.size()])
	for f in failures:
		print("FAILED: ", f)
	_cleanup(scratch)
	quit(1 if failures.size() > 0 else 0)

func _cleanup(dir_path: String) -> void:
	for sub in ["cache", ""]:
		var p := dir_path.path_join(sub) if sub != "" else dir_path
		var d := DirAccess.open(p)
		if d == null:
			continue
		for f in d.get_files():
			d.remove(f)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir_path.path_join("cache")))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir_path))

static func nearest_error(times: PackedFloat32Array, t: float) -> float:
	var i: int = times.bsearch(t)
	var best: float = INF
	for j in [i - 1, i]:
		if j >= 0 and j < times.size() and absf(times[j] - t) < absf(best):
			best = times[j] - t
	return best

func test_offline(a, g: Dictionary) -> void:
	check(absf(a.bpm - 128.0) <= 1.0, "BPM %.2f within +-1 of 128" % a.bpm)
	var good: int = 0
	var bias: float = 0.0
	for bt in g.beats:
		var e: float = nearest_error(a.beats, bt)
		if absf(e) <= 0.03:
			good += 1
			bias += e
	var frac: float = float(good) / float(g.beats.size())
	print("  beat accuracy: %d/%d within 30 ms (%.1f%%), mean signed error %.1f ms" % [good, g.beats.size(), 100.0 * frac, 1000.0 * bias / maxf(1.0, good)])
	check(frac > 0.9, "beats within +-30 ms for >90%% (%.1f%%)" % (100.0 * frac))
	var db_good: int = 0
	for d in a.downbeats:
		if absf(nearest_error(g.downbeats, d)) <= 0.03:
			db_good += 1
	var db_frac: float = float(db_good) / maxf(1.0, float(a.downbeats.size()))
	print("  downbeats: %d/%d on true bar lines, confidence %.2f" % [db_good, a.downbeats.size(), a.downbeat_confidence])
	check(db_frac > 0.9 and a.downbeats.size() >= 36, "downbeats aligned to bar lines (%.0f%%)" % (100.0 * db_frac))
	var types: Array = []
	for s in a.sections:
		types.append(s.type)
	check(types == ["quiet", "build", "drop", "breakdown"], "section order %s" % [types])
	if types.size() == g.sections.size():
		var worst: float = 0.0
		for i in types.size():
			worst = maxf(worst, absf(float(a.sections[i].start) - float(g.sections[i].start)))
		check(worst <= g.bar_len + 1e-3, "section boundaries within 1 bar (worst %.2f s, bar %.3f s)" % [worst, g.bar_len])
	var drop_t: float = g.sections[2].start
	check(a.upcoming_drop_in(drop_t - 1.5, 2.0) and not a.upcoming_drop_in(drop_t - 3.0, 2.0), "upcoming_drop_in(2 s) true 1.5 s before drop, false 3 s before")
	check(a.build_progress(drop_t - 1.0) > 0.8 and a.build_progress(g.sections[1].start + 1.0) < 0.3, "build_progress ramps through the build (%.2f near end)" % a.build_progress(drop_t - 1.0))
	check(a.phrase_times.size() >= 10, "phrase grid (%d phrase starts)" % a.phrase_times.size())
	var ns: Dictionary = a.next_section(drop_t - 5.0)
	check(String(ns.get("type", "")) == "drop" and absf(float(ns.time_until) - 5.0) < g.bar_len, "next_section lookahead finds the drop")

func test_hub_on_track(a, g: Dictionary) -> void:
	print("== reactivity hub on TrackSource")
	var hub = Reactivity.new()
	hub.set_source(TrackSource.new(a))
	var counts := {"beat": 0, "downbeat": 0, "drop": 0, "section": 0, "phrase": 0, "onset": 0, "big": 0}
	var drop_times: Array = []
	var section_types: Array = []
	hub.beat.connect(func(_i, _s): counts.beat += 1)
	hub.downbeat.connect(func(_b): counts.downbeat += 1)
	hub.drop.connect(func(): counts.drop += 1; drop_times.append(hub.frame.time))
	hub.section_changed.connect(func(t): counts.section += 1; section_types.append(t))
	hub.phrase.connect(func(_b): counts.phrase += 1)
	hub.onset.connect(func(_s, _b): counts.onset += 1)
	hub.big_moment.connect(func(_k): counts.big += 1)
	var drop_t: float = g.sections[2].start
	var first_warning: float = INF
	var tier_changes_by_section := {}
	var last_tier: int = -1
	var dt: float = 1.0 / 60.0
	var t: float = 0.0
	var ttd_at_minus_1_5: float = -1.0
	while t < g.duration - 0.5:
		var f = hub.update_time(t, dt)
		if f.time_to_drop <= 2.0 and first_warning == INF:
			first_warning = t
		if absf(t - (drop_t - 1.5)) < dt * 0.5:
			ttd_at_minus_1_5 = f.time_to_drop
		if last_tier >= 0 and f.intensity != last_tier:
			tier_changes_by_section[f.section] = int(tier_changes_by_section.get(f.section, 0)) + 1
		last_tier = f.intensity
		t += dt
	print("  signals: ", counts, " sections ", section_types, " tier changes per section ", tier_changes_by_section)
	check(absi(counts.beat - a.beats.size()) <= 2, "beat signal per tracked beat (%d)" % counts.beat)
	check(absi(counts.downbeat - a.downbeats.size()) <= 1, "downbeat signal per bar (%d)" % counts.downbeat)
	check(counts.drop == 1 and drop_times.size() == 1 and absf(drop_times[0] - drop_t) < 0.1, "drop() fires once at the drop (%s)" % [drop_times])
	check(section_types == ["build", "drop", "breakdown"], "section_changed sequence")
	check(drop_t - first_warning >= 1.0, "drop anticipated %.2f s ahead (time_to_drop <= 2 s first seen at %.2f)" % [drop_t - first_warning, first_warning])
	check(ttd_at_minus_1_5 > 1.3 and ttd_at_minus_1_5 < 1.7, "time_to_drop 1.5 s before drop = %.2f" % ttd_at_minus_1_5)
	check(int(tier_changes_by_section.get("drop", 0)) <= 2 and int(tier_changes_by_section.get("quiet", 0)) <= 2, "intensity tier stable inside steady sections")
	check(counts.big >= 1 and counts.big <= 8, "big moments gated (%d over %.0f s)" % [counts.big, g.duration])
	# Phase is read at the exact render time (not the 86 Hz grid).
	var bt: float = a.beats[60]
	var tt: float = bt - 0.3
	while tt < bt + 0.1:
		hub.update_time(tt, 0.007)
		tt += 0.007
	var expect: float = (tt - 0.007 - bt) / (a.beats[61] - bt)
	check(absf(hub.frame.beat_phase - expect) < 0.01, "beat_phase continuous at render time (%.3f vs %.3f)" % [hub.frame.beat_phase, expect])
	# Seek: backwards jump must resync silently.
	var before: int = counts.beat
	hub.update_time(10.0, dt)
	hub.update_time(10.0 + dt, dt)
	check(counts.beat - before <= 1, "seek backwards fires no burst of events")
	hub.free()

func run_hub(source, dt: float, until: float, sample_every: float) -> Array:
	var hub = Reactivity.new()
	hub.set_source(source)
	var out: Array = []
	var steps: int = int(round(until / dt))
	var every: int = int(round(sample_every / dt))
	for i in steps + 1:
		var t: float = float(i) * dt
		var f = hub.update_time(t, dt)
		if i % every == 0:
			var row := PackedFloat32Array(f.bands)
			row.append(f.energy)
			row.append(f.flux_smooth)
			out.append(row)
	hub.free()
	return out

static func max_diff(x: Array, y: Array) -> float:
	return diff_stats(x, y)[0]

## [max, mean] absolute difference.
static func diff_stats(x: Array, y: Array) -> Array:
	var m: float = 0.0
	var s: float = 0.0
	var c: int = 0
	for i in mini(x.size(), y.size()):
		for j in x[i].size():
			var d: float = absf(x[i][j] - y[i][j])
			m = maxf(m, d)
			s += d
			c += 1
	return [m, s / maxf(1.0, float(c))]

func test_smoothing_invariance(a) -> void:
	print("== frame-rate independent smoothing (dt 1/30 vs 1/144, compared every 1/6 s)")
	var d_track: float = max_diff(run_hub(TrackSource.new(a), 1.0 / 30.0, 40.0, 1.0 / 6.0), run_hub(TrackSource.new(a), 1.0 / 144.0, 40.0, 1.0 / 6.0))
	var syn := SyntheticSource.new()
	var d_syn: float = max_diff(run_hub(syn, 1.0 / 30.0, 40.0, 1.0 / 6.0), run_hub(syn, 1.0 / 144.0, 40.0, 1.0 / 6.0))
	# A source without native_rate (sampled once per frame): bounded, not exact.
	var plain := func(t: float) -> Dictionary: return syn.sample(t)
	var plain_stats: Array = diff_stats(run_hub(plain, 1.0 / 30.0, 40.0, 1.0 / 6.0), run_hub(plain, 1.0 / 144.0, 40.0, 1.0 / 6.0))
	print("  max |diff|: TrackSource %.7f, SyntheticSource %.7f; plain callable (no sub-stepping) max %.3f mean %.4f" % [d_track, d_syn, plain_stats[0], plain_stats[1]])
	check(d_track < 1e-4, "TrackSource smoothing identical across frame rates")
	check(d_syn < 1e-4, "SyntheticSource smoothing identical across frame rates")
	# Without sub-stepping a 30 fps renderer simply misses transients between
	# frames, so only the average agreement is meaningful.
	check(plain_stats[1] < 0.03, "plain source: mean smoothing difference small (%.4f)" % plain_stats[1])

func test_mock_adapter() -> void:
	print("== adapter: ad-hoc feed with named bands and boolean beat flags")
	var hub = Reactivity.new()
	var beats := [0]
	hub.beat.connect(func(_i, _s): beats[0] += 1)
	hub.set_source(func(t: float) -> Dictionary:
		return {"bass": 0.8, "mid": 0.4, "treble": 0.2, "beat": fposmod(t, 0.5) < 0.05, "energy": 0.5})
	for i in 300:
		hub.update(1.0 / 60.0)
	check(beats[0] >= 9 and beats[0] <= 10, "rising-edge beat flags -> %d beats in 5 s at 120 BPM" % beats[0])
	check(absf(hub.frame.bands[1] - 0.8) < 0.01 and absf(hub.frame.bands[5] - 0.2) < 0.01 and not hub.frame.anticipation, "named bands mapped, anticipation off")
	hub.free()

func test_cache(a) -> void:
	print("== cache round trip")
	var tmp_audio := AnalysisCache.dir.path_join("fake.mp3")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(AnalysisCache.dir))
	var f := FileAccess.open(tmp_audio, FileAccess.WRITE)
	f.store_string("not really audio")
	f.close()
	check(AnalysisCache.save_for(tmp_audio, a), "cache save")
	var b = AnalysisCache.load_for(tmp_audio)
	check(b != null and b.summary() == a.summary() and b.beats == a.beats and b.bands == a.bands, "cache load equals original")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp_audio))

func test_thread(g: Dictionary) -> void:
	print("== worker thread")
	var th := Thread.new()
	var short: PackedFloat32Array = g.pcm.slice(0, int(20.0 * g.rate))
	th.start(func(): return Analyzer.analyze_pcm(short, g.rate, "thread"))
	var r = th.wait_to_finish()
	check(r != null and r.beats.size() > 20, "analyze_pcm runs on a Thread (%d beats)" % (r.beats.size() if r != null else 0))

func test_live(g: Dictionary) -> void:
	print("== LiveAnalyzer (realtime path, synthetic track fed as 44.1 kHz stereo blocks)")
	var pcm44 := PcmDecoder.resample(g.pcm, 22050.0, 44100.0)
	var live = LiveAnalyzer.new(44100.0)
	var hub = Reactivity.new()
	hub.set_source(live)
	var live_beats := PackedFloat32Array()
	var sections: Array = []
	var drops: Array = []
	hub.beat.connect(func(_i, _s): live_beats.append(live.last_beat_time))
	hub.section_changed.connect(func(t): sections.append("%s@%.1f" % [t, live.stream_time]))
	hub.drop.connect(func(): drops.append(live.stream_time))
	var block: int = 1024
	var started: int = Time.get_ticks_usec()
	var i: int = 0
	var bpm_at_10: float = 0.0
	while i < pcm44.size():
		var n: int = mini(block, pcm44.size() - i)
		var frames := PackedVector2Array()
		frames.resize(n)
		for k in n:
			var v: float = pcm44[i + k]
			frames[k] = Vector2(v, v)
		live.push_frames(frames)
		hub.update_time(live.stream_time, float(n) / 44100.0)
		if bpm_at_10 == 0.0 and live.stream_time >= 10.0:
			bpm_at_10 = live.bpm
		i += n
	var secs: float = float(Time.get_ticks_usec() - started) / 1e6
	var good: int = 0
	var total: int = 0
	var drop_start: float = g.sections[2].start
	for bt in live_beats:
		if bt >= drop_start + 4.0 and bt < g.sections[3].start:
			total += 1
			if absf(nearest_error(g.beats, bt)) <= 0.04:
				good += 1
	print("  live: bpm@10s %.2f final %.2f conf %.2f, drop-section beats within 40 ms %d/%d, sections %s, drops %s, %.2f s CPU for %.0f s audio" % [bpm_at_10, live.bpm, live.tempo_confidence, good, total, sections, drops, secs, g.duration])
	check(absf(live.bpm - 128.0) <= 2.0, "live BPM within +-2 (%.2f)" % live.bpm)
	check(total > 0 and float(good) / float(total) >= 0.8, "live beats phase-locked in the drop (%d/%d)" % [good, total])
	check(drops.size() >= 1 and absf(drops[0] - drop_start) < 2.0 * g.bar_len, "live drop recognised at bass re-entry (no anticipation)")
	check(not hub.frame.anticipation and hub.frame.time_to_drop == INF, "live frames flag anticipation unavailable")
	check(secs < g.duration * 0.25, "live analysis CPU %.0f%% of realtime" % (100.0 * secs / g.duration))
	hub.free()

func test_real_file() -> void:
	print("== real file (offline, silent): ", REAL_FILE)
	var started: int = Time.get_ticks_usec()
	var r: Dictionary = Analyzer.analyze_file(REAL_FILE, false)
	if r.has("error"):
		print("  SKIP real-file analysis: ", r.error)
		return
	var a = r.analysis
	print("  %s | duration %.1f s, decode %.2f s, analysis %.2f s, total %.2f s" % [a.summary(), a.duration, r.decode_seconds, a.analysis_seconds, float(Time.get_ticks_usec() - started) / 1e6])
	check(a.bpm >= 60.0 and a.bpm <= 200.0 and a.beats.size() > 10, "real file: plausible BPM %.2f" % a.bpm)
	var job = AnalysisJob.new()
	job.start(REAL_FILE, true)
	var jr: Dictionary = job.take_result()
	check(jr.has("analysis") and absf(jr.analysis.bpm - a.bpm) < 0.01, "AnalysisJob (thread + cache write) matches")
	var again: Dictionary = Analyzer.analyze_file(REAL_FILE, true)
	check(again.get("cached", false), "second analyze_file hits the cache")

func test_perf() -> void:
	print("== performance: 4-minute synthetic track")
	var layout: Array = []
	for k in 3:
		layout.append_array(Synth.DEFAULT_LAYOUT)
	layout.append({"type": "drop", "bars": 8})
	var g: Dictionary = Synth.generate(128.0, 22050.0, layout)
	var a = Analyzer.analyze_pcm(g.pcm, g.rate, "perf")
	print("  %.1f s of audio analysed in %.2f s (%.1fx realtime); bpm %.2f; %d sections" % [g.duration, a.analysis_seconds, g.duration / a.analysis_seconds, a.bpm, a.sections.size()])
	check(a.analysis_seconds < 20.0, "4-minute analysis under 20 s (%.2f s)" % a.analysis_seconds)
