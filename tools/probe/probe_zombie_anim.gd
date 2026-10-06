extends SceneTree
## Stage 0c probe: do the Z_* Mixamo clips play on the imported Romero? Pose sanity per clip.
func _initialize() -> void:
	var inst := (load("res://assets/characters/zombie/zombie.glb") as PackedScene).instantiate()
	root.add_child(inst)
	var sk := inst.find_child("GeneralSkeleton", true, false) as Skeleton3D
	var ap := inst.find_child("AnimationPlayer", true, false) as AnimationPlayer
	var lib := load("res://assets/characters/mannequin/anims/mixamo.res") as AnimationLibrary
	ap.add_animation_library("mixamo", lib)
	await process_frame
	var hips := sk.find_bone("Hips")
	var head := sk.find_bone("Head")
	var lf := sk.find_bone("LeftFoot")
	var rf := sk.find_bone("RightFoot")
	var lh := sk.find_bone("LeftHand")
	var rh := sk.find_bone("RightHand")
	for clip in ["Z_Walk", "Z_Creep", "Z_Run", "Z_Idle1", "Z_Crawl", "Z_Swipe", "Z_StandUp", "Z_Hit1", "Z_Agonize"]:
		var a := lib.get_animation(clip)
		var tracks := a.get_track_count()
		var rows := []
		for f in [0.0, 0.25, 0.5, 0.75]:
			ap.play("mixamo/" + clip)
			ap.seek(a.length * f, true)
			ap.advance(0.0)
			await process_frame
			var g := func(b: int) -> Vector3: return sk.get_bone_global_pose(b).origin
			var hp: Vector3 = g.call(hips)
			rows.append("t%.0f%% hips(%.2f,%.2f,%.2f) head y %.2f feet y %.2f/%.2f hands y %.2f/%.2f reach %.2f" % [f * 100, hp.x, hp.y, hp.z, g.call(head).y, g.call(lf).y, g.call(rf).y, g.call(lh).y, g.call(rh).y, (g.call(lh) as Vector3).distance_to(g.call(rh))])
		print("ZA %s: %d tracks, %.2fs" % [clip, tracks, a.length])
		for r in rows:
			print("ZA    ", r)
	quit()
