extends SceneTree
## Finger curl in the pistol clips vs idle: how closed is the right hand?
func _init() -> void:
	var scene: Node = (load("res://assets/characters/mannequin/mannequin.glb") as PackedScene).instantiate()
	root.add_child(scene)
	var sk := scene.find_child("GeneralSkeleton", true, false) as Skeleton3D
	var lib: AnimationLibrary = load("res://assets/characters/mannequin/anims/ual.res")
	var names := []
	for b in sk.get_bone_count():
		var n := sk.get_bone_name(b)
		if n.begins_with("RightIndex") or n.begins_with("RightMiddle") or n.begins_with("RightThumb") or n.begins_with("LeftIndex"):
			names.append(n)
	print("FING bones ", names)
	for clip in ["Pistol_Idle", "Pistol_Aim_Neutral", "Pistol_Shoot", "Pistol_Reload", "Idle_A", "Walk_Carry"]:
		var a := lib.get_animation(clip)
		UltraPoseSampler.pose(a, sk, 0.1)
		var parts := []
		for n in ["RightIndexProximal", "RightIndexIntermediate", "RightMiddleProximal", "RightThumbProximal", "LeftIndexProximal", "LeftMiddleProximal"]:
			var b := sk.find_bone(n)
			if b < 0:
				continue
			var q := sk.get_bone_pose_rotation(b)
			parts.append("%s %.0f" % [n.replace("Right", "R").replace("Left", "L"), rad_to_deg(q.angle_to(sk.get_bone_rest(b).basis.get_rotation_quaternion()))])
		var has_track := false
		for t in a.get_track_count():
			if String(a.track_get_path(t)).contains("RightIndex"):
				has_track = true
		print("FING %-20s finger tracks %s | %s" % [clip, has_track, ", ".join(parts)])
	quit()
