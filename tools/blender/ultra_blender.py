"""UltraController Blender pipeline (Blender 5.0, runs headless).

    blender --background --python tools/blender/ultra_blender.py -- <command> [options]

Commands
  make-edit        Import the mannequin with all its actions into art_src/mannequin_edit.blend
                   so you can author or tweak animations in the Blender GUI.
  export-actions   Export actions as individual armature-only GLBs into intake/blender/
                   (--blend FILE, --actions "Name1,Name2" or --new-only). Godot's intake turns
                   them into the `blender/` animation library.
  mirror           Make a left/right mirrored copy of an action (--action X --out Y).
  make-pistol      Rebuild the pistol model + markers and export assets/items/pistol/pistol.glb
                   (the same build the project shipped with).
  make-bat         Build the baseball bat (GripBody up the handle).
  make-machete     Build the machete (edge forward).
  make-shotgun     Build the 12-gauge pump-action (the fore-end is its own "Pump" node).
  make-rifle       Build the carbine (two-handed: pistol grip, handguard, stock, iron sights,
                   magazine, markers) and export assets/items/rifle/rifle.glb.
  make-cuts        Pre-cut the character for dismemberment (tools/blender/make_cuts.py):
                   body pieces split at every joint, fitted end caps, head chunks, an opened
                   belly -> assets/characters/mannequin/mannequin_cuts.glb. Re-run after
                   changing the model (--src, --bone-map, --out).
  import-mixamo    A Mixamo character FBX -> assets/characters/<name>/<name>.glb (tools/blender/import_mixamo.py):
                   metres, bones renamed mixamorig_*, textures shrunk, skins, no animation
                   (--src, --out, --name, --tex-size).
  mixamo-test      Write intake/mixamo/<name>.fbx: the mannequin renamed to Mixamo bone names
                   with one action — exercises the Mixamo intake without a Mixamo account.

Every command is idempotent and never touches files outside the project.
"""
import bpy, sys, os, math, json, argparse
from mathutils import Matrix, Vector, Euler

PROJECT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SRC_GLB = os.path.join(PROJECT, "art_src", "exported-model.glb")
EDIT_BLEND = os.path.join(PROJECT, "art_src", "mannequin_edit.blend")
INTAKE_BLENDER = os.path.join(PROJECT, "intake", "blender")
INTAKE_MIXAMO = os.path.join(PROJECT, "intake", "mixamo")

UE_TO_MIXAMO = {
    "pelvis": "Hips", "spine_01": "Spine", "spine_02": "Spine1", "spine_03": "Spine2",
    "neck_01": "Neck", "head": "Head", "head_leaf": "HeadTop_End",
}
for side, s in (("l", "Left"), ("r", "Right")):
    UE_TO_MIXAMO.update({
        f"clavicle_{side}": f"{s}Shoulder", f"upperarm_{side}": f"{s}Arm", f"lowerarm_{side}": f"{s}ForeArm",
        f"hand_{side}": f"{s}Hand", f"thigh_{side}": f"{s}UpLeg", f"calf_{side}": f"{s}Leg",
        f"foot_{side}": f"{s}Foot", f"ball_{side}": f"{s}ToeBase", f"ball_leaf_{side}": f"{s}Toe_End",
    })
    for ue, mx in (("index", "Index"), ("middle", "Middle"), ("ring", "Ring"), ("pinky", "Pinky"), ("thumb", "Thumb")):
        for i in range(1, 4):
            UE_TO_MIXAMO[f"{ue}_0{i}_{side}"] = f"{s}Hand{mx}{i}"
        UE_TO_MIXAMO[f"{ue}_04_leaf_{side}"] = f"{s}Hand{mx}4"


def log(*a):
    print("[ultra_blender]", *a, flush=True)


def fresh_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def import_mannequin():
    bpy.ops.import_scene.gltf(filepath=SRC_GLB)
    arm = next(o for o in bpy.context.scene.objects if o.type == 'ARMATURE')
    return arm


def assign_action(arm, act):
    if arm.animation_data is None:
        arm.animation_data_create()
    arm.animation_data.action = act
    if hasattr(arm.animation_data, "action_slot") and getattr(act, "slots", None):
        if len(act.slots):
            arm.animation_data.action_slot = act.slots[0]


# ------------------------------------------------------------------ commands

def cmd_make_edit(args):
    fresh_scene()
    arm = import_mannequin()
    for act in bpy.data.actions:
        act.use_fake_user = True
    bpy.ops.wm.save_as_mainfile(filepath=EDIT_BLEND)
    log("saved", EDIT_BLEND, "with", len(bpy.data.actions), "actions")


