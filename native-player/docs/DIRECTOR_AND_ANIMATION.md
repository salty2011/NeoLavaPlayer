# Virtual director and character animation (Phase 4d)

Brief: modernise Oozic/Lava as if Creative had kept developing it to 2026. Upgrade the fidelity, not the soul. Reactions should feel musical rather than twitchy, and the big ones are saved for big moments.

Both systems are Modern-only. They live in `native-player/modern/` and are switched on per scene by sections of the scene's Modern profile (`modern/profiles/<scene>.json`: `"director"` and `"animation"`). Classic keeps the recovered camera and motion exactly, and the simulation never sees either system.

Showcase scene: Triple Trance. Its three characters are the heads (Mushroom, SignBoard, Sphere). Each sits on a parent-attached stem (Cone1–3) above the marbled platform.

## How it fits

```
visualiser._process
  ReactivityService.tick (priority -50)  -> hub.frame, mapper channels
  runtime.advance(delta)                 -> sim ticks; present() writes sim transforms + camera
  ModernLayer.update(delta)
    1. CharacterAnimator.update(frame, mapper)   display offsets on heads, stems, platform
    2. VirtualDirector.update(frame, mapper, ctx) -> CameraComfort -> camera pose, FOV, DoF focus
    3. materials, lights (the rim follows the camera), particles (they follow the animated heads)
```

- **The simulation is untouched.** `SceneRuntime.present()` writes the simulated transforms to the nodes and the camera every frame. The runtime keeps its own `sim_transform` and `_camera_current` and never reads node transforms back. Animation and director only overwrite the *displayed* transforms after `present()`. If a frame has no `present()` (paused), each slot recognises its own last write and keeps the stored base, so nothing accumulates. `detach()` writes the bases back at once and restores the FOV.
- **Clock.** Both systems run on the reactivity hub clock (`frame.time`). They freeze when the hub freezes (pause), follow seeks, and in mock mode restart with the scene.
- **Frame-rate independence.** Musical decisions are keyed to bar and beat indices. Moves are pure functions of the beat position. Every spring (comfort rig, follow-through) integrates on a fixed 240 Hz grid of the hub clock and is interpolated for display, the same pattern `docs/FRAME_TIMING.md` uses for the simulation. Smoothing elsewhere is `exp(-dt/τ)`.

Files:

| File | Role |
|---|---|
| `modern/director/virtual_director.gd` | Editing grammar, shot choice, musical modulation (pace, boost, push-in, impact FOV), modes |
| `modern/director/shot_library.gd` | Shot types as pose functions; resolution of profile shot definitions with seeded draws; value noise |
| `modern/director/camera_comfort.gd` | Critically damped follow with speed and acceleration caps, angular caps, FOV cap, collision and bounds |
| `modern/animation/character_animator.gd` | Move selection and cross-fades, idle noise, follow-through springs, squash, stem rig, platform float |
| `modern/animation/beat_moves.gd` | The beat-locked move functions |
| `modern/modern_layer.gd` | Builds both from the profile, feeds them, applies the camera pose and DoF focus |
| `test_director.gd`, `test_character_animation.gd` | Tests (below) |
| `tools/director_capture.gd` | Windowed proof captures at chosen times |

## Camera modes

Setting **Modern camera** (Settings → Rendering), saved as `[render] camera_mode` in `user://settings.cfg`:

| Mode | Behaviour |
|---|---|
| Director (default) | The virtual director below |
| Original | The recovered Lava3 camera, untouched (identical to Classic) |
| Locked | One static wide framing (`director.locked`), never moves |

Bus: command `set_camera_mode {mode: "director"|"original"|"locked"}`; state in `PlayerBus.render.camera_mode`. Switching is live: no rebuild and no scene reset. Classic always uses the original camera.

The existing **Camera intensity** setting (Settings → Reactivity, `mapper.camera_intensity`, 0–200 %) scales everything musical the director does: push-in depth, the drop's pace boost, the impact FOV punch and handheld noise. Cuts still happen at 0 %, but the camera stops reacting within shots.

