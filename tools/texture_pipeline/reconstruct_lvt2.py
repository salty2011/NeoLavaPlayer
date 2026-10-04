#!/usr/bin/env python3
"""Procedural RECONSTRUCTIONS of the missing LVT2 ("Dancing Well") textures.

NOT original assets. Seeded + deterministic. Output: 256x256, seamlessly tileable,
late-90s Creative LAVA look (saturated, painterly, slightly soft).

    rainbowflowers.png      ground meadow disc (Ground, r=11.375)
    waterflowers.png        'Tub' well cylinder wall (TexRep 4x1) with ripple
    rainbowflowerwater.png  'Background' inside-out sky sphere (r=20)

Also writes README + sidecar JSON per texture, and copies the chosen bluesky.
"""
import colorsys, json, shutil
from pathlib import Path
import numpy as np
from PIL import Image, ImageFilter
from scipy import ndimage as ndi

ROOT = Path(__file__).resolve().parents[2]
REC = ROOT / "native-player/modern_assets/reconstructions/LVT2"
RECOV = ROOT / "native-player/modern_assets/recovered/LVT2"
N, SS = 256, 4            # final size, supersample
M = N * SS


def fbm(rng, size, octaves=5, base=4, gain=0.5):
    """Periodic fractal noise via filtered white noise (FFT => tileable)."""
    out = np.zeros((size, size)); amp = 1.0
    for o in range(octaves):
        f = base * 2 ** o
        w = rng.standard_normal((size, size))
        W = np.fft.fft2(w)
        fy = np.fft.fftfreq(size)[:, None] * size; fx = np.fft.fftfreq(size)[None, :] * size
        r = np.sqrt(fx * fx + fy * fy)
        W *= np.exp(-(r / f) ** 2)
        n = np.real(np.fft.ifft2(W)); n /= n.std() + 1e-9
        out += amp * n; amp *= gain
    out -= out.min(); out /= out.max() + 1e-9
    return out


def hsv(h, s, v):
    h = np.asarray(h) % 1.0
    i = (h * 6).astype(int) % 6; f = h * 6 - np.floor(h * 6)
    s = np.broadcast_to(s, h.shape); v = np.broadcast_to(v, h.shape)
    p, q, t = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
    r = np.choose(i, [v, q, p, p, t, v]); g = np.choose(i, [t, v, v, q, p, p]); b = np.choose(i, [p, p, t, v, v, q])
    return np.stack([r, g, b], -1)


def wrap_idx(a, size):
    return np.mod(a, size)


def stamp_flower(img, cx, cy, r, hue, rng, petals=None, centre_hue=0.14, sat=0.95):
    """Painterly flower: layered radial petals + bright centre; wraps at edges."""
    petals = petals or int(rng.integers(5, 8))
    rr = int(r * 1.3) + 2
    ys, xs = np.mgrid[-rr:rr + 1, -rr:rr + 1]
    d = np.hypot(xs, ys); a = np.arctan2(ys, xs) + rng.uniform(0, 6.28)
    # petal profile: lobes
    lobe = 0.62 + 0.38 * np.cos(a * petals)
    petal = d < r * lobe
    shade = np.clip(1.0 - d / (r * 1.05), 0, 1)
    col = hsv(np.full(d.shape, hue) + 0.02 * np.cos(a * petals), np.clip(sat - 0.35 * shade, 0, 1), 0.78 + 0.22 * shade)
    centre = d < r * 0.30
    ccol = hsv(np.full(d.shape, centre_hue), 0.95, 1.0)
    rim = (d < r * lobe) & (d > r * lobe - max(1.0, r * 0.12))
    col = np.where(rim[..., None], col * 0.72, col)
    col = np.where(centre[..., None], ccol, col)
    mask = petal | centre
    # soft shadow underneath
    sh = (np.hypot(xs - r * 0.15, ys - r * 0.2) < r * lobe * 1.05) & ~mask
    for mk, c, al in ((sh, np.array([0.0, 0.12, 0.0]), 0.35), (mask, None, 1.0)):
        Y = wrap_idx(ys[mk] + int(cy), img.shape[0]); X = wrap_idx(xs[mk] + int(cx), img.shape[1])
        if c is None:
            img[Y, X] = col[mk]
        else:
            img[Y, X] = img[Y, X] * (1 - al) + c * al


