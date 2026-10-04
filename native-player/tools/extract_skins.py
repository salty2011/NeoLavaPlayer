#!/usr/bin/env python3
"""Static extractor for original LAVA 2.5 / Oozic 3 player skins (.skn).

The .skn files are resource-only PE DLLs. Nothing is executed: the PE
resource directory is parsed with `pefile` and the resources are decoded here.

  RT_BITMAP 3200          sprite sheet (8-bit DIB, magenta #FF00FF = transparent)
  "RGN" / "BACKGROUND"    RGNDATA: window shape as a list of rectangles
  RT_STRING 2000/2001     window width/height (2002/2003: min size, equal here)
  RT_STRING 2101          background: bmp,srcX,srcY,w,h
  RT_STRING 2200..        control records (see parse_control)
  RT_STRING 4000..        fonts: LOGFONT-like "height,..,weight,..,face"
  RT_STRING 5000..        tooltips (a multi-state control uses tooltip+state)
  RT_ACCELERATOR          keyboard accelerators (informational)

Output per skin folder (native-player/skins/<name>/):
  sheet.png        player sprite sheet, magenta keyed to alpha 0
  background.png   player background crop, alpha = RGN region AND not magenta
  drawer_sheet.png / drawer_background.png   playlist drawer (LavaPL / OZPL3)
  skin.json        layout consumed by skin_view.gd

Field meanings marked "inferred" come from comparing the records with the
sprite sheet, not from disassembly of the skin engine. See
native-player/docs/WINDOWS_AND_BUS.md ("Skin format").

Usage (from the repository root, with the research venv):
  research/oozic/.tools/bin/python3 native-player/tools/extract_skins.py
"""
import json
import os
import struct
import sys
import zlib

import pefile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ASSETS = os.path.join(ROOT, "research", "oozic", "assets")
OUT = os.path.join(ROOT, "native-player", "skins")

SKINS = {
    "classic": {
        "title": "Classic (LAVA! 2.5)",
        "player": "lava25/extracted/Skin_Files/LavaPlay.skn",
        "drawer": "lava25/extracted/Skin_Files/LavaPL.skn",
        # Our additions (not in the original skin): LAVA 2.5 had no
        # previous/next/loop/shuffle buttons and no scene name display on the
        # player, so they are drawn as small glyphs in the grey display panel.
        "extras": {
            "lcd": {"rect": [24, 46, 230, 52], "color": "#04649d", "dim": "#5b7f99", "font_size": 11},
            "buttons": [
                {"action": "previous", "rect": [148, 84, 18, 14], "tooltip": "Previous track (Ctrl+B)"},
                {"action": "next", "rect": [168, 84, 18, 14], "tooltip": "Next track (Ctrl+N)"},
                {"action": "shuffle", "rect": [194, 84, 18, 14], "tooltip": "Shuffle"},
                {"action": "repeat", "rect": [214, 84, 18, 14], "tooltip": "Loop (Ctrl+O)"},
                {"action": "open_visualiser", "rect": [234, 84, 18, 14], "tooltip": "Show visualiser"},
            ],
            "glyph_color": "#04649d",
            "drawer_attach": [8, 116],
            "drawer_peek": 34,
            "drawer_list": {"rect": [12, 26, 245, 74], "color": "#1e2a33", "selected": "#04649d", "current": "#c0141e", "font_size": 11},
        },
    },
    "oozic3": {
        "title": "Oozic 3",
        "player": "oozic30/extracted/Oozic_Player/OZPlay3.skn",
        "drawer": "oozic30/extracted/Oozic_Player/OZPL3.skn",
        "extras": {
            "lcd": {"rect": [14, 26, 234, 54], "color": "#e8eef4", "dim": "#8fa0ae", "font_size": 11},
            "buttons": [
                {"action": "shuffle", "rect": [210, 64, 18, 14], "tooltip": "Shuffle"},
                {"action": "open_visualiser", "rect": [230, 64, 18, 14], "tooltip": "Show visualiser"},
            ],
            "glyph_color": "#e8eef4",
            "drawer_attach": [70, 150],
            "drawer_peek": 46,
            "drawer_list": {"rect": [14, 22, 240, 72], "color": "#1e2a33", "selected": "#2c5f8a", "current": "#c0141e", "font_size": 11},
        },
    },
}

