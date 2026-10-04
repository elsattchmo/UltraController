extends SceneTree
func _init() -> void:
	var scene: Node = (load("res://assets/characters/mannequin/mannequin.glb") as PackedScene).instantiate()
	root.add_child(scene)
	var sk := scene.find_child("GeneralSkeleton", true, false) as Skeleton3D
	var lib: AnimationLibrary = load("res://assets/characters/mannequin/anims/ual.res")
	var a := lib.get_animation("Death_A")
	var out := []
	for i in 19:
		var t := a.length * i / 18.0
		UltraPoseSampler.pose(a, sk, t)
		out.append("%.2f:h%.2f/head%.2f,%.2f" % [t, UltraPoseSampler.global_pose(sk, sk.find_bone("Hips")).origin.y, UltraPoseSampler.global_pose(sk, sk.find_bone("Head")).origin.y, UltraPoseSampler.global_pose(sk, sk.find_bone("Head")).origin.z])
	print("DA ", " ".join(out))
	quit()
