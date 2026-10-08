#!/usr/bin/env python3
"""Contact sheets for demo/tours/marksman_moves_review.gd: one sheet per stance and posture, a row per direction
(idle, f, fr, r, br, b, bl, l, fl), the frames of that move left to right, scaled down.
  python3 tools/marksman/contact_sheet.py <tour out dir> [scale]"""
import glob
import os
import sys

from PIL import Image, ImageDraw

DIRS = ["idle", "f", "fr", "r", "br", "b", "bl", "l", "fl"]


def main() -> None:
    src = sys.argv[1]
    scale = float(sys.argv[2]) if len(sys.argv) > 2 else 0.35
    groups = sorted({"_".join(os.path.basename(p).split("_")[:2]) for p in glob.glob(os.path.join(src, "*_*_*_*.png"))})
    for g in groups:
        rows = []
        for d in DIRS:
            files = sorted(glob.glob(os.path.join(src, f"{g}_{d}_*.png")))
            if files:
                rows.append((d, [Image.open(f) for f in files]))
        if not rows:
            continue
        w, h = rows[0][1][0].size
        tw, th = int(w * scale), int(h * scale)
        cols = max(len(r[1]) for r in rows)
        sheet = Image.new("RGB", (tw * cols + 40, th * len(rows)), "white")
        draw = ImageDraw.Draw(sheet)
        for ri, (d, ims) in enumerate(rows):
            draw.text((4, ri * th + th // 2), d, fill="black")
            for ci, im in enumerate(ims):
                sheet.paste(im.resize((tw, th)), (40 + ci * tw, ri * th))
        out = os.path.join(src, f"sheet_{g}.png")
        sheet.save(out)
        print(out)


if __name__ == "__main__":
    main()
