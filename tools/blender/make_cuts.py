"""Pre-cut a humanoid for dismemberment (Blender 5.0, headless). Called by ultra_blender.py:

    blender --background --python tools/blender/ultra_blender.py -- make-cuts
        [--src assets/characters/mannequin/mannequin.glb]
        [--bone-map addons/ultra_controller/import/bone_maps/ue_mannequin_humanoid.tres]
        [--out assets/characters/mannequin/mannequin_cuts.glb]

The character's skinned mesh is split in its bind pose at every joint a limb can come off at
(neck, shoulders, elbows, wrists, hips, knees, ankles): a plane through the joint, square to the
limb, cuts only the faces that move with that limb (weighted to it), so nothing of the torso is
sliced at the armpit / hip. Out comes, all skinned to the same armature:
  Seg.<REGION>          the skin of each body region (Seg.TORSO, Seg.HEAD incl. the neck ...)
  Cap.<REGION>.stump    the cut's end left on the body (weighted to the bone it hangs on)
  Cap.<REGION>.end      the cut's end on the part that comes off (weighted to its root)
  Chunk.HEAD.<k>        the head broken into chunks, each closed (for a head blown apart)
  Seg.TORSO_OPEN        the torso with the belly blown open into a cavity
  Seg.WAIST_UP / _DOWN  the torso in two at the waist, Cap.WAIST.up / .down sealing them
Caps: the real boundary loop of the cut, a thin band of fat, the meat domed out, the bone(s)
snapped off in it with marrow. Materials CutFat / CutMeat / CutBone / CutMarrow (the game
swaps in its own by name). Bone names come from the Godot BoneMap the model is imported with,
so another model only needs its bone map.
"""
import bpy, bmesh, os, re, math, random
from mathutils import Vector, Matrix

# region name, game index, root (profile), parent (profile), tip (profile, None = parent->root)
REGIONS = [
    ("HEAD", 0, "Neck", "UpperChest", "Head"),
    ("ARM_L", 2, "LeftUpperArm", "LeftShoulder", "LeftLowerArm"),
    ("ARM_R", 4, "RightUpperArm", "RightShoulder", "RightLowerArm"),
    ("THIGH_L", 6, "LeftUpperLeg", "Hips", "LeftLowerLeg"),
    ("THIGH_R", 8, "RightUpperLeg", "Hips", "RightLowerLeg"),
    ("FOREARM_L", 3, "LeftLowerArm", "LeftUpperArm", "LeftHand"),
    ("FOREARM_R", 5, "RightLowerArm", "RightUpperArm", "RightHand"),
    ("SHIN_L", 7, "LeftLowerLeg", "LeftUpperLeg", "LeftFoot"),
    ("SHIN_R", 9, "RightLowerLeg", "RightUpperLeg", "RightFoot"),
    ("HAND_L", 10, "LeftHand", "LeftLowerArm", "LeftMiddleProximal"),
    ("HAND_R", 11, "RightHand", "RightLowerArm", "RightMiddleProximal"),
    ("FOOT_L", 12, "LeftFoot", "LeftLowerLeg", "LeftToes"),
    ("FOOT_R", 13, "RightFoot", "RightLowerLeg", "RightToes"),
]
PARENT_REGION = {"HEAD": "TORSO", "ARM_L": "TORSO", "ARM_R": "TORSO", "THIGH_L": "TORSO", "THIGH_R": "TORSO",
    "FOREARM_L": "ARM_L", "FOREARM_R": "ARM_R", "SHIN_L": "THIGH_L", "SHIN_R": "THIGH_R",
    "HAND_L": "FOREARM_L", "HAND_R": "FOREARM_R", "FOOT_L": "SHIN_L", "FOOT_R": "SHIN_R"}
TWO_BONES = {"FOREARM_L", "FOREARM_R", "SHIN_L", "SHIN_R"}
FAT_INSET = 0.12
## Where along root -> tip the cut goes (0 = at the joint). The neck is cut half way up: at its
## root the plane ran across the trapezius and took the shoulders' top with the head.
CUT_AT = {"HEAD": 0.45}
HEAD_CHUNKS = 9
## The belly opening: between Spine and Chest, an ellipse this wide / high (half sizes, m).
BELLY_AT = 0.6
BELLY_W = 0.085
BELLY_H = 0.08
## The waist cut (torso in two): this far from Spine to Chest.
WAIST_AT = 0.5
DOME = 0.3


