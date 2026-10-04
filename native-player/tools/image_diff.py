#!/usr/bin/env python3
"""Per-image pixel diff between two sweep folders (stdlib only: no numpy/PIL).

usage: image_diff.py <reference_dir> <candidate_dir> [--json out.json] [--heatmap dir]

For every PNG present in both folders: mean absolute difference and the 95th
percentile / max of the per-pixel max-channel absolute difference (0..255),
plus the share of pixels differing by more than 8. Used for the Phase 4c
Classic renderer migration check (Compatibility vs Forward+).
"""
import json, os, struct, sys, zlib


def read_png(path):
    data = open(path, 'rb').read()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', path
    pos, idat, width = 8, [], 0
    while pos < len(data):
        length, kind = struct.unpack('>I4s', data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if kind == b'IHDR':
            width, height, depth, ctype = struct.unpack('>IIBB', body[:10])
            assert depth == 8 and ctype in (2, 6), (depth, ctype)
            bpp = 3 if ctype == 2 else 4
        elif kind == b'IDAT':
            idat.append(body)
        pos += 12 + length
    raw = zlib.decompress(b''.join(idat))
    stride = width * bpp
    out = bytearray(height * stride)
    prev = bytearray(stride)
    i = 0
    for y in range(height):
        f = raw[i]; i += 1
        line = bytearray(raw[i:i + stride]); i += stride
        if f == 1:
            for x in range(bpp, stride): line[x] = (line[x] + line[x - bpp]) & 255
        elif f == 2:
            for x in range(stride): line[x] = (line[x] + prev[x]) & 255
        elif f == 3:
            for x in range(stride): line[x] = (line[x] + ((line[x - bpp] if x >= bpp else 0) + prev[x]) // 2) & 255
        elif f == 4:
            for x in range(stride):
                a = line[x - bpp] if x >= bpp else 0
                b = prev[x]; c = prev[x - bpp] if x >= bpp else 0
                p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else (b if pb <= pc else c))) & 255
        out[y * stride:(y + 1) * stride] = line
        prev = line
    if bpp == 4:  # drop alpha
        rgb = bytearray(width * height * 3)
        rgb[0::3] = out[0::4]; rgb[1::3] = out[1::4]; rgb[2::3] = out[2::4]
        out = rgb
    return width, height, bytes(out)


def compare(a_path, b_path):
    wa, ha, a = read_png(a_path)
    wb, hb, b = read_png(b_path)
    if (wa, ha) != (wb, hb):
        return {"error": "size %dx%d vs %dx%d" % (wa, ha, wb, hb)}
    hist = [0] * 256
    total = 0
    for i in range(0, len(a), 3):
        d0 = abs(a[i] - b[i]); d1 = abs(a[i + 1] - b[i + 1]); d2 = abs(a[i + 2] - b[i + 2])
        total += d0 + d1 + d2
        hist[max(d0, d1, d2)] += 1
    n = wa * ha
    acc, p95 = 0, 0
    for v, c in enumerate(hist):
        acc += c
        if acc >= 0.95 * n:
            p95 = v
            break
    mx = max(v for v, c in enumerate(hist) if c)
    over8 = sum(hist[9:]) / n
    return {"mean_abs": round(total / (3 * n), 3), "p95_max_channel": p95, "max": mx, "share_over_8": round(over8, 5)}


def main():
    ref, cand = sys.argv[1], sys.argv[2]
    out_json = sys.argv[sys.argv.index('--json') + 1] if '--json' in sys.argv else None
    results = {}
    for name in sorted(os.listdir(ref)):
        if not name.endswith('.png') or not os.path.exists(os.path.join(cand, name)):
            continue
        results[name] = compare(os.path.join(ref, name), os.path.join(cand, name))
        r = results[name]
        print("%-40s %s" % (name, r if 'error' in r else "mean %.3f  p95 %d  max %d  >8: %.3f%%" % (r['mean_abs'], r['p95_max_channel'], r['max'], 100 * r['share_over_8'])))
    if out_json:
        json.dump(results, open(out_json, 'w'), indent=1)


if __name__ == '__main__':
    main()
