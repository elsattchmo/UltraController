@tool
extends EditorScenePostImport
## Post-import for the UAL mannequin (and any humanoid GLB using the same conventions).
##  1. loop modes from rules        2. remove rest-constant & duplicate tracks
##  3. bake *_RM / Turn_* root motion into RootMotionCurve resources
##  4. save the clips as an AnimationLibrary next to the model
##  5. split the mesh into Body / Head and tag every vertex with its body region (CUSTOM0)

const ROOT_TRACK := "%GeneralSkeleton:Root"


func _post_import(scene: Node) -> Object:
	var src := get_source_file()
	var dir := src.get_base_dir()
	var skel := scene.find_child("GeneralSkeleton", true, false) as Skeleton3D
	if skel == null:
		push_error("UltraController import: no GeneralSkeleton in %s (check the BoneMap retarget)" % src)
		return scene
	var player := scene.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if player:
		_process_animations(player, skel, dir)
	_split_mesh(skel)
	return scene


func _process_animations(player: AnimationPlayer, skel: Skeleton3D, dir: String) -> void:
	var lib := AnimationLibrary.new()
	var rm_dir := dir + "/rootmotion"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(rm_dir))
	var removed := 0
	var baked := 0
	for name in player.get_animation_list():
		var a := player.get_animation(name).duplicate(true) as Animation
		if String(name) in UltraImportTools.PURGED:
			continue
		if name == &"RESET":
			lib.add_animation(name, a)
			continue
		a.loop_mode = UltraImportTools.loop_mode_for(name) as Animation.LoopMode
		removed += UltraImportTools.clean_tracks(a, skel)
		if String(name).ends_with("_RM"):
			var c := UltraImportTools.bake_root_motion(a, name, ROOT_TRACK, skel.motion_scale)
			ResourceSaver.save(c, "%s/%s.tres" % [rm_dir, name])
			baked += 1
		lib.add_animation(name, a)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir + "/anims"))
	var err := ResourceSaver.save(lib, dir + "/anims/ual.res")
	print("UltraController import: %d clips -> %s/anims/ual.res (err %d), %d tracks trimmed, %d root-motion curves" % [lib.get_animation_list().size(), dir, err, removed, baked])
	# The wrapper scene references the saved library; keep the imported scene light.
	for l in player.get_animation_library_list():
		player.remove_animation_library(l)


func _split_mesh(skel: Skeleton3D) -> void:
	var src_mi: MeshInstance3D = null
	for c in skel.get_children():
		if c is MeshInstance3D:
			src_mi = c
			break
	if src_mi == null or src_mi.mesh == null:
		return
	var mesh := src_mi.mesh as ArrayMesh
	var body := ArrayMesh.new()
	var head := ArrayMesh.new()
	for si in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(si)
		var mat := mesh.surface_get_material(si)
		var regions := UltraImportTools.vertex_regions(arrays, src_mi.skin, skel)
		# First-person hide set: head AND neck, so the camera never sees the inside of the neck.
		var fp_w := UltraImportTools.vertex_weight_on(arrays, src_mi.skin, skel, PackedStringArray(["Neck", "Head"]))
		var custom := PackedFloat32Array()
		custom.resize(regions.size())
		for v in regions.size():
			custom[v] = float(regions[v])
		arrays[Mesh.ARRAY_CUSTOM0] = custom
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var body_idx := PackedInt32Array()
		var head_idx := PackedInt32Array()
		for t in range(0, idx.size(), 3):
			var hv := 0
			for k in 3:
				if fp_w[idx[t + k]] > 0.5:
					hv += 1
			var target := head_idx if hv >= 2 else body_idx
			target.append(idx[t]); target.append(idx[t + 1]); target.append(idx[t + 2])
		var fmt := Mesh.ARRAY_FORMAT_CUSTOM0 | (Mesh.ARRAY_CUSTOM_R_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
		var flags := fmt | mesh.surface_get_format(si) & (Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS)
		for pair: Array in [[body, body_idx], [head, head_idx]]:
			if (pair[1] as PackedInt32Array).is_empty():
				continue
			var a := arrays.duplicate()
			a[Mesh.ARRAY_INDEX] = pair[1]
			(pair[0] as ArrayMesh).add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a, [], {}, flags)
			(pair[0] as ArrayMesh).surface_set_material((pair[0] as ArrayMesh).get_surface_count() - 1, mat)
	body.resource_name = "mannequin_body"
	head.resource_name = "mannequin_head"
	src_mi.name = "BodyMesh"
	src_mi.mesh = body
	var head_mi := MeshInstance3D.new()
	head_mi.name = "HeadMesh"
	head_mi.mesh = head
	head_mi.skin = src_mi.skin
	skel.add_child(head_mi)
	head_mi.owner = src_mi.owner
	head_mi.skeleton = src_mi.skeleton
	head_mi.transform = src_mi.transform
