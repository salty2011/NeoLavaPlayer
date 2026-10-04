# Scene transitions, cycle modes and pins

Phase 4e, 2026-10-04. Code: `scene_transition.gd`, `scene_transition.gdshader`, `scene_director.gd`, `visualiser.gd` (hand-over). Tests: `test_scene_transitions.gd`. Proof frames: `research/oozic/proof/phase4e/` (Triple Trance to Dancing Well, `tools/capture_transition.gd`).

## What the original did

- LAVA.exe multi-scene cycling hard-switched on a timer (Lava3.crl DLG 136, `SetTimer(id 10, Time*1000)`; intervals 30 s to 1 h, random or alphabetical). No blend, no beat awareness (`research/oozic/original-player-capability-audit.md`).
- Oozic 3 added per-scene `Lava.script` commands such as `TFX : run peel Stretchy_Peel` and `*.tfx`/`*.tfp` transition files (explode, paintbrush, peel, fade, iris, alphaburn). Those are scene-internal effects between a scene and its own intro, not a player setting, and we have not decoded them.

So the player keeps the original behaviour as **Cut (original)** and adds three styles that follow the Oozic 3 vocabulary (fade, iris) plus dip to black. Default for a new install is Crossfade, 2 s.

## How a transition works

```
window (root viewport)  -- old scene keeps running, drawn as always
stage  SubViewport      -- own World3D, SceneRuntime + ModernLayer for the next scene
overlay CanvasLayer 50  -- ColorRect + shader: alpha-blends the stage over the window
```

1. `PlayerBus.scene_changed(index)` reaches the Visualiser. With style Cut (or nothing loaded yet, or Inspection mode) it hard-loads as before.
2. Otherwise `SceneTransition.prepare()` builds the next scene offscreen, with the same render mode (Classic or Modern, from the settings) and 3D buffer settings as the window, and renders it once so GPU uploads and pipelines are warm.
3. `start()` blends over the configured duration. Both runtimes advance every frame (the incoming one starts at scene time 0; with mock input its beat phase is continuous with the old scene, with real audio it shares the old scene's analysis, padded or cut to its band count). The shader only needs the incoming texture: the old scene is whatever the window already shows.
4. At full cover the Visualiser adopts the stage's runtime into the window (`remove_child`, `add_child`, Modern layer re-attached through the same `apply_render_mode()` path as F9), frees the old runtime, reconfigures the audio bands and republishes scene info. The frozen stage frame keeps covering the window for 2 rendered frames, then the stage and overlay are freed. Nothing flashes at the hand-over (measured: covered vs window frame difference 0.0000 Classic, 0.005 Modern).

Styles (`transition` key): `crossfade`, `dip` (to black over the first half, up from black over the second), `iris` (radial reveal from the centre, soft edge), `cut`. Durations: 0.5, 1, 2, 3, 5 s.

### Edge cases

| Case | Behaviour |
|---|---|
| New scene change mid-blend | At 50 % or more the running blend completes at once, below that it is dropped, then the new blend starts from the window's scene. The last request always wins. |
| Window resize or fullscreen mid-blend | The stage follows the window size (`size_changed`), and the shader aspect updates. |
| Scene fails to load | The stage is discarded and the normal hard load runs, which reports the error. |
| Pre-roll cancelled (`scene_prepare(-1)`) | A prepared stage that never started is freed. |
| Track starts while a scene change is due | The track change decides (pin, by-track), and cancels the pending change. |

### Hitch (Apple M4 Pro, Metal, Forward+, 1200x760, shaders cached)

| Step | Blocks the main thread |
|---|---|
| Prepare Dancing Well, Classic | about 26 ms |
| Prepare Triple Trance, Modern | about 92 ms |
| First blend frames | 18 to 20 ms (same as steady state) |

A cold shader cache costs one frame of about 0.5 s the very first time a Modern material set is drawn (seen once, not repeated). Musical cycling builds the next scene during the wait for the boundary (`scene_prepare`), so the load never lands on the beat itself. Loading is synchronous: node construction cannot be threaded in Godot.

## Cycle modes and timing (`scene_director.gd`)

`PlayerBus.cycling` gained `mode`, `musical`, `transition`, `transition_seconds`. `per_track` stays as an alias of `mode == "track"`, and `set_cycling({"per_track": true})` still works. The old "also change on track change" checkbox became a mode, so by-track no longer runs alongside the timer.

| Mode | Changes scene |
|---|---|
| `time` | When the interval (30 s to 1 h) is up: the original behaviour. |
| `track` | On each new track, once. Ignored while the transport is stopped (a restored playlist announces its track at launch). |
| `section` | At a build, drop or breakdown boundary (`hub.section_changed`), at most once per 60 s since the last change. |

All modes need `enabled`. Pins and manual picks work regardless.

### Musical timing (`musical`, default on)

- **Automatic (time mode).** When due, the director picks the target, announces it with `scene_prepare(index)` so the visualiser can build it, and waits for a boundary from `ReactivityService.frame`: a downbeat or phrase start; inside a drop only a phrase start; the frame a drop begins (the new scene arrives with the drop); not within one bar before a drop (it waits for the drop). At most `MAX_WAIT` = 10 s, then it goes anyway. With no usable tempo (BPM under 40 or confidence under 0.3) it switches at once.
- **Manual (user picks, Next/Previous).** If the next beat is under 0.5 s away, the change waits for it (still prepared early), otherwise it is immediate.
- **Track and section changes** are boundaries already, so they switch at once.

`SceneDirector.boundary_ok()` and `musical_ready()` are static and pure, for tests.

## Pins

`pin_scene` pins the current scene to the playing track, `unpin_scene` removes it (Settings > Scenes, and the scene menu on the player). `PlayerBus.scene_pins` maps track path to scene folder. `AudioService` writes it into `user://playlist.json` as `scene_pins` and restores it with the playlist. When a pinned track starts, its scene is selected whatever the cycle mode, so a pin wins over by-track and time cycling.

## Settings

`[scenes]` in `user://settings.cfg`: `cycle_mode`, `cycle_musical`, `transition_style`, `transition_seconds` (plus the existing `cycle_*`). Settings > Scenes has Cycle mode, Musical timing, Transition style and duration, and Pin/Unpin. Non-persistent directors (tests) default to Cut with musical timing off, so existing tests keep their immediate, synchronous switches.

## Gaps

- The incoming scene starts at scene time 0, so camera and effect state begin fresh. It is not aligned to the track's musical position beyond mock beat phase.
- Real audio feeds both runtimes the same analysis, so a scene with a different band count gets padded or truncated bands during the blend.
- No Oozic 3 TFX styles (peel, explode, paintbrush, alphaburn).
- Dip and iris use the fixed shader shapes above, with no per-style tuning in the UI.
