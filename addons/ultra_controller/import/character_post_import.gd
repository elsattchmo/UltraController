@tool
extends EditorScenePostImport
## Post-import for a plain humanoid CHARACTER model (a Mixamo zombie, ...): skinned meshes only,
## retargeted to the humanoid profile at import (`GeneralSkeleton`, see the .import file).
##  1. the skinned mesh is named "BodyMesh" (BodyProfile.body_mesh_name); several meshes keep
##     their own names (Body is the largest)
##  2. an AnimationPlayer exists (UltraCharacter builds the whole animation stack around it; a
##     glTF with no clips has none)
## No head split, no CUSTOM0 region tags and no clip libraries (the mannequin's script does those):
## runtime regions come from the skin weights (UltraBodyFX._regions_for) and clips come from the
## intake into their own library.


func _post_import(scene: Node) -> Object:
	var src := get_source_file()
	var skel := scene.find_child("GeneralSkeleton", true, false) as Skeleton3D
	if skel == null:
		push_error("UltraController import: no GeneralSkeleton in %s (check the BoneMap retarget)" % src)
		return scene
	var biggest: MeshInstance3D = null
	var biggest_n := -1
	for c in skel.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).mesh:
			var n := (c as MeshInstance3D).mesh.get_surface_count()
			var v := 0
			for si in n:
				v += ((c as MeshInstance3D).mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			if v > biggest_n:
				biggest_n = v
				biggest = c
	if biggest:
		biggest.name = "BodyMesh"
	if scene.find_child("AnimationPlayer", true, false) == null:
		var ap := AnimationPlayer.new()
		ap.name = "AnimationPlayer"
		scene.add_child(ap)
		ap.owner = scene
	print("UltraController import: %s - %d bones, body mesh %d vertices, motion_scale %.4f" % [src.get_file(), skel.get_bone_count(), biggest_n, skel.motion_scale])
	return scene