def cmd_export_actions(args):
    if args.blend:
        bpy.ops.wm.open_mainfile(filepath=os.path.abspath(args.blend))
    else:
        fresh_scene()
        import_mannequin()
    arm = next(o for o in bpy.context.scene.objects if o.type == 'ARMATURE')
    wanted = [a.strip() for a in args.actions.split(",")] if args.actions else None
    original = set()
    if args.new_only:
        manifest = os.path.join(PROJECT, "art_src", "original_actions.json")
        if os.path.exists(manifest):
            original = set(json.load(open(manifest)))
    os.makedirs(INTAKE_BLENDER, exist_ok=True)
    # Armature only: hide meshes from the export.
    for o in bpy.context.scene.objects:
        o.select_set(o == arm)
    count = 0
    for act in list(bpy.data.actions):
        if wanted and act.name not in wanted:
            continue
        if args.new_only and act.name in original:
            continue
        assign_action(arm, act)
        out = os.path.join(INTAKE_BLENDER, act.name + ".glb")
        bpy.ops.export_scene.gltf(filepath=out, use_selection=True, export_animations=True,
                                  export_animation_mode='ACTIVE_ACTIONS', export_force_sampling=True,
                                  export_def_bones=False, export_skins=True)
        count += 1
        log("exported", out)
    log("exported", count, "actions")


def cmd_mirror(args):
    if args.blend:
        bpy.ops.wm.open_mainfile(filepath=os.path.abspath(args.blend))
    else:
        fresh_scene()
        import_mannequin()
    arm = next(o for o in bpy.context.scene.objects if o.type == 'ARMATURE')
    src = bpy.data.actions[args.action]
    dst = src.copy()
    dst.name = args.out
    dst.use_fake_user = True
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode='POSE')
    assign_action(arm, src)
    f0, f1 = int(src.frame_range[0]), int(src.frame_range[1])
    poses = []
    for f in range(f0, f1 + 1):
        bpy.context.scene.frame_set(f)
        bpy.ops.pose.select_all(action='SELECT')
        bpy.ops.pose.copy()
        poses.append(f)
        assign_action(arm, dst)
        bpy.ops.pose.paste(flipped=True)
        bpy.ops.anim.keyframe_insert_by_name(type="LocRotScale")
        assign_action(arm, src)
    bpy.ops.object.mode_set(mode='OBJECT')
    if args.blend:
        bpy.ops.wm.save_mainfile()
    log("mirrored", args.action, "->", args.out, "frames", f0, f1)


def cmd_mixamo_test(args):
    fresh_scene()
    arm = import_mannequin()
    keep = args.action or "Walk"
    for act in list(bpy.data.actions):
        if act.name != keep:
            bpy.data.actions.remove(act)
    act = bpy.data.actions[keep]
    # Assign first: renaming a bone updates the animation paths of the ASSIGNED action.
    assign_action(arm, act)
    bpy.context.scene.frame_start = int(act.frame_range[0])
    bpy.context.scene.frame_end = int(act.frame_range[1])
    for b in arm.data.bones:
        if b.name in UE_TO_MIXAMO:
            b.name = "mixamorig:" + UE_TO_MIXAMO[b.name]
    for o in bpy.context.scene.objects:
        o.select_set(o == arm or o.type == 'MESH')
    os.makedirs(INTAKE_MIXAMO, exist_ok=True)
    out = os.path.join(INTAKE_MIXAMO, (args.name or ("Mixamo_" + keep)) + ".fbx")
    bpy.ops.export_scene.fbx(filepath=out, use_selection=True, add_leaf_bones=False, bake_anim=True,
                             bake_anim_use_all_actions=False, bake_anim_use_nla_strips=False,
                             object_types={'ARMATURE', 'MESH'})
    log("wrote", out)


