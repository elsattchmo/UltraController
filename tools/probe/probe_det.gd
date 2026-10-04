extends SceneTree
func _init() -> void:
	var scene: Node = (load("res://assets/characters/mannequin/mannequin.glb") as PackedScene).instantiate()
	root.add_child(scene)
	var skel := scene.find_child("GeneralSkeleton", true, false) as Skeleton3D
	var lib: AnimationLibrary = load("res://assets/characters/mannequin/anims/ual.res")
	UltraPoseSampler.pose(lib.get_animation("Pistol_Idle"), skel, 0.0)
	for b in ["Hips", "RightHand", "LeftHand", "RightLowerArm"]:
		var g := UltraPoseSampler.global_pose(skel, skel.find_bone(b))
		print(b, " det=", g.basis.determinant(), " scale=", g.basis.get_scale())
	var d: ItemDefinition = load("res://assets/items/pistol/pistol_item.tres")
	print("grip det ", d.grip_offset.basis.determinant(), " support det ", d.support_offset.basis.determinant())
	var fit: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://art_src/pistol_fit.json"))
	var r: Array = fit["gun_in_model_space_rows"]
	var gb := Basis(Vector3(r[0][0], r[1][0], r[2][0]), Vector3(r[0][1], r[1][1], r[2][1]), Vector3(r[0][2], r[1][2], r[2][2]))
	print("gun det ", gb.determinant(), " ", gb)
	var pn: Node3D = (load("res://assets/items/pistol/pistol.glb") as PackedScene).instantiate()
	print("pistol node basis ", (pn.get_child(0) as Node3D).basis, " det ", (pn.get_child(0) as Node3D).basis.determinant())
	quit()
