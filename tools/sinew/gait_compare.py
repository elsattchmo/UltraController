"""Compare Sinew's gait against the reference clips (captures from demo/tours/sinew_gait_compare.gd).

    python tools/sinew/gait_compare.py <capture dir> [walk jog sprint]

<capture dir>/<pace>_clip and <pace>_gait each hold frames.json + f####.png (an orthographic side view
locked to the character). Strides are found the same way in both: phase 0 = the left ankle at its
furthest forward (heel strike). Writes <pace>_strip.png (reference over gait at 8 phases),
<pace>_overlay.png (reference red, gait cyan: where they agree it's grey) and prints per-phase numbers.
"""
import json
import math
import os
import sys

from PIL import Image, ImageChops, ImageOps

PHASES = 8
BUCKETS = 16


def load(d):
    with open(os.path.join(d, "frames.json")) as f:
        return json.load(f)


def v(a, b):
    return [b[0] - a[0], b[1] - a[1], b[2] - a[2]]


def ang(u, w):
    nu = math.sqrt(sum(x * x for x in u))
    nw = math.sqrt(sum(x * x for x in w))
    if nu < 1e-6 or nw < 1e-6:
        return 0.0
    c = max(-1.0, min(1.0, sum(a * b for a, b in zip(u, w)) / (nu * nw)))
    return math.degrees(math.acos(c))


def sag(u):
    """Angle in the side (forward/up) plane from straight down, + = forward (degrees)."""
    return math.degrees(math.atan2(u[2], -u[1]))


MOVE = [0.0, 1.0]      # the motion in the character's frame (x right, z forward), from frames.json


def along(p):
    return p[0] * MOVE[0] + p[2] * MOVE[1]


def metrics(b):
    out = {}
    for side, s in (("L", "Left"), ("R", "Right")):
        hip, knee, ankle, toe = b[s + "UpperLeg"], b[s + "LowerLeg"], b[s + "Foot"], b[s + "Toes"]
        out["knee" + side] = ang(v(hip, knee), v(knee, ankle))                # flexion, 0 = straight
        out["hip" + side] = sag(v(hip, knee))                                  # thigh forward of vertical
        out["ankle_h" + side] = ankle[1]
        out["toe_h" + side] = toe[1]
        f = v(ankle, toe)
        out["foot_pitch" + side] = math.degrees(math.atan2(f[1], f[2]))  # + toes up (signed: past vertical reads past 90)
        out["ankle_fwd" + side] = along(ankle) - along(b["Hips"])     # ahead of the hips along the motion
        sh, el = b[s + "UpperArm"], b[s + "LowerArm"]
        out["arm" + side] = sag(v(sh, el))
    out["pelvis_h"] = b["Hips"][1]
    out["gap"] = abs(b["LeftFoot"][0] - b["RightFoot"][0])                    # feet apart, sideways
    t = v(b["Hips"], b["Head"])
    out["trunk_lean"] = math.degrees(math.atan2(t[2], t[1]))                   # + leaning forward
    return out


def strides(frames):
    """Frame indices where the left ankle is furthest forward (a local max over +-8 frames)."""
    z = [along(f["bones"]["LeftFoot"]) - along(f["bones"]["Hips"]) for f in frames]
    out = []
    for i in range(8, len(z) - 8):
        if z[i] == max(z[i - 8:i + 9]) and (not out or i - out[-1] > 12):
            out.append(i)
    return out


def phased(frames):
    s = strides(frames)
    if len(s) < 2:
        return [], 0.0, s
    period = (s[-1] - s[0]) / (len(s) - 1)
    out = []
    for i, f in enumerate(frames):
        k = max([j for j in s if j <= i], default=None)
        if k is None:
            continue
        out.append(((i - k) / period % 1.0, i))
    return out, period, s


def table(frames, ph):
    acc = [dict() for _ in range(BUCKETS)]
    cnt = [0] * BUCKETS
    for p, i in ph:
        b = int(p * BUCKETS) % BUCKETS
        m = metrics(frames[i]["bones"])
        for k, x in m.items():
            acc[b][k] = acc[b].get(k, 0.0) + x
        cnt[b] += 1
    return [{k: x / max(cnt[b], 1) for k, x in acc[b].items()} for b in range(BUCKETS)]