def finish(img):
    """Downsample, painterly softening, saturation push (Creative-ish)."""
    im = Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8))
    # tile-safe: pad by wrap, filter, crop
    p = 24
    a = np.pad(np.asarray(im), ((p, p), (p, p), (0, 0)), mode="wrap")
    big = Image.fromarray(a).filter(ImageFilter.MedianFilter(5)).filter(ImageFilter.GaussianBlur(0.9 * SS))
    big = big.crop((p, p, p + M, p + M)).resize((N, N), Image.LANCZOS)
    from PIL import ImageEnhance
    big = ImageEnhance.Color(big).enhance(1.25)
    big = ImageEnhance.Contrast(big).enhance(1.08)
    return big


def poisson_wrap(rng, count, min_d, size):
    pts = []
    tries = 0
    while len(pts) < count and tries < count * 400:
        tries += 1
        p = rng.uniform(0, size, 2)
        if all(min(abs(p[0] - q[0]), size - abs(p[0] - q[0])) ** 2 + min(abs(p[1] - q[1]), size - abs(p[1] - q[1])) ** 2 > min_d ** 2 for q in pts):
            pts.append(p)
    return pts


def meadow(rng):
    n1, n2, n3 = fbm(rng, M, 6, 3), fbm(rng, M, 4, 20), fbm(rng, M, 3, 60)
    h = 0.30 + 0.09 * n1 - 0.03 * n2           # greens, slight yellow/teal drift
    img = hsv(h, 0.80 - 0.15 * n3, 0.30 + 0.45 * n1 + 0.10 * n2)
    # grass blade streaks
    streak = ndi.gaussian_filter(rng.standard_normal((M, M)), (0.6 * SS, 7 * SS), mode="wrap")
    streak /= np.abs(streak).max()
    img = np.clip(img * (1 + 0.28 * streak[..., None]), 0, 1)
    pts = poisson_wrap(rng, 150, 12 * SS, M)
    for i, (x, y) in enumerate(pts):
        hue = (x / M * 1.0 + 0.04 * rng.standard_normal()) % 1.0      # rainbow across u
        hue = hue if rng.random() > 0.15 else 0.0  # some red
        r = rng.uniform(5.0, 8.5) * SS
        stamp_flower(img, x, y, r, hue, rng)
    # sparse tiny white daisies
    for x, y in poisson_wrap(rng, 40, 8 * SS, M):
        stamp_flower(img, x, y, 2.6 * SS, 0.15, rng, petals=6, centre_hue=0.12, sat=0.08)
    return finish(img)


def water_base(rng, hue_lo=0.52, hue_hi=0.62):
    # warped ripple field -> caustic-ish bands
    n1, n2 = fbm(rng, M, 4, 3), fbm(rng, M, 4, 5)
    yy, xx = np.mgrid[0:M, 0:M] / M
    ph = 2 * np.pi * (3 * xx + 4 * yy) + 7 * (n1 - 0.5) + 5 * (n2 - 0.5)
    rip = 0.5 + 0.5 * np.sin(ph * 2)
    caustic = np.abs(np.sin(ph + 6 * (n2 - 0.5))) ** 4
    h = hue_lo + (hue_hi - hue_lo) * n1
    img = hsv(h, 0.85 - 0.35 * caustic, 0.40 + 0.30 * rip + 0.30 * caustic)
    return img, n1


def waterflowers(rng):
    img, n = water_base(rng)
    # lily pads
    for x, y in poisson_wrap(rng, 34, 17 * SS, M):
        r = rng.uniform(8, 12) * SS
        rr = int(r) + 2; ys, xs = np.mgrid[-rr:rr + 1, -rr:rr + 1]
        d = np.hypot(xs, ys); a = np.arctan2(ys, xs) - rng.uniform(0, 6.28)
        pad = (d < r) & ~((np.abs(a) < 0.18) & (d > r * 0.05))      # notch
        col = hsv(np.full(d.shape, 0.30 + 0.04 * rng.random()), 0.85, 0.35 + 0.35 * (1 - d / r))
        Y = wrap_idx(ys[pad] + int(y), M); X = wrap_idx(xs[pad] + int(x), M)
        img[Y, X] = col[pad]
        hue = rng.choice([0.92, 0.0, 0.08, 0.13, 0.78, 0.58])
        stamp_flower(img, x + rng.uniform(-2, 2) * SS, y + rng.uniform(-2, 2) * SS, r * 0.62, hue, rng)
    # ripple rings around a few flowers
    for x, y in poisson_wrap(rng, 14, 18 * SS, M):
        pass
    return finish(img)


