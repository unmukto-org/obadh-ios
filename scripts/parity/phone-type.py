#!/usr/bin/env python3
"""Compare iPhone home-row glyphs without assuming a font from its x-height.

Usage: phone-type.py NATIVE.png OBADH.png --width 440 [--font-dir RUNTIME_FONTS]
Light-mode portrait screenshots with the probe enabled for Obadh are required.
Optional font candidates are rendered from local runtime assets for diagnosis;
font files are never copied into the app. Shape scores are evidence, not a
promise about Apple's private keyboard implementation.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFont

spec = importlib.util.spec_from_file_location("geometry", Path(__file__).with_name("measure.py"))
geometry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(geometry)
LETTERS = "asdfghjkl"


def crop_ink(mask):
    y, x = np.where(mask)
    if len(y) == 0:
        raise ValueError("No glyph ink in key")
    return mask[y.min():y.max()+1, x.min():x.max()+1]


def glyphs(path, width, obadh):
    geo = geometry.measure_geometry(path, width, obadh)
    if geo is None:
        raise ValueError(f"Cannot establish keyboard geometry in {path}")
    a = np.array(Image.open(path).convert("L"))
    scale = a.shape[1] / width
    pitch = 54 if width < 410 else 56
    y = int((geo["q"] + pitch + 8) * scale)
    # At a horizontal slice through the upper key interior, runs of light fill
    # identify the nine home-row keys independently of their horizontal spacing.
    edges = np.flatnonzero(np.diff(np.r_[False, a[y] > 230, False]))
    spans = [np.arange(start, end) for start, end in edges.reshape(-1, 2)]
    spans = [x for x in spans if 20*scale < len(x) < 65*scale]
    if len(spans) != 9:
        raise ValueError(f"Expected nine home-row keys, found {len(spans)} in {path}")
    result = {}
    for letter, x in zip(LETTERS, spans):
        top = int((geo["q"] + pitch + 5) * scale)
        bottom = int((geo["q"] + pitch + (43 if width < 410 else 45) - 5) * scale)
        mask = a[top:bottom, x[0]+int(3*scale):x[-1]-int(3*scale)] < 120
        result[letter] = crop_ink(mask)
    return result, scale


def similarity(a, b):
    # Translate only. Scaling to fit would hide the size error being investigated.
    size = max(*a.shape, *b.shape) + 10
    aa = np.zeros((size, size), bool)
    bb = np.zeros_like(aa)
    ay, ax = (size-a.shape[0])//2, (size-a.shape[1])//2
    by, bx = (size-b.shape[0])//2, (size-b.shape[1])//2
    aa[ay:ay+a.shape[0], ax:ax+a.shape[1]] = a
    bb[by:by+b.shape[0], bx:bx+b.shape[1]] = b
    return max(float(np.logical_and(aa, np.roll(bb, (dy,dx), (0,1))).sum()) /
               float(np.logical_or(aa, np.roll(bb, (dy,dx), (0,1))).sum())
               for dy in [-1,0,1] for dx in [-1,0,1])


def candidate(font_path, size, scale, weight):
    font = ImageFont.truetype(str(font_path), round(size*scale))
    if font_path.name == "SFCompact.ttf":
        font.set_variation_by_axes([20, 400, weight])
    else:
        font.set_variation_by_axes([100, max(17,size), 400, weight])
    out = {}
    for letter in LETTERS:
        image = Image.new("L", (150,150), 255)
        ImageDraw.Draw(image).text((20,20), letter, font=font, fill=0)
        out[letter] = crop_ink(np.array(image)<120)
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("native", type=Path)
    parser.add_argument("obadh", type=Path)
    parser.add_argument("--width", type=float, required=True)
    parser.add_argument("--font-dir", type=Path)
    parser.add_argument("--atlas-dir", type=Path,
                        help="UIKit atlas exported by KeyboardTypographyTests (3x screenshots only)")
    args = parser.parse_args()
    native, scale = glyphs(args.native, args.width, False)
    ours, oscale = glyphs(args.obadh, args.width, True)
    if scale != oscale:
        raise ValueError("Screenshots must have the same pixel scale")
    report = {"native": str(args.native), "obadh": str(args.obadh), "scale": scale,
              "glyphs": {c: {"native_wh_pt": [round(x/scale,2) for x in native[c].shape[::-1]],
                             "obadh_wh_pt": [round(x/scale,2) for x in ours[c].shape[::-1]],
                             "shape_iou": round(similarity(native[c],ours[c]),3)} for c in LETTERS}}
    if args.atlas_dir:
        if scale != 3:
            raise ValueError("UIKit atlas currently renders at 3x; do not resize screenshots to fit")
        scores = []
        letters = "qwertyuiopasdfghjklzxcvbnm123"
        for record in json.loads((args.atlas_dir / "manifest.json").read_text()):
            a = np.array(Image.open(args.atlas_dir / record["file"]).convert("L"))
            rendered = {c: crop_ink(a[:, letters.index(c)*132:(letters.index(c)+1)*132] < 120)
                        for c in LETTERS}
            scores.append({**record,
                "native_iou": round(float(np.mean([similarity(native[c], rendered[c]) for c in LETTERS])), 4),
                "obadh_iou": round(float(np.mean([similarity(ours[c], rendered[c]) for c in LETTERS])), 4)})
        report["uikit_atlas"] = {"native_best": max(scores, key=lambda x: x["native_iou"]),
                                 "obadh_best": max(scores, key=lambda x: x["obadh_iou"])}
    if args.font_dir:
        fits = {}
        for family in ["SFUI.ttf", "SFCompact.ttf"]:
            scores = []
            for size in np.arange(20, 26.01, 0.25):
                for weight in [350,400,450]:
                    rendered = candidate(args.font_dir/family, size, scale, weight)
                    scores.append({"size":float(size), "weight":weight,
                        "native_iou": round(float(np.mean([similarity(native[c],rendered[c]) for c in LETTERS])),4),
                        "obadh_iou": round(float(np.mean([similarity(ours[c],rendered[c]) for c in LETTERS])),4)})
            fits[family] = {"native_best":max(scores,key=lambda x:x["native_iou"]),
                            "obadh_best":max(scores,key=lambda x:x["obadh_iou"])}
        report["candidate_fits"] = fits
    print(json.dumps(report, indent=2))

if __name__ == "__main__":
    main()
