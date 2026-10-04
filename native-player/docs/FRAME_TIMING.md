# Frame timing and frame-rate independence

Phase 1 audit, 2026-10-04. Goal: scenes play the same at 30, 60, 144 fps and uncapped.

## What the original did

Evidence: `research/oozic/original-player-capability-audit.md` §5 and §6, from an independent static decompile.

- Lava3 runs one update per rendered frame (0x10025a80). Lava3Aud `GetFilteredData` (0x10005dd0) paces it. When the frame is early it sleeps up to `1000/MaxFrameRate` ms. Otherwise it clamps elapsed time to 100 ms. It then sets `dt = ms * 0.001`, and Lava3 scales dt by the scene's `Responsivness`.
- `MaxFrameRate` defaults to **60** (0x100045b8). It is a registry override, and nothing writes it, so the shipped cap was 60 fps.
- **Correction:** the earlier README/handover statement that "the original Triple Trance frame limit is 25 FPS" is wrong. The scene header's `FramesPerSecond` (25 for Triple Trance, 26 for Hydroid) has no recovered reader and does not pace anything. The old `main.gd` used it as `Engine.max_fps`, with a 26 fallback that disagreed with `scene_runtime`'s 25. Both uses are gone.
- Effects integrate dt. Event logic runs once per update: creation/interrupt threshold tests, decay-end tests, retriggers and the `rand()` draws they make. So does one counter, the camera's random-direction trigger, which adds 1 per update while band A == 1.0 (0x10001183).
- `rand()` is a single MSVC LCG stream. It starts at seed 1, is never reseeded in Lava3, and the camera, effects and texture setup all share it.

## Decision

The scene simulation now runs as **fixed 60 Hz ticks** by default. `SceneRuntime.advance(delta, sampler)` runs whole 1/60 s updates whatever the render rate. It carries the remainder to the next frame and caps catch-up at 6 ticks, which is the original's 100 ms clamp, so a stall turns into slow motion as it did in the original. The vertex output is built only on the frame's last tick, and earlier catch-up ticks advance only the effect state. Object and camera transforms are interpolated between the last two ticks for display ("Smooth motion", on by default). This adds up to one tick (16.7 ms) of display latency.

Why fixed rather than per-frame dt: thresholds, retriggers and rand draws happen per update. Under variable dt, the number of updates decides how many events fire and which random values each one gets, so the scene diverges as the render rate changes. With 60 Hz ticks, every render rate gives the result the original gave at its 60 fps cap, and the output is deterministic.

The original structure is still available. Scene tools → "Per-frame dt (original)" (`settings.cfg [display] timing="frame"`) runs one update per rendered frame with dt clamped to 100 ms. In that mode continuous motion keeps the right speed, but event timing follows the frame rate, as it did in the original.

Deliberate deviation: the camera A==1 counter now adds `dt * 60` instead of 1. At 60 updates/s the two are identical. In per-frame mode the normalised counter fires at the same rate at any fps. `CameraRuntime.count_per_update = true` restores exact per-call counting.

Render pacing is a separate, persisted setting (`app_settings.gd`): vsync on/off, plus a cap of Original (60) / 30 / 60 / 144 / Uncapped. The default is vsync on + Uncapped. The scene speed no longer depends on render rate, and the user asked for uncapped. "Original (60)" reproduces the shipped cap.

## Per-file findings

