"""Mixamo character FBX -> a clean GLB for Godot (Blender 5.0, headless). Called by ultra_blender.py:

    blender --background --python tools/blender/ultra_blender.py -- import-mixamo
        [--src art_src/zombie/Ch10_nonPBR.fbx] [--out assets/characters/zombie/zombie.glb]
        [--name Zombie] [--tex-size 2048]

What it does (the Godot side - bone retarget, rest fix - happens at import, see the .import file):
  * imports the skinned FBX without animation, leaf bones dropped, Mixamo's bone orientation kept
    (the retargeter's rest fixer expects the T-pose as authored);
  * bakes the cm / Y-up object transforms into the data (metres, character standing on Z, feet at 0);
  * renames the bones (and vertex groups) `mixamorigN:Hips` -> `mixamorig_Hips` - Godot's own
    spelling of that prefix, so the stock `bone_maps/mixamo_humanoid.tres` applies;
  * names the armature object `--name` (the Godot import path is `<name>/Skeleton3D`);
  * keeps only albedo + normal per material (a Mixamo "nonPBR" export is specular / glossiness; the
    exporter would wire glossiness up as metal-rough and look wrong) with a constant roughness;
  * shrinks the textures (a Mixamo export carries 4096 x 4096 maps: 8 of them are ~0.5 GB of GPU
    memory per distinct character): albedo to `--tex-size`, normals to half of that, WebP;
  * exports a GLB: armature + meshes + materials, skins, no animations.
Meshes and materials are kept as they are (Romero: one mesh, two materials) - the cut-set builder
copes with several materials.
"""
import bpy, os, re


def log(*a):
    print("[import_mixamo]", *a, flush=True)


def run(src, out_path, name, tex_size):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.fbx(filepath=src, use_anim=False, ignore_leaf_bones=True,
                             automatic_bone_orientation=False)
    arm = next(o for o in bpy.context.scene.objects if o.type == "ARMATURE")
    meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    log("armature", arm.name, "bones", len(arm.data.bones), "meshes", [m.name for m in meshes])

    # Bake the import's object transforms (scale 0.01, rotation X 90 deg) into the data.
    bpy.ops.object.select_all(action="DESELECT")
    for o in [arm] + meshes:
        o.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)

    # Bones and vertex groups: mixamorig5:Hips -> mixamorig_Hips.
    n_ren = 0
    for b in arm.data.bones:
        new = re.sub(r"^mixamorig\d*:", "mixamorig_", b.name)
        if new != b.name:
            for m in meshes:
                vg = m.vertex_groups.get(b.name)
                if vg:
                    vg.name = new
            b.name = new
            n_ren += 1
    log("renamed", n_ren, "bones")

    arm.name = name
    arm.data.name = name + "Armature"

    # Feet on the ground: lift so the lowest vertex sits at z = 0.
    lo = min((m.matrix_world @ v.co).z for m in meshes for v in m.data.vertices)
    if abs(lo) > 1e-4:
        for o in [arm] + meshes:
            o.location.z -= lo
        bpy.ops.object.select_all(action="DESELECT")
        for o in [arm] + meshes:
            o.select_set(True)
        bpy.context.view_layer.objects.active = arm
        bpy.ops.object.transform_apply(location=True, rotation=False, scale=False)
        log("lifted by", -lo)

    # Materials: albedo + normal only, roughness constant; drop the specular / glossiness nodes.
    keep = set()
    for mat in bpy.data.materials:
        if not mat.use_nodes:
            continue
        nt = mat.node_tree
        bsdf = next((n for n in nt.nodes if n.type == "BSDF_PRINCIPLED"), None)
        if bsdf is None:
            continue
        used = set()
        for sock in ("Base Color", "Normal"):
            for link in bsdf.inputs[sock].links:
                node = link.from_node
                stack = [node]
                while stack:
                    n = stack.pop()
                    used.add(n)
                    for i in n.inputs:
                        for l2 in i.links:
                            stack.append(l2.from_node)
        for sock in ("Roughness", "Metallic", "Specular IOR Level", "Emission Color"):
            if sock in bsdf.inputs:
                for link in list(bsdf.inputs[sock].links):
                    nt.links.remove(link)
        bsdf.inputs["Roughness"].default_value = 0.72
        bsdf.inputs["Metallic"].default_value = 0.0
        if "Specular IOR Level" in bsdf.inputs:
            bsdf.inputs["Specular IOR Level"].default_value = 0.25
        for n in list(nt.nodes):
            if n.type == "TEX_IMAGE" and n not in used:
                nt.nodes.remove(n)
            elif n.type == "TEX_IMAGE" and n.image:
                keep.add(n.image)
        log("material", mat.name, "keeps", [n.image.name for n in nt.nodes if n.type == "TEX_IMAGE"])
    # Textures: shrink (albedo to tex_size, normals to half) and make sure they are packed.
    for img in list(bpy.data.images):
        if img not in keep:
            bpy.data.images.remove(img)
            continue
        size = tex_size // 2 if "normal" in img.name.lower() else tex_size
        if img.size[0] > size or img.size[1] > size:
            before = tuple(img.size)
            img.scale(size, size)
            log("texture", img.name, before, "->", tuple(img.size))
        if img.packed_file is None and img.has_data:
            img.pack()

    bpy.ops.object.select_all(action="DESELECT")
    for o in [arm] + meshes:
        o.select_set(True)
    bpy.context.view_layer.objects.active = arm
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    bpy.ops.export_scene.gltf(filepath=out_path, use_selection=True, export_animations=False,
                              export_skins=True, export_morph=False, export_apply=False,
                              export_image_format="WEBP", export_image_quality=88)
    log("wrote", out_path, "%.1f MB" % (os.path.getsize(out_path) / 1e6))
