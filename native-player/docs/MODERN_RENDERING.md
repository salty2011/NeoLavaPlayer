# Modern rendering (Phase 4c)

Brief: "what Lava would look like if Creative had kept developing it for 25 years". Keep each scene's identity and charm, upgrade the fidelity and not the soul, and keep a Classic mode that renders exactly as the original did.

Showcase scene: Triple Trance. Since Phase 4f every catalog scene (all 29 entries) has a Modern profile; see the coverage table below.

## Renderer decision: Forward+ for everything, Classic kept byte-faithful

SDFGI, SSIL, SSR, SSAO, volumetric fog and HDR glow need Forward+. The project used `gl_compatibility`, and Classic colour fidelity depended on it. The project now runs `forward_plus` (Metal on macOS), and Classic was made explicitly colour-correct for it:

| Classic path | What changed | Why |
|---|---|---|
| `legacy_vertex_lighting.gdshader` (Triple Trance, 3D text) | Under Forward+ the raw GL RGB is pre-decoded (`classic_output()`, exact piecewise sRGB, selected with `CURRENT_RENDERER`). Compatibility still writes the raw value | Forward+ renders linear HDR and encodes sRGB on output, so displayed byte = original raw byte |
| Classic Environment (`scene_runtime._build_environment`) | Explicit: linear tonemap, exposure 1, white 1, no glow, adjustments, fog or reflections | The contract the shader relies on |
| StandardMaterial path (other scenes) | `vertex_color_is_srgb = true` under Forward+ | Compatibility linearises the whole albedo product (colour × texture × vertex colour) in its scene shader, so it effectively treats vertex colours as sRGB |

Measured with `tools/render_sweep.gd` (all 29 catalog entries, mock feed at 128 BPM, 10 s of fixed 60 Hz ticks, 1200×760) and `tools/image_diff.py`. Compatibility reference vs Forward+, in 8-bit units. Full table: `research/oozic/proof/phase4c/classic-diff.json`.

| Scene | mean abs | p95 (max channel) | max |
|---|---|---|---|
| Triple Trance | 1.20 | 6 | 7 |
| Hydroid | 1.74 | 3 | 10 |
| LVT1 / LVT2 / LVT3 / LVT4 | 1.07 / 1.62 / 1.89 / 1.30 | 2 / 6 / 8 / 4 | 77 / 22 / 26 / 17 |
| LVT5 / LVT6 / LVT7 | 0.61 / 0.23 / 0.18 | 5 / 3 / 1 | 23 / 5 / 10 |
| Aqua Boogie, Cyber Diva, Lost Road Rave, Wizard, Mind's Eye | 0.8–2.6 | 4–8 | (edge pixels) |
| AK1200, LVT8, Music Metropolis | 3.2–3.6 | 20–49 | 66–89 |
| Keoki EFX, KaleidaTribe, Polyesterday | 8.5 / 10.4 / 17.6 | 33 / 32 / 69 | 204 / 48 / 89 |

- **Triple Trance under Forward+ is the more exact of the two.** Compatibility's scene shader uses approximate sRGB conversions. Their round trip darkened dark raw values: 10/255 came out at about 4/255, and 29/255 at about 26.6/255. That is the whole 1.2 mean difference: Forward+ is never darker than Compatibility by more than 1, and up to 7 brighter in dark areas. `test_legacy_lighting.gd` keeps every numeric expectation and adds a dark-value check (10/255, 29/255, 0.04) that Forward+ passes and Compatibility would fail.
- **The residual differences come from alpha layers.** Scenes with stacked transparent layers (DefAlpha shells and veils: Keoki EFX, Polyesterday, KaleidaTribe, partly LVT8 and AK1200) blend in linear light under Forward+, while Compatibility and the original 8-bit GL framebuffer blend in display space. Translucent overlaps therefore come out somewhat brighter. Fixing this would need display-space blending, which Forward+ does not offer. These scenes were never verified against original footage; recorded as a gap.
- Ruled out with a probe: Forward+ and Compatibility light a StandardMaterial identically (ambient, omni at several distances and angles, specular). The non-alpha differences were the vertex colours alone.
- Frame time: Classic render cost is small in both renderers. Forward+ (Vulkan timestamps) measures 0.69 ms GPU for Triple Trance. The Classic simulation (about 8 ms CPU per frame with geometry rebuilds) is unchanged. Metal under Forward+ keeps the window on the display's 120 Hz cadence even with vsync off, so wall-clock frame times stop at 8.33 ms.

