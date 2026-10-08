extends SceneTree
## Writes addons/marksman/marksman_animset.tres: Marksman's roles -> clips, each clip's measured ground speed
## and left-plant phase (tools/anim_measure.gd), and the stance groups the gait walks in. Edit the tables here
## and re-run, then the clip audit (suite g1): see sinew/ANIMATION_GUIDE.md "Stance sets".
## Run: godot --headless --path . --script res://tools/marksman/build_stance_sets.gd

const DIR := "res://assets/characters/mannequin/"
const OUT := "res://addons/marksman/marksman_animset.tres"
const AnimMeasure := preload("res://tools/anim_measure.gd")

## Directions: role suffix -> Pro Rifle (RFP) clip suffix.
const DIRS := {"f": "Forward", "fl": "ForwardLeft", "fr": "ForwardRight", "l": "Left", "r": "Right",
		"b": "Backward", "bl": "BackwardLeft", "br": "BackwardRight"}

## role -> clip ("library/clip"; a bare name = the default UAL library).
func _roles() -> Dictionary:
	var r := {
		# Unarmed, standing: Sinew's references (sinew/ANIMATION_GUIDE.md).
		"walk_f": "mixamo/N_StdWalk2", "jog_f": "mixamo/U_Run_F", "sprint_f": "mixamo/S_Fast",
		# Rifle (Pro Rifle pack).
		"r_idle": "mixamo/RFP_Idle", "r_aim": "mixamo/RFP_IdleAiming",
		"rc_idle": "mixamo/RFP_IdleCrouching", "rc_aim": "mixamo/RFP_IdleCrouchingAiming",
		"r_turn_l": "mixamo/RFP_Turn90Left", "r_turn_r": "mixamo/RFP_Turn90Right",
		"rc_turn_l": "mixamo/RFP_CrouchingTurn90Left", "rc_turn_r": "mixamo/RFP_CrouchingTurn90Right",
		# Pistol (Pistol / Handgun Locomotion pack). Its walk is a brisk 2.5 m/s: the walk is the unarmed walk's
		# legs under the pistol walk's arms; the sprint is the unarmed sprint's legs under the pistol run's arms.
		"p_idle": "mixamo/PST_PistolIdle", "pc_idle": "mixamo/PST_PistolKneelingIdle",
		"p_walk_arms": "mixamo/PST_PistolWalk", "p_walk_f": "mixamo/N_StdWalk2",
		# (The pack's strafes and back run skate - their feet move at 55-60 % of the clip's pace, the clip audit
		# says: sideways is the unarmed side step's legs under the pistol idle's arms.)
		"p_run_f": "mixamo/PST_PistolRun", "p_walk_b": "mixamo/PST_PistolWalkBackward",
		"p_strafe_l": "mixamo/Strafe_Walk_L", "p_strafe_r": "mixamo/Strafe_Walk_R", "p_sprint_f": "mixamo/S_Fast",
		# Jumps, falls, landings (MarksmanAnimDriver: seeked by the vertical speed / played by the impact): a standing
		# hop (male locomotion pack), a jump on the move (axe pack, unarmed), a fall, a hard landing (action adventure).
		"mk_hop": "mixamo/LMM_Jump", "mk_jump_run": "mixamo/AXE_UnarmedJumpRunning", "mk_fall": "mixamo/AAD_FallingIdle",
		"mk_land_hard": "mixamo/AAD_HardLanding",
	}
	for d: String in DIRS:
		r["r_walk_" + d] = "mixamo/RFP_Walk" + DIRS[d]
		r["r_run_" + d] = "mixamo/RFP_Run" + DIRS[d]
		# (Crouched, the diagonals skate (feet at 65 % of the pace) or cross over, the clip audit says: forward,
		# back and the sides only - the gait takes a diagonal on the nearest one, its hips warped.)
		if d.length() == 1:
			r["rc_walk_" + d] = "mixamo/RFP_WalkCrouching" + DIRS[d]
		# (The backward sprints are broken - two strides crammed into 0.5 s, feet skating; nobody sprints backwards.)
		if not d.begins_with("b"):
			r["r_sprint_" + d] = "mixamo/RFP_Sprint" + DIRS[d]
	return r


