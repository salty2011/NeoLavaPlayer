# Effect classes recovered in Phase 1b

Static disassembly of Lava3.dll (LAVA! 2.5, image base 0x10000000). No original binary was executed. The effect factory is 0x1001be90. All three classes run inside the fixed 60 Hz tick (`docs/FRAME_TIMING.md`) with `dt = tick × Responsivness`. Every per-update counter and random draw therefore happens once per tick, at any render rate.

| Class | Packages | Port | Test | Notes | Status |
|---|---|---|---|---|---|
| DefSwitch | LVT6 (2.5 and 3.0) | `switch_effect.gd` | `test_engine_api.gd` (switch_* and lvt6_*) | below; `research/oozic/disassembly/phase1b-defswitch-evidence.txt` | Confirmed, complete |
| DefElastic | Aqua Boogie, Cyber Diva, Keoki EFX, Polyesterday | `elastic_effect.gd` | `test_elastic_effect.gd` | `research/oozic/disassembly/elastic-recovery-notes.md` | Confirmed update/setter/ctor |
| DefSuperBump | LVT6–8, Lost Road Rave, Polyesterday, Keoki EFX, Mind's Eye | `superbump_deformation.gd` | `test_superbump_deformation.gd` | `research/oozic/disassembly/superbump-recovery-notes.md` | Confirmed effect maths; object texture-mapping fields inferred |

## DefSwitch

- **Layout.** Size 0x38, ctor 0x1000d360, vtable 0x100332fc: setter 0x1000d3a0, update 0x1000d450.
- **Setter.**
  - DecayMin (0x6a) and DecayMax (0x69) are the cross-fade duration range, with ctor values 0.5/1.0.
  - DoSwitch (0x87) requests a switch to the next shape.
  - NextShape (0x145) is applied if it is ≥ 0, no switch is running, and it is not the current shape. It sets next to that shape and requests a switch.
- **Update.** It reads no audio. It needs the object's morph-weight array (object+0x40) with at least 2 targets.
  - **Requested:** wrap next to 0 if it is ≥ count, set elapsed = 0, draw duration = RandRange(DecayMin, DecayMax) (one shared `rand()`), and start switching.
  - **Switching:** once elapsed ≥ duration, set w[current] = 0, w[next] = 1, current = next, next = current + 1, and stop switching. Otherwise elapsed += dt, k = (1 + cos(π·elapsed/duration))/2, w[current] = k, w[next] = 1 − k. The finish lands one update past the duration, exactly as in the original.
- **Runtime.**
  - The weighted target mix (positions and renormalised normals) becomes the source surface, which the object's other deformers (SuperBump on LVT6's Mirror) then displace.
  - Special-effect presets (LVT6 "Morph": sheet/sphere/torus/cylinder = NextShape 0..3) reach the running state through setter semantics.
  - **Deviation:** the switch is evaluated before the object's other effects, so its single `rand()` per switch can come earlier in the shared stream than in the original's effect order.

## DefElastic

A persistent 4×4 matrix effect. Each element has its own clamp range, speed range and velocity.
- While the audio envelope is active, elements move at `AmpScale·E·S·dt·V`. The diagonal scale terms move multiplicatively, and an element bounces off its clamp range.
- Velocities are re-drawn on a trigger, and on an interrupt at least 0.1 s after the last draw.
- With `DoRestore`, the matrix relaxes to identity with half-life `RestoreDecay` (`0.5^(dt/RestoreDecay)`, independent of tick size).
- The runtime composes it like DefScale/DefShear: `effect_transform = MatrixEffects.compose(effect_transform, elastic.update(dt, a, s))`. The original MatMul argument order matches DefShear.

**Gaps:**
- x87/float32 rounding is not emulated.
- The runtime passes the global S, where the original reads the bound band's S.
- Two original setter quirks are reproduced: there is no ZY case, and the duplicated XXVMin name means XT's VMin is unreachable.

## DefSuperBump

DefBump extended with moving bump centres (Cent*), sigma drift, inner/outer twist (Bump*Theta), wave and flow terms, two texture modes, a heightmap and a mask map. Displacement is along the source normal × DefScale, as in DefBump.
- **Layout.** Ctor 0x10007360, vtable 0x10033298: dtor, setter 0x10007db0, update 0x100092c0..0x1000b1d7.
- **Instances.** Per instance: envelope, centre motion scaled by env·S·dt with wrap/bounce/kill, sigma drift, twist and colour interpolation.
- **Events.** Spawn and retrigger follow DefBump, and the random draw order is recovered.
- **Runtime wiring.**
  - Shared CRT stream via `random_source`. `heightmap<N>` / `maskmap<N>` images are loaded from the package for `LoadHeightMap` / `LoadMaskMap`.
  - The object's texture repeat/centre is passed as `texture_mapping`.
  - Dynamic Coloring forces its DoColor.
  - Fixed-tick catch-up uses the state-only `advance()`, whose state and random draws are proven identical to `deform()` over 240 frames.

**Gaps (inferred):**
- The names and meaning of the object texture-mapping fields (+0x7c..+0xa4).
- TexReset's object-side effect.
- Image decoder row order (bottom-up is assumed).
- The object clearing displacement each frame.
- `advance()` does not move the persistent UV state, so UV drift during catch-up ticks is skipped.

## Not done in Phase 1b

Oozic 3 only (OZ3.dll factory 0x67031d3f): DefHalo (0x104), DefFadeOut (0x28), DefSuckOut (0x50), DefMorphOpen (0x28) and DefTexSway (0xbc). They are used only by AK1200 and Keoki EFX pods (Halo/FadeOut) or not at all in the recovered scenes. DefFlyOut is a string only, not in the factory. They are still reported as unsupported in Recovery details.
