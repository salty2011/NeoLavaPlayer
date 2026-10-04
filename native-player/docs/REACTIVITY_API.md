# Reactivity API

Music-reactivity layer for the modernised (non-Classic) scenes. Classic mode keeps the
recovered Lava3Aud path in `audio_inputs.gd`; nothing here replaces or changes it.

All code lives in `native-player/analysis/`. None of it uses `class_name`, so always
`preload()` the scripts. Tests are in `native-player/test_music_analysis.gd` (analysis)
and `native-player/test_reactivity_integration.gd` (app integration and channels).

Phase 4b (2026-10-04) wired the layer into the app: one `ReactivityService` autoload
owns the hub and a musicality layer (`ReactivityMapper`) of reaction channels, and
picks the source on its own (pre-analysed, live, or mock). Scenes no longer build their
own hub; see "How to make a scene react" below.

## Pipeline

```
file --(afconvert, offline, silent)--> mono 22.05 kHz PCM
     --FeatureExtractor (STFT 1024 / hop 256 = 86.13 frames/s)--> bands, flux, loudness
     --TempoTracker--> BPM, beats (Ellis DP), downbeats
     --StructureAnalyzer--> sections, phrases
     = TrackAnalysis (cached in user://analysis-cache/<md5>.anl)
TrackAnalysis --TrackSource--+
LiveAnalyzer (PCM blocks) ---+--> Reactivity hub --> ReactFrame + signals --> scenes
SyntheticSource / mock feed -+
```

| File | Role |
|---|---|
| `fft.gd` | Radix-2 FFT: precomputed twiddles, fused first stages, real-FFT packing |
| `feature_extractor.gd` | Streaming STFT features. The offline and live paths both use it |
| `tempo_tracker.gd` | Tempo (autocorrelation + comb + prior), DP beat tracker, downbeat phase |
| `structure_analyzer.gd` | Bar-level novelty segmentation, section classification, phrase grid |
| `track_analysis.gd` | The timeline and event lists, plus lookahead queries and serialisation |
| `track_analyzer.gd` | Offline pipeline: `analyze_file(path)` and `analyze_pcm(pcm, rate)` |
| `pcm_decoder.gd` | Calls `/usr/bin/afconvert` with an argument array and reads float or int16 WAV, including WAVE_FORMAT_EXTENSIBLE |
| `analysis_cache.gd` | Cache keyed by path, size, mtime and format version |
| `analysis_job.gd` | Wraps `analyze_file` in a worker `Thread` |
| `live_analyzer.gd` | Realtime analysis of `PackedVector2Array` blocks; no lookahead |
| `track_source.gd` | Reactivity source backed by a `TrackAnalysis` |
| `synthetic_source.gd` | Procedural source with no audio, for tests and scene development |
| `synthetic_track.gd` | Renders deterministic PCM test tracks with ground truth |
| `reactivity.gd` | The hub: smoothing, events, tiers, gating, signals, seamless source swaps |
| `react_frame.gd` | The frame object the hub publishes |
| `reactivity_mapper.gd` | Musicality layer: reaction channels (pulse, accent, impact, ...) |
| `reactivity_service.gd` | Autoload `ReactivityService`: one hub + mapper for the whole app, source selection, pre-analysis jobs, settings |

## App integration (Phase 4b)

```
AudioService ──stream_started / seeked / playback_time() / captured PCM──┐
PlayerBus ──transport_changed, analysis_source_changed, set_reactivity───┤
                                                                          v
                         ReactivityService (autoload, process_priority -50)
                          ├ source selection:  TrackSource | LiveAnalyzer | SyntheticSource | silence
                          ├ AnalysisJob worker (current track first, then the next 1-2 tracks)
                          ├ Reactivity hub  ──> frame (ReactFrame) + event signals
                          └ ReactivityMapper ─> reaction channels + pulse/accent/impact signals
                                                                          │
               scenes / overlay / settings read `frame` and `mapper` ─────┘
```

