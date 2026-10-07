"""Measures the moves filmed by demo/tours/sinew_moves_review.gd.

    python tools/sinew/moves_report.py <capture dir> [--strips]

Per segment:
  legs gap   - closest the two legs come, as capsules (thigh, shin, foot), minus their radii (cm; < 0 = through)
  overlap    - ticks the legs are through each other
  splay      - furthest a foot gets from under the hips (m)
  leg speed  - fastest an ankle moves relative to the hips (m/s): "flying legs"
  steps      - touchdowns, and the step lengths of the first five (m)
  hips drop  - lowest the hips get below their standing height (cm)
Standing segments are compared with their "(clip)" twin (the clip alone): feet width, feet yaw, hips height,
knee bend, chest / hips facing off the aim.
--strips writes <segment>.png: a frame every 0.15 s.
"""
import json
import math
import os
import sys

RADIUS = {"thigh": 0.075, "shin": 0.055, "foot": 0.045}
SEGS = {"thigh": ("UpperLeg", "LowerLeg"), "shin": ("LowerLeg", "Foot"), "foot": ("Foot", "Toes")}


def sub(a, b):
    return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def norm(a):
    return math.sqrt(dot(a, a))


def seg_seg(p1, q1, p2, q2):
    """Closest distance between segments p1q1 and p2q2."""
    d1, d2, r = sub(q1, p1), sub(q2, p2), sub(p1, p2)
    a, e, f = dot(d1, d1), dot(d2, d2), dot(d2, r)
    if a < 1e-9 and e < 1e-9:
        return norm(r)
    if a < 1e-9:
        s, t = 0.0, max(0.0, min(1.0, f / e))
    else:
        c = dot(d1, r)
        if e < 1e-9:
            t, s = 0.0, max(0.0, min(1.0, -c / a))
        else:
            b = dot(d1, d2)
            den = a * e - b * b
            s = max(0.0, min(1.0, (b * f - c * e) / den)) if den > 1e-9 else 0.0
            t = (b * s + f) / e
            if t < 0:
                t, s = 0.0, max(0.0, min(1.0, -c / a))
            elif t > 1:
                t, s = 1.0, max(0.0, min(1.0, (b - c) / a))
    c1 = [p1[k] + d1[k] * s for k in range(3)]
    c2 = [p2[k] + d2[k] * t for k in range(3)]
    return norm(sub(c1, c2))


def legs_gap(b):
    best = 9.0
    for na, (a0, a1) in SEGS.items():
        for nb, (b0, b1) in SEGS.items():
            d = seg_seg(b["Left" + a0], b["Left" + a1], b["Right" + b0], b["Right" + b1]) - RADIUS[na] - RADIUS[nb]
            best = min(best, d)
    return best


def wrap(a):
    return (a + math.pi) % (2 * math.pi) - math.pi


def facing(l, r):
    """Facing (yaw, Godot convention: 0 = -Z) of a left/right pair."""
    lx, lz = l[0] - r[0], l[2] - r[2]      # points to the body's left
    fx, fz = -lz, lx                      # left x up -> forward (left rotated -90 deg about up)
    return math.atan2(-fx, -fz)


def foot_yaw(a, t):
    return math.atan2(-(t[0] - a[0]), -(t[2] - a[2]))


def knee(b, s):
    u, v = sub(b[s + "LowerLeg"], b[s + "UpperLeg"]), sub(b[s + "Foot"], b[s + "LowerLeg"])
    return math.degrees(math.acos(max(-1, min(1, dot(u, v) / (norm(u) * norm(v))))))