## Shot library (`director.shots`)

Shots are defined relative to scene objects (by name) and the scene centre (`director.center`). Any field written as `[a, b]` is drawn uniformly when the shot is used, with the director's seeded random.

| Type | Fields | Motion |
|---|---|---|
| `original` | none | The recovered camera's position, LookAt and FOV, fed through the comfort rig and push-in. It is part of the soul, so it stays in the rotation |
| `orbit` | `target`, `distance`, `elevation`, `az_speed` (deg/s, sign drawn), `fov` | Circles the target. Wide establishing shots are slow orbits with a wide FOV |
| `closeup` | `target` (an object), `distance`, `elevation`, `az_offset`, `az_speed`, `fov`, `look_offset` | The camera sits outside the object, away from the scene centre, so the other characters stay behind it. It tracks the object's live (simulated) centre and drifts slowly. DoF focuses on it |
| `dolly` | `from` → `to` distance, `travel_bars`, `elevation`, `az_speed` | Smoothstep distance move over `travel_bars` of the current tempo, then holds |
| `crane` | `distance`, `from` → `to` elevation, `travel_bars`, `az_speed` | Smoothstep elevation move |
| `handheld` | as orbit + `noise`, `noise_aim`, `noise_freq` | A fixed framing with low-amplitude seeded value noise on position and aim |

Triple Trance has 11 shots: `original`, `wide`, `orbit`, `close_mushroom`, `close_signboard`, `close_sphere`, `dolly_in`, `dolly_out`, `crane_up`, `crane_down` and `handheld`.

Shot time `u` advances at the section's **pace** (quiet 0.6, breakdown 0.5, build 0.9, drop 1.25, steady 1.0) times the drop **boost**. Pace changes are smoothed (τ = 1 s), so a shot speeds up rather than jumping.

## Editing grammar (`director.grammar`)

All shot changes happen on downbeats. The director acts on the first render frame after the hub's `bar_index` increments, and records the exact grid time of the downbeat (`frame.beat_time`).

| Rule | Detail |
|---|---|
| Downbeats only | Changes are evaluated once per bar. Phrase positions (bars since the section start) decide: `phrase8` probability on 8-bar boundaries, `phrase4` on 4-bar boundaries, `downbeat` on plain downbeats (0 except in drops) |
| Minimum shot | `max(min_shot_bars, min_shot_seconds)` = 2 bars and 4 s (3 bars at 128 BPM), plus the section's own `min_bars`. `max_bars` forces a change |
| Before a drop | With lookahead (pre-analysed or mock), no change is allowed if it would leave less than the minimum before the drop, so the drop cut is always legal |
| Drop | On the drop downbeat: a **cut** to `drop_shots` (orbit, handheld or a close-up), then `boost` for `boost_bars` (8, one phrase): pace × (1 + 0.35 × camera intensity), stiffer follow. The `impact` channel adds a 3.5° FOV punch-in that releases with it (it fires on drops only) |
| Late drop | On the live path a drop can land inside the minimum. The boost starts anyway, and the next legal downbeat cuts to an energetic shot |
| Build | `push` = max(build_progress, anticipation channel) × `push_in` (0.26) × camera intensity, smoothed with τ = 0.5 s, so the camera pushes in toward the subject as the drop approaches. A cut resets it |
| Quiet | Long shots (8–16 bars), slow pace, soft follow (ω 1.5), 60 % of changes are glides |
| Breakdown | Enters on a glide to `wide`; long and slow (pace 0.5, ω 1.4) |
| Cut or glide | A **cut** snaps the comfort rig to the new shot. A **glide** keeps it, so the camera moves to the new framing with the critically damped follow (ω ≤ 1.1 for 3 s) and inside every cap |
| No repeats | The current and previous shot are excluded; close-ups of the same subject are separate shots |
| 30-degree rule | A cut to a centre-targeted shot turns the view by 35–170° (`min_turn_deg`), so there are no jump cuts |
| Determinism | Draws are `hash(seed, bar, salt)`. They depend only on bar indices and section types, never on render timing. The same music gives the same edit |
| No beat grid | Silence or no confidence: no cuts. After `no_grid_timeout` (24 s) the director glides to a new shot |