def cmd_make_pistol(args):
    fresh_scene()
    coll = bpy.data.collections.new("Pistol")
    bpy.context.scene.collection.children.link(coll)
    import bmesh

    def mat(name, rgb, metal=0.0, rough=0.6):
        m = bpy.data.materials.new(name)
        m.use_nodes = True
        bsdf = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
        bsdf.inputs["Base Color"].default_value = (*rgb, 1)
        bsdf.inputs["Metallic"].default_value = metal
        bsdf.inputs["Roughness"].default_value = rough
        m.diffuse_color = (*rgb, 1)
        return m

    poly = mat("Pistol_Polymer", (0.045, 0.047, 0.05), 0.0, 0.75)
    slide_m = mat("Pistol_Slide", (0.13, 0.135, 0.14), 0.75, 0.35)
    dot = mat("Pistol_SightDot", (1.0, 0.45, 0.05), 0.0, 0.4)
    magm = mat("Pistol_Magazine", (0.07, 0.07, 0.075), 0.4, 0.5)

    def box(name, size, loc, rot=(0, 0, 0), material=None, parent=None, bevel=0.0015):
        me = bpy.data.meshes.new(name)
        bm = bmesh.new()
        bmesh.ops.create_cube(bm, size=1.0)
        for v in bm.verts:
            v.co = Vector((v.co.x * size[0], v.co.y * size[1], v.co.z * size[2]))
        bm.to_mesh(me); bm.free()
        o = bpy.data.objects.new(name, me)
        coll.objects.link(o)
        o.location = loc
        o.rotation_euler = Euler([math.radians(r) for r in rot])
        if material: me.materials.append(material)
        if bevel > 0:
            b = o.modifiers.new("Bevel", "BEVEL"); b.width = bevel; b.segments = 2
        if parent:
            o.parent = parent
        return o

    def cyl(name, r, depth, loc, rot, material, parent):
        me = bpy.data.meshes.new(name)
        bm = bmesh.new()
        bmesh.ops.create_cone(bm, cap_ends=True, segments=12, radius1=r, radius2=r, depth=depth)
        bm.to_mesh(me); bm.free()
        o = bpy.data.objects.new(name, me)
        coll.objects.link(o)
        o.location = loc
        o.rotation_euler = Euler([math.radians(x) for x in rot])
        me.materials.append(material)
        o.parent = parent
        return o

    def empty(name, loc, parent):
        e = bpy.data.objects.new(name, None)
        e.empty_display_type = 'ARROWS'; e.empty_display_size = 0.01
        coll.objects.link(e)
        e.location = loc
        e.parent = parent
        return e

    root = bpy.data.objects.new("Pistol", None)
    coll.objects.link(root)
    rake = 16.0
    box("Frame", (0.028, 0.170, 0.022), (0, -0.045, 0.030), material=poly, parent=root)
    box("GripBody", (0.029, 0.052, 0.112), (0, 0.012, -0.022), rot=(-rake, 0, 0), material=poly, parent=root)
    box("Backstrap", (0.024, 0.012, 0.030), (0, 0.040, 0.030), material=poly, parent=root)
    slide = box("Slide", (0.026, 0.188, 0.034), (0, -0.050, 0.058), material=slide_m, parent=root)
    box("GuardBottom", (0.010, 0.058, 0.006), (0, -0.060, -0.006), material=poly, parent=root)
    box("GuardFront", (0.010, 0.007, 0.034), (0, -0.088, 0.008), rot=(12, 0, 0), material=poly, parent=root)
    box("Rail", (0.020, 0.050, 0.006), (0, -0.105, 0.017), material=poly, parent=root)
    box("Trigger", (0.006, 0.006, 0.022), (0, -0.040, 0.006), rot=(-15, 0, 0), material=slide_m, parent=root)
    mag = box("Magazine", (0.022, 0.040, 0.105), (0, 0.016, -0.026), rot=(-rake, 0, 0), material=magm, parent=root)
    plate = box("MagBaseplate", (0.030, 0.056, 0.010), (0, 0, 0), material=poly, parent=mag)
    plate.location = (0, 0.0, -0.057)
    # Parts that move with the slide.
    parts = [
        box("SlideSerrations", (0.0265, 0.030, 0.026), (0, 0.022, 0.058), material=slide_m, parent=root, bevel=0.0),
        box("RearSight", (0.022, 0.008, 0.008), (0, 0.030, 0.079), material=slide_m, parent=root, bevel=0.0008),
        box("FrontSight", (0.005, 0.006, 0.008), (0, -0.136, 0.079), material=slide_m, parent=root, bevel=0.0008),
        box("DotL", (0.0035, 0.002, 0.0035), (-0.007, 0.0255, 0.0815), material=dot, parent=root, bevel=0.0),
        box("DotR", (0.0035, 0.002, 0.0035), (0.007, 0.0255, 0.0815), material=dot, parent=root, bevel=0.0),
        box("DotF", (0.0035, 0.002, 0.0035), (0, -0.1395, 0.081), material=dot, parent=root, bevel=0.0),
        box("EjectionPort", (0.004, 0.032, 0.012), (0.0115, -0.035, 0.066), material=poly, parent=root, bevel=0.0),
        cyl("BarrelTip", 0.0065, 0.006, (0, -0.1455, 0.060), (90, 0, 0), slide_m, root),
        cyl("Bore", 0.0045, 0.0062, (0, -0.1457, 0.060), (90, 0, 0), poly, root),
    ]
    bpy.context.view_layer.update()
    for p in parts:
        mw = p.matrix_world.copy()
        p.parent = slide
        p.matrix_world = mw
    for name, loc in (("M_Grip", (0, 0, 0)), ("M_SupportGrip", (-0.032, 0.006, -0.020)), ("M_Muzzle", (0, -0.150, 0.060)),
                      ("M_RearSight", (0, 0.030, 0.0835)), ("M_FrontSight", (0, -0.136, 0.0835)),
                      ("M_EjectPort", (0.016, -0.035, 0.068)), ("M_MagWell", (0, 0.032, -0.080)), ("M_Holster", (0, 0, 0))):
        empty(name, loc, root)
    root.matrix_world = Matrix.Rotation(math.pi, 4, 'Z')        # barrel -> glTF -Z (Godot forward)
    bpy.context.view_layer.update()
    for o in coll.objects:
        o.select_set(True)
    out = args.out or os.path.join(PROJECT, "assets", "items", "pistol", "pistol.glb")
    bpy.ops.export_scene.gltf(filepath=out, use_selection=True, export_apply=True, export_yup=True, export_animations=False)
    log("wrote", out)