# Control id -> action. Ids are shared between LavaPlay/OZPlay3 and LavaPL/OZPL3
# (their tooltips name them; e.g. 1000 "Play (Ctrl+P)").
ACTIONS = {
    1000: "play", 1001: "stop", 1002: "pause", 1003: "progress", 1004: "volume",
    1005: "mute", 1006: "system_menu", 1007: "minimize", 1008: "exit",
    1009: "title", 1010: "time", 1011: "status", 1012: "settings",
    1013: "playlist_drawer", 1014: "add_tracks", 1015: "remove_track",
    1016: "unused", 1017: "repeat", 1018: "add_directory", 1019: "next", 1020: "previous",
}
TYPES = {0: "button", 1: "button", 2: "slider", 3: "text"}
HIDDEN_FLAG = 0x1000  # inferred: hidden controls share one dummy rect


def resources(pe):
    found = {}
    for kind in pe.DIRECTORY_ENTRY_RESOURCE.entries:
        kind_key = str(kind.name) if kind.name else kind.id
        for entry in kind.directory.entries:
            name_key = str(entry.name) if entry.name else entry.id
            data = entry.directory.entries[0].data.struct
            found[(kind_key, name_key)] = pe.get_data(data.OffsetToData, data.Size)
    return found


def strings(res):
    table = {}
    for (kind, block), raw in res.items():
        if kind != 6:
            continue
        offset = 0
        for i in range(16):
            length = struct.unpack_from("<H", raw, offset)[0]
            offset += 2
            if length:
                table[(block - 1) * 16 + i] = raw[offset:offset + 2 * length].decode("utf-16le")
            offset += 2 * length
    return table


def accelerators(res):
    out = []
    raw = res.get((9, "ACCELERATORS"), b"")
    for i in range(0, len(raw) - 7, 8):
        flags, key, command, _ = struct.unpack_from("<HHHH", raw, i)
        mods = [name for bit, name in ((0x04, "shift"), (0x08, "ctrl"), (0x10, "alt")) if flags & bit]
        out.append({"key": chr(key) if 32 <= key < 127 and flags & 1 else key, "modifiers": mods, "command": command, "action": ACTIONS.get(command, "")})
    return out