Section types come from the hub (`quiet`, `build`, `drop`, `breakdown`, `steady`). An unknown type uses `steady`, and every section merges over `steady`.

## Comfort safeguards (`director.comfort`, `director.guard`)

| Safeguard | Triple Trance value |
|---|---|
| Linear speed / acceleration cap | 3.5 units/s, 4.0 units/s² (scene radius about 6) |
| Angular speed / acceleration cap (view direction) | 50°/s, 90°/s² |
| FOV speed cap | 15°/s |
| Follow | Critically damped spring, ω per section 1.4–3.0 (×1.3 during the boost) |
| No roll | The camera always aims with world up; near-vertical aims are nudged |
| Inside geometry | Head spheres (bounding radius + clearance) and platform boxes grown by `clearance` = near clip 1.0 + 0.15, resolved inside the integrator (the velocity into the obstacle is removed) |
| Bounds | Within 10 units of the centre, y in [−3, 8] |
| No strobing | At least 2 bars and 4 s between changes |

## DoF

On close-ups the far DoF focuses just behind the subject (`focus + 0.9`, transition 2.2, amount `effects.dof.closeup_amount`). Other shots return to the profile's far DoF. All three values are smoothed (τ = 0.35 s). DoF needs the High or Ultra quality and the DoF effect on.

## Character animation (`animation`)

Layers per character, all display-only and added on top of the recovered motion. The recovered DefCenter, DefShape and DefShear motion keeps running underneath. In Triple Trance the recovered bounce is about ±0.2 units, and the Modern moves are a few hundredths on top of it.

1. **Beat moves** (`beat_moves.gd`). Each is a pure function of the beat position, with its extreme exactly on a beat:

   | Move | Shape | Amplitude (`animation.moves`) |
   |---|---|---|
   | `bob` | Nods down on every beat: −(½ + ½cos 2πφ)² | 0.05 |
   | `hop` | Rises to every beat, sharper: (½ + ½cos 2πφ)³ | 0.07 |
   | `sway` | Side to side, cos(π·beat), extremes on alternate beats | 0.075 |
   | `twist` | Turns about the stem, cos(π·beat) | 9° |
   | `lean_in` | Leans toward the centre on each downbeat (bar phase) | 0.08 |

   **Selection** happens per section (`animation.sections`): on entering a section and every `select_bars` (2) downbeats, each character draws a move from the section's weighted table, with the seed, bar and character as inputs. A character that drew the same move as its neighbour redraws with 60 % probability, so the three rarely move identically. The tables are quiet: sway, bob or rest at 0.45; build: bob, lean_in or sway at 0.5, growing ×(1 + 0.8·build_progress); drop: hop, bob, twist or sway at 1.0; breakdown: mostly rest at 0.35. Each character also has a fixed amplitude scale (0.85–1.15) and sway/twist direction.

   **Blending.** Weights cross-fade with smoothstep over `ramp_beats` (0.5 beat), starting from the current weight at the frame of the change, so nothing jumps. In build, amplitude growth is retargeted just after each beat, so at the next beat the weights are steady and the peak stays on it.
