#!/usr/bin/env python3
"""Generate native-player/skins/modern: the "Modern" Oozic skin.

Oozic as if Creative had kept developing it into 2026: the LAVA glossy red
orbs and logo spirit, redrawn as crisp graphite glass at 2x for Retina.
Everything is drawn programmatically (Pillow + numpy, 4x supersampled), so
the art is reproducible. Rects in skin.json are logical (1x); images are 2x
("scale": 2) and rendered with linear filtering.

Run from the repository root:

    tools/texture_pipeline/.venv/bin/python native-player/tools/make_modern_skin.py
"""
import json
import math
import os

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

OUT = os.path.join(os.path.dirname(__file__), "..", "skins", "modern")
S = 2       # output pixels per logical unit
SS = 4      # supersampling on top of S
K = S * SS  # drawing pixels per logical unit

FONT_BLACK = "/System/Library/Fonts/Supplemental/Arial Black.ttf"
FONT_BOLD = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
FONT_REG = "/System/Library/Fonts/Supplemental/Arial.ttf"

RED = "#e0141c"
GLYPH = "#d3dae5"


def font(path, size):
    return ImageFont.truetype(path, int(round(size * K)))


def hexrgb(value):
    value = value.lstrip("#")
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))


def new(w, h):
    return Image.new("RGBA", (int(round(w * K)), int(round(h * K))), (0, 0, 0, 0))