class _Kit:
    """Box / cylinder / marker helpers for procedural props (blender units = metres).
    Authoring frame like the pistol: barrel toward -Y, up +Z; the root is turned 180 deg about Z
    before export so the barrel ends up on Godot's -Z (forward) and authored -X on Godot's +X."""

    def __init__(self, coll):
        import bmesh
        self.bmesh = bmesh
        self.coll = coll

    def mat(self, name, rgb, metal=0.0, rough=0.6):
        m = bpy.data.materials.new(name)
        m.use_nodes = True
        bsdf = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
        bsdf.inputs["Base Color"].default_value = (*rgb, 1)
        bsdf.inputs["Metallic"].default_value = metal
        bsdf.inputs["Roughness"].default_value = rough
        m.diffuse_color = (*rgb, 1)
        return m

    def box(self, name, size, loc, rot=(0, 0, 0), material=None, parent=None, bevel=0.0015, taper=None):
        me = bpy.data.meshes.new(name)
        bm = self.bmesh.new()
        self.bmesh.ops.create_cube(bm, size=1.0)
        for v in bm.verts:
            x, y, z = v.co.x * size[0], v.co.y * size[1], v.co.z * size[2]
            if taper and v.co.z < 0:          # narrower / shorter at the bottom
                x *= taper[0]
                y *= taper[1]
            v.co = Vector((x, y, z))
        bm.to_mesh(me); bm.free()
        o = bpy.data.objects.new(name, me)
        self.coll.objects.link(o)
        o.location = loc
        o.rotation_euler = Euler([math.radians(r) for r in rot])
        if material: me.materials.append(material)
        if bevel > 0:
            b = o.modifiers.new("Bevel", "BEVEL"); b.width = bevel; b.segments = 2
        if parent:
            o.parent = parent
        return o

    def cyl(self, name, r, depth, loc, rot, material, parent, segments=12, r2=None):
        me = bpy.data.meshes.new(name)
        bm = self.bmesh.new()
        self.bmesh.ops.create_cone(bm, cap_ends=True, segments=segments, radius1=r, radius2=r if r2 is None else r2, depth=depth)
        bm.to_mesh(me); bm.free()
        o = bpy.data.objects.new(name, me)
        self.coll.objects.link(o)
        o.location = loc
        o.rotation_euler = Euler([math.radians(x) for x in rot])
        me.materials.append(material)
        o.parent = parent
        return o

    def empty(self, name, loc, parent):
        e = bpy.data.objects.new(name, None)
        e.empty_display_type = 'ARROWS'; e.empty_display_size = 0.01
        self.coll.objects.link(e)
        e.location = loc
        e.parent = parent
        return e

    def export(self, root, out):
        root.matrix_world = Matrix.Rotation(math.pi, 4, 'Z')        # barrel -> glTF -Z (Godot forward)
        bpy.context.view_layer.update()
        for o in self.coll.objects:
            o.select_set(True)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        bpy.ops.export_scene.gltf(filepath=out, use_selection=True, export_apply=True, export_yup=True, export_animations=False)
        log("wrote", out)