func _groups(roles: Dictionary) -> Array[Dictionary]:
	var rc := []
	var r := []
	for k: String in roles:
		if k.begins_with("rc_walk_"):
			rc.append(k)
		elif k.begins_with("r_walk_") or k.begins_with("r_run_") or k.begins_with("r_sprint_"):
			r.append(k)
	rc.sort()
	r.sort()
	var crouch_arms := {}
	var pistol_crouch_arms := {}
	for k: String in rc:
		crouch_arms[k] = ["walk_f"]
		pistol_crouch_arms[k] = ["p_idle"]
	var out: Array[Dictionary] = [
		{"name": "unarmed_stand", "stance": "unarmed", "posture": "stand", "idle": "idle",
			"cycles": ["walk_f", "jog_f", "sprint_f", "walk_b", "strafe_l", "strafe_r"],
			"upper_from": {"jog_f": ["walk_f", "sprint_f", "sprint_f"]}},
		# (Crouched: the rifle pack's crouch-walk legs and lean - 8 ways at the motor's crouch speed - with the plain
		# walk's arm swing. The UAL Crouch_Walk's whole upper body hunched it over, arms hanging wide: ape-like.)
		{"name": "unarmed_crouch", "stance": "unarmed", "posture": "crouch", "idle": "crouch_idle",
			"cycles": rc, "upper_from": {}, "arms_from": crouch_arms},
		{"name": "rifle_stand", "stance": "rifle", "posture": "stand", "idle": "r_idle", "aim": "r_aim",
			"cycles": r, "upper_from": {}, "turn_l": "r_turn_l", "turn_r": "r_turn_r"},
		{"name": "rifle_crouch", "stance": "rifle", "posture": "crouch", "idle": "rc_idle", "aim": "rc_aim",
			"cycles": rc, "upper_from": {}, "turn_l": "rc_turn_l", "turn_r": "rc_turn_r"},
		{"name": "pistol_stand", "stance": "pistol", "posture": "stand", "idle": "p_idle",
			"cycles": ["p_walk_f", "p_run_f", "p_sprint_f", "p_walk_b", "p_strafe_l", "p_strafe_r"],
			"upper_from": {"p_walk_f": ["p_walk_arms"], "p_sprint_f": ["p_run_f"], "p_strafe_l": ["p_idle"], "p_strafe_r": ["p_idle"]}},
		{"name": "pistol_crouch", "stance": "pistol", "posture": "crouch", "idle": "pc_idle",
			"cycles": rc, "upper_from": pistol_crouch_arms},
	]
	return out


func _init() -> void:
	var libs := {"mixamo": load(DIR + "anims/mixamo.res"), "": load(DIR + "anims/ual.res")}
	var scene: Node = (load(DIR + "mannequin.glb") as PackedScene).instantiate()
	root.add_child(scene)
	var skel := scene.find_child("GeneralSkeleton", true, false) as Skeleton3D
	var base: AnimationSet = load(DIR + "mannequin_animset.tres")
	var set_res := MarksmanStanceSet.new()
	var roles := _roles()
	set_res.overrides = roles
	set_res.groups = _groups(roles)
	set_res.gait_run_upper = [&"walk_f", &"sprint_f", &"sprint_f"]
	# Measure every clip a group uses (overridden or from the base set).
	var clips := {}
	for g: Dictionary in set_res.groups:
		for role: String in g.cycles:
			clips[String(roles.get(role, base.roles.get(StringName(role), "")))] = true
	for clip: String in clips:
		if clip == "":
			continue
		var lib_name := clip.get_slice("/", 0) if clip.contains("/") else ""
		var key := clip.get_slice("/", 1) if clip.contains("/") else clip
		var lib: AnimationLibrary = libs.get(lib_name)
		if lib == null or not lib.has_animation(key):
			push_error("no clip " + clip)
			continue
		var m: Array = AnimMeasure.measure(lib.get_animation(key), skel)
		set_res.authored_speed[clip] = snappedf(m[0], 0.001)
		set_res.plant_phase[clip] = snappedf(m[1], 0.001)
		print("%-40s %5.2f m/s  plant %.2f" % [clip, m[0], m[1]])
	print("saved ", OUT, " err=", ResourceSaver.save(set_res, OUT))
	quit()
