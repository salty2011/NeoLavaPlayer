#!/usr/bin/env python3
"""Offline texture pipeline for OozicPlayer ("modern_assets").

Reads original scene textures (read-only) from native-player/scenes/** and
writes derived PBR-ish maps under native-player/modern_assets/textures/.

    <set>/<scene>/<stem>/albedo_4x.(png|jpg)  colour-preserving upscale
                          normal.png          OpenGL (+Y up) tangent normal
                          roughness.png       8-bit grey
                          height.png          only for relief-type textures

and a manifest.json mapping every original path -> derived maps + parameters.

Usage (from anywhere):
    tools/texture_pipeline/.venv/bin/python tools/texture_pipeline/build.py
        [--only "lava25/Triple Trance"] [--force] [--max-albedo 2048]

Deterministic: same inputs + same parameters => same outputs. Incremental:
an entry is skipped if its recorded parameter hash and outputs are unchanged.
Originals are never modified.
"""
import argparse, hashlib, json, os, shutil, subprocess, sys, tempfile, time
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter
from scipy import ndimage as ndi

PIPELINE_VERSION = "1.0"
ROOT = Path(__file__).resolve().parents[2]
SCENES = ROOT / "native-player" / "scenes"
OUT = ROOT / "native-player" / "modern_assets"
TEX_OUT = OUT / "textures"
SCALE = 4
IMG_EXT = {".jpg", ".jpeg", ".bmp", ".png"}
PRIORITY = ["lava25/Triple Trance"]

# UI / chrome images that are not scene materials (still listed in manifest as skipped)
UI_STEMS = {"album", "cover", "logo", "arrow", "hotspot", "banner"}
MIN_SIDE = 24  # skip tiny icons / 1x1 / 16x16 placeholders

# ---------------------------------------------------------------- categories
# first match wins. params: strength (normal), sigmas (height blur scales in
# source-pixel units, scaled by SCALE), weights, rough (base roughness),
# rough_var (how much local contrast raises roughness), height (write height.png)
CATEGORIES = [
    ("glossy", ("oil", "ooze", "water", "glass", "liquid", "satin", "ripple", "wavy", "lava", "flame", "chrome", "metal", "gold", "silver"),
     dict(strength=3.8, sigmas=(1.2, 3.5, 9.0), weights=(0.25, 0.45, 0.30), rough=0.16, rough_var=0.22, height=False)),
    ("rock", ("rock", "stone", "brick", "pit", "pore", "mosaic", "masiac", "sand", "wall", "building", "road", "statue", "earth", "moon", "body", "fractal", "mystery"),
     dict(strength=5.0, sigmas=(0.8, 2.0, 5.0), weights=(0.45, 0.35, 0.20), rough=0.78, rough_var=0.18, height=True)),
    ("fabric", ("stripe", "cloth", "fabric", "twirl", "weave", "carpet", "wool", "knit", "car"),
     dict(strength=3.5, sigmas=(0.7, 1.8, 4.0), weights=(0.5, 0.3, 0.2), rough=0.70, rough_var=0.15, height=True)),
    ("glow", ("light", "star", "sky", "glow", "sun", "neon", "billboard", "background", "staing", "stain", "long"),
     dict(strength=0.8, sigmas=(2.0, 6.0, 14.0), weights=(0.3, 0.4, 0.3), rough=0.40, rough_var=0.20, height=False)),
]
DEFAULT_CAT = ("generic", dict(strength=2.5, sigmas=(1.0, 3.0, 8.0), weights=(0.35, 0.40, 0.25), rough=0.55, rough_var=0.20, height=False))


def categorise(stem: str):
    s = stem.lower()
    for name, keys, params in CATEGORIES:
        if any(k in s for k in keys):
            return name, params
    return DEFAULT_CAT


# ----------------------------------------------------------------- upscaler
def detect_upscaler():
    for exe in ("realesrgan-ncnn-vulkan", "waifu2x-ncnn-vulkan"):
        p = shutil.which(exe)
        if p:
            return exe, p
    return None, None


def ml_upscale(exe, path, img: Image.Image) -> Image.Image:
    """Run a native macOS/Linux ncnn upscaler on a temp PNG (never Windows binaries)."""
    with tempfile.TemporaryDirectory() as td:
        src, dst = Path(td) / "in.png", Path(td) / "out.png"
        img.save(src)
        if exe.startswith("realesrgan"):
            cmd = [path, "-i", str(src), "-o", str(dst), "-n", "realesrgan-x4plus", "-s", "4"]
        else:
            cmd = [path, "-i", str(src), "-o", str(dst), "-s", "2", "-n", "1"]
        subprocess.run(cmd, check=True, capture_output=True)
        out = Image.open(dst).convert("RGB")
        if exe.startswith("waifu2x"):  # 2x -> 4x with lanczos
            out = out.resize((img.width * 4, img.height * 4), Image.LANCZOS)
        return out