2. **Idle.** Seeded smooth noise per character (0.02 units, 2° twist, 0.22 Hz), scaled by 0.4 + 0.6 × `calm`, so quiet passages breathe and never look looped.
3. **Follow-through.** An underdamped spring (2.6 Hz, ζ 0.35) on the head offset. Displayed offset = primary + 0.6 × (spring − primary), so the head lags and overshoots at the end of each move. Each accent (downbeat, `accent_fired`) kicks the spring downward (`jiggle` 0.25 × accent amplitude) for a short wobble.
4. **Squash and stretch** on accents. A decaying oscillation from the exact bar time, s(τ) = −0.07 · amp · e^(−τ/0.16) · cos(2πτ/0.36): it squashes first, then rebounds. The amplitude is the accent amplitude × (1 + 0.8 · impact), so drops squash hardest. The squash is world-vertical about the head centre and volume-preserving: sy = 1 + s, sx = sz = 1/√(1 + s). It is clamped to ±0.15.

**Stem rig.** The stem is a child of the head, but it must stay planted on the platform. It is rebuilt from its own base point B (the platform top under the head): a shear and stretch whose top follows the head offset exactly, and the same twist. The head tilts toward the stem lean. The stem's local transform is solved as `H'⁻¹ · S'`.

**Environment.** The platform assembly (platform, stems and heads, through one transform) floats up to 0.035 units and tilts up to 0.8°. Both scale with 0.35 + 0.65 × `calm`, and the speed with 1 + 0.8 × `swell`. The background's UV drift speed was already driven by `swell` (Phase 4c). It now also slows by 40 % × `calm` (`reactions.background_drift_calm`). Ambient life comes from the existing motes (`ModernEffects`), which follow the animated heads; no new particles were added. The deformation speed of the background and platform stays the original simulation's.

Every animation amplitude is × **Effects intensity**.

## Adding the director and animation to a new scene

1. Give the scene a Modern profile first (`docs/MODERN_RENDERING.md`).
2. Add `"director"`. Copy Triple Trance's and set:
   - `center`: the point wide shots orbit. It is in scene coordinates, the same space as the camera's LookAt.
   - `subjects`: the objects that may get close-ups, and one `close_<name>` shot per subject.
   - `guard`: `spheres` for compact objects the camera may approach, `boxes` for flat or large ones, `clearance` ≥ the scene's NearClip + 0.15, and `max_radius`/`min_y`/`max_y` inside the scene's enclosing geometry. The original camera's `RadiusMax` is a good guide.
   - Shot distances: scale them to the scene. Triple Trance's original camera radius is 3.5–8; wide shots use 7–8 and close-ups 2.4–2.8. A close-up's `distance` must exceed the subject's guard sphere radius.
   - `comfort`: keep the speed cap around 0.5 × scene radius per second.
3. Add `"animation"` if the scene has characters. List `characters` as `{head, stem}`. The stem must be a child of the head (`ParentChildLink`); leave `stem` empty if there is none. `environment.platform` lists the objects that float together, with the platform top first.
4. Run `test_director.gd` and `test_character_animation.gd` with the scene path changed (both are written for Triple Trance), then capture with `tools/director_capture.gd`.

Tuning knobs, by symptom:

| Symptom | Knob |
|---|---|
| Too many cuts | Raise `min_bars`; lower `phrase4`/`downbeat` |
| Too static | Raise `phrase4`, lower `glide`, raise `pace` |
| Camera lags fast shots | Lower orbit `az_speed` or `boost_pace` (the speed cap is reached) |
| Drop not punchy enough | `impact_fov`, `drop_shots`, drop `omega` |
| Moves too busy | Section `amp`; more `rest` weight |
| Moves too stiff | Raise `secondary.follow`, lower `damping` |

## Tests

`test_director.gd` (headless, Dummy audio; runs 66 s at 30/60/144 fps): see the report `research/oozic/proof/phase4d/director.json`.

`test_character_animation.gd` (64 s at 60 and 144 fps): `research/oozic/proof/phase4d/character-animation.json`.

Measured (headless, Dummy audio, mock 128 BPM, default schedule):