def decode_dib(raw):
    header_size, width, height, _planes, bpp, compression = struct.unpack_from("<IiiHHI", raw, 0)
    if compression != 0 or bpp != 8:
        raise ValueError("unsupported DIB %d bpp compression %d" % (bpp, compression))
    colours = struct.unpack_from("<I", raw, 32)[0] or 256
    palette = [raw[header_size + 4 * i:header_size + 4 * i + 3] for i in range(colours)]
    offset = header_size + 4 * colours
    stride = ((width * bpp + 31) // 32) * 4
    pixels = []
    for y in range(abs(height)):
        row = raw[offset + y * stride:offset + y * stride + width]
        pixels.append([tuple(palette[i][::-1]) for i in row])  # BGR -> RGB
    if height > 0:
        pixels.reverse()
    return width, abs(height), pixels


def region(res):
    raw = res.get(("RGN", "BACKGROUND"))
    if raw is None:
        return None
    size, kind, count, _bytes, left, top, right, bottom = struct.unpack_from("<IIII4i", raw, 0)
    assert size == 32 and kind == 1
    rects = [list(struct.unpack_from("<4i", raw, 32 + 16 * i)) for i in range(count)]
    return {"bounds": [left, top, right, bottom], "rects": rects}


def write_png(path, width, height, rgba_rows):
    raw = b"".join(b"\x00" + bytes(row) for row in rgba_rows)

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    with open(path, "wb") as handle:
        handle.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


MAGENTA = (255, 0, 255)


def is_key(pixel):
    """Colour key: the sheets use (252, 4, 252), i.e. magenta after the 8-bit
    palette's quantisation, so match near-magenta rather than exact #FF00FF."""
    r, g, b = pixel
    return r >= 240 and g <= 16 and b >= 240


def keyed_rows(pixels, x0=0, y0=0, w=None, h=None, mask=None):
    w = w if w is not None else len(pixels[0])
    h = h if h is not None else len(pixels)
    rows = []
    for y in range(h):
        row = bytearray()
        for x in range(w):
            r, g, b = pixels[y0 + y][x0 + x]
            alpha = 0 if is_key((r, g, b)) or (mask is not None and not mask[y][x]) else 255
            row += bytes((r, g, b, alpha) if alpha else (0, 0, 0, 0))
        rows.append(row)
    return rows


def region_mask(rgn, w, h):
    mask = [[False] * w for _ in range(h)]
    for left, top, right, bottom in rgn["rects"]:
        for y in range(max(top, 0), min(bottom, h)):
            for x in range(max(left, 0), min(right, w)):
                mask[y][x] = True
    return mask


def key_mask(pixels, x0, y0, w, h):
    height, width = len(pixels), len(pixels[0])
    return [[(y0 + j < height and x0 + i < width and not is_key(pixels[y0 + j][x0 + i])) for i in range(w)] for j in range(h)]


def mismatch(a, b):
    return sum(1 for ra, rb in zip(a, b) for pa, pb in zip(ra, rb) if pa != pb)


def first_opaque_row(mask):
    for j, row in enumerate(mask):
        if any(row):
            return j
    return len(mask)


def frame_layout(pixels, src_x, src_y, w, h, sets):
    """Inferred: the four visual states sit side by side, separated by 0-3
    columns; extra state sets (mute on/off, loop modes) stack downwards.
    Horizontal gap: the one whose frames' opaque silhouettes best match frame 0
    (states share a silhouette). Vertical gap: the one that puts set 1's first
    opaque row at the same offset as set 0's (sets differ in shape)."""
    base = key_mask(pixels, src_x, src_y, w, h)
    width = len(pixels[0])
    best = None
    for gap in range(4):
        if src_x + 3 * (w + gap) + w > width and gap:
            continue
        score = sum(mismatch(base, key_mask(pixels, src_x + k * (w + gap), src_y, w, h)) for k in range(1, 4))
        if best is None or score < best[0]:
            best = (score, gap)
    gap_x = best[1]
    gap_y = 0
    if sets > 1:
        top = first_opaque_row(base)
        for gap in range(4):
            if first_opaque_row(key_mask(pixels, src_x, src_y + h + gap, w, h)) == top:
                gap_y = gap
                break
    states = sum(1 for k in range(4) if src_x + k * (w + gap_x) + w <= width)
    return {"stride_x": w + gap_x, "stride_y": h + gap_y, "states": states}


def colorref(value):
    value = int(value)
    return "#%02x%02x%02x" % (value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF)


def parse_font(text):
    parts = text.split(",")
    return {"height": abs(int(parts[0])), "weight": int(parts[4]), "italic": parts[5] != "0", "face": parts[-1]}


def anchored_rect(anchor, x, y, w, h, win_w, win_h):
    """Inferred anchor bits: 1 left, 2 right, 4 top, 8 bottom. A right/bottom
    anchored control stores its offset from the right/bottom window edge to its
    left/top edge (LavaPlay Play: anchor 6, x 160 -> left 421-160 = 261, which is
    where the big red ball sits in the background)."""
    left = win_w - x if anchor & 2 else x
    top = win_h - y if anchor & 8 else y
    return [left, top, w, h]


def parse_control(record, table, pixels, win_w, win_h):
    f = [int(v) for v in record.split(",")]
    kind, control_id, flags, anchor, x, y, w, h = f[:8]
    control = {
        "id": control_id,
        "type": TYPES.get(kind, "unknown"),
        "action": ACTIONS.get(control_id, ""),
        "flags": flags,
        "hidden": bool(flags & HIDDEN_FLAG),
        "anchor": anchor,
        "rect": anchored_rect(anchor, x, y, w, h, win_w, win_h),
        "raw": record,
    }
    tooltip_id = f[9]
    if kind in (0, 1):
        sets = max(f[13], 1)
        control.update({"src": [f[11], f[12]], "sets": sets, "tooltips": [table.get(tooltip_id + i, table.get(tooltip_id, "")) for i in range(sets)]})
        control.update(frame_layout(pixels, f[11], f[12], w, h, sets))
    elif kind == 2:
        # Inferred: six rows of w x h; rows 0-2 = track (normal/disabled/hover),
        # rows 3-5 = filled part. f[13] = number of fill steps (77 = per pixel on
        # the 77 px progress bar, 11 ticks on the volume bar).
        control.update({"src": [f[11], f[12]], "steps": max(f[13], 1), "stride_y": h, "colour_raw": f[15], "tooltips": [table.get(tooltip_id, "")]})
    elif kind == 3:
        control.update({"font": parse_font(table.get(f[10], "-11,0,0,0,400,0,0,0,0,3,2,1,34,Arial")), "color": colorref(f[11]), "colour_raw": f[13], "tooltips": [table.get(tooltip_id, "")]})
    return control


def visible_rules(controls):
    """LavaPlay stacks Play and Pause on one rect: show Pause while playing."""
    rects = {}
    for control in controls:
        rects.setdefault(tuple(control["rect"]), []).append(control)
    for group in rects.values():
        actions = {c["action"] for c in group}
        if {"play", "pause"} <= actions:
            for c in group:
                if c["action"] == "play":
                    c["visible_when"] = "not_playing"
                elif c["action"] == "pause":
                    c["visible_when"] = "playing"


def extract_part(path, folder, prefix):
    pe = pefile.PE(path, fast_load=False)
    res = resources(pe)
    table = strings(res)
    width, height, pixels = decode_dib(res[(2, 3200)])
    win_w, win_h = int(table[2000]), int(table[2001])
    bmp, bg_x, bg_y, bg_w, bg_h = [int(v) for v in table[2101].split(",")]
    rgn = region(res)
    mask = region_mask(rgn, bg_w, bg_h) if rgn else None
    write_png(os.path.join(folder, prefix + "sheet.png"), width, height, keyed_rows(pixels))
    write_png(os.path.join(folder, prefix + "background.png"), bg_w, bg_h, keyed_rows(pixels, bg_x, bg_y, bg_w, bg_h, mask))
    count = int(table.get(2014, "0"))
    controls = [parse_control(table[2200 + i], table, pixels, win_w, win_h) for i in range(count) if 2200 + i in table]
    visible_rules(controls)
    fonts = {str(k): parse_font(v) for k, v in table.items() if 4000 <= k < 4100}
    return {
        "source": os.path.relpath(path, ROOT),
        "skin_name": table.get(1000, ""),
        "version": table.get(1001, ""),
        "size": [win_w, win_h],
        "min_size": [int(table.get(2002, win_w)), int(table.get(2003, win_h))],
        "sheet": prefix + "sheet.png",
        "sheet_size": [width, height],
        "background": prefix + "background.png",
        "background_src": [bg_x, bg_y, bg_w, bg_h],
        "region": rgn,
        "controls": controls,
        "fonts": fonts,
        "accelerators": accelerators(res),
        "unknown_strings": {str(k): table[k] for k in (1002, 2010, 2012, 2013) if k in table},
    }


def main():
    for name, spec in SKINS.items():
        folder = os.path.join(OUT, name)
        os.makedirs(folder, exist_ok=True)
        player = extract_part(os.path.join(ASSETS, spec["player"]), folder, "")
        drawer = extract_part(os.path.join(ASSETS, spec["drawer"]), folder, "drawer_")
        layout = {
            "format": "oozic-skin/1",
            "name": name,
            "title": spec["title"],
            "generated_by": "native-player/tools/extract_skins.py (static PE resource parse)",
            "player": player,
            "drawer": drawer,
            "extras": spec["extras"],
            "notes": "extras are additions for this recreation (not in the original skin). Anchor, frame-state order (normal, disabled, hover, pressed), slider rows and hidden flag are inferred from the sprite sheet.",
        }
        with open(os.path.join(folder, "skin.json"), "w") as handle:
            json.dump(layout, handle, indent=1)
        print("%s: player %s %d controls, drawer %s %d controls" % (name, player["size"], len(player["controls"]), drawer["size"], len(drawer["controls"])))


if __name__ == "__main__":
    sys.exit(main())