def rainbowflowerwater(rng):
    img, n = water_base(rng, 0.0, 1.0)
    yy, xx = np.mgrid[0:M, 0:M] / M
    # vertical rainbow (ping-pong so it tiles), warped by the water noise
    t = np.abs(((yy + 0.06 * (n - 0.5) + 0.02 * np.sin(2 * np.pi * xx * 3)) * 2) % 2 - 1)
    h = 0.80 * t
    rip = 0.5 + 0.5 * np.sin(2 * np.pi * (5 * yy + 3 * xx) + 8 * (n - 0.5))
    img = hsv(h, 0.80 - 0.25 * rip ** 3, 0.62 + 0.38 * rip)
    for x, y in poisson_wrap(rng, 46, 15 * SS, M):
        r = rng.uniform(4.5, 8.0) * SS
        stamp_flower(img, x, y, r, (float(y) / M * 1.6 + rng.uniform(0.3, 0.6)) % 1.0, rng, sat=0.7)
    return finish(img)


META = {
    "rainbowflowers": dict(object="Ground (ground.lvo, DISK r=11.375, y=-0.8, bump/texscroll/pools/texwave)", fn=meadow, seed=1101,
                           desc="Saturated rainbow-flower meadow: periodic-noise grass with streaks, ~190 painterly flowers whose hue sweeps across u."),
    "waterflowers": dict(object="Tub (tub.lvo, parametric CYLINDER R=1.77 h=0.62, TexRep 4x1, ripple)", fn=waterflowers, seed=2202,
                         desc="Blue-teal caustic water with floating lily pads carrying multicoloured blossoms."),
    "rainbowflowerwater": dict(object="Background (sky.lvo, inside-out SPHERE r=20) per missing-scene-search.md", fn=rainbowflowerwater, seed=3303,
                               desc="Rainbow-banded rippling water field (ping-pong hue ramp so it tiles) scattered with flowers."),
}


def main():
    REC.mkdir(parents=True, exist_ok=True)
    for name, m in META.items():
        img = m["fn"](np.random.default_rng(m["seed"]))
        img.save(REC / f"{name}.png", optimize=True)
        (REC / f"{name}.json").write_text(json.dumps({
            "label": "reconstruction",
            "WARNING": "RECONSTRUCTION - NOT an original Creative asset. The original %s.bmp was never recovered." % name,
            "replaces_missing_original": f"{name}.bmp",
            "scene": "LVT2 (Dancing Well)", "used_by_object": m["object"],
            "size": [N, N], "tileable": True,
            "method": "tools/texture_pipeline/reconstruct_lvt2.py: numpy/scipy procedural (FFT periodic fbm noise, wrap-around flower stamping, 4x supersample, median+blur painterly softening, saturation push). Seed %d, deterministic." % m["seed"],
            "description": m["desc"],
            "style_reference": "Creative LAVA 25 scene textures (saturated, soft, 256x256, seamless)",
        }, indent=1))
    (REC / "README.md").write_text(
        "# LVT2 texture RECONSTRUCTIONS\n\nThese three images are **procedurally generated reconstructions**, "
        "not original Creative assets. The originals (rainbowflowers.bmp, waterflowers.bmp, rainbowflowerwater.bmp) "
        "were not found on any recovered disc (see research/oozic/texture-recovery-report.md). They are made to fit the roles "
        "described in research/oozic/missing-scene-search.md in the late-90s Creative LAVA style.\n\n"
        "Regenerate: `tools/texture_pipeline/.venv/bin/python tools/texture_pipeline/reconstruct_lvt2.py`\n\n"
        "Per-file details are in the sidecar `<name>.json`. Uncertain: the sky ('Background') mapping of rainbowflowerwater "
        "is taken from the research note; the actual look of the originals is unknown.\n")

    # recovered bluesky: LVT7.lvt variant (128x128, tileable clouds)
    src = ROOT / "research/oozic/assets/recovered-textures/sb-live-platinum-application-cd/LVT7.lvt/bluesky.jpg"
    RECOV.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, RECOV / "bluesky.jpg")
    (RECOV / "bluesky.json").write_text(json.dumps({
        "label": "recovered-original",
        "source": "research/oozic/assets/recovered-textures/sb-live-platinum-application-cd/LVT7.lvt/bluesky.jpg",
        "provenance": "research/oozic/assets/recovered-textures/sb-live-platinum-application-cd/provenance.json",
        "chosen_variant": "LVT7.lvt, 128x128 (md5 53623bfb...)",
        "rejected_variant": "Hydra.mv3/bluesky.jpg, 192x192 (md5 6c8a05b0...), kaleidoscopic sparkle motif belonging to the Hydra gallery scene",
        "reason": "LVT2 is a stock LVT-series template like LVT7 (which also references bluesky.bmp); LVT7's package ships this plain tileable cloud-sky variant, matching a generic template water/sky texture. Which variant LVT2 actually used is unproven.",
    }, indent=1))


if __name__ == "__main__":
    main()