def pick(ph, s, phase):
    """The frame nearest `phase` in the second captured stride (else the first)."""
    lo = s[1] if len(s) > 2 else s[0]
    best, bd = None, 9.0
    for p, i in ph:
        if i < lo:
            continue
        d = min(abs(p - phase), 1.0 - abs(p - phase))
        if d < bd:
            best, bd = i, d
    return best


def compare(root, pace):
    dc, dg = os.path.join(root, pace + "_clip"), os.path.join(root, pace + "_gait")
    c, g = load(dc), load(dg)
    MOVE[:] = c.get("move", [0.0, 1.0])
    fc, fg = c["frames"], g["frames"]
    pc, per_c, sc = phased(fc)
    pg, per_g, sg = phased(fg)
    if not pc or not pg:
        print(pace, ": not enough strides", len(sc), len(sg))
        return
    speed_c = sum(f["speed"] for f in fc) / len(fc)
    speed_g = sum(f["speed"] for f in fg) / len(fg)
    print("\n=== %s: speed clip %.2f / gait %.2f m/s; stride %.2f / %.2f s (%.2f / %.2f m), cadence %.2f / %.2f steps/s" % (
        pace, speed_c, speed_g, per_c / 60, per_g / 60, speed_c * per_c / 60, speed_g * per_g / 60,
        120.0 / per_c, 120.0 / per_g))
    tc, tg = table(fc, pc), table(fg, pg)
    keys = ["kneeL", "hipL", "ankle_hL", "toe_hL", "foot_pitchL", "ankle_fwdL", "gap", "pelvis_h", "trunk_lean", "armL"]
    print("phase " + " ".join("%22s" % k for k in keys))
    worst = {k: 0.0 for k in keys}
    for b in range(BUCKETS):
        row = []
        for k in keys:
            a, x = tc[b].get(k, 0.0), tg[b].get(k, 0.0)
            worst[k] = max(worst[k], abs(x - a))
            unit = 100.0 if k in ("ankle_hL", "toe_hL", "ankle_fwdL", "gap", "pelvis_h") else 1.0
            row.append("%7.1f %6.1f (%+6.1f)" % (a * unit, x * unit, (x - a) * unit))
        print("%4.2f  " % (b / BUCKETS) + " ".join(row))
    print("worst |gait - clip|: " + ", ".join("%s %.1f%s" % (k, worst[k] * (100 if k in ("ankle_hL", "toe_hL", "ankle_fwdL", "gap", "pelvis_h") else 1),
          " cm" if k in ("ankle_hL", "toe_hL", "ankle_fwdL", "gap", "pelvis_h") else " deg") for k in keys))
    # Pictures.
    strip, over = [], []
    for k in range(PHASES):
        ph = k / PHASES
        ic, ig = pick(pc, sc, ph), pick(pg, sg, ph)
        a = Image.open(os.path.join(dc, fc[ic]["image"])).convert("RGB")
        b = Image.open(os.path.join(dg, fg[ig]["image"])).convert("RGB")
        strip.append((a, b))
        ga, gb = ImageOps.grayscale(a), ImageOps.grayscale(b)
        over.append(Image.merge("RGB", (ga, gb, gb)))     # reference in red, gait in cyan
    w, h = strip[0][0].size
    s = Image.new("RGB", (w * PHASES // 2, h * 2 // 2))
    sheet = Image.new("RGB", (w * PHASES, h * 2), "white")
    for k, (a, b) in enumerate(strip):
        sheet.paste(a, (k * w, 0))
        sheet.paste(b, (k * w, h))
    sheet = sheet.resize((sheet.width // 2, sheet.height // 2))
    sheet.save(os.path.join(root, pace + "_strip.png"))
    ov = Image.new("RGB", (w * PHASES, h), "white")
    for k, o in enumerate(over):
        ov.paste(o, (k * w, 0))
    ov = ov.resize((ov.width // 2, ov.height // 2))
    ov.save(os.path.join(root, pace + "_overlay.png"))


if __name__ == "__main__":
    root = sys.argv[1]
    for pace in sys.argv[2:] or sorted(d[:-5] for d in os.listdir(root) if d.endswith("_clip")):
        if os.path.isdir(os.path.join(root, pace + "_clip")) and os.path.isdir(os.path.join(root, pace + "_gait")):
            compare(root, pace)