def lanczos_up(img: Image.Image, scale: int) -> Image.Image:
    """Wrap-padded Lanczos upscale (keeps seamless textures seamless) + mild unsharp."""
    pad = 8
    a = np.asarray(img)
    a = np.pad(a, ((pad, pad), (pad, pad), (0, 0)), mode="wrap")
    big = Image.fromarray(a).resize((a.shape[1] * scale, a.shape[0] * scale), Image.LANCZOS)
    p = pad * scale
    big = big.crop((p, p, big.width - p, big.height - p))
    return big.filter(ImageFilter.UnsharpMask(radius=1.6, percent=40, threshold=2))


# ------------------------------------------------------------- map synthesis
def luminance(rgb: np.ndarray) -> np.ndarray:
    return (0.2126 * rgb[..., 0] + 0.7152 * rgb[..., 1] + 0.0722 * rgb[..., 2]) / 255.0


def height_from_lum(lum, sigmas, weights, scale):
    h = np.zeros_like(lum)
    for s, w in zip(sigmas, weights):
        h += w * ndi.gaussian_filter(lum, s * scale, mode="wrap")
    # normalise to 0..1 (robust)
    lo, hi = np.percentile(h, 0.5), np.percentile(h, 99.5)
    return np.clip((h - lo) / max(hi - lo, 1e-6), 0, 1)


def normal_from_height(h, strength, scale):
    # Sobel with wrap; strength is per source-resolution, so divide by scale to
    # keep relief slope constant regardless of upscale factor.
    gx = ndi.sobel(h, axis=1, mode="wrap") / 8.0
    gy = ndi.sobel(h, axis=0, mode="wrap") / 8.0
    k = strength * scale * 0.5
    nx, ny, nz = -gx * k, gy * k, np.ones_like(h)  # +Y up (OpenGL): image rows go down so flip gy sign
    n = np.sqrt(nx * nx + ny * ny + nz * nz)
    out = np.stack([nx / n, ny / n, nz / n], -1)
    return ((out * 0.5 + 0.5) * 255 + 0.5).astype(np.uint8)


def roughness_map(lum, params, scale):
    mean = ndi.uniform_filter(lum, 9 * scale, mode="wrap")
    var = ndi.uniform_filter(lum * lum, 9 * scale, mode="wrap") - mean * mean
    contrast = np.sqrt(np.maximum(var, 0))
    contrast = contrast / max(np.percentile(contrast, 99), 1e-6)
    contrast = np.clip(contrast, 0, 1)
    # busy (high local contrast) areas read rougher; bright highlights read glossier
    r = params["rough"] + params["rough_var"] * (contrast - 0.5) * 2 - 0.12 * (lum - 0.5)
    r = ndi.gaussian_filter(r, 1.5 * scale, mode="wrap")
    return (np.clip(r, 0.04, 1.0) * 255 + 0.5).astype(np.uint8)


