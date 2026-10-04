# Engine API (Phase 1b: original-engine parity)

Phase 1b, 2026-10-04. This adds the original visualiser's effect toggles, 3D text, intro screen, Response/Brightness and special-effect presets. It also adds three effect classes (DefSwitch, DefElastic, DefSuperBump). All of it sits behind a small API on `SceneRuntime` (`scene_runtime.gd`). The UI or event bus calls that API, so the window split does not need to know how any feature works.

Evidence comes from static disassembly of the shipped binaries; no original binary was executed. Excerpts are in `research/oozic/disassembly/phase1b-*-evidence.txt`. Each feature below is marked **Confirmed** (instructions read end to end) or **Inferred** (best evidence, labelled in code).

## API for the UI / event bus

All methods are on the `SceneRuntime` node. They are safe to call at any time after `load_scene()`, and none of them restarts the scene.

| Call | Effect |
|---|---|
| `get_style_flags() -> int` | Current effects mask (bits below). |
| `set_style_flags(mask: int)` | Replace the mask (low 10 bits). |
| `set_style_flag(flag: int, on: bool)` | Set or clear one bit. |
| `toggle_style_flag(flag: int) -> bool` | XOR one bit, as the original toggle helper LAVA.exe 0x40e96c does. Returns the new state. |
| `style_flag_state() -> Dictionary` | `{"Texture": true, ...}` for checkboxes. |
| `default_style_flags` (var) | The scene's `Style` mask. Loading a scene resets the mask to it, as LAVA.exe re-reads GetEfxInfo after a load (0x40fe2e). |
| `set_response(value_or_null)` / `get_response()` | Responsivness, the simulation-time multiplier. `null` restores the scene value. |
| `response_from_slider(s)` / `slider_from_response(v)` (static) | The original Response slider mapping, `2^(s*0.02-1)`: 0.5 to 2.0 for s in 0..100. |
| `set_brightness(value_or_null)` / `get_brightness()` | Light ambient multiplier. `null` restores the scene value. |
| `brightness_from_slider(s)` (static) | The original Brightness slider mapping, `s*0.01`. |
| `trigger_effect_preset(index: int) -> Dictionary` | F5–F8: advances special-effect category `index` (0–3) to its next preset and applies it while the scene keeps running. Returns `{category, preset, current, applied, unresolved}`, or `{}` if the scene has no such category. |
| `preset_categories` (var) | `[{name, count, current, presets: [{file, name}]}]` for a menu. |
| `show_intro() -> bool` / `hide_intro()` | Intro screen (N). Returns false if the package has no `intro.ini`. |
| `toggle_text_message() -> bool` | 3D text on/off (M). Returns the new state. |
| `set_text_message(text = null, enabled = null)` | Change the message text and/or visibility. |
| `text_message_enabled() -> bool` | Current 3D text visibility. |
| `current_light_terms() -> Dictionary` | `{diffuse, ambient}` currently submitted for light 0 (debug and tests). |
| `apply_preset_file(file, full_reset := true)` | Existing preset-dropdown call. `full_reset=false` rebinds only the named effects. |

Constants live in `style_flags.gd` (`StyleFlags.TEXTURE`, and so on). Key handling lives in `original_hotkeys.gd`: `OriginalHotkeys.handle(runtime, event) -> String` returns a status line, or `""` if the key is not one of the original keys.

### Wiring (Phase 2, docs/WINDOWS_AND_BUS.md)

- **Keys.** `PlayerBus.handle_key` first offers unmodified non-player keys and Shift+F3/F4 to the visualiser's `scene_key_handler`. That handler is `OriginalHotkeys.handle(runtime, event)`, so the keys work from either window, and the returned text becomes the bus status line. Plain F3 and F4 stay as the debug overlay and FPS-cap keys.
- **Settings → Effects.** A checkbox for each Style bit: Texture, Wire frame, Strobe, Colored lighting, Dynamic coloring, Pause camera, Flat shading and Lights. Wire frame replaces the old debug-draw checkbox. Next to them sit the F5–F8 category buttons, the 3D text toggle and an Intro button. They send the bus commands `set_style_flag`, `trigger_effect_preset`, `toggle_text_message` and `show_intro`.
- **Settings → Scenes.** Response and Brightness are 0–100 sliders. They go through `response_from_slider`/`brightness_from_slider`. "Scene values" sends `null`, which restores the scene header values. Loading a scene restores them too.

## Hotkeys

| Key | Action | Original |
|---|---|---|
| T | Texture (0x01) | T |
| W | Wire frame (0x02) | W |
| S | Strobe (0x04) | S |
| L | Colored lighting (0x08) | L |
| C | Dynamic coloring (0x10) | C |
| P | Pause camera (0x40) | P |
| **Shift+F3** | Flat shading (0x80) | F3. Our F3 is the debug overlay |
| **Shift+F4** | Lights (0x20) | F4. Our F4 is the debug FPS cap |
| M | 3D text on/off | M (WM_COMMAND 0x7da) |
| N | Intro screen | N (WM_COMMAND 0x7d9) |
| F5–F8 | Special-effect category 1–4, next preset | F5–F8 (SetPresetInfo index 0–3) |
| (none) | 0x100 | F11. Our F11 is fullscreen, and no consumer was found |

