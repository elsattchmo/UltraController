"""Turning on the spot, from demo/tours/sinew_turn_review.gd captures.

    python tools/sinew/turn_report.py <capture dir> [--sheet]

Per segment (aim +45, +120, ...): the closest the two feet came (ankles and toes, flat), crossings (the left
foot to the right of the right one, in the hips' frame), steps taken, the torso's lag behind the aim
(chest, hips) and how long it took the feet to settle. --sheet writes turn_sheet.png (a frame every 0.15 s).
"""
import json
import math
import os
import sys


def wrap(a):
    return (a + math.pi) % (2 * math.pi) - math.pi


def flat_dist(a, b):
    return math.hypot(a[0] - b[0], a[2] - b[2])


def seg_dist(p0, p1, q0, q1):
    """Closest distance between two flat segments (ankle -> toe of each foot)."""
    best = 9.0
    for k in range(11):
        t = k / 10
        p = [p0[0] + (p1[0] - p0[0]) * t, 0, p0[2] + (p1[2] - p0[2]) * t]
        for j in range(11):
            u = j / 10
            q = [q0[0] + (q1[0] - q0[0]) * u, 0, q0[2] + (q1[2] - q0[2]) * u]
            best = min(best, flat_dist(p, q))
    return best


def main():
    root = sys.argv[1]
    d = json.load(open(os.path.join(root, "frames.json")))
    fr = d["frames"]
    segs = {}
    order = []
    for f in fr:
        segs.setdefault(f["label"], []).append(f)
        if f["label"] not in order:
            order.append(f["label"])
    print("%-18s %8s %8s %6s %6s %9s %9s %9s %8s" % ("segment", "feet min", "cross cm", "steps", "lifts", "chest lag", "hips lag", "feet lag", "settle s"))
    for lab in order:
        fs = segs[lab]
        mind, cross, lifts = 9.0, 0.0, 0
        chest_lag = hips_lag = feet_lag = 0.0
        settle = 0.0
        prev = None
        for i, f in enumerate(fs):
            mind = min(mind, seg_dist(f["lf"], f["lt"], f["rf"], f["rt"]))
            h = f["hips"]
            # In the hips' frame: x to the body's right. Left foot should have the smaller x.
            c, s = math.cos(h), math.sin(h)
            def rx(p):
                return p[0] * c - p[2] * s
            cross = max(cross, rx(f["lf"]) - rx(f["rf"]))
            if prev is not None:
                lifts += (prev["planted_l"] and not f["planted_l"]) + (prev["planted_r"] and not f["planted_r"])
            if not (f["planted_l"] and f["planted_r"]):
                settle = (i + 1) / 60.0
            chest_lag = max(chest_lag, abs(math.degrees(wrap(f["aim"] - f["chest"]))))
            hips_lag = max(hips_lag, abs(math.degrees(wrap(f["aim"] - f["hips"]))))
            feet_yaw = 0.5 * (math.atan2(-(f["lt"][0] - f["lf"][0]), -(f["lt"][2] - f["lf"][2])) +
                              math.atan2(-(f["rt"][0] - f["rf"][0]), -(f["rt"][2] - f["rf"][2])))
            feet_lag = max(feet_lag, abs(math.degrees(wrap(f["aim"] - feet_yaw))))
            prev = f
        end = fs[-1]
        print("%-18s %6.1fcm %8.1f %6s %6d %8.0fd %8.0fd %8.0fd %8.2f   (end: chest %+.0f, hips %+.0f off the aim)" % (
            lab, mind * 100, max(cross, 0) * 100, "", lifts, chest_lag, hips_lag, feet_lag, settle,
            math.degrees(wrap(end["chest"] - end["aim"])), math.degrees(wrap(end["hips"] - end["aim"]))))
    # Moving segments: how the start unfolds (every 0.1 s): speed, travel vs body / hips / feet facing.
    for lab in order:
        fs = segs[lab]
        if not any(math.hypot(*f.get("vel", [0, 0])) > 0.2 for f in fs):
            continue
        print("\n%s: t  speed  travel  body  hips  chest  feet(L/R)  planted" % lab)
        for i in range(0, len(fs), 6):
            f = fs[i]
            v = f["vel"]
            sp = math.hypot(*v)
            trav = math.degrees(math.atan2(-v[0], -v[1])) if sp > 0.05 else float("nan")
            yl = math.degrees(math.atan2(-(f["lt"][0] - f["lf"][0]), -(f["lt"][2] - f["lf"][2])))
            yr = math.degrees(math.atan2(-(f["rt"][0] - f["rf"][0]), -(f["rt"][2] - f["rf"][2])))
            print("  %.1f %5.2f %7.0f %5.0f %5.0f %6.0f %5.0f/%-5.0f %s%s" % (i / 60, sp, trav, math.degrees(f["body"]), math.degrees(f["hips"]),
                  math.degrees(f["chest"]), yl, yr, "L" if f["planted_l"] else "-", "R" if f["planted_r"] else "-"))
    if "--sheet" in sys.argv:
        from PIL import Image
        imgs = [f for f in fr if "image" in f]
        pick = imgs[::3]
        ims = [Image.open(os.path.join(root, f["image"])).convert("RGB") for f in pick]
        w, h = ims[0].size
        cols = 10
        rows = (len(ims) + cols - 1) // cols
        sheet = Image.new("RGB", (w * cols // 3, h * rows // 3), "white")
        for k, im in enumerate(ims):
            sheet.paste(im.resize((w // 3, h // 3)), ((k % cols) * w // 3, (k // cols) * h // 3))
        sheet.save(os.path.join(root, "turn_sheet.png"))
        print("sheet:", os.path.join(root, "turn_sheet.png"), len(ims), "frames")


if __name__ == "__main__":
    main()