def cmd_make_rifle(args):
    """A compact 5.56 carbine. Origin at the top of the pistol grip (like the pistol, so the
    same grip fit holds it); the grip has the pistol's rake so the hand sits the same way."""
    fresh_scene()
    coll = bpy.data.collections.new("Rifle")
    bpy.context.scene.collection.children.link(coll)
    k = _Kit(coll)
    black = k.mat("Rifle_Polymer", (0.04, 0.042, 0.045), 0.0, 0.7)
    metal = k.mat("Rifle_Metal", (0.11, 0.115, 0.12), 0.8, 0.38)
    tan = k.mat("Rifle_Furniture", (0.42, 0.36, 0.26), 0.0, 0.75)
    magm = k.mat("Rifle_Magazine", (0.08, 0.08, 0.085), 0.35, 0.55)
    dot = k.mat("Rifle_SightDot", (1.0, 0.45, 0.05), 0.0, 0.4)
    root = bpy.data.objects.new("Rifle", None)
    coll.objects.link(root)
    bore = 0.055
    # Receivers.
    k.box("LowerReceiver", (0.028, 0.19, 0.036), (0, -0.025, 0.014), material=black, parent=root)
    k.box("UpperReceiver", (0.030, 0.25, 0.046), (0, -0.035, bore + 0.002), material=metal, parent=root)
    k.box("TopRail", (0.022, 0.25, 0.009), (0, -0.035, bore + 0.030), material=metal, parent=root, bevel=0.001)
    k.box("ChargingHandle", (0.022, 0.024, 0.012), (0, 0.098, bore + 0.016), material=metal, parent=root)
    k.box("EjectionPort", (0.004, 0.052, 0.017), (-0.0155, -0.022, bore + 0.004), material=black, parent=root, bevel=0.0)
    k.box("ForwardAssist", (0.012, 0.022, 0.014), (-0.019, 0.045, bore + 0.006), material=metal, parent=root, bevel=0.001)
    # Grip (same rake and place under the bore as the pistol's), trigger, guard.
    k.box("GripBody", (0.030, 0.045, 0.105), (0, 0.012, -0.034), rot=(-16, 0, 0), material=black, parent=root, taper=(0.9, 0.9))
    k.box("Trigger", (0.006, 0.006, 0.022), (0, -0.040, -0.006), rot=(-15, 0, 0), material=metal, parent=root)
    k.box("GuardBottom", (0.012, 0.075, 0.006), (0, -0.052, -0.026), material=black, parent=root)
    # Magazine well + a curved-looking (tapered, tilted) 30-round magazine.
    k.box("MagWell", (0.032, 0.078, 0.046), (0, -0.098, -0.010), material=black, parent=root)
    mag = k.box("Magazine", (0.024, 0.066, 0.175), (0, -0.112, -0.105), rot=(-14, 0, 0), material=magm, parent=root, taper=(1.0, 0.92))
    k.box("MagBaseplate", (0.030, 0.070, 0.010), (0, 0, -0.090), material=black, parent=mag)
    # Handguard (tan) with rails, barrel, gas block / front sight, muzzle device.
    k.box("Handguard", (0.052, 0.30, 0.056), (0, -0.312, bore), material=tan, parent=root, bevel=0.004)
    k.box("HandguardRail", (0.022, 0.29, 0.008), (0, -0.312, bore + 0.032), material=metal, parent=root, bevel=0.001)
    k.box("HandStop", (0.016, 0.018, 0.022), (0, -0.215, bore - 0.036), material=black, parent=root)
    k.cyl("Barrel", 0.0095, 0.22, (0, -0.57, bore), (90, 0, 0), metal, root)
    k.box("FrontSightBase", (0.018, 0.024, 0.040), (0, -0.445, bore + 0.040), material=metal, parent=root)
    k.box("FrontSightEarL", (0.003, 0.010, 0.020), (0.008, -0.445, bore + 0.068), material=metal, parent=root, bevel=0.0)
    k.box("FrontSightEarR", (0.003, 0.010, 0.020), (-0.008, -0.445, bore + 0.068), material=metal, parent=root, bevel=0.0)
    k.box("FrontSight", (0.0035, 0.004, 0.018), (0, -0.445, bore + 0.066), material=metal, parent=root, bevel=0.0)
    k.box("DotF", (0.0035, 0.002, 0.0035), (0, -0.4425, bore + 0.073), material=dot, parent=root, bevel=0.0)
    k.cyl("MuzzleDevice", 0.013, 0.05, (0, -0.705, bore), (90, 0, 0), metal, root, segments=8)
    k.cyl("Bore", 0.0055, 0.051, (0, -0.7055, bore), (90, 0, 0), black, root)
    # Rear sight: two short ears over a base; the notch is the gap between them.
    k.box("RearSightBase", (0.024, 0.026, 0.016), (0, 0.072, bore + 0.040), material=metal, parent=root)
    k.box("RearSightEarL", (0.004, 0.010, 0.016), (0.0075, 0.072, bore + 0.064), material=metal, parent=root, bevel=0.0)
    k.box("RearSightEarR", (0.004, 0.010, 0.016), (-0.0075, 0.072, bore + 0.064), material=metal, parent=root, bevel=0.0)
    k.box("DotL", (0.003, 0.002, 0.003), (0.0075, 0.0665, bore + 0.069), material=dot, parent=root, bevel=0.0)
    k.box("DotR", (0.003, 0.002, 0.003), (-0.0075, 0.0665, bore + 0.069), material=dot, parent=root, bevel=0.0)
    # Stock: buffer tube, body, butt pad.
    k.cyl("BufferTube", 0.016, 0.21, (0, 0.19, bore - 0.004), (90, 0, 0), metal, root)
    k.box("Stock", (0.040, 0.165, 0.062), (0, 0.272, bore - 0.020), material=tan, parent=root, bevel=0.004)
    k.box("StockCheek", (0.036, 0.11, 0.016), (0, 0.255, bore + 0.016), material=tan, parent=root, bevel=0.003)
    k.box("ButtPad", (0.044, 0.018, 0.115), (0, 0.362, bore - 0.034), material=black, parent=root, bevel=0.003)
    # Markers (Godot reads them by name). Sight line: rear aperture -> front post, both at
    # bore + 0.073.
    sight = bore + 0.073
    for name, loc in (("M_Grip", (0, 0, 0)), ("M_SupportGrip", (0, -0.29, bore - 0.028)),
                      ("M_Muzzle", (0, -0.732, bore)), ("M_RearSight", (0, 0.072, sight)),
                      ("M_FrontSight", (0, -0.445, sight)), ("M_EjectPort", (-0.020, -0.022, bore + 0.006)),
                      ("M_MagWell", (0, -0.100, -0.040)), ("M_Stock", (0, 0.371, bore - 0.020)),
                      ("M_Holster", (0, -0.17, bore))):
        k.empty(name, loc, root)
    k.export(root, args.out or os.path.join(PROJECT, "assets", "items", "rifle", "rifle.glb"))