Ctrl, Alt and Cmd combinations are ignored, which leaves the original player accelerators (Ctrl+P and so on) free. Other letters do nothing (the original beeps).

## Style flags (Style header = effects mask)

**Confirmed.**
- GetEfxInfo (ILava3 vtbl+0x34, 0x10015d10) returns property 0x1c5 (`Style`), and SetEfxInfo (vtbl+0x4c, 0x10017630) writes it back.
- The LAVA.exe key handler 0x40e75c maps keys via the jump table at 0x40e8f4/0x40e934. The toggle helper 0x40e96c XORs the bit and pushes the mask.
- The only engine readers of 0x1c5 are three property-refresh routines:

| Bit | Name | Reader | Rendering effect (ours) |
|---|---|---|---|
| 0x01 | Texture | scene 0x10026440 → +0x30 → renderer vtbl+0x10c(on) at 0x10025bb7 (texturing enable) | Albedo texture removed (StandardMaterial) / `has_texture=false` (legacy shader). Lit colours unchanged. |
| 0x02 | Wire frame | scene → +0x2c → renderer vtbl+0x104 (polygon mode) at 0x10025bfd | Viewport `DEBUG_DRAW_WIREFRAME` on the runtime's own viewport. |
| 0x04 | Strobe | light 0x10019be0 → light+0x40 | See "Strobe" below. |
| 0x08 | Colored lighting | light → light+0x50 | See "Colored lighting" below. |
| 0x10 | Dynamic coloring | scene → +0x34 → draw 0x10025c20 | Every frame, every effect of every object gets setter property 0x82 (DoColor) = 1.0 if set, else 0.0. The flag therefore **overrides** each preset's DoColor for classes that accept it (Cos, Bump, Ripple, Pools, SuperBump). |
| 0x20 | Lights (inferred name) | **no Lava3.dll reader** | Named "Lights" by the Oozic 3 LVC header field order `Tmap Wframe Strobe Clights DynCol Lights Pause Flat TRot EnvMap`, which matches the seven confirmed bits exactly. Implemented best-evidence as lighting on/off (off = unlit vertex/material colour). Set in every recovered scene, so default rendering is unchanged. |
| 0x40 | Pause camera | camera 0x1000187a → +0x60; update returns early | `CameraRuntime.scene_style` (already honoured). |
| 0x80 | Flat shading | scene → +0x38 → renderer vtbl+0xec(!flat) (shade model) at 0x10025bda | Legacy shader: `flat` interpolated lit colour (true GL_FLAT; the provoking vertex may differ from GL's last vertex). StandardMaterial path: de-indexed meshes with face normals (an approximation, because Godot has no flat-shading material switch). |
| 0x100 | TRot (inferred name) | none found | Kept in the mask, no effect. |
| 0x200 | EnvMap (inferred name) | none found | Kept in the mask, no effect. |

**Defaults (Confirmed).** The ASHEX header line 6 is the Style value: Triple Trance and Hydroid have 49 = Texture + Dynamic coloring + 0x20. For LVC scenes the mask is built from the named header fields (Mind's Eye: Tmap 1, Lights 1 = 0x21).

### Strobe (0x04), Confirmed

Light update 0x10019430 runs once per engine update with `dt = ctx.dt × Responsivness`:
- `level = global S`.
- If `0.075/dt <= counter`, the phase flips and the counter resets to 0. The counter then increments by 1.

At 60 updates/s the phase flips every 5 updates (83 ms).

In draw 0x10019600, while the phase is 0 (the constructor starts it at 1):
- Light diffuse and specular are multiplied by `1 - 0.75·S`.
- Light ambient is multiplied by `1 - 0.25·S`.

The flip test counts updates, so it is exact under the fixed 60 Hz tick (`test_engine_api.gd` checks 30 fps against 144 fps).

### Colored lighting (0x08), Confirmed

Each update, if `0.1/dt > counter` the counter increments. Otherwise, if `maxA × S >= 0.9`:
- hue += 60. It wraps only when above 360, so 360 occurs.
- Saturation and intensity become 1.
- The light colour becomes HSI→RGB(hue) (0x10019830, same as `RipplePools.hsi_to_rgb`).
- The counter resets.

Before the first trigger the dynamic colour is the constructor value (1,0,0), which is red. Diffuse and specular use that colour; ambient uses colour × Brightness.

**Deviation:** in the original the hue state and counter are process-global statics. Here they reset with the scene.

### Response and Brightness, Confirmed

- SetSceneInfo (vtbl+0x38, 0x10015da0) sets Brightness (0x1c) = `slider × 0.01` and Responsivness (0x1a2) = `2^(slider × 0.02 − 1)`.
- Responsivness multiplies ctx.dt at 0x10025aa5, so it scales all simulation time: camera, lights, effects, intro timer and text.
- Brightness is light+0x2c, the ambient multiplier in draw 0x10019676.

**Inferred:** the 0..100 slider range.

## 3D text message (M)

**Confirmed:**
- **Header block order.** The ASHEX text block is read by LavaFile in this order: Enable 0x94, Message 0x133, Size 0xdd, Weight 0xe2, Italics 0xf3, Color 0x1e5, Extrusion 0xdc, Font 0xe1 (reader 0x1001b651..0x1001b933). SetTextInfo 0x10017000 writes the same set.
- **Triple Trance values.** Enabled, "Triple Trance", size 1.0, weight 700, italic, colour 255 0 255 255, extrusion 0.2, Arial.
- **Glyphs.** LAVARndr 0x10006fa0 builds a LOGFONT (height −10, weight, italic, DEFAULT_CHARSET, face or "Times") and calls `wglUseFontOutlinesA` with `WGL_FONT_POLYGONS` and the extrusion. The result is extruded polygon glyphs in em units, extruded toward −Z.
- **Layout.** Text draw 0x10027ce0 uses the TextDeform preset fields TextMode, TextRadius, Offset, SizeX/Y/Z and ViewFromInsideText, together with the header Size:
  - **Mode 1 (ring, 30 of 38 presets).** Rotation accumulates per glyph: `Ry(SX·S·advance(prev)·57.3/R + extra)`. Each glyph is then placed with `T(R,0,0)·T(offset)·Scale(S·SXYZ)·Ry(96°)`, or `Ry(−84°)` with the angles negated when viewed from inside.
  - **Mode 2.** Adds `extra = 360·(1 − W·SX·S/(2πR))/n`.
  - **Mode 0.** A straight string with `Rz(90°)`, transcribed literally and not visually verified.
- **Classes.** DefMsgRot is the DefRotate class and DefMsgAlpha is the DefAlpha class (factory branches), so `legacy_effect.gd` and `alpha_center_effects.gd` drive them.

**Inferred:**
- The rotation axis comes from DoX/DoY/DoZ.
- The static RotateX/Y/Z is applied under the animated rotation.
- `TextDeform Parent` follows only the parent's position and rotation.
- Material: diffuse is the text colour, specular is white, shininess is 10, and the ambient slot comes from a renderer default, assumed to be GL's 0.2.
- Godot TextMesh glyph geometry and baseline stand in for the Windows outline glyphs.
- Oozic 3 `Text.ini` `[Data]` field order is `Font;Italic;R;G;B;A;Weight;Size;Extrusion`.

Text is rendered with the fixed-function shader and follows Strobe, Colored lighting, Flat and Lights. It is created for every scene that has a message, whether or not it is enabled at load.

## Intro screen (N)

**Confirmed:**
- Show (0x10011bf6) sets `timer = Time·0.001 + 1.5`.
- Update 0x10012a80 runs per engine update: `timer -= min(dt, 0.1)`, clamped at 0.
- Draw 0x10012ae0 uses alpha 0.85 while `timer >= 1.5`, then `timer·0.5667`, a linear fade over the last 1.5 s.
- `intro.ini` key names are in LavaFile (0x1004a4d0...).

**Inferred:**
- The page is 512×256 (from the `*Loc` rectangles), centred and scaled to fit the window.
- It shows at load when `OnOff=1`.
- Labels use the `TextFontInfo` height.
- Greeting mode shows Title/To/Message/From/Date; artist mode shows Genre/Song/Artist/Album/Link/Email/Comments/YearCopyRight.

## Special-effect presets (F5–F8)

**Confirmed:**
- **Keys.** LAVA.exe sends F5–F8 to SetPresetInfo (0x10017430) with index 0–3.
- **Cycling.** For preset category `index` it reads CurrentPreset (0x66) and NumLavaMacros (0x14d), then writes back `(current + 1) % count`.
- **Categories.** These are the scene's `EffectPresetCategoryInfo <name> <count> <current>` lines, each followed by `count` `EffectPreset <file> <name>` lines. Hydroid has Species. LVT6 has Distortion, Ripple and Morph.

**Ours:**
- The `.lvm` bindings are applied with `apply_preset_file(file, false)`. This rebuilds only the rebound effects; the camera, clock and random stream continue.
- DefSwitch keeps its running state and receives the new NextShape through setter semantics.
- Other rebound effects restart their envelopes.

**Inferred:** the original re-applies preset values through each effect's setter, so it may keep more state.

## Effect classes added

See `docs/EFFECTS_RECOVERED.md`: DefSwitch, DefElastic and DefSuperBump.
