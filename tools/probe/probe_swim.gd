extends SceneTree
## Where are head / hips / feet in the swim clips (model space, +Z forward before the 180 turn)?
func _init() -> void:
	var scene: Node = (load("res://assets/characters/mannequin/mannequin.glb") as PackedScene).instantiate()
	root.add_child(scene)
	var sk := scene.find_child("GeneralSkeleton", true, false) as Skeleton3D
	var lib: AnimationLibrary = load("res://assets/characters/mannequin/anims/ual.res")
	for clip in ["Swim_Idle", "Swim_Fwd", "Idle"]:
		var a := lib.get_animation(clip)
		for f in 3:
			var t := a.length * f / 3.0
			UltraPoseSampler.pose(a, sk, t)
			var g := func(b: String) -> Vector3: return UltraPoseSampler.global_pose(sk, sk.find_bone(b)).origin.snappedf(0.01)
			print("%-10s len %.2f t %.2f head %s hips %s footL %s handR %s" % [clip, a.length, t, g.call("Head"), g.call("Hips"), g.call("LeftFoot"), g.call("RightHand")])
	quit()