def log(*a):
    print("[make_cuts]", *a, flush=True)


def read_bone_map(path):
    m = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            r = re.match(r'bone_map/(\w+) = &"([^"]*)"', line.strip())
            if r and r.group(2):
                m[r.group(1)] = r.group(2)
    return m


def mat(name, color, rough=0.5):
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    bsdf.inputs["Base Color"].default_value = (*color, 1.0)
    bsdf.inputs["Roughness"].default_value = rough
    return m


def descendants(arm, name):
    b = arm.data.bones[name]
    out = [b.name]
    for c in b.children_recursive:
        out.append(c.name)
    return out


def run(src, bone_map_path, out_path):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=src)
    arm = next(o for o in bpy.context.scene.objects if o.type == "ARMATURE")
    body = max((o for o in bpy.context.scene.objects if o.type == "MESH" and o.find_armature() == arm),
               key=lambda o: len(o.data.vertices))
    for o in list(bpy.context.scene.objects):
        if o not in (arm, body):
            bpy.data.objects.remove(o, do_unlink=True)
    bm_map = read_bone_map(bone_map_path)
    src_name = lambda prof: bm_map.get(prof, prof)
    inv = body.matrix_world.inverted()
    head_of = lambda prof: inv @ (arm.matrix_world @ arm.data.bones[src_name(prof)].head_local)
    vg_index = {vg.name: vg.index for vg in body.vertex_groups}

    # The model's own materials (a Mixamo body has two: skin and clothes) ride on every piece of skin,
    # in their own slots; the pieces' cut materials follow them. The game swaps the Main ones for the
    # live body's by name.
    main_mats = [m for m in body.data.materials if m] or [mat("Main", (0.8, 0.65, 0.5))]
    OFF = len(main_mats) - 1                 # (cut material k of a piece list [Main, Fat, ...] sits at k + OFF)
    mats = {"Main": main_mats[0]}
    mats["CutFat"] = mat("CutFat", (0.86, 0.62, 0.45), 0.6)
    mats["CutMeat"] = mat("CutMeat", (0.55, 0.06, 0.07), 0.3)
    mats["CutBone"] = mat("CutBone", (0.9, 0.86, 0.76), 0.5)
    mats["CutMarrow"] = mat("CutMarrow", (0.32, 0.03, 0.03), 0.4)

    bm = bmesh.new()
    bm.from_mesh(body.data)
    # A glTF mesh comes split along its UV seams: weld it (UVs live on the face corners), else
    # every cut / opening has gaps where it crosses a seam.
    nv = len(bm.verts)
    bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=1e-5)
    log("welded", nv - len(bm.verts), "seam vertices")
    deform = bm.verts.layers.deform.verify()
    reg = bm.faces.layers.int.new("region")
    names = ["TORSO"] + [r[0] for r in REGIONS]
    rid = {n: i for i, n in enumerate(names)}
    for f in bm.faces:
        f[reg] = rid["TORSO"]

    cuts = {}
    for name, _, root, parent, tip in REGIONS:
        chain = {vg_index[b] for b in descendants(arm, src_name(root)) if b in vg_index}
        p = head_of(root)
        far = head_of(tip) if tip and src_name(tip) in arm.data.bones else p + (p - head_of(parent))
        n = (far - p).normalized()
        p = p.lerp(far, CUT_AT.get(name, 0.0))
        par = rid[PARENT_REGION[name]]
        wc = lambda v: sum(w for g, w in v[deform].items() if g in chain)
        cand = [f for f in bm.faces if f[reg] == par and any(wc(v) > 0.001 for v in f.verts)]
        geom = set(cand)
        for f in cand:
            geom.update(f.edges)
            geom.update(f.verts)
        res = bmesh.ops.bisect_plane(bm, geom=list(geom), plane_co=p, plane_no=n, dist=1e-5)
        moved = 0
        for f in {e for e in res["geom"] if isinstance(e, bmesh.types.BMFace)}:
            if f[reg] != par:
                continue
            if not any(wc(v) > 0.001 for v in f.verts):
                continue
            if (f.calc_center_median() - p).dot(n) > 0.0:
                f[reg] = rid[name]
                moved += 1
        cuts[name] = (p, n, chain, src_name(root), src_name(parent))
        log(name, "cut at", tuple(round(x, 3) for x in p), "faces off", moved)

    made = []

    def segment(region_name, keep_ids, obj_name):
        b2 = bm.copy()
        r2 = b2.faces.layers.int.get("region")
        bmesh.ops.delete(b2, geom=[f for f in b2.faces if f[r2] not in keep_ids], context="FACES")
        bmesh.ops.delete(b2, geom=[v for v in b2.verts if not v.link_faces], context="VERTS")
        me = bpy.data.meshes.new(obj_name)
        b2.to_mesh(me)
        b2.free()
        for m in main_mats:
            me.materials.append(m)
        ob = bpy.data.objects.new(obj_name, me)
        bpy.context.scene.collection.objects.link(ob)
        for vg in body.vertex_groups:
            ob.vertex_groups.new(name=vg.name)
        ob.parent = arm
        ob.matrix_world = body.matrix_world
        mod = ob.modifiers.new("Armature", "ARMATURE")
        mod.object = arm
        made.append(ob)
        return ob

    for n in names:
        segment(n, {rid[n]}, "Seg_" + n)

    # ---- caps: the real boundary loops of each cut
    def loops_between(a_id, b_id):
        """Edges between the two regions, as pairs of (position, weights) - weights {group: w}."""
        edges = []
        for e in bm.edges:
            if len(e.link_faces) != 2:
                continue
            r0, r1 = e.link_faces[0][reg], e.link_faces[1][reg]
            if {r0, r1} == {a_id, b_id}:
                # In the order region b's face runs along it (a cap continues that winding).
                lp = next(l for l in e.link_loops if l.face[reg] == b_id)
                vs = (lp.vert, lp.link_loop_next.vert)
                edges.append(tuple((v.co.copy(), dict(v[deform].items())) for v in vs))
        return edges

    def onehot(bone):
        return {vg_index[bone]: 1.0}

    def mix(wa, wb, t):
        out = {}
        for g, w in wa.items():
            out[g] = out.get(g, 0.0) + w * (1.0 - t)
        for g, w in wb.items():
            out[g] = out.get(g, 0.0) + w * t
        s = sum(out.values()) or 1.0
        return {g: w / s for g, w in out.items() if w / s > 0.002}

    def hash01(co, salt):
        h = math.sin(co.x * 127.1 + co.y * 311.7 + co.z * 74.7 + salt * 19.19) * 43758.5453
        return h - math.floor(h)

    def cap_object(obj_name, segs, c, out, rad, bone, bones2, rng, joint):
        """The cut's end over the boundary edges `segs`: the rim is the skin's own vertices (same
        weights, so it stays sealed however the body bends), a band of fat just inside it, then
        the meat domed out in rings to the middle (weights blending to `bone`), bone(s) in it."""
        bc = bmesh.new()
        dl = bc.verts.layers.deform.verify()
        fat_m, meat_m, bone_m, marrow_m = 0, 1, 2, 3
        salt = rng.random() * 100.0
        centre_w = onehot(bone)
        verts = {}

        def V(key, co, w):
            if key not in verts:
                v = bc.verts.new(co)
                for g, x in w.items():
                    v[dl][g] = x
                verts[key] = v
            return verts[key]

        # Rings from the rim in: (fraction toward the middle, height of the dome, material).
        rings = [(0.0, 0.0), (FAT_INSET, 0.04), (0.3, 0.45), (0.58, 0.8), (0.82, 0.95)]

        def ring_point(co, w, k):
            f, hgt = rings[k]
            if k == 0:
                return co, w
            jitter = (hash01(co, salt + k) - 0.5) * 0.35 if k >= 2 else 0.0
            p = co + (c - co) * f + out * rad * DOME * hgt * (1.0 + jitter)
            return p, mix(w, centre_w, f)

        def key(co):
            return (round(co.x, 5), round(co.y, 5), round(co.z, 5))

        top = V(("top",), c + out * rad * DOME * (1.02 + (rng.random() - 0.5) * 0.2), centre_w)
        for (a, wa), (b, wb) in segs:
            ra, rb = [], []
            for k in range(len(rings)):
                pa, wa2 = ring_point(a, wa, k)
                pb, wb2 = ring_point(b, wb, k)
                ra.append(V((k,) + key(a), pa, wa2))
                rb.append(V((k,) + key(b), pb, wb2))
            for k in range(len(rings) - 1):
                quad = [ra[k], rb[k], rb[k + 1], ra[k + 1]]
                try:
                    f = bc.faces.new(quad)
                    f.material_index = fat_m if k == 0 else meat_m
                    f.smooth = True
                except ValueError:
                    pass
            try:
                f = bc.faces.new([ra[-1], rb[-1], top])
                f.material_index = meat_m
                f.smooth = True
            except ValueError:
                pass
        # The bone(s), snapped off, marrow in the end (weighted to the bone they belong to).
        side = out.cross(Vector((0, 0, 1)) if abs(out.z) < 0.9 else Vector((1, 0, 0))).normalized()
        up2 = out.cross(side)
        sides = 10
        for k in range(bones2):
            off = Vector((0, 0, 0)) if bones2 == 1 else side * (k - 0.5) * rad * 0.75
            br = rad * (0.22 if bones2 == 1 else 0.14)
            ln = rad * (DOME * 0.9 + rng.uniform(0.15, 0.35))
            # (The bone sits where the joint is, not in the middle of the rim: a hip's rim runs
            # round the buttock.)
            base = joint + off - out * rad * 0.05
            r0, r1, r2 = [], [], []
            for s in range(sides):
                ang = math.tau * s / sides
                d = side * math.cos(ang) + up2 * math.sin(ang)
                r0.append(bc.verts.new(base + d * br))
                jag = ln * (1.0 + 0.45 * max(0.0, math.cos(ang * 2.0 + k)) - 0.25 * hash01(base + d, s))
                r1.append(bc.verts.new(base + d * br * 0.95 + out * jag))
                r2.append(bc.verts.new(base + d * br * 0.6 + out * (jag - br * 0.15)))
            mid = bc.verts.new(base + out * (ln * 0.85))
            for v in r0 + r1 + r2 + [mid]:
                v[dl][vg_index[bone]] = 1.0
            for s in range(sides):
                s2 = (s + 1) % sides
                for ring_a, ring_b, m in ((r0, r1, bone_m), (r1, r2, bone_m)):
                    f = bc.faces.new([ring_a[s], ring_a[s2], ring_b[s2], ring_b[s]])
                    f.material_index = m
                    f.smooth = True
                f = bc.faces.new([r2[s], r2[s2], mid])
                f.material_index = marrow_m
            bc.normal_update()
            # Outward from the bone's axis.
            for f in bc.faces:
                if f.material_index in (bone_m, marrow_m) and f.verts[0] in r0 + r1 + r2 + [mid]:
                    fc = f.calc_center_median()
                    radial = (fc - base) - out * (fc - base).dot(out)
                    want = radial if f.material_index == bone_m and radial.length > br * 0.5 else out
                    if f.normal.dot(want) < 0:
                        f.normal_flip()
        me = bpy.data.meshes.new(obj_name)
        bc.to_mesh(me)
        bc.free()
        for m_name in ("CutFat", "CutMeat", "CutBone", "CutMarrow"):
            me.materials.append(mats[m_name])
        ob = bpy.data.objects.new(obj_name, me)
        bpy.context.scene.collection.objects.link(ob)
        for g in body.vertex_groups:
            ob.vertex_groups.new(name=g.name)
        ob.parent = arm
        ob.matrix_world = body.matrix_world
        mod = ob.modifiers.new("Armature", "ARMATURE")
        mod.object = arm
        made.append(ob)
        return ob

    rng = random.Random(7)
    for name, _, root, parent, tip in REGIONS:
        p, n, chain, root_b, parent_b = cuts[name]
        segs = loops_between(rid[name], rid[PARENT_REGION[name]])
        if not segs:
            log(name, "NO boundary - skipped caps")
            continue
        c = Vector((0, 0, 0))
        for (a, _wa), (b, _wb) in segs:
            c += a + b
        c /= len(segs) * 2
        # The middle on the cut plane (an uneven rim pulls the average off it).
        c = c - n * (c - p).dot(n)
        rad = sum(((a - c).length for (a, _w), _b in segs)) / len(segs)
        nb = 2 if name in TWO_BONES else 1
        # (segs run the way the stump's skin winds: the stump cap runs back along them.)
        cap_object("Cap_%s_stump" % name, [(b, a) for a, b in segs], c, n, rad, parent_b, nb, rng, p)
        cap_object("Cap_%s_end" % name, segs, c, -n, rad, root_b, nb, rng, p)
        log(name, "caps: %d edges, radius %.3f" % (len(segs), rad))

    def skinned(obj_name, b, mat_names):
        me = bpy.data.meshes.new(obj_name)
        b.to_mesh(me)
        b.free()
        for m_name in mat_names:
            if m_name == "Main":
                for m in main_mats:
                    me.materials.append(m)
            else:
                me.materials.append(mats[m_name])
        ob = bpy.data.objects.new(obj_name, me)
        bpy.context.scene.collection.objects.link(ob)
        for g in body.vertex_groups:
            ob.vertex_groups.new(name=g.name)
        ob.parent = arm
        ob.matrix_world = body.matrix_world
        mod = ob.modifiers.new("Armature", "ARMATURE")
        mod.object = arm
        made.append(ob)
        return ob

    def rings_in(b, dl, rim_edges, centre, back, centre_w, spec, mat_of):
        """Fill an open edge loop inward: each rim vertex walks through `spec` rings
        [(toward centre, back along `back`)] to a middle point; faces get mat_of(ring k)."""
        made_v = {}

        def ring_v(v, k):
            if k == 0:
                return v
            key = (v, k)          # (not v.index: stale after deleting faces)
            if key not in made_v:
                f, d = spec[k - 1]
                j = 1.0 + (hash01(v.co, k) - 0.5) * 0.3
                nv = b.verts.new(v.co.lerp(centre, f) + back * d * j)
                for g, w in mix(dict(v[dl].items()), centre_w, f).items():
                    nv[dl][g] = w
                made_v[key] = nv
            return made_v[key]

        mid = b.verts.new(centre + back * spec[-1][1] * 1.1)
        for g, w in centre_w.items():
            mid[dl][g] = w
        faces = []
        for e in rim_edges:
            # Back along the way the skin's face runs: the fill winds on from the skin.
            lp = e.link_loops[0]
            a, c2 = lp.link_loop_next.vert, lp.vert
            for k in range(len(spec)):
                q = [ring_v(a, k), ring_v(c2, k), ring_v(c2, k + 1), ring_v(a, k + 1)]
                try:
                    f = b.faces.new(q)
                    f.material_index = mat_of(k)
                    f.smooth = True
                    faces.append(f)
                except ValueError:
                    pass
            try:
                f = b.faces.new([ring_v(a, len(spec)), ring_v(c2, len(spec)), mid])
                f.material_index = mat_of(len(spec))
                f.smooth = True
                faces.append(f)
            except ValueError:
                pass
        return faces

    # ---- the head in chunks, for a blast through it: the head's skin (and the neck down to the
    # cut) split round random seeds on its surface (Voronoi over the faces: torn along the
    # triangles), each closed into a wedge - skin, a skull layer, meat in the middle.
    head_bone = src_name("Head")
    hw = onehot(head_bone)
    hrng = random.Random(3)
    src_b = bm.copy()
    r2 = src_b.faces.layers.int.get("region")
    bmesh.ops.delete(src_b, geom=[f for f in src_b.faces if f[r2] != rid["HEAD"]], context="FACES")
    bmesh.ops.delete(src_b, geom=[v for v in src_b.verts if not v.link_faces], context="VERTS")
    centre = sum((v.co for v in src_b.verts), Vector()) / max(len(src_b.verts), 1)
    centres = [f.calc_center_median() for f in src_b.faces]
    seeds = []
    while len(seeds) < HEAD_CHUNKS:
        cand = centres[hrng.randrange(len(centres))]
        if all((cand - s).length > 0.06 for s in seeds) or hrng.random() < 0.02:
            seeds.append(cand)
    owner = [min(range(len(seeds)), key=lambda k: (fc - seeds[k]).length) for fc in centres]
    src_b.free()
    for k in range(len(seeds)):
        b = bm.copy()
        rr = b.faces.layers.int.get("region")
        dl = b.verts.layers.deform.verify()
        heads = [f for f in b.faces if f[rr] == rid["HEAD"]]
        drop = [f for f in b.faces if f[rr] != rid["HEAD"]]
        drop += [f for f, o in zip(heads, owner) if o != k]
        bmesh.ops.delete(b, geom=drop, context="FACES")
        bmesh.ops.delete(b, geom=[v for v in b.verts if not v.link_faces], context="VERTS")
        if not b.faces:
            b.free()
            continue
        for v in b.verts:
            for g in list(v[dl].keys()):
                del v[dl][g]
            v[dl][vg_index[head_bone]] = 1.0
        rim = [e for e in b.edges if len(e.link_faces) == 1]
        cc = sum((v.co for v in b.verts), Vector()) / len(b.verts)
        inner = cc.lerp(centre, 0.55)
        # Skull (bone, ~7 mm in), then meat to the middle.
        faces = rings_in(b, dl, rim, inner, Vector(), hw, [(0.12, 0.0), (0.2, 0.0), (0.6, 0.0)],
                         lambda ring: OFF + (2 if ring == 1 else (1 if ring == 0 else 3)))
        skinned("Chunk_HEAD_%d" % k, b, ["Main", "CutFat", "CutBone", "CutMeat"])
    log("head chunks:", len(seeds))

    # ---- the torso with the belly blown open into a cavity (front torso blasts)
    tb = bm.copy()
    r3 = tb.faces.layers.int.get("region")
    dl = tb.verts.layers.deform.verify()
    bmesh.ops.delete(tb, geom=[f for f in tb.faces if f[r3] != rid["TORSO"]], context="FACES")
    bmesh.ops.delete(tb, geom=[v for v in tb.verts if not v.link_faces], context="VERTS")
    hips = head_of("Hips")
    toes = head_of("LeftToes") - head_of("LeftFoot")
    fwd = Vector((toes.x, toes.y, 0)).normalized()     # the model's front (the way the feet point)
    belly = head_of("Spine").lerp(head_of("Chest"), BELLY_AT)
    front = [v.co for v in tb.verts if abs(v.co.z - belly.z) < 0.03 and abs((v.co - belly).cross(fwd).length) < 0.04]
    surf = max(front, key=lambda q: (q - belly).dot(fwd)) if front else belly + fwd * 0.12
    hole_c = Vector((belly.x, belly.y, belly.z)) + fwd * (surf - belly).dot(fwd)
    side = fwd.cross(Vector((0, 0, 1))).normalized()
    hole = []
    for f in tb.faces:
        fc = f.calc_center_median()
        # (Any front face: the belly's underside faces down, a normal test left a flap across.)
        if (fc - belly).dot(fwd) < 0.0:
            continue
        d = fc - hole_c
        ex, ez = d.dot(side) / BELLY_W, d.z / BELLY_H
        if ex * ex + ez * ez < 1.0 + (hash01(fc, 5) - 0.5) * 0.5:
            hole.append(f)
    rim_set = {e for f in hole for e in f.edges}
    bmesh.ops.delete(tb, geom=hole, context="FACES_ONLY")
    bmesh.ops.delete(tb, geom=[v for v in tb.verts if not v.link_faces], context="VERTS")
    rim = [e for e in rim_set if e.is_valid and len(e.link_faces) == 1]
    rim_c = sum((v.co for e in rim for v in e.verts), Vector()) / max(len(rim) * 2, 1)
    deep = -fwd
    faces = rings_in(tb, dl, rim, rim_c, deep, onehot(src_name("Spine")),
                     [(0.1, 0.012), (0.3, 0.05), (0.6, 0.085), (0.85, 0.1)],
                     lambda ring: OFF + (1 if ring == 0 else 2))
    skinned("Seg_TORSO_OPEN", tb, ["Main", "CutFat", "CutMeat"])
    log("belly cavity:", len(hole), "faces opened,", len(rim), "rim edges at", tuple(round(x, 3) for x in hole_c))

    # ---- the torso in two at the waist (a blast through the middle): Seg.WAIST_UP (chest,
    # shoulders) and Seg.WAIST_DOWN (belly down to the hips), each sealed, the spine snapped in it.
    wb = bm.copy()
    rw = wb.faces.layers.int.get("region")
    dw = wb.verts.layers.deform.verify()
    bmesh.ops.delete(wb, geom=[f for f in wb.faces if f[rw] != rid["TORSO"]], context="FACES")
    bmesh.ops.delete(wb, geom=[v for v in wb.verts if not v.link_faces], context="VERTS")
    lo_b, hi_b = head_of("Spine"), head_of("Chest")
    wp = lo_b.lerp(hi_b, WAIST_AT)
    wn = (hi_b - lo_b).normalized()
    bmesh.ops.bisect_plane(wb, geom=wb.verts[:] + wb.edges[:] + wb.faces[:], plane_co=wp, plane_no=wn, dist=1e-5)
    UP, DOWN = 1, 2
    for f in wb.faces:
        f[rw] = UP if (f.calc_center_median() - wp).dot(wn) > 0 else DOWN
    wsegs = []
    for e in wb.edges:
        if len(e.link_faces) == 2 and {e.link_faces[0][rw], e.link_faces[1][rw]} == {UP, DOWN}:
            lp = next(l for l in e.link_loops if l.face[rw] == DOWN)
            vs = (lp.vert, lp.link_loop_next.vert)
            wsegs.append(tuple((v.co.copy(), dict(v[dw].items())) for v in vs))
    # Each half rides only its own side of the spine: weight on the other side's bones goes to
    # the half's own spine bone (the skin round the waist is shared by Spine and Chest - once
    # the halves part it stretched across the gap).
    upper = {vg_index[b] for b in descendants(arm, src_name("Chest")) if b in vg_index}

    def own_side(w, up):
        anchor = vg_index[src_name("Chest") if up else src_name("Spine")]
        out = {}
        for g, x in w.items():
            k = g if (g in upper) == up else anchor
            out[k] = out.get(k, 0.0) + x
        return out

    for half, nm in ((UP, "Seg_WAIST_UP"), (DOWN, "Seg_WAIST_DOWN")):
        hb = wb.copy()
        rh = hb.faces.layers.int.get("region")
        dh = hb.verts.layers.deform.verify()
        bmesh.ops.delete(hb, geom=[f for f in hb.faces if f[rh] != half], context="FACES")
        bmesh.ops.delete(hb, geom=[v for v in hb.verts if not v.link_faces], context="VERTS")
        for v in hb.verts:
            w = own_side(dict(v[dh].items()), half == UP)
            for g in list(v[dh].keys()):
                del v[dh][g]
            for g, x in w.items():
                v[dh][g] = x
        skinned(nm, hb, ["Main"])
    wb.free()
    if wsegs:
        c = Vector()
        for (a, _wa), (b, _wb) in wsegs:
            c += a + b
        c /= len(wsegs) * 2
        c = c - wn * (c - wp).dot(wn)
        rad = sum(((a - c).length for (a, _w), _b in wsegs)) / len(wsegs)
        # (The spine runs up the back: the bone sits there, at the cut.)
        down = [((b, own_side(wb_, False)), (a, own_side(wa_, False))) for (a, wa_), (b, wb_) in wsegs]
        up = [((a, own_side(wa_, True)), (b, own_side(wb_, True))) for (a, wa_), (b, wb_) in wsegs]
        cap_object("Cap_WAIST_down", down, c, wn, rad, src_name("Spine"), 1, rng, wp)
        cap_object("Cap_WAIST_up", up, c, -wn, rad, src_name("Chest"), 1, rng, wp)
    log("waist: %d edges, radius %.3f at" % (len(wsegs), rad if wsegs else 0), tuple(round(x, 3) for x in wp))

    bm.free()
    bpy.data.objects.remove(body, do_unlink=True)
    # The game puts the live body's materials on the pieces by name: the textures riding along in this
    # file are dead weight (a Mixamo body's are 2048 x 2048). Keep the image nodes (the exporter writes
    # UVs for textured materials) but make the images tiny.
    for m in main_mats:
        if m.use_nodes:
            for n in m.node_tree.nodes:
                if n.type == "TEX_IMAGE" and n.image and n.image.size[0] > 8:
                    n.image.scale(8, 8)
    bpy.ops.object.select_all(action="DESELECT")
    arm.select_set(True)
    for ob in made:
        ob.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.export_scene.gltf(filepath=out_path, use_selection=True, export_animations=False,
                              export_skins=True, export_morph=False, export_apply=False)
    log("wrote", out_path, len(made), "meshes")
