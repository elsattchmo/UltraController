extends UltraTestSuite
## Import pipeline: retarget, library, loops, root motion, mesh split, animation set.

const DIR := "res://assets/characters/mannequin/"


func test_skeleton_is_humanoid() -> void:
	var scene := (load(DIR + "mannequin.glb") as PackedScene).instantiate()
	var sk := scene.find_child("GeneralSkeleton", true, false) as Skeleton3D
	if check(sk != null, "GeneralSkeleton exists"):
		var prof := SkeletonProfileHumanoid.new()
		var missing := []
		for i in prof.bone_size:
			var n := prof.get_bone_name(i)
			if n in [&"LeftEye", &"RightEye", &"Jaw"]:
				continue
			if sk.find_bone(n) < 0:
				missing.append(n)
		check(missing.is_empty(), "humanoid bones present, missing: %s" % [missing])
		near(sk.motion_scale, 0.9167, 0.01, "motion scale = hip height")
	var body := scene.find_child("BodyMesh", true, false) as MeshInstance3D
	var head := scene.find_child("HeadMesh", true, false) as MeshInstance3D
	check(body != null and head != null, "Body/Head meshes split")
	if body and head:
		var ba := body.mesh.surface_get_arrays(0)
		check(ba[Mesh.ARRAY_CUSTOM0] != null, "BodyMesh carries region ids in CUSTOM0")
		var ht := (head.mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
		check(ht > 200 and ht < 1500, "head+neck triangles in range (%d)" % ht)
	scene.free()


func test_library_and_loops() -> void:
	var lib: AnimationLibrary = load(DIR + "anims/ual.res")
	check(lib.get_animation_list().size() >= 179 - UltraImportTools.PURGED.size(), "the 178 clips + RESET, less the purged ones (%d)" % lib.get_animation_list().size())
	for n in ["Walk", "Jog", "Sprint", "Idle_A", "Jump_air", "Crouch_Walk", "Ledge_Hang", "Swim_Fwd", "Climb_Ladder"]:
		check(lib.get_animation(n).loop_mode == Animation.LOOP_LINEAR, "%s loops" % n)
	for n in ["Jump_Start", "Jump_Land", "Roll_RM", "Pistol_Shoot", "Death_A", "Interact"]:
		check(lib.get_animation(n).loop_mode == Animation.LOOP_NONE, "%s is one-shot" % n)
	var a := lib.get_animation("Sword_Regular_C_RM")
	var seen := {}
	var dup := 0
	for t in a.get_track_count():
		var k := "%s|%d" % [a.track_get_path(t), a.track_get_type(t)]
		if seen.has(k):
			dup += 1
		seen[k] = true
	check(dup == 0, "no duplicate tracks in Sword_Regular_C_RM (%d)" % dup)


func test_root_motion_curves() -> void:
	var roll: RootMotionCurve = load(DIR + "rootmotion/Roll_RM.tres")
	near(roll.total().z, -4.99, 0.05, "Roll_RM forward (-Z) distance")
	near(roll.total().x, 0.0, 0.02, "Roll_RM no drift")
	var kb: RootMotionCurve = load(DIR + "rootmotion/Hit_Knockback_RM.tres")
	near(kb.total().z, 2.96, 0.05, "knockback goes backward (+Z)")
	var dl: RootMotionCurve = load(DIR + "rootmotion/Dodge_left_RM.tres")
	near(dl.total().x, -1.97, 0.05, "dodge left goes -X")
	var cu: RootMotionCurve = load(DIR + "rootmotion/ClimbUp_1m_RM.tres")
	near(cu.extent().size.y, 0.92, 0.06, "climb-up rise")
	near(cu.extent().size.z, 1.53, 0.08, "climb-up reach")


func test_animation_set() -> void:
	var s: AnimationSet = load(DIR + "mannequin_animset.tres")
	check(s.roles.size() >= 60, "roles mapped (%d)" % s.roles.size())
	check(s.root_motion.size() == 13, "13 root-motion curves: the 12 UAL ones + the prone roll (%d)" % s.root_motion.size())
	for r in [&"roll", &"dodge_left", &"knockback", &"climb_up_1m"]:
		check(s.rm_index(r) >= 0, "rm index for %s" % r)
	var w := s.speed_of(&"walk_f", 0)
	var j := s.speed_of(&"jog_f", 0)
	var sp := s.speed_of(&"sprint_f", 0)
	check(w > 0.4 and w < j and j < sp, "authored speeds ordered walk %.2f < jog %.2f < sprint %.2f" % [w, j, sp])


## Mixamo-named FBX and Blender-exported GLB, retargeted through the intake, must reproduce
## the original clip on the mannequin (same motion, only the rig naming differed).
func test_intake_roundtrip() -> void:
	var pairs := [["mixamo", "Mixamo_Jog", "Jog"], ["blender", "Sprint", "Sprint"]]
	var scene := (load(DIR + "mannequin.glb") as PackedScene).instantiate()
	add_child(scene)
	var sk := scene.find_child("GeneralSkeleton", true, false) as Skeleton3D
	var ual: AnimationLibrary = load(DIR + "anims/ual.res")
	for p: Array in pairs:
		var lib_path := DIR + "anims/%s.res" % p[0]
		if not ResourceLoader.exists(lib_path):
			info("no %s library yet (run tools/intake.sh)" % p[0])
			continue
		var lib: AnimationLibrary = load(lib_path)
		if not check(lib.has_animation(p[1]), "%s/%s imported" % [p[0], p[1]]):
			continue
		var a := lib.get_animation(p[1])
		var b := ual.get_animation(p[2])
		var worst := 0.0
		for i in 8:
			var t := b.length * i / 8.0
			var got := {}
			for pass_i in 2:
				UltraPoseSampler.pose(a if pass_i == 0 else b, sk, t)
				for bone in ["LeftFoot", "RightFoot", "LeftHand", "RightHand", "Head"]:
					var pos := UltraPoseSampler.global_pose(sk, sk.find_bone(bone)).origin
					if pass_i == 0:
						got[bone] = pos
					else:
						worst = maxf(worst, pos.distance_to(got[bone]))
		info("%s/%s vs %s: worst end-effector difference %.3f m" % [p[0], p[1], p[2], worst])
		# FBX is baked/resampled (24 -> 30 fps): allow a little more there.
		var tol := 0.05 if p[0] == "mixamo" else 0.02
		check(worst < tol, "%s round trip reproduces %s (%.3f m)" % [p[0], p[2], worst])
	scene.queue_free()
