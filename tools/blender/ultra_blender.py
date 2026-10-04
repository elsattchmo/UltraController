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
    mt = sub.add_parser("mixamo-test")
    mt.add_argument("--action")
    mt.add_argument("--name")
    a = p.parse_args(argv)
    {"make-edit": cmd_make_edit, "export-actions": cmd_export_actions, "mirror": cmd_mirror,
     "make-pistol": cmd_make_pistol, "mixamo-test": cmd_mixamo_test}[a.cmd](a)


if __name__ == "__main__":
    main()