No fallback (Compatibility default plus a Forward+ restart for Modern) was needed. If it is ever needed, `--rendering-method gl_compatibility` still renders Classic correctly, because the shader branches on `CURRENT_RENDERER` and the vertex colour flag follows the running renderer. Modern needs Forward+.

## Architecture

```
visualiser.gd ──load_scene──> SceneRuntime (simulation + Classic look, unchanged)
      │                             ▲ reads only: objects, camera, data, style flags, light terms
      └─ ModernLayer (modern/modern_layer.gd)  attach(runtime) / detach() / update(delta)
            ├ ModernProfiles   modern/profiles/*.json + modern_assets/manifest.json (derived maps)
            ├ ModernQuality    Low/Medium/High/Ultra rows + viewport/RenderingServer knobs
            ├ ModernEnvironment Environment + CameraAttributes from profile × quality
            ├ modern_surface.gdshader  PBR surface fed by the Classic colour inputs
            └ ModernEffects    motes / drop bursts / trails / impact lens pass (modern_post.gdshader)
ReactivityService.mapper ── channels ──> ModernLayer.update (light, fog, emission, glow, exposure)
```

- **The simulation is untouched.** The layer never writes simulation state. Geometry, deformers, texture effect UVs, event (HSI) colours, the camera and every random draw stay in `SceneRuntime`, which keeps running exactly as in Classic. `test_modern_render.gd` runs Triple Trance three ways: Classic only, then with the layer attached, detached and re-attached mid-run. Camera, transforms, vertices and tick count come out identical.
- **What attach swaps:** each object's `material_override` (saved), `cast_shadow` and `gi_mode`; `WorldEnvironment.environment` (saved); the camera's `attributes` (DoF); the Classic omni lights' `light_cull_mask` (set to 0, saved; the runtime keeps animating them for Strobe and Coloured Lighting); and the viewport MSAA/TAA/FXAA, scaling, anisotropy and shadow atlas (saved). Attach also adds its own key, fill and rim lights and the effects nodes. `detach()` restores all of it, which the test verifies.
- **Inputs mirrored every frame:** `entry.material.albedo_color` (event colours, DefAlpha), the TEXTURE, LIGHTS and FLAT_SHADING style flags, the classic light-0 colour after Brightness, Strobe and Coloured Lighting (`runtime.current_light_terms()`), and the head node positions for the particles.
- Inspection mode (the 3D object grid) always renders Classic.

### Switching

