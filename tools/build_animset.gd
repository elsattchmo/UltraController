extends SceneTree
## Builds assets/characters/mannequin/mannequin_animset.tres:
##   * role -> clip mapping for the UAL mannequin
##   * measured authored ground speed + left-foot plant phase of every locomotion cycle
##   * the baked root-motion curves (fixed order: index rides in MotorState.rm_clip)
## Run: godot --headless --path . --script res://tools/build_animset.gd

const DIR := "res://assets/characters/mannequin/"
const ROLES := {
	&"idle": "Idle_A", &"idle_alt": "Idle_Subtle", &"idle_hurt": "Idle_Hurt",
	&"walk_f": "Walk", &"walk_b": "Walk_Backwards", &"strafe_l": "mixamo/Strafe_Walk_L", &"strafe_r": "mixamo/Strafe_Walk_R",
	&"jog_f": "Jog", &"sprint_f": "Sprint", &"walk_carry": "Walk_Carry", &"walk_stealth": "Walk_Stealth",
	&"crouch_idle": "Crouch_Idle", &"crouch_f": "Crouch_Walk", &"crawl": "Crawl",
	&"turn_l90": "Turn_Left_90", &"turn_r90": "Turn_Right_90", &"turn_l180": "Turn_Left_180", &"turn_r180": "Turn_Right_180",
	&"jump_start": "Jump_Start", &"jump_air": "Jump_air", &"jump_land": "Jump_Land", &"land_heavy": "Land_Three_Point",
	&"run_jump": "Run_Jump",
	&"slide_start": "Slide_Start", &"slide": "Slide", &"slide_exit": "Slide_Exit",
	&"roll": "Roll_RM", &"dodge_back": "Dodge_back_RM", &"dodge_left": "Dodge_left_RM", &"dodge_right": "Dodge_right_RM",
	&"knockback": "Hit_Knockback_RM", &"climb_up_1m": "ClimbUp_1m_RM", &"crawl_rm": "Crawl_RM",
	&"ladder_idle": "Ladder_Idle", &"ladder_climb": "mixamo/Ladder_Climb", &"wall_climb": "Climb_Wall", &"pipe_climb": "Pipe_Climb",
	&"ledge_hang": "Ledge_Hang", &"hang_idle": "mixamo/Braced_Catch", &"shimmy_l": "mixamo/Shimmy_L", &"shimmy_r": "mixamo/Shimmy_R", &"swim_idle": "Swim_Idle", &"swim_f": "Swim_Fwd",
	&"interact": "Interact", &"pickup": "PickUp_Table", &"push": "Push", &"throw": "OverhandThrow", &"throw_object": "Throw_Object",
	&"consume": "Consume", &"open_chest": "Chest_Open", &"kick_door": "Kick_Breach",
	&"pistol_idle": "Pistol_Idle", &"pistol_aim_up": "Pistol_Aim_Up", &"pistol_aim_neutral": "Pistol_Aim_Neutral",
	&"pistol_aim_down": "Pistol_Aim_Down", &"pistol_shoot": "Pistol_Shoot", &"pistol_reload": "Pistol_Reload",
	&"hit_chest": "Hit_Chest", &"hit_head": "Hit_Head", &"get_up": "LayToIdle", &"get_up_front": "mixamo/GetUp_Prone",
	&"death_a": "Death_A", &"death_b": "Death_B", &"death_c": "Death_C", &"death_d": "Death_D",
	&"tired": "Tired_Hunched",
}
const MEASURE := ["Walk", "Walk_Backwards", "Strafe_left", "Strafe_right", "Jog", "Sprint", "Walk_Carry", "Walk_Stealth", "Crouch_Walk", "Crawl", "Run_Anime", "Run_Stealth", "Walk_Large", "Zombie_Walk"]


