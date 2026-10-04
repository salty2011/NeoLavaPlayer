extends SceneTree
## Reactivity integration (Phase 4b). Silent: Dummy audio driver, no output.
##   Godot --headless --audio-driver Dummy --path native-player --script res://test_reactivity_integration.gd
## 1. Mock 128 BPM through the full path (PlayerBus analysis source -> ReactivityService
##    -> hub -> mapper channels): beat times at 30/60/144 fps.
## 2. Impact channel: only on drops / gated big moments, rate-limited, budgeted.
## 3. Hot swap live -> pre-analysed: no discontinuity in smoothed bands.
## 4. Real AudioService path on test-media (live first, then pre-analysed;
##    seek, pause, stop, track change, cache hit), and the offline analyzer run
##    on every file in test-media.
## 5. Settings persist ([reactivity] in settings.cfg) and reach the mapper.
## Writes research/oozic/proof/phase4b/reactivity-integration.json.

const AudioService := preload("res://audio_service.gd")
const ReactivityService := preload("res://analysis/reactivity_service.gd")
const Reactivity := preload("res://analysis/reactivity.gd")
const ReactivityMapper := preload("res://analysis/reactivity_mapper.gd")
const SyntheticSource := preload("res://analysis/synthetic_source.gd")
const Synth := preload("res://analysis/synthetic_track.gd")
const Analyzer := preload("res://analysis/track_analyzer.gd")
const TrackSource := preload("res://analysis/track_source.gd")
const LiveAnalyzer := preload("res://analysis/live_analyzer.gd")
const AnalysisCache := preload("res://analysis/analysis_cache.gd")
const PcmDecoder := preload("res://analysis/pcm_decoder.gd")
const MockAudioFeed := preload("res://mock_audio_feed.gd")
const AppSettings := preload("res://app_settings.gd")
const PlayerBusScript := preload("res://player_bus.gd")

const MEDIA_DIR := "res://test-media"
const REPORT := "res://../research/oozic/proof/phase4b/reactivity-integration.json"

var failures: Array = []
var passes := 0
var report := {}
var bus
var rx
var audio

func check(ok: bool, label: String) -> void:
	if ok:
		passes += 1
		print("  ok   ", label)
	else:
		failures.append(label)
		print("  FAIL ", label)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var scratch := "user://test-reactivity-integration"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(scratch))
	PcmDecoder.temp_dir = scratch
	AnalysisCache.dir = scratch.path_join("cache")
	_clear_dir(AnalysisCache.dir)
	bus = PlayerBusScript.instance()
	audio = AudioService.new(false)
	root.add_child(audio)
	rx = ReactivityService.instance()
	await process_frame
	await process_frame
	check(rx.is_inside_tree() and audio.reactivity == rx, "service is a singleton reached by AudioService")
	rx.auto_tick = false
	test_mock_beats()
	test_mock_consistency()
	test_impact()
	test_hot_swap()
	await test_real_path(scratch)
	test_offline_media()
	test_settings(scratch)
	print("\n%d checks passed, %d failed" % [passes, failures.size()])
	for f in failures: print("FAILED: ", f)
	report.passes = passes
	report.failures = failures
	var out := ProjectSettings.globalize_path(REPORT).simplify_path()
	DirAccess.make_dir_recursive_absolute(out.get_base_dir())
	var file := FileAccess.open(out, FileAccess.WRITE)
	if file: file.store_string(JSON.stringify(report, "\t"))
	print("REPORT ", out)
	_clear_dir(AnalysisCache.dir)
	audio.queue_free()
	await create_timer(0.1).timeout
	quit(1 if failures.size() > 0 else 0)