| Where | How |
|---|---|
| Key | **F9** toggles the global mode (and clears this scene's override). **Shift+F9** toggles only the current scene (per-scene override) |
| Bus | `toggle_render_mode {scope: "global"\|"scene"}`, `set_render_mode {mode: "classic"\|"modern"\|"default", scope}`, `set_modern_quality {quality}`, `set_modern_effects {particles?, trails?, dof?, post?}` |
| Bus state | `PlayerBus.render` + `render_changed()`: `{mode, effective, scene_override, modern_available, modern_active, quality, effects}` |
| Settings window | New **Rendering** tab: mode, this-scene override, quality, effect toggles (all bus commands) |
| Saved | `user://settings.cfg` `[render]` mode, quality, `effect_*`; `[render_scenes]` `"<set>/<scene>" = "classic"\|"modern"` |
| Overlay | F3 shows `render: Modern (High)` / `Classic` |

Default mode is **Modern**. Scenes with no profile show Classic, and the status line says so.

### Quality presets (`modern/modern_quality.gd`)

| | Low | Medium | High | Ultra |
|---|---|---|---|---|
| GI | ambient only | ambient only | SSIL | SDFGI + SSIL |
| Key shadows | off | 2048, hard | 4096, soft (PCSS light size) | 8192, soft, quality 5 |
| SSAO | off | on (q1) | on (q2) | on (q3) |
| SSR | off | off | 48 steps | 96 steps |
| Fog | depth fog | volumetric 64×64×48 | volumetric 96×96×64 | volumetric 160×160×96 |
| Glow | on | on | on, bicubic | on, bicubic |
| AA / scaling | FXAA, FSR 1 at 0.77 | MSAA 2× | MSAA 4× | MSAA 4× + TAA |
| Particles / trails / DoF | 40 % / off / off | 70 % / on / off | 100 % / on / on | 100 % / on / on |

GI choice: the scene's geometry deforms every tick, and VoxelGI needs a bake of static geometry, so it was ruled out. SSIL is screen space and fully dynamic, which fits deforming meshes; it is the High setting. Ultra adds SDFGI with only the enclosing background marked `gi_static` (`"gi_static": true` in the profile). SDFGI picks up the big blue/purple surround's bounce light from its current pose. The background's deformation is small relative to its size, so the staleness is not visible. The heads and platform stay dynamic receivers.

## Profile format (`modern/profiles/<scene>.json`)

```jsonc
{
  "name": "Triple Trance",
  "folders": ["lava25/Triple Trance"],          // "<set>/<scene>" folder keys this profile applies to
  "environment": {                               // modern_environment.gd
    "ambient_color": [r,g,b], "ambient_energy": 0.38,
    "tonemap": "filmic"|"aces"|"agx"|"linear", "exposure": 1.0, "white": 6.0,
    "adjust_brightness"/"adjust_contrast"/"adjust_saturation": 1.0,   // per-scene grade
    "glow_intensity", "glow_strength", "glow_bloom", "glow_hdr_threshold", "glow_levels": [7],
    "fog_color", "fog_density",                                       // Low (depth fog)
    "volumetric_fog_density", "volumetric_fog_albedo", "volumetric_fog_emission",
    "volumetric_fog_anisotropy", "volumetric_fog_length",
    "ssao_radius", "ssao_intensity", "ssil_intensity", "sdfgi_cascades", "sdfgi_min_cell", "sdfgi_energy"
  },
  "lights": {
    "key":  {"from_scene_light": 0, "energy", "range", "attenuation", "size", "shadow", "specular", "volumetric"},
    "fill": {"color", "energy", "direction": [x,y,z]},
    "rim":  {"color", "energy", "camera_relative": [x,y,z]}           // kept behind the subject as the camera orbits
  },
  "materials": {
    "default": {...},
    "objects": {"<object name>": {                                    // names from the scene's lava.ashex
      "roughness_scale", "roughness_bias", "normal_strength", "specular", "clearcoat", "clearcoat_gloss",
      "albedo_gain", "saturation", "emission_base", "emission_music", "rim_strength", "rim_color",
      "ao", "shadows": bool, "gi_static": bool, "drift": [u,v]        // modern-only UV drift (background motion)
    }}
  },
  "reactions": {                                                       // multipliers on ReactivityService channels
    "key_energy_swell", "key_energy_pulse", "key_hue_accent", "fog_calm", "fog_anticipation",
    "emission_pulse", "emission_accent", "glow_impact", "exposure_impact", "background_drift_swell", "rim_swell"
  },
  "effects": {
    "particles": {"emitters": [names], "colors": {name: [r,g,b]}, "radius", "amount", "burst"},
    "trails": {"emitters", "amount", "lifetime"},
    "dof": {"far_distance", "far_transition", "amount"},
    "post": {"chromatic", "motion_blur"}
  },
  "extends": "<template>" | ["<template>", ...],                      // Phase 4f, see Templates
  "atmosphere": {"fog_volumes": [...], "particles": [...]}              // Phase 4f, see Atmosphere
}
```

Phase 4f added these keys (all optional):

| Where | Key | Meaning |
|---|---|---|
| environment | `sky` | Procedural sky (`modern_sky.gdshader`): `sky_top`, `sky_horizon`, `ground_color`, `sun_dir`, `sun_color`, `sun_energy`, `cloud_cover`, `cloud_scale`, `cloud_speed [u,v]`, `haze`. Becomes background, ambient and reflection source |
| environment | `fog_height`, `fog_height_density`, `fog_aerial_perspective`, `fog_sun_scatter` | Depth-fog extras (Low) |
| lights.key | `type: "directional"`, `direction`, `shadow_distance` | Key as a sun (colour and energy still follow the original light 0 terms) |
| materials.objects.* | `hidden` | Do not draw this Classic object in Modern (e.g. a sky sphere the procedural sky replaces) |
| | `unlit` | Self-lit (flat colour plus emission, no key/fill/specular); for backdrops and screens |
| | `translucent`, `blend: "mix"\|"add"\|"premul"`, `alpha_gain`, `priority` | Transparency (below). `blend` other than `mix` is Modern-only |
| | `tint_to [r,g,b]`, `tint_amount` | Pull the Classic event colour toward a palette colour (display space) |
| | `metallic`, `emissive_luma`, `emissive_luma_curve` | Metal; emission from the texture's own brightness (windows, LEDs, lane markings) |
| | `wave_amp/freq/speed` | Breeze: travelling UV warp (flowers) |
| | `glint_normal/scale/speed/strength/threshold/color` | Animated water micro-normals and sparkles |
| | `procedural: {mode, a, b, c, scale, speed}`, `procedural_force` | Procedural albedo (`plasma`, `planet`, `rock`, `terrain`, `sun`) for a texture the package never shipped; `procedural_force` replaces a shipped one |
| reactions | `sun_swell`, `sun_impact`, `cloud_speed_swell` | Sky reactivity |

## Transparency (Phase 4f)

Classic switches an object's StandardMaterial to alpha blending when its material alpha is below 1, or when a DefAlpha effect is running (`scene_runtime.gd`). The Modern surface path mirrors that decision at attach time: `modern_surface_variants.gd` builds a *translucent variant* of the PBR shader (compile-time, because a shader that writes `ALPHA` sorts into the transparent pass) with `ALPHA = material_diffuse.a x vertex colour.a x alpha_gain`. `material_diffuse` already carries the live DefAlpha/event colour every frame, and DefAlpha writes the vertex alpha, so the same inputs drive both paths. Variants are cached per (cull, translucent, blend). Opaque objects are untouched (Triple Trance: the `--effects=none` High sweep at 8 s and 26 s is pixel-identical before and after, 0.000 mean diff).

- Classic blends `mix`; a profile may choose `add` (Music Metropolis search-light cones: the Classic scene draws them alpha-mixed) or `premul` for Modern-only looks.
- `alpha_gain` compensates the linear-light brightness of stacked layers (below): KaleidaTribe sheets and Polyesterday/Keoki shells use 0.85 to 0.9. `priority` orders sibling layers.
- Lit translucent surfaces (the LVT8 glass and Cyber Diva face panes) use the full PBR shader, so they pick up clearcoat and rim.

### Classic translucency under Forward+ (investigated, not fixed)

Stacked translucent layers come out brighter than under Compatibility (`classic-diff.json`: Polyesterday 17.6, KaleidaTribe 10.4, Keoki EFX 8.5 mean). The cause is that Forward+ blends in linear light while Compatibility (and the original 8-bit GL framebuffer) blended display-space values. A fixed-function blend cannot reproduce that: matching `out = a*S + (1-a)*D` in gamma space needs a different effective alpha depending on S and D (for D = 0 it is `a^2.2`, for S = 0 it is `1-(1-a)^2.2`), so no single alpha remap works, and a shader that reads the destination (`hint_screen_texture`) cannot see other transparent layers in the same pass, so stacked layers would still be wrong. Display-space blending does not exist in Forward+. Classic is left as measured and documented; the Modern profiles compensate with `alpha_gain`.

## Templates

`modern/profiles/templates/<name>.json` hold shared looks; a profile (or another template) lists `"extends": "<name>"` and overrides what differs. Merge is recursive for dictionaries and replacing for arrays and scalars (`ModernProfiles.resolve`). A profile can also extend another *profile* by file name (`lvt3.json` extends `triple_trance`, so LVT3, the same scene under its template name, inherits Triple Trance's whole look including the director and animation blocks).

| Template | Look | Used by |
|---|---|---|
| `abstract_space` | Self-lit textured backdrop, lit subjects, soft key + cool fill + camera-relative rim, light haze, bloom | base of the others, Hydroid, LVT1, LVT4, Lost Road Rave, Mind's Eye, Wizard base |
| `outdoor_sky` | Procedural sky and sun, sky-lit ambient and reflections, directional sun with soft shadows, aerial fog, pollen | LVT2, LVT6, LVT7 |
| `underwater` | Teal ambient, dense volumetric haze (light shafts), bubbles | Aqua Boogie, LVT5 |
| `techno_club` | Dark rooms, neon bloom, glossy floors (SSR), texture-luminance emission, magenta/cyan haze | Cyber Diva, Music Metropolis, Wizard, AK1200 |
| `veils` | Unlit translucent sheets and shells through the transparent variant, bloom on overlaps | KaleidaTribe, Polyesterday, Keoki EFX |

## Atmosphere (`modern/modern_atmosphere.gd`)

Display-only scene air, driven by channels: the sky's sun and cloud drift (`cloud_speed`, `sun_swell`, `sun_impact`), low height-limited fog volumes (Medium and above) that thicken with `anticipation`, and ambient GPU particles (pollen, bubbles, dust, embers, spores) whose rate follows `sparkle`/`pulse`/`impact`. Particle counts scale with the quality preset and the Settings particles toggle.

Textures are not listed. Each object's Classic texture is resolved as Classic does it, and `modern_assets/manifest.json` maps it to the derived `albedo_4x`/`normal`/`roughness`/`height` maps. Those are imported without mipmaps, so the layer builds a mipmapped copy once per file. An object with no derived maps keeps its original texture through the PBR shader.

## Adding a Modern profile to another scene

1. Copy `modern/profiles/triple_trance.json` to `modern/profiles/<scene>.json`. Set `folders` to `["<set>/<scene>"]`, e.g. `"lava25/Hydroid"`, and the object names in `materials.objects` and `effects.*.emitters`. Names come from the scene's objects; the Inspect tool or `SceneData.read_scene` lists them.
2. Start from neutral materials: `default` only. Then give each object a group look: glossy (clearcoat 0.5–1.0, `clearcoat_gloss` ≤ 0.75 so highlights stay broad), matte (roughness), or emissive surround (`emission_base`, `shadows: false`, `gi_static: true`).
3. Keep the Classic palette recognisable. Compare with `tools/render_sweep.gd --mode=classic` at the same `--times` and tune `albedo_gain`, `saturation` and the environment grade, not the hues.
4. Check Low and Ultra, quiet and drop: `--mode=modern --quality=low|ultra --times=8,26,30.4`. The drop (30 s on the default mock schedule) is where `impact` peaks.
5. Add the scene to `test_modern_render.gd` if it needs special handling (e.g. alpha objects). The simulation identity check is generic.

Profiles only describe looks. Transparent objects are now supported (see Transparency) and need no special handling. A scene whose textures never shipped (LVT1, LVT4, LVT6, LVT7, LVT8) gets `procedural` albedo in its profile; the original objects and effects are unchanged.

Faster route since Phase 4f: start a new profile with `"extends": "<template>"` and list only the object roles and palette overrides.

Capture helper: `tools/render_sweep.gd --paths=lava25/LVT2 --cam=x,y,z,lx,ly,lz[,fov]` renders one scene (optionally from a fixed camera) and `tools/scene_survey.gd` dumps every scene's objects, textures, alpha, effects and lights as JSON. Anything that changes behaviour belongs in a module under `modern/`, and must never write runtime state. Examples: transparent objects (the PBR shader is opaque) and objects with Hydra or morph meshes (these already work, since meshes are read live).

## Triple Trance Modern

- **Materials:** derived 4× albedo with normal and roughness maps, mapped on the original (animated) UVs, so TexScroll and TexWave move the new detail exactly as before. Event HSI colours and vertex DoColor multiply as in Classic, in display space, then are linearised. The heads (blue Mushroom torus, red Sphere, magenta SignBoard) keep their glossy personality: GGX plus clearcoat, a broad highlight (`clearcoat_gloss` 0.72 ≈ the original shininess-38 Blinn lobe), a soft fresnel rim in each head's colour, and emission on pulse/accent. The marbled platform is bright: albedo gain 2.4, desaturated toward the original lavender-silver, low clearcoat, a little emissive fill (the original's 0.75 ambient). The ooze background stays blue/purple: emissive base, stronger normal relief, modern-only UV drift.
- **Normals without tangents:** the runtime rebuilds meshes from the deformers every tick and they carry no tangents. The shader builds a cotangent frame from screen derivatives, so normal maps follow the deformation at no CPU cost.
- **Lighting:** the original light 0 at (0, 2, 0) is the key. Its colour follows Classic Brightness, Strobe and Coloured Lighting. It uses constant attenuation like the original: an inverse-square key made a hot spot on the platform near the light. Soft PCSS shadows from heads and stems only; the platform and background receive but do not cast. Cool blue fill, magenta rim that stays behind the subject as the camera orbits. SSIL (High) or SDFGI (Ultra), SSAO, SSR on the platform and heads, volumetric fog with the key scattering into it, Filmic tonemap, glow above an HDR threshold of 1.6, grade: contrast 1.04, saturation 1.12.
  - Tonemapper: AgX washed the saturated heads to pastel and ACES pushed the blue platform to purple. Filmic kept the palette.
- **Music** (ReactivityService channels, × effects intensity; never raw bands):

  | Channel | Drives |
  |---|---|
  | swell | Key energy (+60 %), rim (+60 %), background drift speed |
  | pulse | Key energy (+35 %), head and stem emission, mote rate |
  | accent | Emission, slight key hue lift |
  | calm, anticipation | Volumetric or depth fog density (thickens into a drop) |
  | impact (drops only) | Glow (+60 %) and exposure (+12 %), particle bursts, the lens pass (chromatic aberration 0.003, radial blur 0.012); fog thins on the hit |
  | sparkle | Mote rate |

- **Effects** (Settings → Rendering, each toggleable): GPU motes around the three heads, in each head's colour, with world-space drift; one-shot bursts on `impact_fired`; light trails while a head moves (rate from its smoothed speed); far DoF (High/Ultra, ready for the director's close-ups); the impact-only lens pass. That pass is a full-screen quad hidden at strength 0, and is drawn before the particles so they are not erased.
- **Frame-rate independence:** every animated value is either a reaction channel (time-based envelopes) or a delta integrator (`exp(-dt/τ)` smoothing, `drift += v·dt`). GPU particles run on their own clock.

