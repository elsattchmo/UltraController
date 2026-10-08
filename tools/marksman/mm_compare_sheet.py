#!/usr/bin/env python3
"""Side-by-side sheets for demo/tours/marksman_mm_review.gd: per stance, a pair of rows per move (gait above,
motion matching below), its frames left to right, scaled down.
  python3 tools/marksman/mm_compare_sheet.py <tour out dir> [scale]   -> <dir>/<stance>_compare_<k>.png"""
import glob
import os
import sys

from PIL import Image, ImageDraw


def main() -> None:
    src = sys.argv[1]
    scale = float(sys.argv[2]) if len(sys.argv) > 2 else 0.3
    for stance in ("unarmed", "rifle"):
        moves = sorted({"_".join(os.path.basename(p).split("_")[1:3]) for p in glob.glob(os.path.join(src, "gait", f"{stance}_*.png"))})
        if not moves:
            continue
        rows = []
        for mv in moves:
            for mode in ("gait", "mm"):
                files = sorted(glob.glob(os.path.join(src, mode, f"{stance}_{mv}_*.png")))
                if files:
                    rows.append((f"{mv} {mode}", [Image.open(f) for f in files]))
        w, h = rows[0][1][0].size
        tw, th = int(w * scale), int(h * scale)
        per = 8  # move pairs per sheet
        for k in range(0, len(rows), per * 2):
            chunk = rows[k:k + per * 2]
            cols = max(len(r[1]) for r in chunk)
            sheet = Image.new("RGB", (tw * cols + 150, th * len(chunk)), "white")
            draw = ImageDraw.Draw(sheet)
            for r, (label, imgs) in enumerate(chunk):
                draw.text((4, r * th + th // 2), label, fill="black" if label.endswith("gait") else "blue")
                for c, im in enumerate(imgs):
                    sheet.paste(im.resize((tw, th)), (150 + c * tw, r * th))
            out = os.path.join(src, f"{stance}_compare_{k // (per * 2)}.png")
            sheet.save(out)
            print(out)


if __name__ == "__main__":
    main()