func _clear_dir(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null: return
	for f in d.get_files(): d.remove(f)

# --- 1. Mock beats through the bus at 30/60/144 fps -----------------------------

func _run_mock(fps: float, seconds: float, schedule: Array = SyntheticSource.SCHEDULE) -> Dictionary:
	bus.publish_analysis_source("mock", {"bpm": 128.0, "schedule": schedule})
	var beats := []
	var bars := []
	var pulses := []
	var impacts := []
	var drops := []
	var bigs := []
	var max_lag := 0.0
	var dt := 1.0 / fps
	var on_pulse := func(i, a): pulses.append([i, a])
	var on_impact := func(s, k): impacts.append([rx.frame.time, s, k])
	rx.mapper.pulse_fired.connect(on_pulse)
	rx.mapper.impact_fired.connect(on_impact)
	var frames := int(round(seconds * fps))
	for i in frames:
		rx.tick(dt)
		var f = rx.frame
		if f.beat: beats.append({"index": f.beat_index, "beat_time": f.beat_time, "emitted": f.time})
		if f.downbeat: bars.append(f.bar_index)
		if f.drop: drops.append(f.time)
		if f.big_moment: bigs.append([f.time, f.big_kind])
	rx.mapper.pulse_fired.disconnect(on_pulse)
	rx.mapper.impact_fired.disconnect(on_impact)
	return {"beats": beats, "bars": bars, "pulses": pulses, "impacts": impacts, "drops": drops, "bigs": bigs}

func test_mock_beats() -> void:
	print("== mock 128 BPM via bus -> ReactivityService -> channels")
	var beat_len := 60.0 / 128.0
	var results := {}
	for fps in [30.0, 60.0, 144.0]:
		var r := _run_mock(fps, 40.0)
		check(rx.source_kind == "mock", "%d fps: service source is mock" % fps)
		var worst_time := 0.0
		var worst_lag := 0.0
		var min_lag := INF
		var indices := []
		for b in r.beats:
			var expected: float = float(b.index) * beat_len
			worst_time = maxf(worst_time, absf(float(b.beat_time) - expected))
			worst_lag = maxf(worst_lag, float(b.emitted) - expected)
			min_lag = minf(min_lag, float(b.emitted) - expected)
			indices.append(b.index)
		var expected_count := int(floor(40.0 / beat_len))
		check(r.beats.size() == expected_count, "%d fps: %d beats in 40 s (expected %d)" % [fps, r.beats.size(), expected_count])
		check(worst_time < 0.011, "%d fps: beat_time within 11 ms of the grid (worst %.2f ms)" % [fps, worst_time * 1000.0])
		check(min_lag >= -1e-4 and worst_lag <= 1.0 / fps + 0.0105, "%d fps: beat signal latency %.1f..%.1f ms <= one frame + 10 ms" % [fps, min_lag * 1000.0, worst_lag * 1000.0])
		check(r.pulses.size() == r.beats.size(), "%d fps: pulse channel fires on every beat (%d)" % [fps, r.pulses.size()])
		check(r.bars.size() == int(floor(40.0 / (4.0 * beat_len))), "%d fps: %d downbeats" % [fps, r.bars.size()])
		results[str(int(fps))] = {"beats": r.beats.size(), "worst_beat_time_ms": worst_time * 1000.0, "latency_ms": [min_lag * 1000.0, worst_lag * 1000.0], "indices": indices, "pulses": r.pulses.size(), "downbeats": r.bars.size()}
	check(results["30"].indices == results["60"].indices and results["60"].indices == results["144"].indices, "same beat sequence at 30/60/144 fps")
	for k in results: results[k].erase("indices")
	report.mock_beats = results

func test_mock_consistency() -> void:
	print("== mock feed and synthetic source agree")
	var feed := MockAudioFeed.new(128.0, 3)
	var src = feed.reactivity_source()
	var ok_sections := true
	var ok_beats := true
	for i in 3000:
		var t := float(i) * 0.05
		var s: Dictionary = src.sample(t)
		if feed.section(t) != s.section: ok_sections = false
		var m: Dictionary = feed.sample(t)
		var phase: float = s.beat_phase
		if m.beat and s.section in ["build", "drop"] and phase > 0.2: ok_beats = false
	check(ok_sections, "mock feed sections == synthetic source sections over 150 s")
	check(ok_beats, "mock kicks land on synthetic beat phase 0")
	var custom := SyntheticSource.parse_schedule("quiet:4,drop:2,build:1,drop:4")
	check(custom.size() == 4 and custom[1].type == "drop" and custom[1].bars == 2, "parse_schedule")
	check(SyntheticSource.parse_schedule("nonsense:4") == SyntheticSource.SCHEDULE, "parse_schedule falls back on bad input")

# --- 2. Impact channel ------------------------------------------------------------

func test_impact() -> void:
	print("== impact channel: drops / big moments only, rate-limited")
	var r := _run_mock(60.0, 230.0)
	var min_gap := INF
	var on_event := true
	var prev := -INF
	for imp in r.impacts:
		var t: float = imp[0]
		min_gap = minf(min_gap, t - prev)
		prev = t
		var hit := false
		for d in r.drops: hit = hit or absf(d - t) < 1e-6
		for b in r.bigs: hit = hit or absf(b[0] - t) < 1e-6
		on_event = on_event and hit
	var drop_impacts: int = r.impacts.filter(func(i): return i[2] == "drop").size()
	check(r.drops.size() == 3, "3 drops in 230 s of the 40-bar loop (%d)" % r.drops.size())
	check(drop_impacts == r.drops.size(), "every drop fires an impact (%d)" % drop_impacts)
	check(on_event, "every impact coincides with a drop or a big moment")
	check(min_gap >= rx.mapper.impact_min_interval, "impacts >= %.0f s apart (min %.1f s)" % [rx.mapper.impact_min_interval, min_gap])
	var budget_ok := true
	var last_bar := -1000
	var bar_len := 4.0 * 60.0 / 128.0
	for imp in r.impacts:
		var bar := int(floor(float(imp[0]) / bar_len))
		if imp[2] != "drop" and bar - last_bar < rx.mapper.impact_budget_bars: budget_ok = false
		last_bar = bar
	check(budget_ok, "non-drop impacts respect the %d-bar budget" % rx.mapper.impact_budget_bars)
	# Two drops 3 bars apart: the second is inside the rate limit and is suppressed.
	var suppressed_before: int = rx.mapper.impacts_suppressed
	var close := _run_mock(60.0, 30.0, SyntheticSource.parse_schedule("quiet:4,drop:2,build:1,drop:4,quiet:8"))
	check(close.drops.size() == 2 and close.impacts.size() == 1, "close drops: %d drops -> %d impact" % [close.drops.size(), close.impacts.size()])
	check(rx.mapper.impacts_suppressed > suppressed_before, "rate limit suppressed the second drop")
	# Non-drop big moments: tier, section, budget and drop-guard rules (unit).
	var m := ReactivityMapper.new()
	var f = preload("res://analysis/react_frame.gd").new()
	f.bpm = 128.0
	f.intensity = 2
	f.section = "steady"
	var fired := []
	m.impact_fired.connect(func(_s, k): fired.append(k))
	var big_at := func(bar: int, section: String, intensity: int, ttd: float):
		f.time = float(bar) * bar_len
		f.bar_index = bar
		f.section = section
		f.intensity = intensity
		f.time_to_drop = ttd
		f.anticipation = is_finite(ttd)
		f.big_moment = true
		f.big_kind = "downbeat"
		m.update(f, 1.0 / 60.0)
		f.big_moment = false
		return fired.size()
	check(big_at.call(0, "steady", 2, INF) == 1, "big downbeat at tier high fires an impact")
	check(big_at.call(8, "steady", 3, INF) == 1, "second big moment within 16 bars is budgeted out")
	check(big_at.call(16, "breakdown", 3, INF) == 1, "no non-drop impact in a breakdown")
	check(big_at.call(17, "steady", 1, INF) == 1, "no non-drop impact at tier normal")
	check(big_at.call(18, "steady", 3, 2.0) == 1, "no non-drop impact while a drop is imminent")
	check(big_at.call(19, "steady", 3, INF) == 2, "allowed again after 16 bars")
	report.impact = {"drops": r.drops, "impacts": r.impacts, "big_moments": r.bigs, "min_gap_s": min_gap, "close_drops": close.drops.size(), "close_impacts": close.impacts.size()}

# --- 3. Hot swap --------------------------------------------------------------------

func test_hot_swap() -> void:
	print("== hot swap live -> pre-analysed (synthetic 128 BPM track)")
	var g: Dictionary = Synth.generate(128.0, 22050.0)
	var analysis = Analyzer.analyze_pcm(g.pcm, g.rate, "synthetic")
	var pcm: PackedFloat32Array = g.pcm
	var live = LiveAnalyzer.new(g.rate)
	var lc = ReactivityService.LiveClock.new(live, 0.0)
	var ts = TrackSource.new(analysis)
	var hubs := {}
	var maps := {}
	for k in ["live", "track", "blend", "hard"]:
		hubs[k] = Reactivity.new()
		maps[k] = ReactivityMapper.new()
	hubs.live.set_source(lc)
	hubs.blend.set_source(lc)
	hubs.hard.set_source(lc)
	hubs.track.set_source(ts)
	var fps := 60.0
	var dt := 1.0 / fps
	var swap_t := 40.0
	var blend: float = ReactivityService.SWAP_BLEND
	var fed := 0
	var prev := {}
	var excess := {"blend": 0.0, "hard": 0.0}
	var excess_ch := {"blend": 0.0, "hard": 0.0}
	var swapped := false
	var beats_around := {"blend": 0, "track": 0}
	for i in int(55.0 * fps):
		var t := float(i + 1) * dt
		var upto := mini(pcm.size(), int(t * g.rate))
		if upto > fed:
			live.push_mono(pcm.slice(fed, upto))
			fed = upto
		if not swapped and t >= swap_t:
			swapped = true
			hubs.blend.set_source(ts, blend)
			hubs.hard.set_source(ts, 0.0)
			hubs.hard.rebase(t - dt)
		var cur := {}
		for k in hubs:
			var f = hubs[k].update_time(t, dt)
			maps[k].update(f, dt)
			cur[k] = [f.bands.duplicate(), PackedFloat32Array([maps[k].value("sub"), maps[k].value("bass"), maps[k].value("mid"), maps[k].value("high")])]
		if t >= swap_t and t <= swap_t + blend + 0.25:
			if hubs.blend.frame.beat: beats_around.blend += 1
			if hubs.track.frame.beat: beats_around.track += 1
			for k in ["blend", "hard"]:
				for b in 6:
					var d: float = absf(cur[k][0][b] - prev[k][0][b])
					var ref: float = maxf(absf(cur.live[0][b] - prev.live[0][b]), absf(cur.track[0][b] - prev.track[0][b]))
					excess[k] = maxf(excess[k], d - ref)
				for c in 4:
					var d2: float = absf(cur[k][1][c] - prev[k][1][c])
					var ref2: float = maxf(absf(cur.live[1][c] - prev.live[1][c]), absf(cur.track[1][c] - prev.track[1][c]))
					excess_ch[k] = maxf(excess_ch[k], d2 - ref2)
		prev = cur
	print("  excess per-frame jump: blend %.4f (channels %.4f), hard swap %.4f (channels %.4f)" % [excess.blend, excess_ch.blend, excess.hard, excess_ch.hard])
	# Hub bands follow the raw input within ~20 ms (attack), so their tolerance
	# is looser; the mapper's band channels are what scenes should bind to.
	check(excess.blend <= 0.1 and excess.blend < 0.3 * excess.hard, "blended swap: hub bands jump <= 0.1 beyond the sources' own motion (%.4f)" % excess.blend)
	check(excess_ch.blend <= 0.03, "blended swap: band channels jump <= 0.03 beyond the sources' own motion (%.4f)" % excess_ch.blend)
	check(not hubs.blend.is_blending(), "cross-fade finished")
	check(absi(beats_around.blend - beats_around.track) <= 1, "beats during the swap match the pre-analysed beats (%d vs %d)" % [beats_around.blend, beats_around.track])
	report.hot_swap = {"swap_time": swap_t, "blend_seconds": blend, "excess_bands_blend": excess.blend, "excess_channels_blend": excess_ch.blend, "excess_bands_hard": excess.hard, "excess_channels_hard": excess_ch.hard, "beats_during_swap": beats_around}

# --- 4. Real AudioService path ---------------------------------------------------------

func _media_files() -> PackedStringArray:
	var out := PackedStringArray()
	var d := DirAccess.open(MEDIA_DIR)
	if d == null: return out
	for f in d.get_files():
		if f.get_extension().to_lower() in ["mp3", "flac", "wav"]: out.append(MEDIA_DIR.path_join(f))
	return out

func _frames(n: int) -> void:
	for i in n: await process_frame

func test_real_path(_scratch: String) -> void:
	print("== real AudioService path (Dummy driver, silent)")
	var files := _media_files()
	if files.is_empty():
		print("  SKIP no test media")
		return
	var path: String = files[0]
	var probe := PcmDecoder.decode_mono(path)
	if probe.has("error"):
		print("  SKIP afconvert cannot decode here: ", probe.error)
		report.real_path = {"skipped": probe.error}
		return
	bus.publish_analysis_source("real")
	rx.auto_tick = true
	var r := {}
	audio.playlist = PackedStringArray([path, path])
	audio.queue.configure(2)
	var t0 := Time.get_ticks_msec()
	check(await audio.play_track(0), "track loads")
	check(rx.source_kind == "live" and rx.is_analysing(), "cache miss: live analysis while the worker pre-analyses (%s)" % rx.source_kind)
	var swapped_at := -1.0
	var live_frames := 0
	while Time.get_ticks_msec() - t0 < 20000:
		await process_frame
		if rx.source_kind == "live": live_frames += 1
		if rx.source_kind == "pre-analysed":
			swapped_at = float(Time.get_ticks_msec() - t0) / 1000.0
			break
	r.live_stream_seconds = rx.live.stream_time if rx.live != null else -1.0
	r.swap_after_s = swapped_at
	r.live_frames = live_frames
	check(swapped_at > 0.0, "hot-swapped to pre-analysed after %.2f s" % swapped_at)
	check(rx.hub.is_blending() or rx.analysis != null, "swap cross-fades")
	# The blend runs on frame time, which lags wall time on slow machines (CI):
	# wait for it, with a generous deadline, instead of a fixed timer.
	var deadline := Time.get_ticks_msec() + int((ReactivityService.SWAP_BLEND + 0.5) * 1000.0) + 15000
	await create_timer(ReactivityService.SWAP_BLEND + 0.5).timeout
	while (rx.hub.is_blending() or rx.live != null) and Time.get_ticks_msec() < deadline:
		await process_frame
	check(not rx.hub.is_blending() and rx.live == null, "live analyzer released after the cross-fade")
	var pos: float = audio.playback_time()
	r.position_after_swap = pos
	check(absf(rx.clock - pos) < 0.3, "service clock follows playback (%.2f vs %.2f)" % [rx.clock, pos])
	check(FileAccess.file_exists(AnalysisCache.path_for(path)), "analysis written to the cache")
	# Seek: hub rebases, no events for the skipped span.
	var beats_before: int = rx.frame.beat_index
	audio.seek_to(20.0)
	await _frames(3)
	check(rx.frame.time >= 19.9 and rx.frame.time < 21.0, "seek rebases the hub (t=%.2f)" % rx.frame.time)
	r.beat_index_before_after_seek = [beats_before, rx.frame.beat_index]
	# Pause freezes.
	audio.toggle_play()
	await _frames(2)
	var frozen: float = rx.frame.time
	var pulse: float = rx.mapper.value("pulse")
	await create_timer(0.3).timeout
	check(rx.frame.time == frozen and rx.mapper.value("pulse") == pulse, "pause freezes hub and channels")
	audio.toggle_play()
	await create_timer(0.3).timeout
	check(rx.frame.time > frozen and audio.player.get_playback_position() > 19.0, "resume continues from the paused position (t=%.2f)" % rx.frame.time)
	check(rx.frame.time > frozen, "resume continues")
	# Track change to the same file: memory hit, instantly pre-analysed.
	check(await audio.play_track(1), "track change")
	check(rx.source_kind == "pre-analysed" and not rx.is_analysing(), "cache hit is instant")
	await _frames(10)
	# Mock on and off while a track plays.
	bus.publish_analysis_source("mock", {"bpm": 128.0})
	check(rx.source_kind == "mock", "mock overrides the track")
	bus.publish_analysis_source("real")
	check(rx.source_kind == "pre-analysed" and absf(rx.clock - audio.playback_time()) < 0.1, "back to the pre-analysed track at the playback clock")
	# Stop: idle, channels release.
	audio.stop_play()
	await create_timer(1.5).timeout
	check(rx.source_kind == "idle" and rx.mapper.value("bass") < 0.2, "stop -> idle, channels release (bass %.3f)" % rx.mapper.value("bass"))
	audio.toggle_play()
	await create_timer(0.2).timeout
	check(rx.source_kind == "pre-analysed" and rx.frame.time < 1.0, "play after stop restarts pre-analysed from 0 (t=%.2f)" % rx.frame.time)
	audio.stop_play()
	# Fresh service on the same cache: disk cache hit.
	var fresh = ReactivityService.new()
	fresh.persist = false
	fresh.track_started(path, 0.0)
	check(fresh.source_kind == "pre-analysed", "disk cache hit gives pre-analysed at track start")
	fresh.free()
	rx.auto_tick = false
	report.real_path = r

func test_offline_media() -> void:
	print("== offline analyzer on test-media (no audio output)")
	var rows := []
	for path in _media_files():
		var t0 := Time.get_ticks_usec()
		var res: Dictionary = Analyzer.analyze_file(path, false)
		var secs := float(Time.get_ticks_usec() - t0) / 1e6
		if res.has("error"):
			rows.append({"file": path.get_file(), "error": res.error})
			print("  ", path.get_file(), ": ", res.error)
			continue
		var a = res.analysis
		var sections := []
		for s in a.sections: sections.append("%s@%.1f" % [s.type, float(s.start)])
		var row := {"file": path.get_file(), "duration_s": a.duration, "bpm": a.bpm, "tempo_confidence": a.tempo_confidence,
			"downbeat_confidence": a.downbeat_confidence, "beats": a.beats.size(), "onsets": a.onsets.size(),
			"sections": sections, "analysis_s": secs, "realtime_factor": a.duration / maxf(secs, 1e-6)}
		rows.append(row)
		print("  ", JSON.stringify(row))
		check(a.bpm > 40.0 and a.beats.size() > 10, path.get_file() + ": tempo and beats found")
	report.offline_media = rows

# --- 5. Settings ---------------------------------------------------------------------------

func test_settings(scratch: String) -> void:
	print("== settings persist")
	var cfg := scratch.path_join("settings.cfg")
	if FileAccess.file_exists(cfg): DirAccess.remove_absolute(ProjectSettings.globalize_path(cfg))
	rx.persist = true
	rx.settings_path = cfg
	bus.command(&"set_reactivity", {"sensitivity": 1.5, "camera_intensity": 0.4, "effects_intensity": 1.8, "prefetch": false})
	var loaded := AppSettings.load_reactivity(cfg)
	check(is_equal_approx(loaded.sensitivity, 1.5) and is_equal_approx(loaded.camera_intensity, 0.4) and is_equal_approx(loaded.effects_intensity, 1.8) and loaded.prefetch == false, "set_reactivity persists to [reactivity]")
	check(is_equal_approx(rx.mapper.sensitivity, 1.5) and is_equal_approx(rx.mapper.camera_intensity, 0.4), "settings reach the mapper")
	check(bus.reactivity.get("camera_intensity") == 0.4, "settings published on the bus")
	var other = ReactivityService.new()
	other.settings_path = cfg
	other.load_settings()
	check(is_equal_approx(other.mapper.effects_intensity, 1.8), "a new service loads the saved values")
	other.free()
	var full := AppSettings.new()
	full.path = cfg
	full.load_settings()
	check(is_equal_approx(float(full.reactivity.sensitivity), 1.5), "AppSettings.load_settings reads [reactivity]")
	rx.set_reactivity({"sensitivity": 9.0})
	check(is_equal_approx(rx.settings.sensitivity, 3.0), "values are clamped")
	rx.persist = false
	rx.set_reactivity(AppSettings.REACTIVITY_DEFAULTS)
