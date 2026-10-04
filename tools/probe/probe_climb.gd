extends SceneTree
func _init() -> void:
	var c: RootMotionCurve = load("res://assets/characters/mannequin/rootmotion/ClimbUp_1m_RM.tres")
	var out := []
	for i in 11:
		var t := c.length * i / 10.0
		out.append("%.2f:%s" % [t, c.sample_pos(t).snappedf(0.01)])
	print("ClimbUp root: ", " ".join(out))
	var scene: Node = (load("res://assets/characters/mannequin/mannequin.glb") as PackedScene).instantiate()
	root.add_child(scene)
	var sk := scene.find_child("GeneralSkeleton", true, false) as Skeleton3D
	var lib: AnimationLibrary = load("res://assets/characters/mannequin/anims/ual.res")
	for clip in ["Ledge_Hang", "Climb_Ladder", "Climb_Wall", "Pipe_Climb", "ClimbUp_1m_RM", "Run_Jump"]:
		var a := lib.get_animation(clip)
		UltraPoseSampler.pose(a, sk, 0.0)
		var lh := UltraPoseSampler.global_pose(sk, sk.find_bone("LeftHand")).origin
		var rh := UltraPoseSampler.global_pose(sk, sk.find_bone("RightHand")).origin
		var lf := UltraPoseSampler.global_pose(sk, sk.find_bone("LeftFoot")).origin
		var hips := UltraPoseSampler.global_pose(sk, sk.find_bone("Hips")).origin
		print("%-14s len %.2f  hands L%s R%s  footL %s hips %s" % [clip, a.length, lh.snappedf(0.01), rh.snappedf(0.01), lf.snappedf(0.01), hips.snappedf(0.01)])
	# Hand height over the climb-up clip
	var a2 := lib.get_animation("ClimbUp_1m_RM")
	var hs := []
	for i in 9:
		var t := a2.length * i / 8.0
		UltraPoseSampler.pose(a2, sk, t)
		hs.append("%.2f: hands %.2f hips %s" % [t, UltraPoseSampler.global_pose(sk, sk.find_bone("RightHand")).origin.y, UltraPoseSampler.global_pose(sk, sk.find_bone("Hips")).origin.snappedf(0.01)])
	print("\n".join(hs))
	quit()