def cmd_make_shotgun(args):
    """A 12-gauge pump-action. Origin at the top of the pistol grip (the same grip fit as the
    pistol and carbine holds it). The fore-end is its own node, "Pump", with M_SupportGrip on
    it: Godot slides the pump back and forth and the support hand rides it."""
    fresh_scene()
    coll = bpy.data.collections.new("Shotgun")
    bpy.context.scene.collection.children.link(coll)
    k = _Kit(coll)
    black = k.mat("Shotgun_Polymer", (0.04, 0.042, 0.045), 0.0, 0.7)
    metal = k.mat("Shotgun_Metal", (0.09, 0.095, 0.1), 0.85, 0.35)
    wood = k.mat("Shotgun_Wood", (0.36, 0.2, 0.1), 0.0, 0.6)
    bead = k.mat("Shotgun_Bead", (1.0, 0.85, 0.3), 0.3, 0.3)
    root = bpy.data.objects.new("Shotgun", None)
    coll.objects.link(root)
    bore = 0.05
    # Receiver (a long box, rounded off), loading port underneath, ejection port on the right.
    k.box("Receiver", (0.036, 0.215, 0.064), (0, -0.075, bore - 0.004), material=metal, parent=root, bevel=0.004)
    k.box("LoadPort", (0.022, 0.07, 0.004), (0, -0.10, bore - 0.037), material=black, parent=root, bevel=0.0)
    k.box("EjectPort", (0.004, 0.06, 0.022), (-0.0185, -0.07, bore + 0.006), material=black, parent=root, bevel=0.0)
    k.box("SightRib", (0.012, 0.20, 0.006), (0, -0.075, bore + 0.031), material=metal, parent=root, bevel=0.0)
    k.box("RearNotchL", (0.004, 0.008, 0.008), (0.006, 0.02, bore + 0.036), material=metal, parent=root, bevel=0.0)
    k.box("RearNotchR", (0.004, 0.008, 0.008), (-0.006, 0.02, bore + 0.036), material=metal, parent=root, bevel=0.0)
    # Grip (same rake and place as the pistol's), trigger, guard.
    k.box("GripBody", (0.030, 0.045, 0.105), (0, 0.012, -0.034), rot=(-16, 0, 0), material=black, parent=root, taper=(0.9, 0.9))
    k.box("Trigger", (0.006, 0.006, 0.022), (0, -0.040, -0.006), rot=(-15, 0, 0), material=metal, parent=root)
    k.box("GuardBottom", (0.012, 0.075, 0.006), (0, -0.052, -0.026), material=black, parent=root)
    k.box("GuardFront", (0.012, 0.006, 0.03), (0, -0.088, -0.012), material=black, parent=root)
    # Barrel and magazine tube under it.
    k.cyl("Barrel", 0.0115, 0.47, (0, -0.415, bore + 0.006), (90, 0, 0), metal, root, segments=14)
    k.cyl("Bore", 0.0095, 0.012, (0, -0.646, bore + 0.006), (90, 0, 0), black, root, segments=14)
    k.cyl("MagTube", 0.0105, 0.40, (0, -0.38, bore - 0.020), (90, 0, 0), metal, root, segments=12)
    k.cyl("TubeCap", 0.0125, 0.024, (0, -0.585, bore - 0.020), (90, 0, 0), metal, root, segments=12)
    k.box("BarrelClamp", (0.016, 0.02, 0.04), (0, -0.565, bore - 0.006), material=metal, parent=root)
    k.box("Bead", (0.005, 0.005, 0.005), (0, -0.63, bore + 0.020), material=bead, parent=root, bevel=0.0)
    # The pump: wooden fore-end with grooves round the tube; slides back on the action bars.
    pump = bpy.data.objects.new("Pump", None)
    coll.objects.link(pump)
    pump.parent = root
    pump.location = (0, -0.30, bore - 0.020)
    k.box("Forend", (0.046, 0.17, 0.042), (0, 0, -0.004), material=wood, parent=pump, bevel=0.006)
    for i in range(6):
        k.box("Groove%d" % i, (0.048, 0.006, 0.040), (0, -0.06 + i * 0.024, -0.004), material=black, parent=pump, bevel=0.0)
    k.box("ActionBarL", (0.003, 0.12, 0.006), (0.019, 0.13, 0.004), material=metal, parent=pump, bevel=0.0)
    k.box("ActionBarR", (0.003, 0.12, 0.006), (-0.019, 0.13, 0.004), material=metal, parent=pump, bevel=0.0)
    k.empty("M_SupportGrip", (0, 0.0, -0.026), pump)
    # Stock: wood, dropping slightly toward the butt, with a rubber pad.
    k.box("Stock", (0.042, 0.30, 0.066), (0, 0.19, bore - 0.034), rot=(-4, 0, 0), material=wood, parent=root, bevel=0.006, taper=(0.9, 1.0))
    k.box("StockComb", (0.036, 0.22, 0.02), (0, 0.17, bore - 0.0), rot=(-2, 0, 0), material=wood, parent=root, bevel=0.005)
    k.box("ButtPad", (0.046, 0.02, 0.12), (0, 0.345, bore - 0.048), rot=(-4, 0, 0), material=black, parent=root, bevel=0.004)
    sight = bore + 0.040
    for name, loc in (("M_Grip", (0, 0, 0)), ("M_Muzzle", (0, -0.652, bore + 0.006)),
                      ("M_RearSight", (0, 0.02, sight)), ("M_FrontSight", (0, -0.63, sight)),
                      ("M_EjectPort", (-0.022, -0.07, bore + 0.006)), ("M_LoadPort", (0, -0.10, bore - 0.040)),
                      ("M_MagWell", (0, -0.10, bore - 0.040)), ("M_Stock", (0, 0.352, bore - 0.045)),
                      ("M_Holster", (0, -0.17, bore))):
        k.empty(name, loc, root)
    k.export(root, args.out or os.path.join(PROJECT, "assets", "items", "shotgun", "shotgun.glb"))


