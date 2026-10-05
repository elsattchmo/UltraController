extends SceneTree
## Builds assets/characters/mannequin/mannequin_animset.tres:
##   * role -> clip mapping for the UAL mannequin
##   * measured authored ground speed + left-foot plant phase of every locomotion cycle
##   * the baked root-motion curves (fixed order: index rides in MotorState.rm_clip)
## Run: godot --headless --path . --script res://tools/build_animset.gd

const DIR := "res://assets/characters/mannequin/"
const AnimMeasure := preload("res://tools/anim_measure.gd")
const ROLES := {
	&"idle": "Idle_A", &"idle_alt": "Idle_Subtle", &"idle_hurt": "Idle_Hurt",
	&"walk_f": "Walk", &"walk_b": "Walk_Backwards", &"strafe_l": "mixamo/Strafe_Walk_L", &"strafe_r": "mixamo/Strafe_Walk_R",
	&"jog_f": "Jog", &"sprint_f": "Sprint", &"walk_carry": "Walk_Carry", &"walk_stealth": "Walk_Stealth",
	&"crouch_idle": "Crouch_Idle", &"crouch_f": "Crouch_Walk", &"crawl": "Crawl",
	&"turn_l90": "Turn_Left_90", &"turn_r90": "Turn_Right_90", &"turn_l180": "Turn_Left_180", &"turn_r180": "Turn_Right_180",
	&"stand_turn_l": "mixamo/T_StandL90", &"stand_turn_r": "mixamo/T_StandR90", &"crouch_turn_l": "mixamo/T_CrouchB_L", &"crouch_turn_r": "mixamo/T_CrouchB_R",
	&"aim_turn_l": "mixamo/T_RifleL90", &"aim_turn_r": "mixamo/T_RifleR90",
	&"jump_start": "Jump_Start", &"jump_air": "Jump_air", &"jump_land": "Jump_Land", &"land_heavy": "Land_Three_Point",
	&"run_jump": "Run_Jump", &"leap": "mixamo/J_Sprint_RM",
	&"slide_start": "Slide_Start", &"slide": "Slide", &"slide_exit": "Slide_Exit",
	&"roll": "Roll_RM", &"dodge_back": "Dodge_back_RM", &"dodge_left": "Dodge_left_RM", &"dodge_right": "Dodge_right_RM",
	&"knockback": "Hit_Knockback_RM", &"climb_up_1m": "ClimbUp_1m_RM", &"crawl_rm": "Crawl_RM",
	&"ladder_idle": "Ladder_Idle", &"ladder_climb": "mixamo/Ladder_Climb", &"wall_climb": "Climb_Wall", &"pipe_climb": "Pipe_Climb",
	&"ledge_hang": "Ledge_Hang", &"hang_idle": "mixamo/Braced_Catch", &"shimmy_l": "mixamo/Shimmy_L", &"shimmy_r": "mixamo/Shimmy_R", &"limp_f": "mixamo/Injured_Walk", &"limp_b": "mixamo/Injured_Walk_Back", &"teeter": "mixamo/Lose_Balance",
	&"e_walk_f": "mixamo/R_Walk_F", &"e_walk_fr": "mixamo/R_Walk_FR", &"e_walk_r": "mixamo/R_Walk_R", &"e_walk_br": "mixamo/R_Walk_BR", &"e_walk_b": "mixamo/R_Walk_B", &"e_walk_bl": "mixamo/R_Walk_BL", &"e_walk_l": "mixamo/R_Walk_L", &"e_walk_fl": "mixamo/R_Walk_FL", &"e_run_f": "mixamo/R_Run_F", &"e_run_fr": "mixamo/R_Run_FR", &"e_run_r": "mixamo/R_Run_R", &"e_run_br": "mixamo/R_Run_BR", &"e_run_b": "mixamo/R_Run_B", &"e_run_bl": "mixamo/R_Run_BL", &"e_run_l": "mixamo/R_Run_L", &"e_run_fl": "mixamo/R_Run_FL", &"e_sprint_f": "mixamo/R_Sprint_F", &"e_sprint_fr": "mixamo/R_Sprint_FR", &"e_sprint_fl": "mixamo/R_Sprint_FL",
	&"n_walk_f": "mixamo/N_StdWalk2", &"n_walk_b": "Walk_Backwards", &"n_side": "Strafe_left", &"n_jog_f": "Jog", &"n_sprint_f": "mixamo/S_Fast",
	&"rifle_idle": "mixamo/Rifle_Idle", &"rifle_aim": "mixamo/Rifle_Idle_Aiming", &"rifle_reload": "mixamo/Rifle_Reload",
	&"interact": "Interact", &"pickup": "PickUp_Table", &"push": "Push", &"throw": "OverhandThrow", &"throw_object": "Throw_Object", &"push_throw": "Push",
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
		var m := AnimMeasure.measure(lib.get_animation(clip), skel)
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
