extends SceneTree
## Is the retargeted skeleton mirror-symmetric (rest_R == M rest_L M, M = diag(-1,1,1))?
func _init() -> void:
	var scene: Node = (load("res://assets/characters/mannequin/mannequin.glb") as PackedScene).instantiate()
	root.add_child(scene)
	var sk := scene.find_child("GeneralSkeleton", true, false) as Skeleton3D
	var M := Basis(Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1))
	var worst := 0.0
	var names := []
	for b in sk.get_bone_count():
		var n := sk.get_bone_name(b)
		if not n.begins_with("Left"):
			continue
		var rb := sk.find_bone("Right" + n.substr(4))
		if rb < 0:
			continue
		var l := sk.get_bone_rest(b)
		var r := sk.get_bone_rest(rb)
		var ml := M * l.basis * M
		var err := (ml.get_rotation_quaternion().angle_to(r.basis.get_rotation_quaternion()))
		var perr := (M * l.origin).distance_to(r.origin)
		worst = maxf(worst, rad_to_deg(err))
		if rad_to_deg(err) > 1.0 or perr > 0.005:
			names.append("%s rot %.1f pos %.3f" % [n, rad_to_deg(err), perr])
	print("MIRROR worst rot err %.2f deg; off: %s" % [worst, names])
	quit()