def cmd_make_bat(args):
    """A wooden baseball bat. Held at the handle near the knob: the GripBody empty (Godot +Y =
    authored +Z, up the handle) sits in the fist, the bat runs on up out of the top of it."""
    fresh_scene()
    coll = bpy.data.collections.new("Bat")
    bpy.context.scene.collection.children.link(coll)
    k = _Kit(coll)
    wood = k.mat("Bat_Wood", (0.62, 0.44, 0.25), 0.0, 0.5)
    tape = k.mat("Bat_Tape", (0.06, 0.06, 0.07), 0.0, 0.85)
    root = bpy.data.objects.new("Bat", None)
    coll.objects.link(root)
    k.cyl("Knob", 0.024, 0.02, (0, 0, -0.105), (0, 0, 0), wood, root, segments=14)
    k.cyl("Handle", 0.0155, 0.20, (0, 0, -0.0), (0, 0, 0), tape, root, segments=12)
    k.cyl("Taper", 0.0175, 0.24, (0, 0, 0.22), (0, 0, 0), wood, root, segments=14, r2=0.031)
    k.cyl("Barrel", 0.031, 0.30, (0, 0, 0.49), (0, 0, 0), wood, root, segments=16, r2=0.035)
    k.cyl("EndCap", 0.035, 0.03, (0, 0, 0.655), (0, 0, 0), wood, root, segments=16, r2=0.028)
    for name, loc in (("GripBody", (0, 0, -0.03)), ("M_Tip", (0, 0, 0.66)), ("M_Grip", (0, 0, 0)), ("M_Holster", (0, 0, 0.25))):
        k.empty(name, loc, root)
    k.export(root, args.out or os.path.join(PROJECT, "assets", "items", "bat", "bat.glb"))