## Proof

`research/oozic/proof/phase4c/`:

- `classic-compat/`, `classic-forward/`, `classic-diff.json`: the renderer migration sweep and diff.
- `tripletrance/{classic,modern-low,modern-high,modern-ultra}/00-Triple Trance-t08|t26|t30.png`: quiet (8 s), build (26 s) and just after the drop (30.4 s) on the default mock schedule (quiet 8 bars, build 8, drop 16, breakdown 8 at 128 BPM). The same simulation state appears in every folder.
- `perf.json`: frame times per preset (see below).

### Frame time per preset (Triple Trance, build section, 1200×760, M4 Pro)

| | Classic | Low | Medium | High | Ultra |
|---|---|---|---|---|---|
| GPU ms (Vulkan timestamps) | 0.69 | 2.46 | 4.61 | 6.40 | 8.46 |
| Frame ms, wall, scene running | 9.37 | 9.36 | 9.38 | 9.76 | 10.15 |

The wall frame time is dominated by the Classic simulation's per-frame geometry rebuild (about 8 ms CPU), which is the same in both modes. Presentation is capped at the display's 120 Hz under Forward+. The GPU cost scales with pixel count. At 4K fullscreen (about 9× the pixels), High and Ultra will exceed a 60 Hz budget on this machine and Low or Medium are the right presets; Low renders at 0.77 scale with FSR 1. The F3 overlay shows live FPS and frame ms.