| Path | Per-frame logic found | Frame-locked? | Fix |
|---|---|---|---|
| `scene_runtime.gd` `step()` | Geometry throttle `_geometry_elapsed >= 1/FramesPerSecond`, reset to 0 (remainder dropped). It applied only in inspection mode, and in normal mode geometry ran every frame with variable dt | Yes: the throttle dropped its remainder (60 fps render with a 25 Hz throttle → ~20 Hz). Every event system below was per frame | Throttle removed, since it has no binary evidence. `advance()` is the fixed-tick driver. `step(dt, …, build_geometry)` is one original update. Catch-up ticks use new state-only `advance()` methods |
| `legacy_effect.gd` (Rotate/Orbit/TexScroll) | `angle += dt*v`, envelope `elapsed += dt`, trigger/retrigger per call, `direction_threshold *=` per trigger, `texture_scale *= 1+k` | Integration is dt-correct; triggers are per update. TexScroll's `*= (1+k·dt)` is first-order and slightly rate-dependent | Fixed ticks |
| `texture_effects.gd` (Translate/Wave/Zoom) | Per-call triggers with rand draws, `m *= 1+mv`, single-turn wraps, `MinBetweenTime` accumulator. Zoom restore uses `pow(0.5, dt/decay)` (already exponential) | Triggers and multiplicative growth per update | Fixed ticks |
| `cos_deformation.gd`, `bump_deformation.gd`, `ripple_pools.gd` | Wave slot selection, `_spacing += dt`, creation/interrupt per call, 9–12 rand draws per creation, palette push per call | Yes (event count and rand order) | Fixed ticks. `advance()` state-only paths added |
| `shape_weights.gd`, `morph_runtime.gd` | Envelope/trigger per call; morph phase `+= dt·v`, with a strict `> 1` wrap | Triggers per update | Fixed ticks. Morph state now advances on catch-up ticks too |
| `alpha_center_effects.gd`, `matrix_effects.gd` | Envelope/trigger per call; rand on fresh triggers | Triggers per update | Fixed ticks |
| `hydra_motion.gd` | Crawl velocity is `v·dt·0.5`, added to output per call. Retrigger when `candidate >= V`. `exp(-k·dt)` decay. Rand per retrigger | Yes: the retrigger comparison depends on dt | Fixed ticks. The mesh is rebuilt only on the frame's last tick |
| `camera_runtime.gd` | Counter +1 per update while A==1; Godot `RandomNumberGenerator` (randomised) | Yes, also in the original | Counter normalised to dt·60. RNG → `legacy_rand.gd` (MSVC LCG) |
| `audio_inputs.gd` | One FFT pass per `update()` call, max-pooling the windows completed in that call. Reference/S smoothing via `exp(-ln2·elapsed/T)` with elapsed = sample count/rate | Yes: at >94 fps a 48 kHz frame holds fewer than 512 samples, so ~35% of frames had no FFT window and reported **zero** bands and decaying references | Split into `push()` (per render frame) and `consume()` (per scene update). Windows pool between consumes; a consume with no new window holds the previous A/S |
| `main.gd` `_process` | Called `inputs.update` + `runtime.step(delta)` per frame; recovery-button timer is dt-based | Yes (above) | Push per frame, `runtime.advance(delta, sampler)` |
| `main.gd` `set_frame_rate` | `Engine.max_fps = FramesPerSecond` (26 fallback), 60 in inspection | Wrong pacing source | `AppSettings.apply()` |

## Shared random stream (partial)

`legacy_rand.gd` implements the MSVC `rand()`. The scene runtime owns one instance, reseeded to 1 on `reset()`. The camera and the scene-level texture/alpha/center/scale/shear draws (`_texture_random`) share it. To match the original order, the camera now updates before objects in each tick. Still separate: Cos/Bump/Ripple/Pools/Hydra keep their own seed-1 LCGs. Two more differences remain: reseeding on reset differs from the original's process-lifetime stream, and the exact cross-object draw order is unverified. Both are recorded as fidelity work, not fixed here.

## Verification

`test_frame_rate_independence.gd` (headless, Dummy audio, about 75 s) does the following:

- Steps Triple Trance and Hydroid for 12.02 s with the synthetic feed (crossing build → drop), under seven dt sequences: 25, 30, 60, 144 fps; jittery 90–300 fps; 10.5 fps (multi-tick catch-up); and 60 fps with 90 ms hitches. In every sequence it compares the tick count, camera position/angles, the A==1 counter, every object transform, the Rotate/Orbit angles, and four sampled vertex positions per object. Measured difference: **0.0** in all sequences. This also shows that the state-only catch-up paths match the full deform paths.
- Checks catch-up capping (2 s stall → 6 ticks, rest dropped), and that uninterpolated presentation equals the tick state.
- Per-frame mode: with constant input, angles stay within 0.30 rad and camera angles within 0.21° after 12 s at 30 vs 144 fps. A frame-locked speed bug would be about 4.8× off. With music, the camera ends 3.5–4.6 units apart, which shows why the fixed tick is the default.
- Audio: the pooled push/consume analysis at 30 and 144 fps renders matches 60 fps, with a mean abs difference of 0.026 / 0.005. Hold is verified. The old `update()` had no FFT window on 202 of 576 frames at 144 fps.
- Camera counter: 1 s of A==1 reaches 60 at 30/60/144 updates/s; exact-original mode reaches 144 at 144.

The report is written to `research/oozic/proof/phase1/frame-rate-independence.json`.

## Phase 1b additions

The following run once per scene update, so they follow the same fixed 60 Hz tick:
- The strobe flip counter and the coloured-light beat counter (Lava3 0x10019430). Both count updates against `0.075/dt` and `0.1/dt`.
- The intro timer.
- 3D text DefMsgRot/DefMsgAlpha.
- DefSwitch, DefElastic and DefSuperBump.

`test_engine_api.gd` checks the following at 30 and 144 fps:
- The light-FX state after 20 s is identical.
- LVT7 SuperBump vertices agree to within 1e-4.

DefSuperBump's persistent UV drift (DoTextureRestore) only advances on geometry ticks. Under heavy catch-up, UV restore is therefore slightly slower. Vertices are unaffected unless DoMask samples those UVs.

## Not done / follow-ups

- Geometry deformation is presented at 60 Hz. Vertex interpolation between ticks (for example in the vertex shader) is not implemented.
- The real-audio analysis consume rate (60 Hz) differs from the original's per-frame read size. The original clamped its read between rate/FPS and rate/10 samples, so it read about rate/60 at the cap, which matches.
- Measured vsync behaviour: a windowed capture with vsync "on" reported ~700 fps. The window was probably not presented to an active display (machine idle), so this is unverified on a visible display.