def down(image):
    return image.resize((image.width // SS, image.height // SS), Image.LANCZOS)


def mask_rrect(size, box, radius):
    m = Image.new("L", size, 0)
    d = ImageDraw.Draw(m)
    x0, y0, x1, y1 = [v * K for v in box]
    d.rounded_rectangle((x0, y0, x1 - 1, y1 - 1), radius=radius * K, fill=255)
    return m


def vgrad(size, stops):
    """Vertical gradient image from [(t, '#rrggbb' or (r,g,b,a)), ...]."""
    w, h = size
    t = np.linspace(0, 1, h)[:, None]
    out = np.zeros((h, w, 4), dtype=np.float32)
    ts = [s[0] for s in stops]
    cols = [np.array(c if not isinstance(c, str) else hexrgb(c) + (255,), dtype=np.float32) for _, c in stops]
    for ch in range(4):
        out[:, :, ch] = np.interp(t, ts, [c[ch] for c in cols])
    return Image.fromarray(out.astype(np.uint8), "RGBA")


def paste_masked(base, layer, mask):
    base.alpha_composite(Image.composite(layer, Image.new("RGBA", layer.size, (0, 0, 0, 0)), mask))


def blur(image, radius):
    return image.filter(ImageFilter.GaussianBlur(radius * K))


def shadow(base, box, radius, offset, blur_r, alpha):
    m = mask_rrect(base.size, box, radius)
    m = ImageChops.offset(m, int(offset[0] * K), int(offset[1] * K)).filter(ImageFilter.GaussianBlur(blur_r * K))
    layer = Image.new("RGBA", base.size, (0, 0, 0, int(255 * alpha)))
    layer.putalpha(m.point(lambda v: int(v * alpha)))
    base.alpha_composite(layer)


# --- Orbs --------------------------------------------------------------------

PALETTES = {
    # lava red (LAVA! heritage)
    "red": dict(edge=(96, 0, 10), mid=(222, 20, 28), core=(255, 96, 72), rim=(255, 130, 70)),
    # graphite orb for the window buttons
    "graphite": dict(edge=(14, 15, 18), mid=(62, 66, 74), core=(120, 126, 138), rim=(150, 160, 175)),
    # silver slider knob
    "silver": dict(edge=(110, 116, 126), mid=(214, 220, 230), core=(255, 255, 255), rim=(255, 255, 255)),
}


def orb(d, palette, state, glyph=None, glyph_color=(255, 255, 255), raw=False):
    """One glossy orb of diameter d (logical) in a state: 0 normal, 1 disabled, 2 hover, 3 pressed."""
    n = int(round(d * K))
    p = PALETTES[palette]
    yy, xx = np.mgrid[0:n, 0:n].astype(np.float32)
    cx = cy = (n - 1) / 2
    r = n / 2
    dx, dy = (xx - cx) / r, (yy - cy) / r
    dist = np.sqrt(dx * dx + dy * dy)
    # light comes from the upper left; the core of the gradient sits low, as on the LAVA orbs
    lx, ly = (xx - cx) / r - 0.0, (yy - cy) / r - (0.15 if state != 3 else -0.05)
    t = np.clip(np.sqrt(lx * lx + ly * ly) / 1.05, 0, 1)
    edge, mid, core = (np.array(p[k], dtype=np.float32) for k in ("edge", "mid", "core"))
    col = np.where(t[..., None] < 0.5, core + (mid - core) * (t[..., None] / 0.5) ** 0.9, mid + (edge - mid) * (np.clip(t[..., None] - 0.5, 0, 1) / 0.5) ** 1.3)
    # warm rim light along the bottom
    rim = np.clip((dy - 0.55) / 0.45, 0, 1) ** 2 * np.clip(1 - np.abs(dx) * 0.9, 0, 1) * np.clip((dist - 0.45) / 0.5, 0, 1)
    col = col + rim[..., None] * np.array(p["rim"], dtype=np.float32) * (0.45 if state != 3 else 0.2)
    if state == 2:
        col = col * 1.10 + 22
    elif state == 3:
        col = col * 0.80
    elif state == 1:
        grey = col.mean(axis=2, keepdims=True)
        col = grey * 0.7 + col * 0.3
    col = np.clip(col, 0, 255)
    # edge: crisp 1-sample dark rim, antialiased by downsampling
    inside = dist <= 1.0
    out = np.zeros((n, n, 4), dtype=np.uint8)
    out[..., :3] = col.astype(np.uint8)
    out[..., 3] = (inside * 255).astype(np.uint8)
    img = Image.fromarray(out, "RGBA")
    # specular dome
    hl = new(d, d)
    hd = ImageDraw.Draw(hl)
    hd.ellipse((n * 0.17, n * 0.05, n * 0.83, n * 0.52), fill=(255, 255, 255, 255))
    hl_mask = hl.split()[3]
    grad = vgrad((n, n), [(0.05, (255, 255, 255, 235)), (0.30, (255, 255, 255, 120)), (0.52, (255, 255, 255, 12))])
    grad.putalpha(ImageChops.multiply(grad.split()[3], hl_mask))
    if state == 3:
        grad.putalpha(grad.split()[3].point(lambda v: int(v * 0.45)))
    img.alpha_composite(grad)
    # fine inner outline for definition
    ol = Image.new("L", (n, n), 0)
    ImageDraw.Draw(ol).ellipse((0, 0, n - 1, n - 1), outline=255, width=max(2, int(n * 0.012)))
    edge_layer = Image.new("RGBA", (n, n), (0, 0, 0, 90))
    edge_layer.putalpha(ol.point(lambda v: int(v * 0.35)))
    img.alpha_composite(edge_layer)
    if glyph is not None:
        draw_glyph(img, glyph, n, glyph_color, state)
    if state == 1:
        img.putalpha(img.split()[3].point(lambda v: int(v * 0.5)))
    return img if raw else down(img)


def draw_glyph(img, glyph, n, color, state):
    r = n / 2
    c = (r, r + (0.015 * n if state == 3 else 0))
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    col = tuple(color) + (255,)
    if glyph == "play":
        d.polygon([(c[0] - 0.24 * r, c[1] - 0.42 * r), (c[0] - 0.24 * r, c[1] + 0.42 * r), (c[0] + 0.46 * r, c[1])], fill=col)
    elif glyph == "pause":
        for sx in (-0.26, 0.26):
            d.rounded_rectangle((c[0] + (sx - 0.12) * r, c[1] - 0.40 * r, c[0] + (sx + 0.12) * r, c[1] + 0.40 * r), radius=0.05 * r, fill=col)
    elif glyph == "stop":
        d.rounded_rectangle((c[0] - 0.36 * r, c[1] - 0.36 * r, c[0] + 0.36 * r, c[1] + 0.36 * r), radius=0.09 * r, fill=col)
    elif glyph == "gear":
        pts = []
        teeth = 8
        for i in range(teeth * 4):
            a = math.pi * 2 * i / (teeth * 4) - math.pi / (teeth * 4)
            rad = 0.60 if (i % 4) in (0, 1) else 0.44
            pts.append((c[0] + math.cos(a) * rad * r, c[1] + math.sin(a) * rad * r))
        d.polygon(pts, fill=col)
        d.ellipse((c[0] - 0.22 * r, c[1] - 0.22 * r, c[0] + 0.22 * r, c[1] + 0.22 * r), fill=(0, 0, 0, 0))
    elif glyph == "close":
        w = max(2, int(0.16 * r))
        a = 0.40 * r
        d.line((c[0] - a, c[1] - a, c[0] + a, c[1] + a), fill=col, width=w)
        d.line((c[0] - a, c[1] + a, c[0] + a, c[1] - a), fill=col, width=w)
    elif glyph == "minimize":
        w = max(2, int(0.16 * r))
        d.line((c[0] - 0.42 * r, c[1] + 0.12 * r, c[0] + 0.42 * r, c[1] + 0.12 * r), fill=col, width=w)
    # soft drop shadow so the glyph sits on the orb
    if glyph == "gear":
        # punch the hole through the shadow too
        pass
    sh = Image.new("RGBA", img.size, (30, 0, 0, 0))
    sh.putalpha(ImageChops.offset(layer.split()[3], 0, int(0.04 * n)).filter(ImageFilter.GaussianBlur(0.02 * n)).point(lambda v: int(v * 0.55)))
    img.alpha_composite(sh)
    img.alpha_composite(layer)


# --- Flat controls -----------------------------------------------------------

def pill(w, h, state, label=None, fill=(255, 255, 255), base_alpha=0.07, font_path=FONT_BOLD, size=9, chevron=None):
    img = new(w, h)
    d = ImageDraw.Draw(img)
    a = {0: base_alpha, 1: base_alpha * 0.5, 2: base_alpha + 0.10, 3: base_alpha + 0.20}[state]
    d.rounded_rectangle((0, 0, img.width - 1, img.height - 1), radius=h * K / 2, fill=fill + (int(255 * a),))
    if base_alpha > 0:
        d.rounded_rectangle((0, 0, img.width - 1, img.height - 1), radius=h * K / 2, outline=(255, 255, 255, int(255 * (0.12 if state != 1 else 0.05))), width=max(1, K // 2))
    text_col = hexrgb(GLYPH) + (255 if state != 1 else 90,)
    if state == 2 or state == 3:
        text_col = (255, 255, 255, 255)
    if label:
        f = font(font_path, size)
        tw = d.textlength(label, font=f)
        # letter-spaced caps
        spacing = 0.6 * K
        total = tw + spacing * (len(label) - 1)
        x = (img.width - total) / 2 - (7 * K if chevron else 0)
        for ch in label:
            d.text((x, img.height / 2 + 0.05 * K), ch, font=f, fill=text_col, anchor="lm")
            x += d.textlength(ch, font=f) + spacing
    if chevron:
        cx = img.width / 2 + (total / 2 + 8 * K if label else 0)
        cy = img.height / 2
        s = 2.6 * K
        if chevron == "down":
            pts = [(cx - s, cy - s * 0.5), (cx, cy + s * 0.5), (cx + s, cy - s * 0.5)]
        else:
            pts = [(cx - s, cy + s * 0.5), (cx, cy - s * 0.5), (cx + s, cy + s * 0.5)]
        d.line(pts, fill=text_col, width=int(1.5 * K), joint="curve")
    return down(img)


def icon_button(w, h, state, kind, muted=False):
    img = new(w, h)
    d = ImageDraw.Draw(img)
    a = {0: 0.0, 1: 0.0, 2: 0.10, 3: 0.20}[state]
    if a:
        d.rounded_rectangle((0, 0, img.width - 1, img.height - 1), radius=5 * K, fill=(255, 255, 255, int(255 * a)))
    col = hexrgb(GLYPH) + (255 if state != 1 else 90,)
    if state >= 2:
        col = (255, 255, 255, 255)
    cx, cy = img.width / 2, img.height / 2
    u = K
    if kind == "mute":
        # speaker
        d.polygon([(cx - 6 * u, cy - 2.2 * u), (cx - 3 * u, cy - 2.2 * u), (cx + 0.5 * u, cy - 5.2 * u), (cx + 0.5 * u, cy + 5.2 * u), (cx - 3 * u, cy + 2.2 * u), (cx - 6 * u, cy + 2.2 * u)], fill=col)
        if not muted:
            for rad, w_ in ((3.2, 1.3), (5.6, 1.3)):
                d.arc((cx + 0.2 * u - rad * u * 0.7, cy - rad * u, cx + 0.2 * u + rad * u * 1.3, cy + rad * u), -48, 48, fill=col, width=int(w_ * u))
        else:
            d.line((cx + 3 * u, cy - 3 * u, cx + 8 * u, cy + 3 * u), fill=(224, 20, 28, 255), width=int(1.6 * u))
            d.line((cx + 3 * u, cy + 3 * u, cx + 8 * u, cy - 3 * u), fill=(224, 20, 28, 255), width=int(1.6 * u))
    return down(img)


def slider_rows(w, h, knob=True):
    """Rows 0-2 track (normal, disabled, hover), 3-5 fill, 6-8 knob."""
    rows = []
    gh = 5  # groove thickness
    for variant in range(3):
        img = new(w, h)
        d = ImageDraw.Draw(img)
        gy0, gy1 = (h - gh) / 2 * K, (h + gh) / 2 * K
        d.rounded_rectangle((0, gy0, img.width - 1, gy1), radius=gh * K / 2, fill=(4, 5, 7, 255 if variant != 1 else 150))
        d.rounded_rectangle((0, gy0, img.width - 1, gy1), radius=gh * K / 2, outline=(255, 255, 255, 40 if variant != 2 else 70), width=max(1, K // 2))
        # top inner shade
        sh = Image.new("RGBA", img.size, (0, 0, 0, 0))
        ImageDraw.Draw(sh).rounded_rectangle((K, gy0 + K, img.width - K, gy0 + 2.2 * K), radius=K, fill=(0, 0, 0, 140))
        img.alpha_composite(sh)
        rows.append(down(img))
    for variant in range(3):
        img = new(w, h)
        gy0, gy1 = (h - gh) / 2 * K, (h + gh) / 2 * K
        grad = vgrad(img.size, [(0, (255, 120, 90, 255)), (0.35, (235, 38, 40, 255)), (1, (150, 4, 14, 255))])
        m = Image.new("L", img.size, 0)
        ImageDraw.Draw(m).rounded_rectangle((0, gy0, img.width - 1, gy1), radius=gh * K / 2, fill=255)
        layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
        # gradient spans only the groove height
        band = grad.crop((0, 0, img.width, int(gy1 - gy0))).resize((img.width, int(gy1 - gy0)))
        layer.paste(band, (0, int(gy0)))
        paste_masked(img, layer, m)
        if variant == 1:
            img.putalpha(img.split()[3].point(lambda v: int(v * 0.5)))
        if variant == 2:
            img = Image.eval(img, lambda v: min(255, v + 18)) if False else img
        rows.append(down(img))
    if knob:
        for variant in range(3):
            canvas = new(h, h)
            ko = h - (3 if variant != 2 else 2)
            o = orb(ko, "silver", {0: 0, 1: 1, 2: 2}[variant])
            img = down(canvas)
            img.alpha_composite(o, (int((img.width - o.width) / 2), int((img.height - o.height) / 2)))
            rows.append(img)
    return rows


# --- Sheet packer --------------------------------------------------------------

class Sheet:
    def __init__(self, width):
        self.width = width
        self.items = []
        self.x = 2
        self.y = 2
        self.row_h = 0

    def add(self, w, h, frames, sets=1):
        bw, bh = w * frames, h * sets
        if self.x + bw + 2 > self.width:
            self.x = 2
            self.y += self.row_h + 2
            self.row_h = 0
        pos = (self.x, self.y)
        self.x += bw + 2
        self.row_h = max(self.row_h, bh)
        return pos

    @property
    def height(self):
        return self.y + self.row_h + 2

    def finish(self, entries):
        h = self.height
        sheet = Image.new("RGBA", (self.width * S, h * S), (0, 0, 0, 0))
        for (px, py), image in entries:
            sheet.alpha_composite(image, (px * S, py * S))
        return sheet, (self.width, h)


def button_entry(sheet, w, h, frame_fn, sets=1):
    """frame_fn(state, set) -> image. Returns (src, entries, stride dict)."""
    pos = sheet.add(w, h, 4, sets)
    entries = []
    for s_ in range(sets):
        for f in range(4):
            entries.append(((pos[0] + f * w, pos[1] + s_ * h), frame_fn(f, s_)))
    return pos, entries


# --- Backgrounds ---------------------------------------------------------------

PLAYER_W, PLAYER_H = 470, 172
BODY = (10, 6, 460, 162)  # x0, y0, x1, y1
DRAWER_W, DRAWER_H = 426, 196
DRAWER_ATTACH = (22, 140)
DRAWER_PEEK = 62


def panel(size, box, radius, top="#34373e", bottom="#121317", glow_at=None):
    w, h = size
    img = new(w, h)
    shadow(img, box, radius, (0, 4), 6, 0.55)
    shadow(img, box, radius, (0, 1), 1.5, 0.5)
    x0, y0, x1, y1 = box
    m = mask_rrect(img.size, box, radius)
    grad = vgrad(img.size, [(0, top), (max(0.001, (y0) / h), top), (min(1, y1 / h), bottom), (1, bottom)])
    paste_masked(img, grad, m)
    # glass sheen on the upper third
    sheen = vgrad(img.size, [(0, (255, 255, 255, 0)), (y0 / h, (255, 255, 255, 34)), ((y0 + (y1 - y0) * 0.38) / h, (255, 255, 255, 0)), (1, (255, 255, 255, 0))])
    paste_masked(img, sheen, m)
    if glow_at:
        gx, gy, gr, ga = glow_at
        yy, xx = np.mgrid[0:img.height, 0:img.width].astype(np.float32)
        t = np.clip(np.sqrt((xx - gx * K) ** 2 + (yy - gy * K) ** 2) / (gr * K), 0, 1)
        a = ((1 - t) ** 2 * ga * 255).astype(np.uint8)
        glow = np.zeros((img.height, img.width, 4), dtype=np.uint8)
        glow[..., 0], glow[..., 1], glow[..., 2], glow[..., 3] = 235, 24, 28, a
        paste_masked(img, Image.fromarray(glow, "RGBA"), m)
    # rim: light on the top edge, fading down
    outer = m
    inner = mask_rrect(img.size, (x0 + 1, y0 + 1, x1 - 1, y1 - 1), radius - 1)
    ring = ImageChops.subtract(outer, inner)
    rim = vgrad(img.size, [(0, (255, 255, 255, 0)), (y0 / h, (255, 255, 255, 120)), ((y0 + (y1 - y0) * 0.5) / h, (255, 255, 255, 30)), (y1 / h, (255, 255, 255, 14)), (1, (255, 255, 255, 14))])
    paste_masked(img, rim, ring)
    return img, m


def well(img, box, radius, alpha=255):
    """Inset dark glass well."""
    x0, y0, x1, y1 = box
    m = mask_rrect(img.size, box, radius)
    fill = vgrad(img.size, [(0, (3, 4, 6, alpha)), (1, (14, 16, 20, alpha))])
    # gradient spans whole image; crop to well by mask and re-map vertically
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    hh = int((y1 - y0) * K)
    band = vgrad((img.width, hh), [(0, (3, 4, 7, alpha)), (1, (15, 17, 22, alpha))])
    layer.paste(band, (0, int(y0 * K)))
    paste_masked(img, layer, m)
    # inner top shade
    shade = vgrad(img.size, [(0, (0, 0, 0, 0)), (y0 / img.height * K, (0, 0, 0, 170)), ((y0 + 5) * K / img.height, (0, 0, 0, 0)), (1, (0, 0, 0, 0))])
    paste_masked(img, shade, m)
    # outline + bottom lip highlight
    inner = mask_rrect(img.size, (x0 + 0.6, y0 + 0.6, x1 - 0.6, y1 - 0.6), radius - 0.6)
    ring = ImageChops.subtract(m, inner)
    paste_masked(img, Image.new("RGBA", img.size, (255, 255, 255, 30)), ring)
    lip = ImageChops.subtract(mask_rrect(img.size, (x0, y0 + 1, x1, y1 + 1), radius), mask_rrect(img.size, (x0, y0, x1, y1), radius))
    paste_masked(img, Image.new("RGBA", img.size, (255, 255, 255, 36)), lip)
    # faint diagonal glass reflection
    refl = Image.new("L", img.size, 0)
    rd = ImageDraw.Draw(refl)
    rd.polygon([(x0 * K, y0 * K), ((x0 + (x1 - x0) * 0.55) * K, y0 * K), ((x0 + (x1 - x0) * 0.40) * K, (y0 + (y1 - y0) * 0.5) * K), (x0 * K, (y0 + (y1 - y0) * 0.5) * K)], fill=14)
    paste_masked(img, Image.new("RGBA", img.size, (255, 255, 255, 255)), ImageChops.multiply(refl, m))


def logo(img, x, y):
    """LAVA! logo spirit: a red glossy dot, italic wordmark, red bang."""
    d_ = 12
    ox, oy = int(x * K), int((y + 3.2) * K)
    img.alpha_composite(orb(d_, "red", 0, raw=True), (ox, oy))
    text = new(120, 28)
    td = ImageDraw.Draw(text)
    f = font(FONT_BLACK, 16)
    tx = 0
    for ch, colr in (("L", "#f3f5f8"), ("A", "#f3f5f8"), ("V", "#f3f5f8"), ("A", "#f3f5f8"), ("!", RED)):
        td.text((tx, 22 * K), ch, font=f, fill=hexrgb(colr) + (255,), anchor="ls")
        tx += td.textlength(ch, font=f) - 0.4 * K
    # italic shear around the baseline
    shear = 0.20
    text = text.transform(text.size, Image.AFFINE, (1, shear, -shear * 22 * K, 0, 1, 0), Image.BICUBIC)
    # subtle shadow
    sh = Image.new("RGBA", text.size, (0, 0, 0, 0))
    sh.putalpha(ImageChops.offset(text.split()[3], 0, int(0.6 * K)).filter(ImageFilter.GaussianBlur(0.8 * K)).point(lambda v: int(v * 0.7)))
    img.alpha_composite(sh, (int((x + 16) * K), int((y - 8.5) * K)))
    img.alpha_composite(text, (int((x + 16) * K), int((y - 8.5) * K)))
    # OOZIC wordmark, small and spaced
    f2 = font(FONT_BOLD, 7.5)
    d = ImageDraw.Draw(img)
    px = (x + 16 + 62) * K
    for ch in "OOZIC":
        d.text((px, (y + 13.6) * K), ch, font=f2, fill=(150, 158, 172, 255), anchor="ls")
        px += d.textlength(ch, font=f2) + 1.2 * K


def build_player_background():
    img, body_mask = panel((PLAYER_W, PLAYER_H), BODY, 24, glow_at=(372, 78, 120, 0.30))
    # red lava line along the bottom edge
    x0, y0, x1, y1 = BODY
    line = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(line).rounded_rectangle((60 * K, (y1 - 3) * K, 330 * K, (y1 - 1.2) * K), radius=K, fill=(224, 20, 28, 255))
    line = blur(line, 1.2)
    line.putalpha(ImageChops.multiply(line.split()[3], Image.new("L", img.size, 150)))
    h = np.linspace(0, 1, img.width)
    fade = Image.fromarray((np.clip(np.sin(h * math.pi), 0, 1) * 255).astype(np.uint8)[None, :].repeat(img.height, axis=0), "L")
    line.putalpha(ImageChops.multiply(line.split()[3], fade))
    paste_masked(img, line, body_mask)
    well(img, (24, 36, 318, 86), 11)
    # track-title plate
    plate = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(plate).rounded_rectangle((24 * K, 88 * K, 318 * K, 104 * K), radius=8 * K, fill=(0, 0, 0, 70))
    img.alpha_composite(plate)
    logo(img, 28, 17)
    # orb wells: soft shadows under the orbs
    for cx, cy, d in ((372, 78, 88), (432, 112, 40), (434, 60, 34), (424, 22, 16), (444, 22, 16)):
        sh = Image.new("RGBA", img.size, (0, 0, 0, 0))
        r = d / 2
        ImageDraw.Draw(sh).ellipse(((cx - r - 1) * K, (cy - r + 2.5) * K, (cx + r + 1) * K, (cy + r + 3.5) * K), fill=(0, 0, 0, 170))
        img.alpha_composite(blur(sh, 2.6 if d > 30 else 1.2))
        ring = Image.new("RGBA", img.size, (0, 0, 0, 0))
        ImageDraw.Draw(ring).ellipse(((cx - r - 1.6) * K, (cy - r - 1.6) * K, (cx + r + 1.6) * K, (cy + r + 1.6) * K), outline=(0, 0, 0, 110), width=int(1.2 * K))
        img.alpha_composite(ring)
    return down(img)


def build_drawer_background():
    w, h = DRAWER_W, DRAWER_H
    img, m = panel((w, h), (8, 0, w - 8, 184), 20, top="#202227", bottom="#0f1013")
    well(img, (22, 28, w - 22, 116), 10, 255)
    return down(img)


# --- Assemble --------------------------------------------------------------------

def main():
    os.makedirs(OUT, exist_ok=True)
    player = Sheet(520)
    entries = []
    controls = []
    nid = [1000]

    def ctl(kind, action, rect, **extra):
        c = {"id": nid[0], "type": kind, "action": action, "flags": 0, "hidden": False, "anchor": 5, "rect": rect}
        nid[0] += 1
        c.update(extra)
        controls.append(c)
        return c

    def add_button(action, rect, frame_fn, sets=1, tooltips=None, **extra):
        w, h = rect[2], rect[3]
        pos, ents = button_entry(player, w, h, frame_fn, sets)
        entries.extend(ents)
        ctl("button", action, rect, src=list(pos), sets=sets, stride_x=w, stride_y=h, states=4, tooltips=tooltips or [""], **extra)

    add_button("play", [328, 34, 88, 88], lambda f, s: orb(88, "red", f, "play"), tooltips=["Play (Ctrl+P)"], visible_when="not_playing")
    add_button("stop", [412, 92, 40, 40], lambda f, s: orb(40, "red", f, "stop"), tooltips=["Stop (Ctrl+S)"])
    add_button("pause", [328, 34, 88, 88], lambda f, s: orb(88, "red", f, "pause"), tooltips=["Pause (Ctrl+P)"], visible_when="playing")
    # sliders: progress (id order mirrors the classic skin)
    pw, ph = 294, 14
    prog_rows = slider_rows(pw, ph)
    ppos = player.add(pw, ph, 1, 9)
    for i, row in enumerate(prog_rows):
        entries.append(((ppos[0], ppos[1] + i * ph), row))
    ctl("slider", "progress", [24, 106, pw, ph], src=list(ppos), steps=600, stride_y=ph, knob=True, tooltips=["Seek"])
    vw, vh = 78, 14
    vol_rows = slider_rows(vw, vh)
    vpos = player.add(vw, vh, 1, 9)
    for i, row in enumerate(vol_rows):
        entries.append(((vpos[0], vpos[1] + i * vh), row))
    ctl("slider", "volume", [240, 137, vw, vh], src=list(vpos), steps=600, stride_y=vh, knob=True, tooltips=["Volume"])
    add_button("mute", [216, 134, 20, 20], lambda f, s: icon_button(20, 20, f, "mute", muted=bool(s)), sets=2, tooltips=["Mute: ON (Ctrl+M)", "Mute: OFF (Ctrl+M)"])
    add_button("system_menu", [24, 9, 112, 24], lambda f, s: pill(112, 24, f, None, base_alpha=0.0), tooltips=["System Menu (Alt+Space)"])
    add_button("minimize", [416, 14, 16, 16], lambda f, s: orb(16, "graphite", f, "minimize"), tooltips=["Minimize (Ctrl+I)"])
    add_button("exit", [436, 14, 16, 16], lambda f, s: orb(16, "red", f, "close"), tooltips=["Exit (Alt+F4)"])
    ctl("text", "title", [28, 88, 286, 16], font={"height": 12, "weight": 700, "italic": False, "face": "Arial"}, color="#eef1f6", tooltips=["Track Title"])
    add_button("settings", [417, 43, 34, 34], lambda f, s: orb(34, "red", f, "gear"), tooltips=["Settings (Ctrl+T)"])
    # pill buttons / drawer sheet
    drawer = Sheet(320)
    dentries = []
    dcontrols = []
    did = [1013]

    def dbtn(action, rect, frame_fn, sets=1, tooltips=None):
        w, h = rect[2], rect[3]
        pos, ents = button_entry(drawer, w, h, frame_fn, sets)
        dentries.extend(ents)
        dcontrols.append({"id": did[0], "type": "button", "action": action, "flags": 0, "hidden": False, "anchor": 5, "rect": rect, "src": list(pos), "sets": sets, "stride_x": w, "stride_y": h, "states": 4, "tooltips": tooltips or [""]})
        did[0] += 1

    dbtn("playlist_drawer", [153, 158, 120, 22], lambda f, s: pill(120, 22, f, "PLAYLIST", chevron="up" if s else "down"), sets=2, tooltips=["Slide Up/Down PlayList (Ctrl+L)", "Slide Up/Down PlayList (Ctrl+L)"])
    dbtn("add_tracks", [202, 120, 56, 20], lambda f, s: pill(56, 20, f, "+ ADD", size=8.5), tooltips=["Add Track (Ctrl+A)"])
    dbtn("add_directory", [266, 120, 64, 20], lambda f, s: pill(64, 20, f, "FOLDER", size=8.5), tooltips=["Add Directory"])
    dbtn("remove_track", [338, 120, 64, 20], lambda f, s: pill(64, 20, f, "REMOVE", size=8.5), tooltips=["Delete Track (Ctrl+D)"])
    sheet_img, sheet_size = player.finish(entries)
    sheet_img.save(os.path.join(OUT, "sheet.png"), optimize=True)
    dsheet_img, dsheet_size = drawer.finish(dentries)
    dsheet_img.save(os.path.join(OUT, "drawer_sheet.png"), optimize=True)
    build_player_background().save(os.path.join(OUT, "background.png"), optimize=True)
    build_drawer_background().save(os.path.join(OUT, "drawer_background.png"), optimize=True)

    accel = lambda key, mods, cmd, action: {"key": key, "modifiers": mods, "command": cmd, "action": action}
    ids = {c["action"]: c["id"] for c in controls}
    dids = {c["action"]: c["id"] for c in dcontrols}
    skin = {
        "format": "oozic-skin/1",
        "name": "modern",
        "title": "Modern (Oozic 2026)",
        "filter": "linear",
        "generated_by": "native-player/tools/make_modern_skin.py (programmatic, 2x art)",
        "player": {
            "size": [PLAYER_W, PLAYER_H],
            "min_size": [PLAYER_W, PLAYER_H],
            "scale": S,
            "sheet": "sheet.png",
            "sheet_size": list(sheet_size),
            "background": "background.png",
            "controls": controls,
            "fonts": {},
            "accelerators": [
                accel("P", ["ctrl"], ids["play"], "play"), accel("S", ["ctrl"], ids["stop"], "stop"),
                accel("P", ["ctrl"], ids["pause"], "pause"), accel("M", ["ctrl"], ids["mute"], "mute"),
                accel(" ", ["alt"], ids["system_menu"], "system_menu"), accel("I", ["ctrl"], ids["minimize"], "minimize"),
                accel("T", ["ctrl"], ids["settings"], "settings"),
            ],
        },
        "drawer": {
            "size": [DRAWER_W, DRAWER_H],
            "min_size": [DRAWER_W, DRAWER_H],
            "scale": S,
            "sheet": "drawer_sheet.png",
            "sheet_size": list(dsheet_size),
            "background": "drawer_background.png",
            "controls": dcontrols,
            "fonts": {},
            "accelerators": [
                accel("L", ["ctrl"], dids["playlist_drawer"], "playlist_drawer"),
                accel("A", ["ctrl"], dids["add_tracks"], "add_tracks"),
                accel("D", ["ctrl"], dids["remove_track"], "remove_track"),
            ],
        },
        "extras": {
            "lcd": {"rect": [36, 40, 270, 42], "layout": "modern", "color": "#f1f4f8", "dim": "#8791a0", "accent": RED, "font_size": 11},
            "buttons": [
                {"action": "previous", "rect": [24, 132, 24, 22], "tooltip": "Previous track (Ctrl+B)"},
                {"action": "next", "rect": [50, 132, 24, 22], "tooltip": "Next track (Ctrl+N)"},
                {"action": "shuffle", "rect": [84, 132, 24, 22], "tooltip": "Shuffle"},
                {"action": "repeat", "rect": [110, 132, 24, 22], "tooltip": "Loop (Ctrl+O)"},
                {"action": "open_visualiser", "rect": [136, 132, 24, 22], "tooltip": "Show visualiser"},
                {"action": "scene_menu", "rect": [162, 132, 24, 22], "tooltip": "Choose scene"},
            ],
            "glyph_color": GLYPH,
            "drawer_attach": list(DRAWER_ATTACH),
            "drawer_peek": DRAWER_PEEK,
            "drawer_list": {"rect": [30, 34, 366, 76], "color": "#e1e7f0", "selected": RED, "current": "#ff6a5c", "font_size": 12},
        },
        "notes": "Generated art. Rects are logical (1x); sheets and backgrounds are 2x. Window shape comes from the background alpha (rounded body, soft shadow below the hit threshold).",
    }
    with open(os.path.join(OUT, "skin.json"), "w") as fh:
        json.dump(skin, fh, indent=1)
    print("wrote", OUT, "sheet", sheet_size, "drawer sheet", dsheet_size)


if __name__ == "__main__":
    main()