## Coverage (Phase 4f)

All 29 catalog entries have a profile (oozic30 copies share the lava25 profile via `folders`). Proof captures: `research/oozic/proof/phase4f/<scene>/{classic,modern-low,modern-high}.png` (1200x760, mock feed at 128 BPM, 14 s; LVT2 from a fixed three-quarter camera at 45 s).

| Scene | Profile | Notes |
|---|---|---|
| Triple Trance | `triple_trance.json` | Showcase (Phase 4c, unchanged) |
| LVT3 (lava25, oozic30) | `lvt3.json` | Extends `triple_trance` (identical scene) |
| Hydroid | `hydroid.json` (`abstract_space`) | Wet clearcoat hydra, warm sunset fill, rose haze, spores, beat glow |
| LVT2 Dancing Well (both) | `lvt2_dancing_well.json` (`outdoor_sky`) | Procedural sunny sky replaces the sky sphere, wet stone tub, glinting water, breeze on flowers, low ground mist, pollen and spray. Reconstructed textures keep their roles |
| LVT1 Solar Swirl (both) | `lvt1_solar_swirl.json` | Procedural sun, Earth, Moon (textures never shipped); key inside the sun; orbit trails |
| LVT4 Hydra Hypnosis (both) | `lvt4_hydra_hypnosis.json` | Procedural magenta plasma backdrop and rock; glossy yellow hydra |
| LVT5 Cyber Circus (both) | `lvt5_cyber_circus.json` (`underwater`) | Neon plastic rings, aqua caustic backdrop, bubbles |
| LVT6 Ancient Egypt (both) | `lvt6_ancient_egypt.json` (`outdoor_sky`) | Golden desert sky replaces the missing eye-rock sphere; sandstone pyramids; dark metal mirror; dust |
| LVT7 River Rave (both) | `lvt7_river_rave.json` (`outdoor_sky`) | Procedural river valley (texture never shipped); procedural sky; pollen |
| LVT8 Liquid Light (both) | `lvt8_liquid_light.json` | Procedural plasma room, translucent glass and liquid, glowing pulsing core |
| Aqua Boogie | `aqua_boogie.json` (`underwater`) | Wet stingrays, teal shafts, bubbles, trails |
| Cyber Diva | `cyber_diva.json` (`techno_club`) | Glossy floors, LED screens glow by luminance, translucent glass and face panes |
| KaleidaTribe | `kaleidatribe.json` (`veils`) | Nine alpha sheets through the transparent variant |
| Lost Road Rave | `lost_road_rave.json` | Wet glossy road, emissive lane markings, embers |
| Music Metropolis | `music_metropolis.json` (`techno_club`) | Lit windows by luminance, verdigris statue, additive search-light cones |
| Polyesterday | `polyesterday.json` (`veils`) | Nested alpha shells, soft bloom |
| Wizard (both) | `wizard.json` (`techno_club`) | Circuit pyramids glow by luminance, chrome sphere |
| AK1200 | `ak1200.json` (`techno_club`) | Self-lit logo walls, glossy pod, green haze |
| Keoki EFX | `keoki_efx.json` (`veils`) | Monochrome kept; alpha shells |
| Mind's Eye | `minds_eye.json` | Glowing logo plane in a violet void, drifting glints |

