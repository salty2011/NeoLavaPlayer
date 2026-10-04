# modern_assets

Modernised texture set for OozicPlayer ("as if Creative kept developing it to 2026: upgrade fidelity, not the soul").
Everything here is additive. Originals in `native-player/scenes/**` and `research/**` are never modified.
Nothing in the Godot project references this folder yet.

## Provenance labels

| label | meaning |
|---|---|
| original | untouched asset from a Creative disc, kept in `native-player/scenes/**` (not stored here) |
| recovered-original | a genuine Creative file found on another disc/package (`research/oozic/assets/recovered-textures/**`), copied unchanged |
| derived | machine-processed from an original or recovered-original (upscale, normal, roughness, height); colour not restyled |
| reconstruction | newly generated stand-in for an asset that was never recovered. NOT a Creative asset |

## Layout

```
manifest.json                         original path -> derived maps + parameters + hash (label: derived)
textures/<set>/<scene>/<stem>/        derived
    albedo_4x.png|jpg                 upscaled (4x, capped at 2048 px); PNG if small, else JPEG q95 4:4:4
    normal.png                        OpenGL convention (green = +Y up), from blurred multi-scale luminance height + Sobel
    roughness.png                     8-bit; category base + local contrast, brighter = rougher
    height.png                        only for relief categories (rock, fabric)
recovered/<set>/<scene>/<file>        recovered-original textures copied per referencing scene
recovered/texture-map.json            {"<set>/<scene>": {"missing texture name": "recovered file path"}}
recovered/texture-map-detail.json     per-entry source, selection reason, and still-unrecovered references
recovered/LVT2/bluesky.{jpg,json}     chosen bluesky variant with provenance
reconstructions/LVT2/*.png + .json    RECONSTRUCTIONS of rainbowflowers, waterflowers, rainbowflowerwater (+ README.md)
```
`<set>` is `lava25`, `oozic30`, `Hydroid`; `shared-textures` is processed too.

## Pipeline (tools/texture_pipeline/)

```
python3 -m venv tools/texture_pipeline/.venv && tools/texture_pipeline/.venv/bin/pip install pillow numpy scipy
tools/texture_pipeline/.venv/bin/python tools/texture_pipeline/build.py [--only "lava25/Triple Trance"] [--force]
tools/texture_pipeline/.venv/bin/python tools/texture_pipeline/map_recovered.py
tools/texture_pipeline/.venv/bin/python tools/texture_pipeline/reconstruct_lvt2.py
```
- `build.py`: processes every jpg/bmp/png in the scene packages, Triple Trance first. Skips duplicate hashes (manifest records `duplicate_of`), UI images (album, cover, logo, arrow, hotspot, banner) and sub-24 px images. Incremental via a parameter hash; `--force` rebuilds.
- Upscaler: uses `realesrgan-ncnn-vulkan` or `waifu2x-ncnn-vulkan` if on PATH (native binaries only); otherwise wrap-padded Lanczos 4x + mild unsharp (radius 1.6, 40%). Wrap padding keeps tileable textures seamless. The Lanczos path is what produced the current output.
- Per-category parameters (name heuristics, see `CATEGORIES` in build.py): glossy (oil/ooze/water/glass/satin...), rock (rock/pore/pit/mosaic/building...), fabric (stripe/cloth...), glow (light/sky/star...), generic. They set normal strength, height blur scales, roughness base.
- The sources are mostly 100-256 px, so 4x output is soft but colour-faithful. Maps are heuristics from luminance, not real material scans.

## Notes
- LVT2 "Dancing Well": bluesky uses the LVT7.lvt variant (128 px tileable clouds) over the Hydra variant (192 px kaleidoscope); unproven which LVT2 used. The other three textures are reconstructions.
- 34 references per set remain unrecovered; listed in `recovered/texture-map-detail.json`. Some (flame, glass, core) are `.lvm` materials, not images.