- **Autoload.** `project.godot` registers `ReactivityService="*res://analysis/reactivity_service.gd"`.
  Code reaches it through `preload("res://analysis/reactivity_service.gd").instance()`, which
  also works under `--script` (it creates the node, as `PlayerBus.instance()` does). The
  autoload name is `ReactivityService`, not `Reactivity`, so it never shadows the many
  `const Reactivity := preload("res://analysis/reactivity.gd")` declarations.
- **Classic mode is untouched.** The classic scene runtime is still driven by
  `audio_inputs.gd` through `AudioService.sample()`. The service only reads the same
  captured PCM (`push_pcm`, called right after `inputs.push`) and the playback clock.
- **One update per render frame.** The service ticks in `_process` before other nodes
  (priority −50), so a scene reading `frame` or the mapper in its own `_process` sees
  this frame's values.

### Source lifecycle

| Event | What the service does |
|---|---|
| Track starts (`AudioService.stream_started`) | Looks the path up in memory, then in the disk cache, **synchronously**. A hit drives the hub from a `TrackSource` at once ("pre-analysed"). A miss starts an `AnalysisJob` (low-priority worker thread) and drives the hub from a `LiveAnalyzer` fed with captured PCM ("live"). Either way the hub cross-fades from the previous track's last values over 0.75 s and its clock is rebased to the start position |
| Pre-analysis finishes for the current track | Hot swap: `hub.set_source(TrackSource, 2.0 s blend)`. Continuous inputs cross-fade from the live analyzer (which keeps receiving PCM until the blend ends, then is released); event trackers re-baseline without firing; a beat closer than 0.4 beat periods to the previous one is ignored at the seam |
| Seek (`AudioService.seeked`) | `hub.rebase(position)`: no events for the skipped span, smoothing kept (no snap). The live analyzer's clock offset is moved so its beat phase stays valid |
| Pause | Hub and channels freeze (the classic scene also stops advancing while paused) |
| Resume after Stop | Same stream restarts without `stream_started`; the service reselects the best source for the current path |
| Stop | Cross-fades to silence over 0.6 s and keeps ticking on its own clock, so channels release gently. Source "idle" |
| Mock (`--mock-audio[=BPM]`, `--mock-sections=…`, Settings → Display → Scene input) | The visualiser publishes `analysis_source_changed("mock", {bpm, schedule})`. The service runs a `SyntheticSource` with the same BPM, phase and schedule as the visualiser's `mock_audio_feed.gd`, on its own clock restarted at 0 together with the scene. Source "mock" |
| Next tracks | After each track start, `AudioService.upcoming_paths(2)` (sequential order; empty while shuffling, because the next pick is random) are queued behind the current track's job, one worker at a time. Results go to the disk cache and a 3-slot memory cache, so the next track starts pre-analysed. Setting `prefetch` turns it off |
| App quit during analysis | `FeatureExtractor.abort` stops the worker's STFT loop; the partial result is discarded, not cached |

The service clock follows `AudioService.playback_time()` (playback position + time since
last mix − output latency) with a monotonic, rate-limited correction (gain 4/s); an error
over 0.25 s snaps and rebases instead. Without this, mix-chunk jitter in the raw position
would occasionally run backwards and trigger the hub's seek resync.

### Service API

| Member | Meaning |
|---|---|
| `instance()` (static) | The autoload node (created under `--script`) |
| `frame` | The hub's `ReactFrame` for this render frame |
| `hub` | The `Reactivity` node: all signals and knobs below |
| `mapper` | The `ReactivityMapper`: reaction channels |
| `source_kind` | `"pre-analysed"`, `"live"`, `"mock"` or `"idle"`; signal `source_changed(kind)` |
| `analysis` | The current track's `TrackAnalysis` once known, else `null` |
| `analysis_ready(path, analysis)` | Signal for every finished job (current or prefetched) |
| `set_reactivity({sensitivity?, camera_intensity?, effects_intensity?, prefetch?})` | Also reachable as the bus command `set_reactivity` |
| `debug_info()` | Dictionary used by the F3 overlay |
| `tick(delta)`, `auto_tick` | Tests set `auto_tick = false` and call `tick` themselves |