# --------------------------------------------------------------------- core
def sha256(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def safe(name: str) -> str:
    return "".join(c if c.isalnum() or c in "-_. ()" else "_" for c in name)


def collect():
    items = []
    for p in sorted(SCENES.rglob("*")):
        if not p.is_file() or p.suffix.lower() not in IMG_EXT:
            continue
        rel = p.relative_to(SCENES)
        parts = rel.parts
        if any(x.endswith("_files") for x in parts[:-1]):
            continue
        scene = "/".join(parts[:-1]) or "."
        items.append((scene, p))

    def key(it):
        scene = it[0]
        return (0 if any(scene.startswith(pp) for pp in PRIORITY) else 1, scene, it[1].name)

    return sorted(items, key=key)


def process(scene, path, args, upscaler, manifest, by_hash):
    rel = str(path.relative_to(ROOT))
    h = sha256(path)
    stem = path.stem
    entry = {"hash": h, "scene": scene}
    im = Image.open(path).convert("RGB")
    entry["size"] = list(im.size)

    if stem.lower() in UI_STEMS:
        entry["status"] = "skipped_ui"
        return rel, entry
    if min(im.size) < MIN_SIDE:
        entry["status"] = "skipped_tiny"
        return rel, entry
    if h in by_hash:
        entry.update(status="duplicate", duplicate_of=by_hash[h]["path"], **{k: by_hash[h]["entry"][k] for k in ("dir", "maps", "params", "category") if k in by_hash[h]["entry"]})
        return rel, entry

    cat, cp = categorise(stem)
    scale = SCALE
    while max(im.size) * scale > args.max_albedo and scale > 1:
        scale -= 1
    params = {"pipeline": PIPELINE_VERSION, "category": cat, "scale": scale, **{k: list(v) if isinstance(v, tuple) else v for k, v in cp.items()},
              "upscaler": upscaler[0] or "lanczos+unsharp(r1.6,40%)"}
    phash = hashlib.sha1(json.dumps(params, sort_keys=True).encode() + h.encode()).hexdigest()[:12]
    out_dir = TEX_OUT / safe(scene.split("/")[0]) / safe("/".join(scene.split("/")[1:]) or "_root") / safe(stem)
    maps = {}
    prev = (manifest.get("textures", {}).get(rel) or {})
    names = ["albedo_4x.png", "albedo_4x.jpg", "normal.png", "roughness.png", "height.png"]
    cached = (not args.force and prev.get("param_hash") == phash and out_dir.exists()
              and all((out_dir / v).exists() for v in prev.get("maps", {}).values()))
    if cached:
        entry.update({k: prev[k] for k in ("status", "dir", "maps", "params", "category", "param_hash", "out_size", "bytes") if k in prev})
        by_hash[h] = {"path": rel, "entry": entry}
        return rel, entry

    out_dir.mkdir(parents=True, exist_ok=True)
    for n in names:
        (out_dir / n).unlink(missing_ok=True)

    # --- albedo
    if upscaler[0] and scale == SCALE:
        try:
            up = ml_upscale(upscaler[0], upscaler[1], im)
        except Exception as e:  # fall back
            print("  ML upscaler failed, using Lanczos:", e)
            up = lanczos_up(im, scale)
    else:
        up = lanczos_up(im, scale)
    rgb = np.asarray(up)
    # PNG when small, high-quality JPEG (4:4:4) when the lossless file would be big
    if up.width * up.height <= 1024 * 1024 // 2:
        albedo_name = "albedo_4x.png"
        up.save(out_dir / albedo_name, optimize=True)
    else:
        albedo_name = "albedo_4x.jpg"
        up.save(out_dir / albedo_name, quality=95, subsampling=0, optimize=True)
    maps["albedo"] = albedo_name

    # --- height / normal / roughness
    lum = luminance(rgb.astype(np.float32))
    hmap = height_from_lum(lum, cp["sigmas"], cp["weights"], scale)
    nrm = normal_from_height(hmap, cp["strength"], scale)
    Image.fromarray(nrm).save(out_dir / "normal.png", optimize=True)
    maps["normal"] = "normal.png"
    rough = roughness_map(lum, cp, scale)
    Image.fromarray(rough, "L").save(out_dir / "roughness.png", optimize=True)
    maps["roughness"] = "roughness.png"
    if cp["height"]:
        Image.fromarray((hmap * 255 + 0.5).astype(np.uint8), "L").save(out_dir / "height.png", optimize=True)
        maps["height"] = "height.png"

    entry.update(status="ok", category=cat, dir=str(out_dir.relative_to(ROOT)), maps=maps, params=params, param_hash=phash,
                 out_size=list(up.size), bytes=sum((out_dir / v).stat().st_size for v in maps.values()),
                 normal_convention="OpenGL (Y+ up, green = up)", label="derived")
    by_hash[h] = {"path": rel, "entry": entry}
    return rel, entry


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", help='scene prefix filter, e.g. "lava25/Triple Trance"')
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--max-albedo", type=int, default=2048)
    args = ap.parse_args()

    upscaler = detect_upscaler()
    print("upscaler:", upscaler[0] or "none found -> Lanczos 4x + mild unsharp")
    mpath = OUT / "manifest.json"
    manifest = json.loads(mpath.read_text()) if mpath.exists() else {}
    manifest.setdefault("textures", {})
    items = collect()
    if args.only:
        items = [it for it in items if it[0].startswith(args.only)]
    by_hash, t0 = {}, time.time()
    for scene, p in items:
        rel, entry = process(scene, p, args, upscaler, manifest, by_hash)
        manifest["textures"][rel] = entry
        print(f"{entry['status']:12s} {rel}")
    manifest["_meta"] = {
        "pipeline_version": PIPELINE_VERSION,
        "generator": "tools/texture_pipeline/build.py",
        "upscaler": upscaler[0] or "Lanczos 4x (wrap-padded) + UnsharpMask r1.6 40%",
        "label": "derived",
        "note": "Derived from original textures; originals untouched. Normals are OpenGL convention.",
        "albedo_cap_px": args.max_albedo,
    }
    manifest["textures"] = dict(sorted(manifest["textures"].items()))
    mpath.write_text(json.dumps(manifest, indent=1))
    total = sum(f.stat().st_size for f in TEX_OUT.rglob("*") if f.is_file()) if TEX_OUT.exists() else 0
    print(f"done in {time.time()-t0:.0f}s; textures dir {total/1e6:.1f} MB")


if __name__ == "__main__":
    main()