| Check | Result |
|---|---|
| Edit over 66 s | `wide` (start), cut to `original` (bar 8, build), `close_sphere` (bar 12, phrase), **`orbit` on the drop downbeat** (bar 16), `close_mushroom` (19), `crane_up` (23), `orbit` (28, phrase), glide to `wide` (bar 32, breakdown) |
| Change timing | Every change on the downbeat grid (< 1e-6 s), at most one frame + 10 ms after it, at 30/60/144 fps |
| Shortest shot | 5.6 s (3 bars); no immediate repeats |
| Push-in through the build | push 0.01 → 0.25; camera-to-subject distance 2.99 → 2.67 within one close-up |
| Comfort at 30 / 60 / 144 fps | speed 2.63 / 2.63 / 2.62 units/s (cap 3.5), angular 24.8°/s (cap 50), accel 3.2 / 3.7 / 3.6 units/s² (cap 4), FOV 2.9°/s (cap 15), roll 0, never inside geometry or out of bounds |
| Determinism | 60 fps twice: bit-identical. 30 and 144 fps: the same edit (bars, kinds, shots); pose within 0.04 / 0.03 units of 60 fps at common times |
| Modes | Locked: static. Original: identical to the Classic camera, frame by frame |
| Classic | Simulation (camera state, ticks, sim transforms, vertices) identical with the director and animation attached; detach restores the camera and FOV |
| Hand-over | `rebuild()` at 8 s and a new layer adopting at 17 s: camera path identical to an uninterrupted run |
| Move peaks on beats | 308 extrema of every move's contribution, all on beats: worst 8.3 ms at 60 fps (tolerance 26.7 ms), 3.5 ms at 144 fps (tolerance 16.9 ms) |
| Blending | Head offset speed ≤ 0.86 units/s, accel ≤ 24 units/s², twist ≤ 1.34 rad/s; the largest one-frame step on a move switch is 0.0035 units at 144 fps |
| Squash | Up to 0.10, \|det − 1\| ≤ 6e-7 |
| Stems | Base drift ≤ 6e-7 (planted); top follows the head within 0.016 |
| Sections | Mean head offset: quiet 0.013, build 0.017, drop 0.022, breakdown 0.004 |
| 60 vs 144 fps | Head offsets within 0.004 units at common times |

Regression: every other suite passes, including `test_frame_rate_independence.gd` (all differences 0.0), `test_modern_render.gd` and `test_scene_transitions.gd`.

## Proof

`research/oozic/proof/phase4d/`: `frames/` holds 8 frames across quiet, build, drop and breakdown (Modern High, Director, mock 128 BPM), with `capture.json` recording the shot, section and push per frame. The test reports are in the same folder.

## Gaps

- Only Triple Trance has `director` and `animation` sections. Other Modern profiles fall back to the original camera with no character animation. They need shot distances, subjects and guards per scene (see "Adding" above).
- Tuned and verified on the mock feed (128 BPM synthetic schedule) only. The grammar uses the hub's sections, which on real tracks come from heuristics validated on one real clip (`docs/REACTIVITY_API.md`). On the live path (no lookahead) the drop can land inside the minimum shot. The boost still starts, and the energetic cut follows on the next legal downbeat.
- The hub's `beat_phase` is quantised to the source's 10 ms grid on mock input, so the animator derives its own smooth beat position from `frame.beat_time`. The director records exact downbeat times the same way. The hub itself is unchanged.
- Shots avoid geometry with bounding spheres and boxes (the guard), not with ray casts. The background is excluded by a radius and height bound, not by its deformed surface.
- The recovered heads already bounce about ±0.2 units through DefCenter/DefShape. The Modern moves (0.01–0.1) sit on top of that and are deliberately subtle. Raise `animation.sections.*.amp` for a livelier look.
- The opening shot's start time comes from the hub's 10 ms grid (a few ms of difference between frame rates), which is why 30/144 fps poses match 60 fps to about 0.04 units rather than exactly.
- The Triple Trance 3D text message (`TT`) is part of the scene and is not handled by the director. A close-up can occasionally frame it at the platform edge.
- Visual QA used 2 capture rounds of the 8 proof frames (High quality, 1200×760). Motion was judged from the tests' numbers, not from video.
