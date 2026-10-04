#!/usr/bin/env python3
"""Map recovered textures (research/oozic/assets/recovered-textures/**) to the scene
packages that reference them but lack them. Copies files (originals untouched) to
native-player/modern_assets/recovered/<set>/<scene>/<name> and writes
native-player/modern_assets/recovered/texture-map.json.

A texture is "referenced" if a line of the scene's lava.ashex (or lava.lvc) is a bare
image filename. It is "missing" if no file with that stem exists in the scene folder
or scenes/shared-textures. Matching to recovered files is by case-insensitive stem;
the source package whose name equals the scene name wins, else a stable preference order.
"""
import json, re, shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCENES = ROOT / "native-player/scenes"
REC = ROOT / "research/oozic/assets/recovered-textures"
OUT = ROOT / "native-player/modern_assets/recovered"
EXT = (".bmp", ".jpg", ".jpeg", ".png", ".tga")
SRC_PREF = ["sb-live-platinum-application-cd", "creative-audigy-2201US0003071-oozic", "creative-dap-jukebox-software"]
# manual evidence-based overrides: (scene, stem) -> recovered path (relative to REC)
OVERRIDE = {("LVT2", "bluesky"): "sb-live-platinum-application-cd/LVT7.lvt/bluesky.jpg"}

recovered = {}  # stem -> [paths]
for p in sorted(REC.rglob("*")):
    if p.is_file() and p.suffix.lower() in EXT and p.stat().st_size > 0:
        recovered.setdefault(p.stem.lower(), []).append(p)

shared = {p.stem.lower() for p in (SCENES / "shared-textures").glob("*") if p.suffix.lower() in EXT}

def pick(scene, stem):
    ov = OVERRIDE.get((scene, stem))
    if ov:
        return REC / ov, "override: see recovered/LVT2/bluesky.json"
    c = recovered.get(stem, [])
    if not c:
        return None, None
    def score(p):
        rel = p.relative_to(REC).parts
        pkg = Path(rel[1]).stem.lower()
        same = 0 if pkg == scene.lower() else 1
        src = SRC_PREF.index(rel[0]) if rel[0] in SRC_PREF else 99
        return (same, src, str(p))
    best = sorted(c, key=score)[0]
    return best, ("package name matches scene" if Path(best.relative_to(REC).parts[1]).stem.lower() == scene.lower() else "same-stem file from other package/disc (variants possible)")

tmap, detail, unrecovered = {}, [], {}
for setdir in sorted(d for d in SCENES.iterdir() if d.is_dir() and d.name != "shared-textures"):
    for sc in sorted(d for d in setdir.iterdir() if d.is_dir()):
        names = set()
        for f in ("lava.ashex", "lava.lvc"):
            fp = sc / f
            if fp.exists():
                for line in fp.read_text(errors="ignore").splitlines():
                    line = line.strip()
                    if line.lower().endswith(EXT) and re.fullmatch(r"[\w\-. ()]+", line):
                        names.add(line)
        have = {p.stem.lower() for p in sc.iterdir() if p.suffix.lower() in EXT} | shared
        for n in sorted(names):
            stem = Path(n).stem.lower()
            if stem in have:
                continue
            src, why = pick(sc.name, stem)
            key = f"{setdir.name}/{sc.name}"
            if src is None:
                unrecovered.setdefault(key, []).append(n)
                continue
            dst = OUT / setdir.name / sc.name / (Path(n).stem + src.suffix.lower())
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
            tmap.setdefault(key, {})[n] = str(dst.relative_to(ROOT).as_posix())
            detail.append({"scene": key, "missing": n, "recovered_from": str(src.relative_to(ROOT).as_posix()),
                           "copied_to": str(dst.relative_to(ROOT).as_posix()), "selection": why, "label": "recovered-original"})

OUT.mkdir(parents=True, exist_ok=True)
(OUT / "texture-map.json").write_text(json.dumps(tmap, indent=1, sort_keys=True))
(OUT / "texture-map-detail.json").write_text(json.dumps({"label": "recovered-original", "entries": detail, "still_unrecovered": unrecovered}, indent=1, sort_keys=True))
print(sum(len(v) for v in tmap.values()), "mapped in", len(tmap), "scenes;", sum(len(v) for v in unrecovered.values()), "unrecovered refs")
for k, v in unrecovered.items(): print(" unrecovered", k, v)
