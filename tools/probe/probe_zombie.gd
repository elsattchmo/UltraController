extends SceneTree
## Stage 0c probe: what the imported zombie scene looks like after the humanoid retarget.
func _init() -> void:
	var inst := (load("res://assets/characters/zombie/zombie.glb") as PackedScene).instantiate()
	root.add_child(inst)
	print("ZP tree:")
	_dump(inst, 0)
	var sk := inst.find_child("GeneralSkeleton", true, false) as Skeleton3D
	if sk == null:
		print("ZP no GeneralSkeleton")
		quit()
		return
	var names := []
	for b in sk.get_bone_count():
		names.append("%s<%d" % [sk.get_bone_name(b), sk.get_bone_parent(b)])
	print("ZP bones (%d): %s" % [sk.get_bone_count(), names])
	print("ZP has Root: ", sk.find_bone("Root") >= 0, " motion_scale ", sk.motion_scale, " scale ", sk.global_transform.basis.get_scale())
	var hips := sk.find_bone("Hips")
	print("ZP hips rest origin ", sk.get_bone_rest(hips).origin, " global rest ", sk.get_bone_global_rest(hips).origin)
	for n in ["Head", "LeftFoot", "LeftToes", "LeftHand", "RightHand", "Neck", "Chest", "UpperChest"]:
		var b := sk.find_bone(n)
		print("ZP   %s global rest %s" % [n, sk.get_bone_global_rest(b).origin if b >= 0 else "MISSING"])
	var mi := inst.find_child("BodyMesh", true, false) as MeshInstance3D
	if mi:
		print("ZP BodyMesh aabb ", mi.get_aabb(), " surfaces ", mi.mesh.get_surface_count(), " skin binds ", mi.skin.get_bind_count() if mi.skin else -1)
		for si in mi.mesh.get_surface_count():
			var m := mi.mesh.surface_get_material(si)
			print("ZP   surface %d material %s %s" % [si, m.resource_name if m else "none", (m as BaseMaterial3D).albedo_texture.get_size() if m is BaseMaterial3D and (m as BaseMaterial3D).albedo_texture else "no albedo"])
	var ap := inst.find_child("AnimationPlayer", true, false)
	print("ZP AnimationPlayer ", ap != null)
	quit()


func _dump(n: Node, d: int) -> void:
	if d > 3:
		return
	print("ZP  ", "  ".repeat(d), n.name, " (", n.get_class(), ")")
	for c in n.get_children():
		if c is Skeleton3D and d >= 1:
			print("ZP  ", "  ".repeat(d + 1), c.name, " (Skeleton3D)")
			for cc in c.get_children():
				print("ZP  ", "  ".repeat(d + 2), cc.name, " (", cc.get_class(), ")")
			continue
		_dump(c, d + 1)