def stance(fs):
    """Averages of a standing segment's last half."""
    tail = fs[len(fs) // 2:]
    out = {"width": 0, "yaw_l": 0, "yaw_r": 0, "hips_h": 0, "knee": 0, "chest": 0, "hips": 0, "fwd_l": 0, "fwd_r": 0}
    for f in tail:
        b = f["bones"]
        aim = f["aim"]
        out["width"] += math.hypot(b["LeftFoot"][0] - b["RightFoot"][0], b["LeftFoot"][2] - b["RightFoot"][2])
        out["yaw_l"] += math.degrees(wrap(foot_yaw(b["LeftFoot"], b["LeftToes"]) - aim))
        out["yaw_r"] += math.degrees(wrap(foot_yaw(b["RightFoot"], b["RightToes"]) - aim))
        out["hips_h"] += b["Hips"][1] - min(b["LeftToes"][1], b["RightToes"][1])
        out["knee"] += 0.5 * (knee(b, "Left") + knee(b, "Right"))
        out["chest"] += math.degrees(wrap(facing(b["LeftUpperArm"], b["RightUpperArm"]) - aim))
        out["hips"] += math.degrees(wrap(facing(b["LeftUpperLeg"], b["RightUpperLeg"]) - aim))
    return {k: v / len(tail) for k, v in out.items()}


def main():
    root = sys.argv[1]
    fr = json.load(open(os.path.join(root, "frames.json")))["frames"]
    segs, order = {}, []
    for f in fr:
        if f["label"] not in segs:
            order.append(f["label"])
        segs.setdefault(f["label"], []).append(f)
    print("%-20s %9s %8s %7s %10s %7s %9s %8s  %s" % ("segment", "legs gap", "overlap", "splay", "leg speed", "steps", "hips drop", "sink", "first steps (m)"))
    stand_h = None
    # The sink probe's own offset (the bones aren't the soles): what the clip reads standing on flat ground.
    base = [x for f in segs.get("idle unarmed (clip)", []) for x in f.get("sink", [])]
    sink0 = sum(base) / len(base) if base else 0.0
    for lab in order:
        fs = segs[lab]
        if lab.startswith("idle unarmed (clip)"):
            stand_h = sum(f["bones"]["Hips"][1] - min(f["bones"]["LeftToes"][1], f["bones"]["RightToes"][1]) for f in fs) / len(fs)
    for lab in order:
        fs = segs[lab]
        gap, over, splay, speed, drop, sink = 9.0, 0, 0.0, 0.0, 0.0, 0.0
        touch, prev = [], None
        for f in fs:
            b = f["bones"]
            sink = max([sink] + [x - sink0 for x in f.get("sink", [])])
            g = legs_gap(b)
            gap = min(gap, g)
            over += g < 0
            h = b["Hips"]
            for s in ("Left", "Right"):
                a = b[s + "Foot"]
                splay = max(splay, math.hypot(a[0] - h[0], a[2] - h[2]))
            if prev:
                pb = prev["bones"]
                for s in ("Left", "Right"):
                    rel = sub(b[s + "Foot"], b["Hips"])
                    prel = sub(pb[s + "Foot"], pb["Hips"])
                    speed = max(speed, norm(sub(rel, prel)) * 60.0)
                for side, key in (("Left", "planted_l"), ("Right", "planted_r")):
                    if f[key] and not prev[key]:
                        touch.append(b[side + "Foot"])
            if stand_h:
                drop = max(drop, stand_h - (h[1] - min(b["LeftToes"][1], b["RightToes"][1])))
            prev = f
        steps = [math.hypot(touch[k][0] - touch[k - 1][0], touch[k][2] - touch[k - 1][2]) for k in range(1, min(len(touch), 6))]
        print("%-20s %7.1fcm %8d %6.2fm %8.2f/s %7d %7.1fcm %6.1fcm  %s" % (lab, gap * 100, over, splay, speed, len(touch), drop * 100, sink * 100,
              " ".join("%.2f" % x for x in steps)))
    # Standing vs the clip.
    print("\nstanding vs the clip:   width   yaw L / R      hips h   knee   chest / hips off the aim")
    for lab in order:
        if not lab.startswith("idle") or lab.endswith("(clip)"):
            continue
        twin = lab + " (clip)"
        for name in (lab, twin):
            if name in segs:
                s = stance(segs[name])
                print("  %-20s %5.2fm  %+5.0f / %+5.0f  %6.2fm  %4.0f   %+5.0f / %+5.0f" % (name, s["width"], s["yaw_l"], s["yaw_r"], s["hips_h"],
                      s["knee"], s["chest"], s["hips"]))
    if "--strips" in sys.argv:
        from PIL import Image
        for lab in order:
            imgs = [f for f in segs[lab] if "image" in f][::3][:12]
            if not imgs:
                continue
            ims = [Image.open(os.path.join(root, f["image"])).convert("RGB") for f in imgs]
            w, h = ims[0].size
            sheet = Image.new("RGB", (w * len(ims), h), "white")
            for k, im in enumerate(ims):
                sheet.paste(im, (k * w, 0))
            sheet = sheet.resize((sheet.width * 2 // 5, sheet.height * 2 // 5))
            name = "".join(ch if ch.isalnum() else "_" for ch in lab)
            sheet.save(os.path.join(root, name + ".png"))


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        pass