Bus state (`PlayerBus.reactivity`, signal `reactivity_changed()`): the four settings plus
`source`, `analysing` (file name being analysed or "") and `track_bpm`.

### Settings

`[reactivity]` in `user://settings.cfg` (`AppSettings.load_reactivity` /
`save_reactivity` / `sanitize_reactivity`):

| Key | Range | Default | Effect |
|---|---|---|---|
| `sensitivity` | 0–3 | 1.0 | Global gain on every channel (multiplies each channel's own sensitivity) |
| `camera_intensity` | 0–2 | 1.0 | Scale applied by `mapper.camera(name)` |
| `effects_intensity` | 0–2 | 1.0 | Scale applied by `mapper.effect(name)` |
| `prefetch` | bool | true | Background pre-analysis of the next tracks |

Settings → **Reactivity** shows these as percentage sliders and a checkbox, plus the
current source and any file being analysed. Every change is a `set_reactivity` bus
command; the service clamps, applies, saves and republishes.

## Reaction channels (`reactivity_mapper.gd`)

Scenes should bind to channels rather than raw analysis. Every channel is 0..1, has its
own `sensitivity`, `attack`, `release` and `enabled` (`mapper.set_channel(name, {...})`),
and is read with `value(name)`, `camera(name)` (× camera intensity) or `effect(name)`
(× effects intensity).

| Channel | Follows | Shape | Guards |
|---|---|---|---|
| `pulse` | Each beat | 12 ms attack, exponential decay of 0.35 beat (clamped 60–300 ms), so the envelope breathes with the tempo. Amplitude = (0.5 + 0.5·beat_strength) × tier gain (calm 0.35, normal 0.6, high 0.85, peak 1.0): calm passages pulse gently | Tempo confidence gate with hysteresis (on ≥ 0.45, off < 0.3); at most one pulse per half beat |
| `accent` | Downbeats | Decay of a quarter bar; 1.0 on 8/16-bar phrase starts, 0.7 otherwise (× tier gain, at least 0.5) | Downbeat confidence gate (on ≥ 0.5, off < 0.35); at most one per 0.9 bar |
| `impact` | Drops; gated big moments | Instant attack, 80 ms hold, 1.2 s decay. Drops 1.0, other big moments 0.6 | Never two within 8 s. Non-drop big moments also need tier high/peak, a section other than quiet/breakdown, 16 bars since the previous impact, and no drop due within 2 bars (the big reaction is saved for the drop) |
| `anticipation` | `build_progress` (smoothstep) and, on pre-analysed tracks, `(1 − time_to_drop/8 s)²` | 0.4 s attack, 0.25 s release; forced to 0 for 0.25 s when the drop lands, as `impact` fires | Live path: no lookahead, so only the live build heuristic |
| `swell` | `energy_raw` | 1.2 s attack, 2.5 s release | |
| `calm` | 1 − smoothstep(0.2, 0.6, swell) | 2 s attack, 1 s release | Ignores sensitivity (it is an inverse) |
| `sparkle` | Onsets in mid/presence/high bands | 120 ms decay, × (0.5 + 0.5·tier/3) | At most one per 90 ms |
| `sub` `bass` `lowmid` `mid` `presence` `high` | Unsmoothed hub bands | Slower than the hub's own smoothing: 40–60 ms attack, 180–450 ms release | |

Signals: `pulse_fired(beat_index, amplitude)`, `accent_fired(bar, amplitude)`,
`impact_fired(strength, kind)`. Counters `impacts`, `impacts_suppressed` and
`last_impact_kind` are there for tests and tuning.

Event envelopes are functions of (hub time − event time). The event time comes from the
hub's grid (`frame.beat_time`, `frame.drop_time`), so envelopes are the same at any
render rate; only the generic smoothing pass uses `exp(-dt/τ)`.

## How to make a scene react

```gdscript
extends Node3D
const ReactivityServiceScript := preload("res://analysis/reactivity_service.gd")

@onready var rx = ReactivityServiceScript.instance()
@onready var mesh: MeshInstance3D = $Mesh
@onready var cam: Camera3D = $Camera3D
var base_fov := 70.0

func _ready() -> void:
	rx.mapper.impact_fired.connect(_on_impact)       # drops: rare, big
	rx.hub.section_changed.connect(_on_section)      # e.g. swap palettes per section

func _process(_delta: float) -> void:
	var m = rx.mapper
	# Small, beat-locked motion every beat; bigger only when the music is.
	mesh.scale = Vector3.ONE * (1.0 + 0.12 * m.effect("pulse") + 0.06 * m.effect("bass"))
	# Slow breathing from loudness; idle drift when the music is calm.
	mesh.rotation.y += 0.002 + 0.01 * m.effect("swell") + 0.004 * m.value("calm")
	# Camera: lean in as a drop approaches, punch on impact (camera intensity applies).
	cam.fov = base_fov - 6.0 * m.camera("anticipation") + 10.0 * m.camera("impact")
	# Raw frame data is still there when needed.
	var f = rx.frame
	if f.anticipation and f.time_to_drop < 1.0: pass  # e.g. pre-roll a particle burst

func _on_impact(strength: float, kind: String) -> void:
	pass  # one-shot effects: flash, camera cut, particle burst

func _on_section(type: String) -> void:
	pass
```

Rules of thumb:

- Use `pulse` and band channels for continuous motion, and `impact` for anything
  dramatic. Do not trigger big effects from `beat` or `onset`: they fire many times per
  second on dense music.
- Use `camera(...)` for anything that moves the viewpoint and `effect(...)` for
  everything else, so the user's Camera/Effects intensity settings apply.
- `frame.anticipation == false` means the source is live (or mock without lookahead);
  `time_to_drop` is then `INF`.
- Never keep a reference to `frame` values across frames; call `frame.snapshot()`.

## Standalone hub (tests, tools)

The hub still works on its own, for tests and offline tools:

```gdscript
const Reactivity := preload("res://analysis/reactivity.gd")
const TrackSource := preload("res://analysis/track_source.gd")
const AnalysisJob := preload("res://analysis/analysis_job.gd")

var hub := Reactivity.new()
var job := AnalysisJob.new()

func _ready() -> void:
	add_child(hub)
	hub.beat.connect(_on_beat)
	hub.drop.connect(func(): flash(1.0))
	hub.big_moment.connect(func(kind): camera_cut(kind))
	job.finished.connect(func(result):
		if result.has("analysis"):
			hub.set_source(TrackSource.new(result.analysis)))
	job.start(track_path)            # runs on a worker thread; cached on later runs

func _process(delta: float) -> void:
	var t := player.get_playback_position() + AudioServer.get_time_since_last_mix() - AudioServer.get_output_latency()
	var f = hub.update_time(t, delta)  # returns the ReactFrame
	mesh.scale = Vector3.ONE * (1.0 + 0.3 * f.bands[1])     # bass
	material.emission_energy = 0.5 + 2.0 * f.energy
	if f.build_progress > 0.0: shake = f.build_progress * f.build_progress

func _on_beat(index: int, strength: float) -> void:
	pulse(strength * (1.5 if hub.frame.downbeat else 1.0))
```

If you prefer polling, read `hub.frame` after calling `update_time`. If you prefer
push, connect to `frame_updated(frame)` and the event signals. To let the hub drive
itself, set `hub.time_provider = func(): return <position>` and then
`hub.auto_process = true`.

To analyse a stream with no pre-analysis, such as a capture bus:

```gdscript
var live := LiveAnalyzer.new(AudioServer.get_mix_rate())
hub.set_source(live)
# each frame:
live.push_frames(capture.get_buffer(capture.get_frames_available()))
hub.update_time(live.stream_time, delta)
```

### Seamless swaps and rebasing (Phase 4b)

- `set_source(src, blend := 0.0, hold_previous := false)`. With `blend > 0` (after the first
  update) the swap is seamless: smoothing state is kept, event trackers re-baseline on the
  new source without firing, and `bands`, `energy`, `flux`, `loudness_db`, `build_progress`
  and `beat_strength` cross-fade linearly from the old source over `blend` seconds of hub
  time. Discrete fields (indices, phases, section) come from the new source at once.
  `hold_previous = true` fades from a frozen copy of the last values instead of sampling
  the old source (track change, stop). `is_blending()` reports a running fade. With
  `blend == 0` the old behaviour holds: the next update resyncs and snaps.
- `rebase(time)` moves the hub clock to `time` (a known seek or a new track) without
  resyncing smoothing; nothing fires for the skipped span.
- `min_beat_spacing` (0.4): a beat closer than this fraction of a beat period to the
  previous one is ignored (guards the seam of a swap). Backwards time disables the guard.
- New `ReactFrame` fields: `beat_time` (exact time of the latest beat: grid time minus
  `beat_phase` × period) and `drop_time` (hub time of the latest drop).

## Source interface (adapter)

`hub.set_source(x)` accepts either of these:

- an Object with `sample(time: float) -> Dictionary`, optionally with
  `native_rate() -> float`;
- a `Callable(time) -> Dictionary`.

When a source declares `native_rate()`, the hub samples it on that grid. It integrates
smoothing between grid points with zero-order hold, so smoothed output depends only on
time and not on render frame rate. Sources without a native rate are sampled once per
update.

Every key is optional. The hub also accepts aliases, which lets the mock feed or any
other ad-hoc feed plug in without changes:

| Key | Type / range | Notes |
|---|---|---|
| `bands` | 6 floats 0..1 | sub, bass, lowmid, mid, presence, high. Arrays of 1 to 5 values are stretched to 6 |
| `sub` `bass`/`low` `lowmid` `mid` `presence`/`high_mid` `high`/`treble` | float 0..1 | Used when `bands` is absent. Missing bands are interpolated from the others |
| `energy` | 0..1 | Defaults to the mean of the bands |
| `flux` | 0..1 | Spectral flux. Falls back to `onset_strength` |
| `beat_index`, `bar_index`, `onset_index`, `phrase_index`, `section_index` | int | An event fires when the value increases |
| `beat`, `downbeat`, `onset`, `drop` | bool | Alternative event form. An event fires on the false→true edge |
| `beat_strength`, `onset_strength` | 0..1 | |
| `onset_band` | int 0..5 | |
| `beat_phase`, `bar_phase` | 0..1 | |
| `bpm`, `confidence`, `downbeat_confidence` | float | |
| `loudness_db` | dB | Short-term loudness, LUFS-like |
| `section` | String | One of `quiet`, `breakdown`, `build`, `drop`, `steady` |
| `phrase_bars` | 4 / 8 / 16 | Read when `phrase_index` changes |
| `build_progress` | 0..1 | |
| `time_to_drop`, `time_to_next_beat`, `time_to_next_downbeat` | seconds | `INF` when unknown |
| `next_section` | String | |
| `anticipation` | bool | `false` means lookahead fields are unavailable (the live path) |

## ReactFrame fields

The hub reuses one instance and overwrites it on every update. Call `frame.snapshot()`
if you need to keep the values. Values marked "sensitivity" pass through the
sensitivity gamma before you see them.

| Field | Range | Meaning |
|---|---|---|
| `time`, `delta` | s | Playback time of this frame, and the caller's delta |
| `bands[6]` | 0..1 | Smoothed bands (per-band attack and release; sensitivity) |
| `bands_raw[6]` | 0..1 | The same bands unsmoothed, at the latest timeline frame (sensitivity) |
| `band(name)` | 0..1 | Smoothed band looked up by name |
| `flux` / `flux_smooth` | 0..1 | Spectral flux: raw, and smoothed with a 10 ms attack and 120 ms release |
| `onset`, `onset_band` | 0..1, int | Strength and band of an onset that fired this frame. Otherwise 0 and -1 |
| `beat`, `beat_index`, `beat_strength` | bool, int, 0..1 | Whether a beat fired this frame |
| `downbeat`, `bar_index` | bool, int | Whether a bar started this frame |
| `beat_phase`, `bar_phase` | 0..1 | Read at the exact render time, so they animate smoothly between frames |
| `bpm`, `confidence`, `downbeat_confidence` | BPM, 0..1 | |
| `loudness_db` | dB | Short-term (3 s) LUFS-like loudness. Uses approximate K-weighting, so it is not calibrated LUFS |
| `energy` / `energy_raw` | 0..1 | Overall energy: smoothed (0.3 s attack, 1.5 s release) and raw |
| `intensity`, `intensity_name` | 0..3 | `calm`, `normal`, `high`, `peak` (`ReactFrame.Tier`) |
| `section`, `section_index`, `section_changed` | | Current section type. `section_changed` is true on the frame the section changes |
| `drop` | bool | True on the frame a drop starts |
| `phrase` | 0/4/8/16 | Length of a phrase that starts this frame |
| `big_moment`, `big_kind` | bool, `drop`/`downbeat` | True on a gated peak-class moment |
| `build_progress` | 0..1 | Progress through a build. Also ramps over the last 4 bars before any drop |
| `time_to_drop`, `time_to_next_beat`, `time_to_next_downbeat` | s | `INF` when unknown or when the source is live |
| `next_section` | String | Type of the next section (offline only) |
| `anticipation` | bool | False on the live path |

## Signals

| Signal | When it fires |
|---|---|
| `frame_updated(frame)` | Every update, after all event signals for that update |
| `beat(index, strength)` | Each tracked beat. On the offline path it fires at the timeline grid point at or after the beat, so it is at most 11.6 ms late |
| `downbeat(bar)` | The first beat of each 4/4 bar |
| `onset(strength, band)` | An onset with shaped strength ≥ `onset_threshold`, at least `min_onset_interval` after the previous one |
| `section_changed(type)` | The section index changes |
| `drop()` | A section of type `drop` begins. On the live path this happens when bass re-enters |
| `phrase(bars)` | A 4-, 8- or 16-bar group starts, aligned to the start of the section |
| `intensity_changed(tier)` | A tier change that passes hysteresis and the dwell check |
| `big_moment(kind)` | Every drop. Also a downbeat that meets all four conditions under "big moments" below |

Seeking: if time goes backwards, or jumps forward by more than `seek_threshold`
(default 1 s), the hub resyncs. It snaps its smoothing and fires no events for the
skipped span.

## Tuning knobs (all on the hub)

| Property | Default | Effect |
|---|---|---|
| `sensitivity` | 1.0 | Gamma `v^(1/s)` applied to bands, energy and onsets. 2.0 is livelier; 0.5 is calmer |
| `band_attack` / `band_release` | 15–30 ms / 100–300 ms | Per-band exponential time constants. Independent of frame rate |
| `energy_attack` / `energy_release` | 0.3 s / 1.5 s | |
| `flux_attack` / `flux_release` | 10 ms / 120 ms | |
| `tier_thresholds` | [0.30, 0.58, 0.82] | Energy needed to enter normal, high and peak |
| `tier_hysteresis` | 0.1 | Energy must fall this far below an entry threshold before the tier drops |
| `tier_min_dwell` | 2 s | Minimum time between tier changes. A big moment can still lift the tier to peak immediately |
| `peak_window` | 8 s | How long after a big moment peak stays reachable outside a drop section |
| `onset_threshold`, `min_onset_interval` | 0.35, 60 ms | Onset event gating |
| `min_big_interval` | 4 s | Rate limit for big downbeat moments. Drops always fire |
| `big_downbeat_confidence`, `big_downbeat_energy` | 0.6, 0.7 | Gate for downbeat big moments |
| `seek_threshold`, `max_substeps` | 1 s, 256 | |

Peak tier is gated. The hub enters it only during a `drop` section or within
`peak_window` of a big moment. If the source reports no sections at all, peak needs
energy of at least 0.92.

Big moments are gated the same way. A downbeat counts as a big moment only when all
four conditions hold:

- downbeat confidence is at least 0.6;
- it starts a phrase of 8 or 16 bars;
- energy is at least 0.7;
- at least 4 s have passed since the last big moment.

## Offline analysis details

- **Features.** The band edges are 20/60/250/500/2k/6k/11k Hz. Bands are normalised per
  track, from the 10th to the 99.5th percentile in dB with a range of at least 24 dB, so
  quiet and loud masters both use the full 0..1 range while quiet intros stay low. Flux
  is the half-wave-rectified difference of `log(1+γ|X|)` over 36 log-spaced bands,
  divided by its 99th percentile. Energy is the momentary (0.4 s) loudness mapped from
  its 5th to 98th percentile.
- **Onsets.** A frame is an onset when it is the local maximum within ±3 frames, it
  exceeds the moving mean over the previous 100 ms and next 70 ms by at least 0.06, and
  it is at least 30 ms after the previous onset. The onset's band is whichever band has
  the most normalised flux.
- **Tempo.** The onset envelope is autocorrelated with an FFT. Each candidate BPM from
  60 to 200 is scored with comb taps at L, 2L, 3L and 4L plus half-beat taps at L/2 and
  3L/2, then weighted by a log-Gaussian prior centred on 120 BPM (σ = 0.9 octave).
  Beats come from Ellis's dynamic programming with tightness 100, then get sub-frame
  parabolic refinement. The final BPM is a least-squares fit over the longest steady run
  of beats.
- **Downbeats.** The phase is chosen as one of four hypotheses. The score combines three
  z-scored terms: low-band accent at the beat, log-spectral novelty between successive
  beat intervals (chord or bass changes land on bar lines), and energy change across
  the beat. `downbeat_confidence` comes from the margin between the best and second-best
  hypotheses.
- **Sections.** Bar features are E, LOW, HIGH, MID and ONS. Novelty is the distance
  between means over windows of up to 4 bars on each side, peak-picked with a threshold
  of max(0.06, mean + 0.5σ). Sections are at least 4 bars long and snap to the 4-bar
  grid. Classification rules are documented at the top of `structure_analyzer.gd`.
  Adjacent sections of the same type merge, and a high steady section with bass that
  follows a drop is merged into the drop.
- **Cache.** `user://analysis-cache/<md5(path|size|mtime|version)>.anl` holds a binary
  Variant written by `store_var` with objects disallowed, so loading a cache file cannot
  run code. Changing `TrackAnalysis.VERSION` invalidates the cache. The test overrides
  `AnalysisCache.dir` and `PcmDecoder.temp_dir`.

## Live path differences

`LiveAnalyzer` uses the same feature extractor. Band normalisation is an AGC: a peak
follower with an 8 s release over a 24 dB window. Tempo comes from the same estimator,
run on the last 8 s every second, with vote-based switching that needs 5 consistent
votes to change by an octave. Beats come from a phase-locked predictor with phase gain
0.25 and period gain 0.03. Downbeats use decaying per-position accent scores. Sections
come from a per-beat state machine on raw low-band and high-band dB levels: a drop is a
jump of at least 5 dB in the low band near its recent peak. No lookahead is available,
so `anticipation` is false and `time_to_drop` is `INF`. Live analysis uses about 5% of
one core in realtime.

## Measured (M4 Pro, Godot 4.7.1 headless, `test_music_analysis.gd`)

- **Synthetic 128 BPM track** (8-bar intro, 8-bar build, 16-bar drop, 8-bar breakdown):
  - BPM measured as 128.00.
  - 160 of 160 beats fall within 30 ms; the mean error is −0.1 ms.
  - 40 of 40 downbeats are correct.
  - Sections come out in the correct order with exact boundaries.
  - The drop is announced 2.0 s ahead.
- **Smoothing at dt 1/30 versus 1/144:** the maximum difference is 3e-7 with sub-stepping
  sources. A plain callable with no sub-stepping has a mean difference of 0.010.
- **`Polyesterday.mp3` (a song clip since replaced by the synthetic `DemoBeat.mp3`)** (30 s): BPM 99.96, analysed in 1.2 s (decoding took 0.05 s of that).
- **4-minute track:** analysed in about 9.5 s, roughly 25× realtime. Setting `HOP = 512`
  roughly halves that time but costs beat precision.
- **Other tempos** (scratch run): 95, 110, 140 and 150 BPM are exact. 72 BPM is reported
  as 144 and 174 BPM as 87. Both are octave errors, caused by the prior's preference
  for 90–150 BPM, and the beats still land on the true grid.

## Measured, Phase 4b (`test_reactivity_integration.gd`, headless, Dummy audio)

Report: `research/oozic/proof/phase4b/reactivity-integration.json`.

- **Mock 128 BPM through PlayerBus → service → hub → mapper, 40 s at 30/60/144 fps:**
  85 of 85 beats at each rate, the same beat sequence at every rate, `beat_time` exact to
  the grid (error < 1e-9 ms), signal latency 0 to one frame + 10.4 ms (the 100 Hz
  synthetic grid): at most 43.8 / 27.1 / 17.4 ms. 21 downbeats, and a pulse on every beat.
- **Mock feed vs synthetic source:** the same section at every 50 ms step over 150 s; mock
  kicks land at synthetic beat phase 0.
- **Impact over 230 s of the 40-bar loop:** 3 drops, 3 impacts, all on drops (75 s apart).
  Two drops 3 bars apart produce one impact; the second is rate-limited. Non-drop rules
  (tier, breakdown, 16-bar budget, imminent drop) are unit-checked.
- **Hot swap live → pre-analysed** on the synthetic track at 40 s, 2 s blend, 60 fps.
  "Excess jump" = per-frame change of the swapped hub beyond the larger per-frame change
  of a live-only and a track-only hub:

  | | Hub bands (20 ms attack) | Mapper band channels |
  |---|---|---|
  | Blended swap | 0.074 | 0.006 |
  | Hard swap (`blend = 0`) | 0.514 | 0.029 |

  The test asserts ≤ 0.1 for hub bands (and < 30% of the hard swap) and ≤ 0.03 for the
  channels. Beats during the swap match the pre-analysed beats (5 vs 5).
- **Real AudioService path** (`Polyesterday.mp3` (a song clip since replaced by the synthetic `DemoBeat.mp3`), Dummy driver, empty cache): starts
  live, hot-swaps to pre-analysed 1.1–1.2 s after the track starts (the live analyzer had
  consumed 1.0–1.1 s of captured PCM), releases the live analyzer after the blend, clock
  within 0.01 s of playback; seek, pause (frozen), resume, track change (instant memory
  hit), stop (idle, channels release) and a fresh service hitting the disk cache.
- **Offline analyzer on `test-media/`:** `Polyesterday.mp3` (a song clip since replaced by the synthetic `DemoBeat.mp3`) (30.0 s): 99.96 BPM, tempo
  confidence 0.96, downbeat confidence 0.99, 49 beats, 196 onsets, sections
  `steady@0.0, breakdown@26.8`, analysed in 1.16 s (26× realtime). It is the only file in
  `test-media/`.

## Limitations

- The offline path assumes one tempo and constant 4/4 meter. Downbeat phase is chosen
  once for the whole track, so tempo changes, dropped beats or 3/4 sections will drift.
- The section heuristics are tuned for electronic and dance structure. They have been
  validated on synthetic tracks and one 30 s real clip only, and need checking against
  more real tracks.
- Decoding needs macOS `afconvert`. Inside a sandbox without Core Audio codecs, the
  real-file test is skipped rather than failed.
- On the live path, sections are causal and coarse. For example, the intro reads as
  `steady` because the AGC is relative, and a drop is recognised one beat late.
- Prefetch follows sequential order only; with shuffle on, nothing is prefetched.
- No scene binds to the channels yet: the classic scenes keep the original analysis, and
  the modern scenes that will use the channels are later work. Channel time constants
  are tuned on synthetic material and one real clip, not by eye on real scenes.
- Hub bands are fast (20 ms attack), so even a blended swap moves them by up to ~0.07 in
  one frame beyond the music's own motion; the mapper's band channels (≤ 0.006) are the
  values to bind visuals to.
- The live analyzer's clock is mapped to playback time by an offset; capture latency
  (one mix buffer) is not compensated, so live beat phases may lag by a few ms.