def cmd_make_machete(args):
    """A machete: a long single-edged blade on a riveted handle. GripBody up the handle (+Z
    authored), the edge facing forward (-Y authored = Godot -Z, along the index finger)."""
    fresh_scene()
    coll = bpy.data.collections.new("Machete")
    bpy.context.scene.collection.children.link(coll)
    k = _Kit(coll)
    steel = k.mat("Machete_Steel", (0.62, 0.63, 0.65), 0.9, 0.3)
    edge = k.mat("Machete_Edge", (0.85, 0.86, 0.88), 1.0, 0.15)
    grip = k.mat("Machete_Grip", (0.08, 0.06, 0.05), 0.0, 0.7)
    root = bpy.data.objects.new("Machete", None)
    coll.objects.link(root)
    k.box("Handle", (0.024, 0.034, 0.13), (0, 0.004, 0.0), material=grip, parent=root, bevel=0.005)
    k.box("Guard", (0.012, 0.05, 0.012), (0, -0.004, 0.072), material=steel, parent=root, bevel=0.002)
    k.box("Blade", (0.004, 0.048, 0.40), (0, -0.002, 0.28), material=steel, parent=root, bevel=0.0, taper=(1.0, 1.0))
    k.box("Edge", (0.0025, 0.008, 0.40), (0, -0.028, 0.28), material=edge, parent=root, bevel=0.0)
    k.box("Tip", (0.004, 0.05, 0.06), (0, -0.008, 0.505), rot=(25, 0, 0), material=steel, parent=root, bevel=0.0)
    for zz in (-0.035, 0.02):
        k.cyl("Rivet%d" % int(zz * 1000), 0.004, 0.026, (0, 0.004, zz), (0, 90, 0), steel, root, segments=8)
    for name, loc in (("GripBody", (0, 0.004, -0.0)), ("M_Tip", (0, -0.01, 0.53)), ("M_Grip", (0, 0, 0)), ("M_Holster", (0, 0, 0.2))):
        k.empty(name, loc, root)
    k.export(root, args.out or os.path.join(PROJECT, "assets", "items", "machete", "machete.glb"))


def cmd_make_cuts(args):
    sys.path.insert(0, os.path.dirname(__file__))
    import make_cuts
    make_cuts.run(args.src, args.bone_map, args.out)


def cmd_import_mixamo(args):
    sys.path.insert(0, os.path.dirname(__file__))
    import import_mixamo
    import_mixamo.run(args.src, args.out, args.name, args.tex_size)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    p = argparse.ArgumentParser(prog="ultra_blender")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("make-edit")
    e = sub.add_parser("export-actions")
    e.add_argument("--blend")
    e.add_argument("--actions")
    e.add_argument("--new-only", action="store_true")
    m = sub.add_parser("mirror")
    m.add_argument("--blend")
    m.add_argument("--action", required=True)
    m.add_argument("--out", required=True)
    mp = sub.add_parser("make-pistol")
    mp.add_argument("--out")
    mr = sub.add_parser("make-rifle")
    mr.add_argument("--out")
    ms = sub.add_parser("make-shotgun")
    ms.add_argument("--out")
    mb = sub.add_parser("make-bat")
    mb.add_argument("--out")
    mm = sub.add_parser("make-machete")
    mm.add_argument("--out")
    mc = sub.add_parser("make-cuts")
    mc.add_argument("--src", default=os.path.join(PROJECT, "assets", "characters", "mannequin", "mannequin.glb"))
    mc.add_argument("--bone-map", default=os.path.join(PROJECT, "addons", "ultra_controller", "import", "bone_maps", "ue_mannequin_humanoid.tres"))
    mc.add_argument("--out", default=os.path.join(PROJECT, "assets", "characters", "mannequin", "mannequin_cuts.glb"))
    im = sub.add_parser("import-mixamo")
    im.add_argument("--src", default=os.path.join(PROJECT, "art_src", "zombie", "Ch10_nonPBR.fbx"))
    im.add_argument("--out", default=os.path.join(PROJECT, "assets", "characters", "zombie", "zombie.glb"))
    im.add_argument("--name", default="Zombie")
    im.add_argument("--tex-size", type=int, default=2048)
    mt = sub.add_parser("mixamo-test")
    mt.add_argument("--action")
    mt.add_argument("--name")
    a = p.parse_args(argv)
    {"make-edit": cmd_make_edit, "export-actions": cmd_export_actions, "mirror": cmd_mirror,
     "make-pistol": cmd_make_pistol, "make-rifle": cmd_make_rifle, "make-shotgun": cmd_make_shotgun, "make-bat": cmd_make_bat, "make-machete": cmd_make_machete, "mixamo-test": cmd_mixamo_test, "make-cuts": cmd_make_cuts, "import-mixamo": cmd_import_mixamo}[a.cmd](a)


if __name__ == "__main__":
    main()