func _init() -> void:
	var lib: AnimationLibrary = load(DIR + "anims/ual.res")
	var scene: Node = (load(DIR + "mannequin.glb") as PackedScene).instantiate()
	root.add_child(scene)
	var skel := scene.find_child("GeneralSkeleton", true, false) as Skeleton3D
	var set := AnimationSet.new()
	for r: StringName in ROLES:
		if lib.has_animation(StringName(ROLES[r])) or String(ROLES[r]).contains("/"):
			set.roles[r] = ROLES[r]
		else:
			push_warning("missing clip for role %s: %s" % [r, ROLES[r]])
	for clip: String in MEASURE:
		if not lib.has_animation(clip):
			continue
		var m := _measure(lib.get_animation(clip), skel)
		set.authored_speed[clip] = m[0]
		set.plant_phase[clip] = m[1]
		print("%-14s speed=%.3f m/s  plant=%.3f  len=%.3f" % [clip, m[0], m[1], lib.get_animation(clip).length])
	var rm: Array[RootMotionCurve] = []
	var d := DirAccess.open(DIR + "rootmotion")
	var files := d.get_files()
	files.sort()
	for f in files:
		if f.ends_with(".tres"):
			rm.append(load(DIR + "rootmotion/" + f))
	set.root_motion = rm
	for n in lib.get_animation_list():
		set.loops[String(n)] = lib.get_animation(n).loop_mode != Animation.LOOP_NONE
	var err := ResourceSaver.save(set, DIR + "mannequin_animset.tres")
	print("saved animset err=", err, " roles=", set.roles.size(), " rm=", rm.size())
	quit()


## Returns [ground speed m/s, left-foot plant phase 0..1]. The clip is in place, so during
## stance the planted foot slides backwards under the body at exactly the authored speed.
func _measure(anim: Animation, skel: Skeleton3D, bone_l := "LeftToes", bone_r := "RightToes") -> Array:
	## Returns [ground speed m/s, left-foot plant phase 0..1]. The clip is in place, so the
	## supporting foot (the lower one, while on the ground) slides backwards under the body
	## at exactly the authored speed. Same rule the foot-slide test uses in-engine.
	var n := 240
	var feet := [skel.find_bone(bone_l), skel.find_bone(bone_r)]
	var pos := [[], []]
	for i in n:
		_pose(anim, skel, anim.length * i / n)
		for f in 2:
			pos[f].append(_global(skel, feet[f]).origin)
	var miny := [INF, INF]
	for f in 2:
		for p: Vector3 in pos[f]:
			miny[f] = minf(miny[f], p.y)
	var dt := anim.length / n
	var vels: Array[Vector2] = []
	for i in n:
		var j := (i + 1) % n
		var lo := 0 if (pos[0][i] as Vector3).y <= (pos[1][i] as Vector3).y else 1
		var p: Vector3 = pos[lo][i]
		var q: Vector3 = pos[lo][j]
		if p.y > miny[lo] + 0.03 or q.y > miny[lo] + 0.03:
			continue
		vels.append(Vector2(q.x - p.x, q.z - p.z) / dt)
	var mean := Vector2.ZERO
	for v in vels:
		mean += v
	var dir := mean.normalized()
	var speeds: Array[float] = []
	for v in vels:
		speeds.append(maxf(v.dot(dir), 0.0))
	speeds.sort()
	var med := speeds[speeds.size() / 2] if not speeds.is_empty() else 0.0
	# Left-foot plant: first frame the left foot becomes the low, grounded foot.
	var plant := 0.0
	var was := true
	for i in n:
		var lo := 0 if (pos[0][i] as Vector3).y <= (pos[1][i] as Vector3).y else 1
		var down: bool = lo == 0 and (pos[0][i] as Vector3).y < float(miny[0]) + 0.03
		if down and not was:
			plant = float(i) / n
			break
		was = down
	return [med, plant]


func _global(skel: Skeleton3D, bone: int) -> Transform3D:
	var xf := skel.get_bone_pose(bone)
	var p := skel.get_bone_parent(bone)
	while p >= 0:
		xf = skel.get_bone_pose(p) * xf
		p = skel.get_bone_parent(p)
	return xf


func _pose(anim: Animation, skel: Skeleton3D, t: float) -> void:
	for b in skel.get_bone_count():
		skel.reset_bone_pose(b)
	for tr in anim.get_track_count():
		var bone := skel.find_bone(String(anim.track_get_path(tr).get_concatenated_subnames()))
		if bone < 0:
			continue
		match anim.track_get_type(tr):
			Animation.TYPE_POSITION_3D:
				skel.set_bone_pose_position(bone, anim.position_track_interpolate(tr, t) * skel.motion_scale)
			Animation.TYPE_ROTATION_3D:
				skel.set_bone_pose_rotation(bone, anim.rotation_track_interpolate(tr, t))
			Animation.TYPE_SCALE_3D:
				skel.set_bone_pose_scale(bone, anim.scale_track_interpolate(tr, t))