Per-scene grading keeps each Classic palette (hues come from the original event colours and textures; profiles tune `albedo_gain`, saturation and the environment grade). Reactivity mappings follow the Triple Trance pattern through channels (swell/pulse on key, rim and emission; anticipation on fog; impact on glow, exposure, bursts and sun).

## Gaps / next

- The director and character animation (Phase 4d) are authored for Triple Trance only; other profiles have no `director` block, so they keep the original camera.
- Phase 4f profiles were tuned from the 14 s mock frame at two quality levels (at most two visual rounds per scene). Ultra, the drop frame and the Medium preset were not reviewed per scene, and several scenes (Wizard, Mind's Eye, Keoki EFX, AK1200 and Polyesterday) are essentially an image-plane look that Modern can only grade lightly.
- Procedural albedo for missing textures is stand-in art (like the LVT2 reconstructions), clearly not Creative's originals. Dropping the real files in (or the profile's `procedural` block removal) restores them.
- Transparent sorting is per object (Godot sorts translucent surfaces by distance); KaleidaTribe sheets that cross each other can pop. `priority` orders the nine sheets as a first approximation.
- Classic translucent layers under Forward+ remain brighter than the Compatibility reference (see Transparency).
- Geometry is not tessellated in Modern. The parametric meshes keep their original resolution, because extra vertices would have to run through every deformer and that would change the simulation path. Smoothness comes from per-pixel lighting and normal maps.
- GPU timing comes from the Vulkan (MoltenVK) driver. Godot's Metal driver reports no viewport GPU timestamps, and its presentation stays at the display rate, so Metal frame times are reported as wall time only.
- The virtual director and character animation are built (Phase 4d): see `docs/DIRECTOR_AND_ANIMATION.md`. DoF focuses on close-up subjects.
- At low camera angles the platform side reads darker than Classic. The original's 0.75 ambient flattens every face, while Modern lights faces by direction. Tune `PlatformSide.emission_base` if that is unwanted.
- 4K performance was not measured on a 4K display; it is extrapolated from 1200×760 GPU time.
