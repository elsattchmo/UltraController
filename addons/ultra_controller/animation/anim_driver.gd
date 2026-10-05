class_name UltraAnimDriver
extends Node
## Builds the character's AnimationTree from an AnimationSet and drives it from motor state.
## Runs per rendered frame from presentation data, so local, predicted and remote characters
## all animate through the same path.
##
## Tree:  loco (StateMachine) -> upper (Blend2, upper-body filter) -> hit (OneShot) -> out
##   loco.ground  = Blend3(turn L / idle / turn R) ⨯ Blend2 ⨯ BlendSpace2D(velocity, cyclic-synced) -> TimeScale
##   loco.crouch  = idle / crouch walk (time-scaled)        loco.crawl = crawl cycle
##   loco.air     = jump_start -> jump_air                  loco.land / land_heavy
##   loco.slide   = slide_start -> slide                    loco.rm = whichever root-motion clip

const LOCO := "parameters/loco/"

@export var anim_set: AnimationSet
@export var library: AnimationLibrary
@export var library_name: StringName = &""
## Extra libraries by prefix (Mixamo / Blender intake): roles can name "mixamo/Clip".
var extra_libraries: Dictionary = {}

var tree: AnimationTree
var player: AnimationPlayer
var modifier: BodyDynamicsModifier
var inertial: InertialBlendModifier
var foot_ik: FootIKModifier
var hand_ik: HandIKModifier
var weapon_pose: WeaponPoseModifier
var arm_clear: UltraArmClear
var look: LookModifier
var skeleton: Skeleton3D

## Presentation inputs, written by the character every frame.
var state: int = MotorState.Id.IDLE
var stance: int = MotorState.Stance.STAND
var velocity := Vector3.ZERO
var body_yaw: float = 0.0
var aim_yaw: float = 0.0
var aim_pitch: float = 0.0
var turning := false
var rm_clip: int = -1
var hard_landing := false
var land_impact := 0.0
var on_platform := false
## Traversal presentation: signed climb speed (m/s), pipe vs ladder, scripted move duration.
var climb_speed := 0.0
var climb_kind := 0
var climb_duration := 0.6
var air_time := 0.0
var getup_crawl := false
var getup_front := false
var _owned_w := 0.0
## Injuries: limp severity 0..1 and which leg; hunch from a hurt torso.
var limp := 0.0
var limp_left := true
var injury_hunch := 0.0
## The weapon is in the left hand (right arm out of action): item clips play mirrored.
var item_left := false
var _item_left_for := false
var _bad_stance := false
var _lfoot := -1
var _rfoot := -1
## Held item presentation (set by the character).
var held_def: ItemDefinition
var item_action := 0
var item_ready_pose := 1.0          ## 1 = weapon up, 0 = lowered (sprinting, busy)
var _held_roles_for: ItemDefinition
var _item_w := 0.0
var _pose_w := 0.0
## 1 when the body faces the aim (first person, aiming): spine carries aim yaw/pitch.
## 0 in free third-person movement: only the head glances (LookModifier).
var aim_weight := 1.0
var _aim_w := 1.0
## Scales all IK (e.g. 0 while ragdolled).
var ik_scale := 1.0
var accel := Vector3.ZERO

var _loco: AnimationNodeStateMachinePlayback
var _cur_loco := ""
var _cur_rm := -1
var _hull: PackedVector2Array = []
var _walk_speed := 0.8
var _sprint_speed := 7.3
var _back_speed := 1.0
var _crouch_speed := 0.58
var _crawl_speed := 0.76
var _lean := Vector2.ZERO
var _lean_vel := Vector2.ZERO
var _warp := 0.0
var _backwards := false
var _side_step := false             ## walking: side-step cycle (vs forward walk) in use
var _side_g := 0.0
var _foot_w := 0.0


func setup(p_player: AnimationPlayer, p_skeleton: Skeleton3D) -> void:
	player = p_player
	skeleton = p_skeleton
	if library and not player.has_animation_library(library_name):
		player.add_animation_library(library_name, library)
	for k: String in extra_libraries:
		if not player.has_animation_library(k):
			player.add_animation_library(k, extra_libraries[k])
	_read_speeds()
	tree = AnimationTree.new()
	tree.name = "AnimationTree"
	player.get_parent().add_child(tree)
	tree.anim_player = tree.get_path_to(player)
	tree.root_node = player.root_node
	tree.deterministic = true
	tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE
	tree.root_motion_track = NodePath("%GeneralSkeleton:Root")
	tree.tree_root = _build()
	tree.active = true
	_loco = tree.get(LOCO + "playback")
	# Modifier order = processing order: transition smoothing, pose shaping, grounding, hands, gaze.
	inertial = InertialBlendModifier.new()
	inertial.name = "InertialBlend"
	skeleton.add_child(inertial)
	modifier = BodyDynamicsModifier.new()
	modifier.name = "BodyDynamics"
	skeleton.add_child(modifier)
	foot_ik = FootIKModifier.new()
	foot_ik.name = "FootIK"
	skeleton.add_child(foot_ik)
	arm_clear = UltraArmClear.new()
	arm_clear.name = "ArmClear"
	skeleton.add_child(arm_clear)
	weapon_pose = WeaponPoseModifier.new()
	weapon_pose.name = "WeaponPose"
	skeleton.add_child(weapon_pose)
	hand_ik = HandIKModifier.new()
	hand_ik.name = "HandIK"
	skeleton.add_child(hand_ik)
	look = LookModifier.new()
	look.name = "Look"
	skeleton.add_child(look)


func _clip(role: StringName) -> StringName:
	var c := anim_set.clip(role)
	if library_name != &"" and c != &"" and not String(c).contains("/"):
		return StringName("%s/%s" % [library_name, c])
	return c


const BRISK_RATE := 1.75
## Which leg the injured-walk clips favour (measured: Injured_Walk lingers on the right foot,
## so its bad leg is the left; Injured_Walk_Back the other way round).
## Lose_Balance: the stretch where the arms windmill (before the walk-off).
const TEETER_SEG := Vector2(3.3, 4.4)
## Mixamo "Running Jump" (from a sprint): take-off .. touchdown, and its apex in that segment.
const RUN_JUMP_SEG := Vector2(0.04, 0.62)
const RUN_JUMP_APEX := 0.28
const RUN_JUMP_SPEED := 3.2
## (Not VAULT: it keeps the run's momentum, the running legs carry on after it.)
const TRAVERSING := [MotorState.Id.MANTLE, MotorState.Id.LEDGE_CLIMB, MotorState.Id.LEDGE_HANG,
	MotorState.Id.LADDER, MotorState.Id.WALL_CLIMB, MotorState.Id.ROPE]
const LEAP_ARMS := 0.5                 ## how much of the falling loop's arms a long leap gets
var _leap_arms := 0.0
var _run_jump := false
var _jump_vy0 := 0.0
## Throwing a carried prop: the arms-out "Push" pose held briefly - the one-shot's quick fade
## in from the carry (hands at the chest) is the shove itself; faded out after PUSH_HOLD s.
const PUSH_HOLD := 0.3
var _push_t := 0.0
const LIMP_F_BAD_LEG := "l"
const LIMP_B_BAD_LEG := "r"
var _has_limp := false
var _limp_f_speed := 0.7
var _limp_b_speed := 0.7
var _limp_hull := PackedVector2Array()
var _limp_w := 0.0
## 0..1 while teetering on an edge (MotorState.teeter): arms flail on the upper body.
var teeter := 0.0
var _teeter_w := 0.0
var _climb_look := 0.0
## Face-down get-up: Death_A from where it lies on its front (3.85 s) back to standing (1.6 s).
const FRONT_GETUP_FROM := 1.6
const FRONT_GETUP_LEN := 2.25
const GETUP_TIME := 2.8          ## keep in step with ragdoll_state.gd GET_UP_TIME
## Face-down get-up from the Mixamo clip: from the start of the push-up to standing (s).
const FRONT_GETUP_SEG := Vector2(1.4, 5.3)
var _front_len := FRONT_GETUP_LEN


func _clip_len(role: StringName, fallback: float) -> float:
	var a := _role_anim(role)
	return a.length if a else fallback
## Most the legs turn toward travel when walking backwards on a diagonal.
var back_warp_deg := 35.0
## The mannequin's Strafe_Right doesn't blend with Walk_Backwards (back-right diagonals skate
## ~0.8 m/s); a mirrored Strafe_Left does.
static var strafe_r_mirror := true


## The stock Strafe_Right skates; mirror Strafe_Left - unless the set has its own side-steps.
func _mirror_strafe() -> bool:
	return strafe_r_mirror and not String(anim_set.clip(&"strafe_r")).contains("/")


## Short shuffle side-steps need speeding up to cover walking speed; real side-step walks don't.
func _side_brisk() -> float:
	return BRISK_RATE if anim_set.speed_of(&"strafe_l", 0.69) < 1.0 else 1.0


func _read_speeds() -> void:
	_walk_speed = anim_set.speed_of(&"walk_f", 0.8)
	_sprint_speed = anim_set.speed_of(&"sprint_f", 7.3)
	_back_speed = anim_set.speed_of(&"walk_b", 1.0)
	_crouch_speed = anim_set.speed_of(&"crouch_f", 0.58)
	var crawl_rm := anim_set.rm_curve(anim_set.rm_index(&"crawl_rm"))
	_crawl_speed = crawl_rm.total().length() / crawl_rm.length if crawl_rm else 0.76
	# Convex hull of the locomotion blend space (x = right, y = forward), for clamping.
	_hull = PackedVector2Array([
		Vector2(0, _sprint_speed),
		Vector2((anim_set.speed_of(&"strafe_l", 0.69) if _mirror_strafe() else anim_set.speed_of(&"strafe_r", 0.85)) * _side_brisk(), 0),
		Vector2(0, -_back_speed),
		Vector2(-anim_set.speed_of(&"strafe_l", 0.69) * _side_brisk(), 0),
	])


## The Animation behind a role, from the main or an extra ("lib/clip") library.
func _role_anim(role: StringName) -> Animation:
	var c := String(anim_set.clip(role))
	if c == "":
		return null
	if c.contains("/"):
		var parts := c.split("/", true, 1)
		var lib: AnimationLibrary = extra_libraries.get(parts[0])
		return lib.get_animation(parts[1]) if lib and lib.has_animation(parts[1]) else null
	return library.get_animation(c) if library and library.has_animation(c) else null


func _anim(role: StringName, loop := true) -> AnimationNodeAnimation:
	var a := AnimationNodeAnimation.new()
	a.animation = _clip(role)
	if loop:
		a.use_custom_timeline = true
		a.loop_mode = Animation.LOOP_LINEAR
		var lib_anim := _role_anim(role)
		if lib_anim:
			a.timeline_length = lib_anim.length
			# Align every cycle so the left foot plants at phase 0 (keeps synced blends in step).
			a.start_offset = float(anim_set.plant_phase.get(String(anim_set.clip(role)), 0.0)) * lib_anim.length
	return a


## One-shot clip that starts `offset` seconds in.
func _anim_from(role: StringName, offset: float) -> AnimationNodeAnimation:
	var a := AnimationNodeAnimation.new()
	a.animation = _clip(role)
	var src := library.get_animation(anim_set.clip(role)) if library and anim_set.clip(role) != &"" else null
	if src:
		a.use_custom_timeline = true
		a.loop_mode = Animation.LOOP_NONE
		a.start_offset = offset
		a.timeline_length = maxf(src.length - offset, 0.05)
	return a


func _build() -> AnimationNodeBlendTree:
	var root := AnimationNodeBlendTree.new()
	var loco := AnimationNodeStateMachine.new()
	loco.state_machine_type = AnimationNodeStateMachine.STATE_MACHINE_TYPE_ROOT

	# --- ground: idle / turn-in-place vs. velocity blend space
	var ground := AnimationNodeBlendTree.new()
	var bs := AnimationNodeBlendSpace2D.new()
	bs.sync = true
	bs.sync_mode = 2                      # Cyclic Mutable: shared phase, length interpolated
	bs.min_space = Vector2(-2, -2)
	bs.max_space = Vector2(2, 8)
	var sr := _anim(&"strafe_l") if _mirror_strafe() else _anim(&"strafe_r")
	if _mirror_strafe():
		sr.animation = _mirrored(sr.animation)
	var brisk_side := _side_brisk()
	_neutral = NEUTRAL_ROLES.all(func(r: StringName) -> bool: return _role_anim(r) != null)
	_eight_way = EIGHT_WAY_ROLES.all(func(r: StringName) -> bool: return _role_anim(r) != null)
	if _neutral:
		_build_neutral(bs)
	else:
		bs.add_blend_point(_anim(&"walk_f"), Vector2(0, _walk_speed), -1, &"walk")
		# A brisk walk: the same cycle played faster (its stride is right; the jog's 2.8 m bound
		# is not a walk), so normal walking speeds never pull the jog in.
		var brisk := _anim(&"walk_f")
		var walk_len := brisk.timeline_length
		if walk_len > 0.0:
			brisk.timeline_length = walk_len / BRISK_RATE
			brisk.stretch_time_scale = true
			brisk.start_offset /= BRISK_RATE
			bs.add_blend_point(brisk, Vector2(0, _walk_speed * BRISK_RATE), -1, &"walk_brisk")
		bs.add_blend_point(_anim(&"jog_f"), Vector2(0, anim_set.speed_of(&"jog_f", 4.7)), -1, &"jog")
		bs.add_blend_point(_anim(&"sprint_f"), Vector2(0, _sprint_speed), -1, &"sprint")
		bs.add_blend_point(_anim(&"walk_b"), Vector2(0, -_back_speed), -1, &"back")
		bs.add_blend_point(sr, _hull[1] / brisk_side, -1, &"strafe_r")
		bs.add_blend_point(_anim(&"strafe_l"), _hull[3] / brisk_side, -1, &"strafe_l")
		# Brisk side-steps (the same cycles faster) for short shuffle clips; a real walking
		# side-step (e.g. Mixamo's) already covers walking speed.
		for spec: Array in ([] if brisk_side == 1.0 else [[sr, _hull[1], &"strafe_r_brisk"], [_anim(&"strafe_l"), _hull[3], &"strafe_l_brisk"]]):
			var b := (spec[0] as AnimationNodeAnimation).duplicate() as AnimationNodeAnimation
			if b.timeline_length > 0.0:
				b.timeline_length /= BRISK_RATE
				b.stretch_time_scale = true
				b.start_offset /= BRISK_RATE
			bs.add_blend_point(b, spec[1], -1, spec[2])
	ground.add_node("move", bs, Vector2(0, 0))
	ground.add_node("rate", AnimationNodeTimeScale.new(), Vector2(200, 0))
	ground.connect_node("rate", 0, "move")
	var move_out := "rate"
	if _eight_way and _neutral:
		# Bladed stance (a two-handed weapon whose own clips stand bladed, e.g. a rifle): the
		# legs come from the 8-way rifle set as authored, so they match the item's upper body
		# (on square-on legs the spine had to twist ~50 deg: a big sideways lean).
		var bsb := AnimationNodeBlendSpace2D.new()
		bsb.sync = true
		bsb.sync_mode = 2
		bsb.min_space = Vector2(-8, -8)
		bsb.max_space = Vector2(8, 8)
		_build_eight_way(bsb)
		ground.add_node("move_b", bsb, Vector2(0, 150))
		ground.add_node("rate_b", AnimationNodeTimeScale.new(), Vector2(200, 150))
		ground.connect_node("rate_b", 0, "move_b")
		ground.add_node("stance", AnimationNodeBlend2.new(), Vector2(320, 0))
		ground.connect_node("stance", 0, "rate")
		ground.connect_node("stance", 1, "rate_b")
		move_out = "stance"
	# Limping: the same space with Mixamo's injured walks (forward / back), one copy per bad
	# leg (mirrored where the clip favours the other leg), mixed in by how hurt the legs are.
	_has_limp = _role_anim(&"limp_f") != null and _role_anim(&"limp_b") != null
	if _has_limp:
		_limp_f_speed = anim_set.speed_of(&"limp_f", 0.7)
		_limp_b_speed = anim_set.speed_of(&"limp_b", 0.7)
		var side_pts := [_nw_ring[1], _nw_ring[3]] if _neutral else [_hull[1] / brisk_side, _hull[3] / brisk_side]
		_limp_hull = PackedVector2Array([Vector2(0, _limp_f_speed), side_pts[0], Vector2(0, -_limp_b_speed), side_pts[1]])
		for side: String in ["l", "r"]:
			var ls := AnimationNodeBlendSpace2D.new()
			ls.sync = true
			ls.sync_mode = 2
			ls.min_space = bs.min_space
			ls.max_space = bs.max_space
			var lf := _anim(&"limp_f")
			if side != LIMP_F_BAD_LEG:
				lf.animation = _mirrored(lf.animation)
			ls.add_blend_point(lf, Vector2(0, _limp_f_speed), -1, &"walk")
			var lb := _anim(&"limp_b")
			if side != LIMP_B_BAD_LEG:
				lb.animation = _mirrored(lb.animation)
			ls.add_blend_point(lb, Vector2(0, -_limp_b_speed), -1, &"back")
			ls.add_blend_point(_side_walk_anim(true, sr), side_pts[0], -1, &"strafe_r")
			ls.add_blend_point(_side_walk_anim(false, sr), side_pts[1], -1, &"strafe_l")
			ground.add_node("limp_" + side, ls, Vector2(0, 500 + (100 if side == "r" else 0)))
		ground.add_node("limp_side", AnimationNodeBlend2.new(), Vector2(200, 550))
		ground.connect_node("limp_side", 0, "limp_l")
		ground.connect_node("limp_side", 1, "limp_r")
		ground.add_node("limp_rate", AnimationNodeTimeScale.new(), Vector2(350, 550))
		ground.connect_node("limp_rate", 0, "limp_side")
		ground.add_node("limp", AnimationNodeBlend2.new(), Vector2(450, 0))
		ground.connect_node("limp", 0, move_out)
		ground.connect_node("limp", 1, "limp_rate")
	ground.add_node("idle", _anim(&"idle"), Vector2(0, 200))
	ground.add_node("mix", AnimationNodeBlend2.new(), Vector2(600, 100))
	_turn_nodes.clear()
	var idle_out := _add_turn(ground, LOCO + "ground/", "stand", "idle", Vector2(0, 300))
	if _eight_way and _neutral:
		# Standing in the bladed stance: the held item's aiming clip, whole body (set per item).
		ground.add_node("idle_b_src", _anim(&"idle"), Vector2(200, 450))
		ground.add_node("idle_stance", AnimationNodeBlend2.new(), Vector2(450, 350))
		ground.connect_node("idle_stance", 0, idle_out)
		ground.connect_node("idle_stance", 1, _add_turn(ground, LOCO + "ground/", "aim", "idle_b_src", Vector2(0, 600)))
		idle_out = "idle_stance"
	ground.connect_node("mix", 0, idle_out)
	ground.connect_node("mix", 1, "limp" if _has_limp else move_out)
	ground.connect_node("output", 0, "mix")
	loco.add_node("ground", ground, Vector2(0, 0))

	# --- crouch and crawl: one cycle each, direction handled by orientation warping
	for spec: Array in [["crouch", &"crouch_idle", &"crouch_f"], ["crawl", &"crawl", &"crawl"]]:
		var bt := AnimationNodeBlendTree.new()
		bt.add_node("idle", _anim(spec[1]), Vector2(0, 0))
		bt.add_node("walk", _anim(spec[2]), Vector2(0, 200))
		bt.add_node("rate", AnimationNodeTimeScale.new(), Vector2(200, 200))
		bt.connect_node("rate", 0, "walk")
		if spec[0] == "crawl":
			bt.add_node("idle_rate", AnimationNodeTimeScale.new(), Vector2(200, 0))
			bt.connect_node("idle_rate", 0, "idle")
		bt.add_node("mix", AnimationNodeBlend2.new(), Vector2(400, 100))
		bt.connect_node("mix", 0, "idle_rate" if spec[0] == "crawl" else _add_turn(bt, LOCO + "crouch/", "crouch", "idle", Vector2(0, 400)))
		bt.connect_node("mix", 1, "rate")
		bt.connect_node("output", 0, "mix")
		loco.add_node(spec[0], bt, Vector2(200, 0))

	# --- air
	var air := AnimationNodeStateMachine.new()
	air.add_node("start", _anim(&"jump_start", false), Vector2(0, 0))
	air.add_node("loop", _anim(&"jump_air"), Vector2(200, 0))
	var st := AnimationNodeStateMachineTransition.new()
	st.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_AT_END
	st.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO
	st.xfade_time = 0.15
	air.add_transition("start", "loop", st)
	var air_in := AnimationNodeStateMachineTransition.new()
	air_in.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO
	air.add_transition("Start", "start", air_in)
	loco.add_node("air", air, Vector2(400, 0))
	# Running jump: a leap from a sprint, its time driven by the vertical speed (take-off ->
	# apex -> touchdown), so it fits any jump height and speed.
	if _role_anim(&"leap"):
		var rj := AnimationNodeBlendTree.new()
		var rja := AnimationNodeAnimation.new()
		rja.animation = _segment(_clip(&"leap"), RUN_JUMP_SEG.x, RUN_JUMP_SEG.y)
		rj.add_node("clip", rja, Vector2(0, 0))
		rj.add_node("seek", AnimationNodeTimeSeek.new(), Vector2(200, 0))
		rj.add_node("hold", AnimationNodeTimeScale.new(), Vector2(400, 0))
		rj.connect_node("seek", 0, "clip")
		rj.connect_node("hold", 0, "seek")
		# The leap's touchdown pose comes before a longer fall lands: the arms then go on
		# moving (the falling loop's arms, a little of them) instead of freezing.
		var arms := AnimationNodeBlend2.new()
		arms.filter_enabled = true
		for bn in _arm_bones():
			arms.set_filter_path(NodePath("%GeneralSkeleton:" + bn), true)
		rj.add_node("arms", arms, Vector2(600, 0))
		rj.add_node("arms_src", _anim(&"jump_air"), Vector2(400, 150))
		rj.connect_node("arms", 0, "hold")
		rj.connect_node("arms", 1, "arms_src")
		rj.connect_node("output", 0, "arms")
		loco.add_node("air_run", rj, Vector2(400, 100))
	loco.add_node("fall", _anim(&"jump_air"), Vector2(400, 200))
	# Landings: soft ones play the squat faster (less dip); the heavy one starts after its
	# built-in fall (Land_Three_Point begins ~4.8 m up).
	var land := AnimationNodeBlendTree.new()
	land.add_node("clip", _anim(&"jump_land", false), Vector2(0, 0))
	land.add_node("speed", AnimationNodeTimeScale.new(), Vector2(200, 0))
	land.connect_node("speed", 0, "clip")
	# How deep the landing squats: a hop barely dips, a big drop goes all the way down (the clip
	# is a deep squat - every small jump sank the body ~45 cm).
	land.add_node("stand", _anim(&"idle"), Vector2(200, 150))
	land.add_node("depth", AnimationNodeBlend2.new(), Vector2(400, 0))
	land.connect_node("depth", 0, "stand")
	land.connect_node("depth", 1, "speed")
	land.connect_node("output", 0, "depth")
	loco.add_node("land", land, Vector2(600, 0))
	loco.add_node("land_heavy", _anim_from(&"land_heavy", 0.45), Vector2(600, 200))

	# --- slide
	var slide := AnimationNodeStateMachine.new()
	# Slide_Start is a whole slide (down and back up in 0.83 s): use only the drop into it.
	var ss := _anim(&"slide_start", false)
	ss.animation = _segment(ss.animation, 0.0, 0.40)
	slide.add_node("start", ss, Vector2(0, 0))
	slide.add_node("loop", _anim(&"slide"), Vector2(200, 0))
	var sl := AnimationNodeStateMachineTransition.new()
	sl.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_AT_END
	sl.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO
	sl.xfade_time = 0.15
	slide.add_transition("start", "loop", sl)
	var sl_in := AnimationNodeStateMachineTransition.new()
	sl_in.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO
	slide.add_transition("Start", "start", sl_in)
	loco.add_node("slide", slide, Vector2(800, 0))

	# --- traversal: climb-up (seekable), vault, hang, ladder / pipe / wall cycles, rope
	var climb := AnimationNodeBlendTree.new()
	var ca := AnimationNodeAnimation.new()
	ca.animation = _clip(&"climb_up_1m")
	climb.add_node("clip", ca, Vector2(0, 0))
	climb.add_node("seek", AnimationNodeTimeSeek.new(), Vector2(200, 0))
	climb.add_node("speed", AnimationNodeTimeScale.new(), Vector2(400, 0))
	climb.connect_node("seek", 0, "clip")
	climb.connect_node("speed", 0, "seek")
	climb.connect_node("output", 0, "speed")
	loco.add_node("climb", climb, Vector2(800, 400))
	loco.add_node("vault", _anim_from(&"run_jump", 0.15), Vector2(800, 500))
	for spec: Array in [["hang", &"ledge_hang"], ["ladder", &"ladder_climb"], ["pipe", &"pipe_climb"], ["wall", &"wall_climb"], ["rope", &"pipe_climb"]]:
		var bt := AnimationNodeBlendTree.new()
		bt.add_node("clip", _anim(spec[1]), Vector2(0, 0))
		bt.add_node("rate", AnimationNodeTimeScale.new(), Vector2(200, 0))
		bt.connect_node("rate", 0, "clip")
		bt.connect_node("output", 0, "rate")
		loco.add_node(spec[0], bt, Vector2(1000, 400))
	_build_hang(loco)
	_build_ladder(loco)

	# --- water: tread <-> stroke by speed (stroke rate-matched); dive = stroke along the body
	var swim := AnimationNodeBlendTree.new()
	swim.add_node("idle", _anim(&"swim_idle"), Vector2(0, 0))
	swim.add_node("fwd", _anim(&"swim_f"), Vector2(0, 200))
	swim.add_node("rate", AnimationNodeTimeScale.new(), Vector2(200, 200))
	swim.add_node("mix", AnimationNodeBlend2.new(), Vector2(400, 0))
	swim.connect_node("rate", 0, "fwd")
	swim.connect_node("mix", 0, "idle")
	swim.connect_node("mix", 1, "rate")
	swim.connect_node("output", 0, "mix")
	loco.add_node("swim", swim, Vector2(1200, 400))
	var dive := AnimationNodeBlendTree.new()
	dive.add_node("clip", _anim(&"swim_f"), Vector2(0, 0))
	dive.add_node("rate", AnimationNodeTimeScale.new(), Vector2(200, 0))
	dive.connect_node("rate", 0, "clip")
	dive.connect_node("output", 0, "rate")
	loco.add_node("dive", dive, Vector2(1200, 500))
	# --- down and up again (the ragdoll covers the fall; this is the pose it fades into)
	# Both get-ups last GETUP_TIME (the motor's GET_UP_TIME), played at their own speed:
	# face up = LayToIdle after lying still for the rest of the time; face down = Mixamo's
	# "Getting Up (from prone)" (role get_up_front), or Death_A's fall reversed as a fallback.
	var gu := AnimationNodeBlendTree.new()
	var ua := AnimationNodeAnimation.new()
	var up_len := _clip_len(&"get_up", 1.5)
	ua.animation = _segment(_clip(&"get_up"), 0.0, up_len, maxf(GETUP_TIME - up_len, 0.0))
	gu.add_node("clip", ua, Vector2(0, 0))
	gu.add_node("speed", AnimationNodeTimeScale.new(), Vector2(200, 0))
	gu.connect_node("speed", 0, "clip")
	gu.connect_node("output", 0, "speed")
	loco.add_node("getup", gu, Vector2(1400, 400))
	var gf := AnimationNodeBlendTree.new()
	var fa := AnimationNodeAnimation.new()
	if _role_anim(&"get_up_front"):
		_front_len = FRONT_GETUP_SEG.y - FRONT_GETUP_SEG.x
		fa.animation = _segment(_clip(&"get_up_front"), FRONT_GETUP_SEG.x, FRONT_GETUP_SEG.y)
	else:
		_front_len = FRONT_GETUP_LEN
		fa.animation = _reversed(_clip(&"death_a"), FRONT_GETUP_FROM, FRONT_GETUP_FROM + FRONT_GETUP_LEN)
	gf.add_node("clip", fa, Vector2(0, 0))
	gf.add_node("speed", AnimationNodeTimeScale.new(), Vector2(200, 0))
	gf.connect_node("speed", 0, "clip")
	gf.connect_node("output", 0, "speed")
	loco.add_node("getup_front", gf, Vector2(1400, 500))

	# --- root motion one-shots (clip swapped at runtime); two slots so back-to-back moves blend
	for n in ["rm_a", "rm_b"]:
		var a := AnimationNodeAnimation.new()
		a.animation = _clip(&"roll")
		loco.add_node(n, a, Vector2(800, 200))

	# Fully connected so travel() always crossfades directly.
	var names := ["ground", "crouch", "crawl", "air", "air_run", "fall", "land", "land_heavy", "slide", "rm_a", "rm_b", "climb", "vault", "hang", "ladder", "pipe", "wall", "rope", "swim", "dive", "getup", "getup_front"]
	for a_name in names:
		for b_name in names:
			if a_name == b_name:
				continue
			var t := AnimationNodeStateMachineTransition.new()
			t.xfade_time = _xfade(a_name, b_name)
			t.xfade_curve = _ease_curve()
			loco.add_transition(a_name, b_name, t)
	var start := AnimationNodeStateMachineTransition.new()
	loco.add_transition("Start", "ground", start)
	root.add_node("loco", loco, Vector2(0, 0))

	# --- upper-body layer (filled by items/carry in later milestones)
	var upper := AnimationNodeBlend2.new()
	upper.filter_enabled = true
	for b in _upper_body_bones():
		upper.set_filter_path(NodePath("%GeneralSkeleton:" + b), true)
	root.add_node("upper", upper, Vector2(300, 0))
	# Held-item layer: lowered / aimed pose, plus fire and reload one-shots. Clip names are
	# swapped in from the item's anim_roles when it changes (see _set_item_clips).
	var item := AnimationNodeBlendTree.new()
	item.add_node("low", _anim(&"idle"), Vector2(0, 0))
	item.add_node("aim", _anim(&"idle"), Vector2(0, 150))
	item.add_node("pose", AnimationNodeBlend2.new(), Vector2(200, 50))
	item.connect_node("pose", 0, "low")
	item.connect_node("pose", 1, "aim")
	var fire := AnimationNodeOneShot.new()
	fire.fadein_time = 0.02
	fire.fadeout_time = 0.12
	item.add_node("fire", fire, Vector2(400, 50))
	var fire_clip := AnimationNodeAnimation.new()
	item.add_node("fire_clip", fire_clip, Vector2(200, 200))
	# Sprinting with a rifle: one held frame of the rifle sprint clip (port arms - the rifle level
	# across the chest). The clip itself pumps the rifle 50 deg up and down every stride.
	var carry_clip := AnimationNodeAnimation.new()
	if _role_anim(&"e_sprint_f"):
		carry_clip.animation = _clip(&"e_sprint_f")
	item.add_node("carry_clip", carry_clip, Vector2(0, 300))
	item.add_node("carry_seek", AnimationNodeTimeSeek.new(), Vector2(150, 300))
	item.add_node("carry_hold", AnimationNodeTimeScale.new(), Vector2(300, 300))
	item.connect_node("carry_seek", 0, "carry_clip")
	item.connect_node("carry_hold", 0, "carry_seek")
	item.add_node("carry", AnimationNodeBlend2.new(), Vector2(300, 50))
	item.connect_node("carry", 0, "pose")
	item.connect_node("carry", 1, "carry_hold")
	item.connect_node("fire", 0, "carry")
	item.connect_node("fire", 1, "fire_clip")
	var reload := AnimationNodeOneShot.new()
	reload.fadein_time = 0.12
	reload.fadeout_time = 0.2
	for os: AnimationNodeOneShot in [fire, reload]:
		os.fadein_curve = _ease_curve()
		os.fadeout_curve = _ease_curve()
	item.add_node("reload", reload, Vector2(600, 50))
	var reload_clip := AnimationNodeAnimation.new()
	item.add_node("reload_clip", reload_clip, Vector2(400, 200))
	item.connect_node("reload", 0, "fire")
	item.connect_node("reload", 1, "reload_clip")
	item.connect_node("output", 0, "reload")
	root.add_node("upper_src", item, Vector2(150, 200))
	root.connect_node("upper", 0, "loco")
	root.connect_node("upper", 1, "upper_src")

	# Sprinting with a rifle (GTA's arms-only carry filter): the legs, hips, spine and head run
	# the plain upright sprint; only the arms (clavicles down) take one held frame of the rifle
	# sprint clip - port arms, the rifle across the chest. The rifle clip's own torso leaned
	# forward and twisted to the side, which looked wrong.
	var carry_arms := AnimationNodeBlend2.new()
	carry_arms.filter_enabled = true
	for b in _arm_bones():
		carry_arms.set_filter_path(NodePath("%GeneralSkeleton:" + b), true)
	root.add_node("carry_arms", carry_arms, Vector2(400, 0))
	var ca_clip := AnimationNodeAnimation.new()
	if _role_anim(&"e_sprint_f"):
		ca_clip.animation = _clip(&"e_sprint_f")
	root.add_node("carry_arms_clip", ca_clip, Vector2(150, 400))
	root.add_node("carry_arms_seek", AnimationNodeTimeSeek.new(), Vector2(250, 400))
	root.add_node("carry_arms_hold", AnimationNodeTimeScale.new(), Vector2(350, 400))
	root.connect_node("carry_arms_seek", 0, "carry_arms_clip")
	root.connect_node("carry_arms_hold", 0, "carry_arms_seek")
	# ... and the chest still: one held frame of the plain sprint (upright) for Spine..UpperChest,
	# so the shoulders don't counter-rotate the held rifle every stride (only the hips run).
	var carry_chest := AnimationNodeBlend2.new()
	carry_chest.filter_enabled = true
	for b in ["Spine", "Chest", "UpperChest"]:
		carry_chest.set_filter_path(NodePath("%GeneralSkeleton:" + b), true)
	root.add_node("carry_chest", carry_chest, Vector2(330, 0))
	var cc_clip := AnimationNodeAnimation.new()
	if _role_anim(&"n_sprint_f"):
		cc_clip.animation = _clip(&"n_sprint_f")
	root.add_node("carry_chest_clip", cc_clip, Vector2(150, 500))
	root.add_node("carry_chest_seek", AnimationNodeTimeSeek.new(), Vector2(250, 500))
	root.add_node("carry_chest_hold", AnimationNodeTimeScale.new(), Vector2(350, 500))
	root.connect_node("carry_chest_seek", 0, "carry_chest_clip")
	root.connect_node("carry_chest_hold", 0, "carry_chest_seek")
	root.connect_node("carry_chest", 0, "upper")
	root.connect_node("carry_chest", 1, "carry_chest_hold")
	root.connect_node("carry_arms", 0, "carry_chest")
	root.connect_node("carry_arms", 1, "carry_arms_hold")

	var hit := AnimationNodeOneShot.new()
	hit.fadein_time = 0.06
	hit.fadeout_time = 0.25
	hit.fadein_curve = _ease_curve()
	hit.fadeout_curve = _ease_curve()
	hit.filter_enabled = true
	for b in _upper_body_bones():
		hit.set_filter_path(NodePath("%GeneralSkeleton:" + b), true)
	root.add_node("hit", hit, Vector2(500, 0))
	root.add_node("hit_src", _anim(&"hit_chest", false), Vector2(350, 200))
	root.connect_node("hit", 0, "carry_arms")
	root.connect_node("hit", 1, "hit_src")
	var out_node := "hit"
	# Strikes (melee weapon swings, gun-butts): one segment of a swing clip, played time-scaled
	# so its contact frame lands on the simulated hit. Standing, the whole body swings (hips
	# and legs drive the blow - GTA / RDR play standing attacks full-body); moving, only the
	# upper body does, over the running legs, with part of the clip's hip lean folded into the
	# spine. Two layers fed the same segment, seeked together: "swing" (upper body) and
	# "swing_full" (whole body); weights from _drive_swing.
	var sw := AnimationNodeBlend2.new()
	sw.filter_enabled = true
	for b in _upper_body_bones():
		sw.set_filter_path(NodePath("%GeneralSkeleton:" + b), true)
	root.add_node("swing", sw, Vector2(560, 50))
	var sf := AnimationNodeBlend2.new()
	root.add_node("swing_full", sf, Vector2(640, 50))
	for k: String in ["swing_src", "swing_full_src"]:
		var src := _anim(&"hit_chest", false)
		root.add_node(k, src, Vector2(420, 230))
		root.add_node(k + "_seek", AnimationNodeTimeSeek.new(), Vector2(480, 230))
		root.add_node(k + "_ts", AnimationNodeTimeScale.new(), Vector2(540, 230))
		root.connect_node(k + "_seek", 0, k)
		root.connect_node(k + "_ts", 0, k + "_seek")
	root.connect_node("swing", 0, out_node)
	root.connect_node("swing", 1, "swing_src_ts")
	root.connect_node("swing_full", 0, "swing")
	root.connect_node("swing_full", 1, "swing_full_src_ts")
	out_node = "swing_full"
	# Throwing a carried prop: a two-handed push from the chest (upper body).
	if _role_anim(&"push_throw"):
		var push := AnimationNodeOneShot.new()
		push.fadein_time = 0.11
		push.fadeout_time = 0.3
		push.fadein_curve = _ease_curve()
		push.fadeout_curve = _ease_curve()
		push.filter_enabled = true
		for b in _upper_body_bones():
			push.set_filter_path(NodePath("%GeneralSkeleton:" + b), true)
		root.add_node("push", push, Vector2(600, 100))
		var pa := AnimationNodeAnimation.new()
		pa.animation = _upper_lean(_clip(&"push_throw"), 0.85)
		root.add_node("push_src", pa, Vector2(450, 250))
		root.connect_node("push", 0, out_node)
		root.connect_node("push", 1, "push_src")
		out_node = "push"
	if _role_anim(&"teeter"):
		var tb := AnimationNodeBlend2.new()
		tb.filter_enabled = true
		for b in _upper_body_bones():
			tb.set_filter_path(NodePath("%GeneralSkeleton:" + b), true)
		root.add_node("teeter", tb, Vector2(700, 0))
		var ta := AnimationNodeAnimation.new()
		ta.animation = _segment(_clip(&"teeter"), TEETER_SEG.x, TEETER_SEG.y)
		ta.use_custom_timeline = true
		ta.loop_mode = Animation.LOOP_LINEAR
		ta.timeline_length = TEETER_SEG.y - TEETER_SEG.x
		root.add_node("teeter_src", ta, Vector2(550, 200))
		root.connect_node("teeter", 0, out_node)
		root.connect_node("teeter", 1, "teeter_src")
		out_node = "teeter"
	root.connect_node("output", 0, out_node)
	return root


static func _xfade(a: String, b: String) -> float:
	if b == "air_run":
		return 0.1
	if b.begins_with("land"):
		return 0.12
	if a.begins_with("land") or b == "air":
		return 0.2
	if b.begins_with("rm") or a.begins_with("rm"):
		return 0.22
	if b == "slide" or a == "slide":
		return 0.18
	return 0.3


static var _ease: Curve


## Ease-in-out for crossfades (a linear fade reads as a pop at its ends).
static func _ease_curve() -> Curve:
	if _ease == null:
		_ease = Curve.new()
		_ease.add_point(Vector2(0, 0), 0, 0)
		_ease.add_point(Vector2(1, 1), 0, 0)
	return _ease


## Shoulders down to the fingertips, both sides.
func _arm_bones() -> PackedStringArray:
	var out := PackedStringArray()
	if skeleton == null:
		return out
	var roots := [skeleton.find_bone("LeftShoulder"), skeleton.find_bone("RightShoulder")]
	for b in skeleton.get_bone_count():
		var p := b
		while p >= 0:
			if p in roots:
				out.append(skeleton.get_bone_name(b))
				break
			p = skeleton.get_bone_parent(p)
	return out


func _upper_body_bones() -> PackedStringArray:
	var out := PackedStringArray()
	if skeleton == null:
		return out
	var spine := skeleton.find_bone("Spine")
	for b in skeleton.get_bone_count():
		var p := b
		while p >= 0:
			if p == spine:
				out.append(skeleton.get_bone_name(b))
				break
			p = skeleton.get_bone_parent(p)
	return out


# ------------------------------------------------------------------ per-frame drive

func _process(delta: float) -> void:
	if tree == null:
		return
	var local_v := _to_local(velocity)              # x = right, y = forward
	var speed := local_v.length()
	_drive_state(speed)
	# Climbing over / up, hanging, ladders...: the scripted move's own speed (a ledge climb
	# peaks at several m/s) isn't running. Fed to the ground blend it showed a frame or two of
	# sprinting legs as the move handed back to the ground.
	if state in TRAVERSING:
		local_v = Vector2.ZERO
	_drive_ground(local_v, local_v.length(), delta)
	_drive_swing(speed, delta)
	if _push_t > 0.0:
		_push_t -= delta
		if _push_t <= 0.0:
			tree.set("parameters/push/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FADE_OUT)
	_drive_body(delta)


func _to_local(v: Vector3) -> Vector2:
	var b := Basis(Vector3.UP, body_yaw)
	var l := b.inverse() * v
	return Vector2(l.x, -l.z)


func _drive_state(speed: float) -> void:
	var want := "ground"
	var Id := MotorState.Id
	match state:
		Id.JUMP:
			# Jumping at a run: the running leap.
			if _cur_loco != "air" and _cur_loco != "air_run":
				_run_jump = speed > RUN_JUMP_SPEED and _role_anim(&"leap") != null
				_jump_vy0 = 0.0
			want = "air_run" if _run_jump else "air"
		Id.FALL:
			# Brief ungrounded moments (a kerb, a ledge lip) aren't a fall worth showing.
			if air_time < 0.15 and _cur_loco in ["ground", "crouch", "crawl", "land"]:
				want = _cur_loco
			elif _cur_loco == "air_run" and air_time < 1.3:
				want = "air_run"
			else:
				want = "fall" if _cur_loco != "air" else "air"
		Id.LAND:
			want = "land_heavy" if hard_landing else "land"
		Id.SLIDE:
			want = "slide"
		Id.CROUCH:
			want = "crouch"
		Id.CRAWL:
			want = "crawl"
		Id.ROOT_MOTION:
			want = "rm"
		Id.MANTLE, Id.LEDGE_CLIMB:
			want = "climb"
		Id.VAULT:
			want = "vault"
		Id.LEDGE_HANG:
			want = "hang"
		Id.LADDER:
			want = "pipe" if climb_kind == 1 else "ladder"
		Id.WALL_CLIMB:
			want = "wall"
		Id.ROPE:
			want = "rope"
		Id.SWIM:
			want = "swim"
		Id.DIVE:
			want = "dive"
		Id.RAGDOLL, Id.DEAD:
			want = "fall"
		Id.GET_UP:
			# No legs to stand on: fade from the ragdoll straight into the crawl.
			want = "crawl" if getup_crawl else ("getup_front" if getup_front else "getup")
	if want == "rm":
		if rm_clip != _cur_rm:
			var curve := anim_set.rm_curve(rm_clip)
			var slot := "rm_b" if _cur_loco == "rm_a" else "rm_a"
			var node := (tree.tree_root as AnimationNodeBlendTree).get_node("loco").get_node(slot) as AnimationNodeAnimation
			var clip := String(curve.clip) if curve else ""
			node.animation = StringName(library_name + "/" + clip) if library_name != &"" else StringName(clip)
			_cur_rm = rm_clip
			_loco.travel(slot)
			_cur_loco = slot
			if inertial:
				inertial.trigger()
		return
	_cur_rm = -1
	if want == "land" and stance != MotorState.Stance.STAND:
		want = "crouch"
	if want == "climb" and _cur_loco != "climb":
		# A ledge climb-up starts with the hands already high (about a third into the clip).
		tree.set(LOCO + "climb/seek/seek_request", 0.22 if state == MotorState.Id.LEDGE_CLIMB else 0.0)
		tree.set(LOCO + "climb/speed/scale", 0.6 / maxf(climb_duration, 0.2))
	if want.begins_with("getup") and _cur_loco != want:
		var dur := GETUP_TIME
		tree.set(LOCO + "getup/speed/scale", maxf(_clip_len(&"get_up", 1.5), GETUP_TIME) / dur)
		tree.set(LOCO + "getup_front/speed/scale", _front_len / dur)
		_loco.start(want, true)
		_cur_loco = want
		if inertial:
			inertial.trigger()
		return
	if want != _cur_loco:
		if want in ["air", "land", "land_heavy"]:
			_loco.travel(want)
			# Restart one-shots even when re-entering the same node.
			if want != "air":
				_loco.start(want, true)
		else:
			_loco.travel(want)
		_cur_loco = want
		if inertial:
			inertial.trigger()


func _drive_ground(local_v: Vector2, speed: float, delta: float) -> void:
	var moving := speed > 0.12
	# Orientation warping: past a brisk walk the forward (or backward) cycle plays and the hips
	# turn up to 90° toward the travel direction, instead of over-speeding a walk-only strafe.
	var theta := atan2(local_v.x, local_v.y) if moving else 0.0
	var a := absf(theta)
	if _backwards and a < deg_to_rad(80.0):
		_backwards = false
	elif not _backwards and a > deg_to_rad(100.0):
		_backwards = true
	var backwards := _backwards
	# Past the strafe clips' own speed the forward cycle plays and the hips turn toward travel
	# (the strafe/diagonal clips would skate at a brisk walk).
	# Forward / sideways the blend space covers walking speeds (brisk walk + brisk side-steps);
	# only runs turn the hips. Backwards the side-steps blend badly, so it warps sooner.
	var target_warp := 0.0
	var blend_dir := theta
	var bp := Vector2.ZERO
	var clamped := Vector2.ZERO
	var rate := 1.0
	var side_r := 0.0
	var side_k := 0.0
	if _neutral:
		# Gait (walk / jog / sprint, and the bladed run vs sprint stance) follows an eased speed:
		# the motor brakes from a sprint in a few tenths of a second, which swept the body
		# through three clips (and the bladed set's hips through 40 deg) in a handful of frames.
		var gs := _ease_speed(speed, delta) if moving else speed
		var np := _neutral_point(theta, gs, moving)
		var wn: float = np[0]
		clamped = np[1]
		rate = np[2]
		if _eight_way:
			var bpt := _ring_point(theta, gs, moving)
			wn = lerp_angle(wn, bpt[0], _stance_w)
			tree.set(LOCO + "ground/move_b/blend_position", bpt[1])
			tree.set(LOCO + "ground/rate_b/scale", bpt[2])
		# (The limp clips play their own direction: no clip-snapping hip turn under them.)
		target_warp = wn * (1.0 - _limp_w)
		bp = Vector2(sin(theta), cos(theta)) * speed       # the true travel (limp space)
	else:
		if moving:
			var base := PI if backwards else 0.0
			var rel := angle_difference(base, theta)
			if backwards:
				# Backwards the legs only turn a little (looking down you'd see them cross under
				# you); the back + side-step clips blend for the rest of the angle.
				var lim := deg_to_rad(back_warp_deg)
				target_warp = clampf(rel, -lim, lim) * smoothstep(_walk_speed * 1.0, _walk_speed * 1.45, speed)
			else:
				# Walking: never blend the walk with a side-step (diagonals skate). Below ~45 deg
				# off forward play the walk with the hips turned toward travel; beyond it play the
				# side-step with the hips turned back. Running: the forward cycle, hips turned.
				var a2 := absf(rel)
				if _side_step and a2 < deg_to_rad(38.0):
					_side_step = false
				elif not _side_step and a2 > deg_to_rad(52.0):
					_side_step = true
				_side_g = move_toward(_side_g, 1.0 if _side_step else 0.0, delta * 4.0)
				var g := smoothstep(0.0, 1.0, _side_g)
				var walk_warp := signf(rel) * (a2 - g * PI * 0.5)
				var run_w := smoothstep(2.2, 3.2, speed)
				var walk_w := smoothstep(_walk_speed * 0.6, _walk_speed * 1.2, speed)
				target_warp = lerpf(walk_warp * walk_w, clampf(rel, -PI * 0.5, PI * 0.5), run_w)
			blend_dir = theta - target_warp
		bp = Vector2(sin(blend_dir), cos(blend_dir)) * speed
		clamped = _clamp_to_hull(bp)
		if clamped.length() > 0.01:
			rate = clampf(speed / clamped.length(), 1.0, 2.4 if backwards else 1.4)
		# Side-stepping slower than the side-step clip was authored: stay on the side-step point
		# and slow its cycle. (Off the points, the blend mixes the forward walk and the backpedal
		# into the side-step: a shorter stride under feet that keep cycling, so they skate and
		# the legs pop between poses.)
		side_r = absf(_hull[1].x if bp.x > 0.0 else _hull[3].x)
		side_k = smoothstep(0.8, 0.97, absf(bp.x) / maxf(bp.length(), 0.001)) * smoothstep(0.0, 1.0, _side_g)
		if side_k > 0.0 and speed < side_r and not backwards:
			clamped = clamped.lerp(Vector2(signf(bp.x) * side_r, 0.0), side_k)
			rate = lerpf(rate, maxf(speed / side_r, 0.4), side_k)
	_warp = lerp_angle(_warp, target_warp, 1.0 - exp(-10.0 * delta))
	# Limp: the cycle hurries through the bad leg's stance (short step) and lingers on the good
	# one, so the asymmetry comes from the real clip's timing rather than an overlay.
	if limp > 0.0 and moving and skeleton:
		if _lfoot < 0:
			_lfoot = skeleton.find_bone("LeftFoot")
			_rfoot = skeleton.find_bone("RightFoot")
		var ly := skeleton.get_bone_global_pose(_lfoot).origin.y
		var ry := skeleton.get_bone_global_pose(_rfoot).origin.y
		_bad_stance = (ly < ry) == limp_left
		if not _has_limp:
			rate *= (1.0 + 0.6 * limp) if _bad_stance else (1.0 - 0.25 * limp)
	else:
		_bad_stance = false
	tree.set(LOCO + "ground/move/blend_position", clamped)
	tree.set(LOCO + "ground/rate/scale", rate)
	if _eight_way and _neutral:
		var bladed := _item_w > 0.5 and not is_nan(modifier.item_hips_yaw) and absf(modifier.item_hips_yaw) > BLADED_HIPS
		_stance_w = _ease_w(&"stance", 1.0 if bladed else 0.0, delta)
		# (Sprinting with the rifle carried, the legs run the plain sprint: see carry_arms.)
		var sw := smoothstep(0.0, 1.0, _stance_w) * (1.0 - smoothstep(0.0, 1.0, sprint_carry))
		tree.set(LOCO + "ground/stance/blend_amount", sw)
		tree.set(LOCO + "ground/idle_stance/blend_amount", sw)
	if _has_limp:
		_limp_w = move_toward(_limp_w, smoothstep(0.0, 0.6, limp), get_process_delta_time() * 1.5)
		tree.set(LOCO + "ground/limp/blend_amount", _limp_w)
		tree.set(LOCO + "ground/limp_side/blend_amount", 0.0 if limp_left else 1.0)
		var lp := _clamp_to_hull(bp, _limp_hull)
		var lrate := clampf(speed / lp.length(), 0.6, 1.6) if lp.length() > 0.01 else 1.0
		if side_k > 0.0 and speed < side_r and not backwards:
			lp = lp.lerp(Vector2(signf(bp.x) * side_r, 0.0), side_k)
			lrate = lerpf(lrate, maxf(speed / side_r, 0.4), side_k)
		tree.set(LOCO + "ground/limp_l/blend_position", lp)
		tree.set(LOCO + "ground/limp_r/blend_position", lp)
		tree.set(LOCO + "ground/limp_rate/scale", lrate)
	# Idle <-> moving: eased in time, not taken straight from the speed (the motor gets up to
	# walking speed in a couple of ticks: the legs then cut from one pose to the other).
	tree.set(LOCO + "ground/mix/blend_amount", _ease_w(&"ground", smoothstep(0.05, 0.45, speed), delta))
	_drive_turn(moving, delta)
	if _cur_loco == "air_run":
		# Rising: take-off -> apex; falling: apex -> touchdown pose (held for a longer fall).
		_jump_vy0 = maxf(_jump_vy0, velocity.y)
		var v0 := maxf(_jump_vy0, 3.0)
		var seg := RUN_JUMP_SEG.y - RUN_JUMP_SEG.x
		var apex := RUN_JUMP_APEX - RUN_JUMP_SEG.x
		var t := lerpf(0.02, apex, clampf(1.0 - velocity.y / v0, 0.0, 1.0)) if velocity.y > 0.0 \
			else lerpf(apex, seg - 0.02, clampf(-velocity.y / v0, 0.0, 1.0))
		tree.set(LOCO + "air_run/seek/seek_request", t)
		tree.set(LOCO + "air_run/hold/scale", 0.0)
		# Past most of the way down: the falling arms come in (half strength at most).
		var down := smoothstep(apex + (seg - apex) * 0.55, seg - 0.02, t) if velocity.y < 0.0 else 0.0
		_leap_arms = move_toward(_leap_arms, down * LEAP_ARMS, delta * 1.5)
		tree.set(LOCO + "air_run/arms/blend_amount", smoothstep(0.0, 1.0, _leap_arms / LEAP_ARMS) * LEAP_ARMS)
	else:
		_leap_arms = 0.0
	tree.set(LOCO + "land/speed/scale", lerpf(1.5, 1.0, clampf((land_impact - 3.0) / 6.0, 0.0, 1.0)))
	tree.set(LOCO + "land/depth/blend_amount", lerpf(0.3, 1.0, smoothstep(3.0, 11.0, land_impact)))
	# Climbing cycles run at the speed you climb (and hold still when you stop).
	var cr := climb_speed / 0.6
	tree.set(LOCO + "ladder/rate/scale", climb_speed / _ladder_speed)
	tree.set(LOCO + "pipe/rate/scale", cr)
	tree.set(LOCO + "wall/rate/scale", climb_speed / 0.5)
	_hang_dir = move_toward(_hang_dir, clampf(climb_speed / 0.5, -1.0, 1.0), get_process_delta_time() * 5.0)
	tree.set(LOCO + "hang/side/blend_position", _hang_dir)
	tree.set(LOCO + "hang/rate/scale", 1.0 if absf(_hang_dir) < 0.05 else maxf(absf(climb_speed) / _shimmy_speed, 0.4))
	tree.set(LOCO + "rope/rate/scale", climb_speed / 0.6)
	# Swimming: stroke fades in with speed; dive strokes match 3D speed (slow glide when still).
	tree.set(LOCO + "swim/mix/blend_amount", _ease_w(&"swim", smoothstep(0.15, 0.8, speed), delta))
	tree.set(LOCO + "swim/rate/scale", clampf(speed / 1.5, 0.5, 1.8))
	tree.set(LOCO + "dive/rate/scale", clampf(velocity.length() / 1.8, 0.3, 1.6))
	# Crouch / crawl cycles: forward clip, warped toward travel direction, rate-matched.
	var crouch_rate := clampf(speed / _crouch_speed, 0.3, 2.2) * (-1.0 if backwards else 1.0)
	tree.set(LOCO + "crouch/rate/scale", crouch_rate)
	tree.set(LOCO + "crouch/mix/blend_amount", _ease_w(&"crouch", smoothstep(0.05, 0.3, speed), delta))
	var crawl_rate := clampf(speed / _crawl_speed, 0.0, 2.0) * (-1.0 if backwards else 1.0)
	tree.set(LOCO + "crawl/rate/scale", crawl_rate)
	tree.set(LOCO + "crawl/idle_rate/scale", 0.0)
	tree.set(LOCO + "crawl/mix/blend_amount", 1.0)
	if state in [MotorState.Id.CROUCH, MotorState.Id.CRAWL] and moving:
		var rel2 := angle_difference(PI if backwards else 0.0, theta)
		_warp = lerp_angle(_warp, clampf(rel2, -1.2, 1.2), 1.0 - exp(-10.0 * delta))


## The gait speed on a spring (half-life GAIT_HALFLIFE); it starts from the real speed.
const GAIT_HALFLIFE := 0.1
var _gait := Vector2(-1.0, 0.0)


func _ease_speed(speed: float, delta: float) -> float:
	if _gait.x < 0.0 or absf(_gait.x - speed) > 4.0 and speed < 0.2:
		_gait = Vector2(speed, 0.0)
	var y := 4.0 * 0.69314718 / GAIT_HALFLIFE / 2.0
	var j0 := _gait.x - speed
	var j1 := _gait.y + j0 * y
	var e := exp(-y * maxf(delta, 0.0))
	_gait = Vector2(maxf(e * (j0 + j1 * delta) + speed, 0.0), e * (_gait.y - j1 * y * delta))
	return _gait.x


## Blend weights that follow a target on a critically damped spring (half-life MIX_HALFLIFE):
## they start and settle gently however fast the target moves.
const MIX_HALFLIFE := 0.09
var _mix := {}


func _ease_w(key: StringName, target: float, delta: float) -> float:
	var st: Vector2 = _mix.get(key, Vector2(target, 0.0))          # x = value, y = rate
	var y := 4.0 * 0.69314718 / MIX_HALFLIFE / 2.0
	var j0 := st.x - target
	var j1 := st.y + j0 * y
	var e := exp(-y * maxf(delta, 0.0))
	st = Vector2(e * (j0 + j1 * delta) + target, e * (st.y - j1 * y * delta))
	st.x = clampf(st.x, 0.0, 1.0)
	_mix[key] = st
	return st.x


# ---------------------------------------------------------------- turning in place

## Turn-in-place clips per stance: [left, right]. The motor turns the body (eased); the clip,
## its hips' own yaw taken out, is played from how far the body has turned - the feet step
## round in time with the turn whatever its speed or size.
const TURN_ROLES := {
	"stand": [&"stand_turn_l", &"stand_turn_r"],
	"aim": [&"aim_turn_l", &"aim_turn_r"],
	"crouch": [&"crouch_turn_l", &"crouch_turn_r"],
}
var _turn_nodes := []               ## [param prefix, left clip, right clip]
var _turn_tabs := {}                ## clip -> PackedFloat32Array, turned so far (|yaw|) at 60 Hz
var _turn_dir := 0                  ## -1 left, +1 right, 0 none
var _turn_from := 0.0
var _turn_p := 0.0                  ## 0..1 of this turn done
var _turn_w := 0.0


## Insert a turn blend (left clip, `idle_node`, right clip) into `bt`; returns the node to use
## in place of `idle_node` (unchanged when the clips are missing).
func _add_turn(bt: AnimationNodeBlendTree, prefix: String, key: String, idle_node: String, at: Vector2) -> String:
	var roles: Array = TURN_ROLES[key]
	if _role_anim(roles[0]) == null or _role_anim(roles[1]) == null:
		return idle_node
	var clips := []
	for i in 2:
		var a := AnimationNodeAnimation.new()
		a.animation = _turn_clip(roles[i])
		clips.append(a.animation)
		bt.add_node("%s_t%d" % [key, i], a, at + Vector2(0, i * 100))
		bt.add_node("%s_seek%d" % [key, i], AnimationNodeTimeSeek.new(), at + Vector2(200, i * 100))
		bt.connect_node("%s_seek%d" % [key, i], 0, "%s_t%d" % [key, i])
	bt.add_node(key + "_turn", AnimationNodeBlend3.new(), at + Vector2(400, 50))
	bt.connect_node(key + "_turn", 0, key + "_seek0")
	bt.connect_node(key + "_turn", 1, idle_node)
	bt.connect_node(key + "_turn", 2, key + "_seek1")
	_turn_nodes.append([prefix + key, clips[0], clips[1]])
	return key + "_turn"


## The role's clip with the Hips' yaw taken out (in place, facing ahead throughout), and its
## progress table (how far it has turned at each 1/60 s, never decreasing).
func _turn_clip(role: StringName) -> StringName:
	var clip := _clip(role)
	var src := _lib_anim(clip)
	var s := String(clip)
	var lib := s.get_slice("/", 0) if s.contains("/") else ""
	var clip_name := s.get_slice("/", 1) if s.contains("/") else s
	var l := player.get_animation_library(lib)
	if src == null or l == null:
		return clip
	var rt := src.find_track(NodePath("%GeneralSkeleton:Hips"), Animation.TYPE_ROTATION_3D)
	if rt < 0:
		return clip
	var y0 := _yaw_of(src.rotation_track_interpolate(rt, 0.0))
	var yaw_at := func(t: float) -> float: return angle_difference(y0, _yaw_of(src.rotation_track_interpolate(rt, t)))
	var tab := PackedFloat32Array()
	var best := 0.0
	for i in int(ceil(src.length * 60.0)) + 1:
		best = maxf(best, absf(yaw_at.call(minf(i / 60.0, src.length))))
		tab.append(best)
	var out := StringName((lib + "/" if lib != "" else "") + clip_name + "_inplace")
	_turn_tabs[out] = tab
	if not l.has_animation(clip_name + "_inplace"):
		var a := src.duplicate(true) as Animation
		var art := a.find_track(NodePath("%GeneralSkeleton:Hips"), Animation.TYPE_ROTATION_3D)
		for k in a.track_get_key_count(art):
			var y: float = yaw_at.call(a.track_get_key_time(art, k))
			a.track_set_key_value(art, k, Quaternion(Vector3.UP, -y) * (a.track_get_key_value(art, k) as Quaternion))
		var pt := a.find_track(NodePath("%GeneralSkeleton:Hips"), Animation.TYPE_POSITION_3D)
		if pt >= 0 and a.track_get_key_count(pt) > 0:
			var p0: Vector3 = a.track_get_key_value(pt, 0)
			var n := a.track_get_key_count(pt)
			for k in n:
				var y: float = yaw_at.call(a.track_get_key_time(pt, k))
				var p: Vector3 = a.track_get_key_value(pt, k)
				a.track_set_key_value(pt, k, p0 + Basis(Vector3.UP, -y) * (p - p0))
			# Turning on the spot: take out any net sideways drift (it would snap back as the clip
			# blends out to the idle), spread over the clip.
			var d: Vector3 = a.track_get_key_value(pt, n - 1) - p0
			d.y = 0.0
			for k in n:
				var f := a.track_get_key_time(pt, k) / maxf(a.length, 0.001)
				a.track_set_key_value(pt, k, (a.track_get_key_value(pt, k) as Vector3) - d * f)
		a.loop_mode = Animation.LOOP_NONE
		l.add_animation(clip_name + "_inplace", a)
	return out


static func _yaw_of(q: Quaternion) -> float:
	var z := Basis(q).z
	return atan2(z.x, z.z)


## Clip time at which the turn clip has done `p` of its turn.
func _turn_time(clip: StringName, p: float) -> float:
	var tab: PackedFloat32Array = _turn_tabs.get(clip, PackedFloat32Array())
	if tab.size() < 2:
		return 0.0
	var want := clampf(p, 0.0, 1.0) * tab[tab.size() - 1]
	for i in range(1, tab.size()):
		if tab[i] >= want:
			var span := tab[i] - tab[i - 1]
			var f := (want - tab[i - 1]) / span if span > 1e-5 else 1.0
			return (i - 1 + f) / 60.0
	return (tab.size() - 1) / 60.0


func _drive_turn(moving: bool, delta: float) -> void:
	var on := turning and not moving and state in [MotorState.Id.IDLE, MotorState.Id.CROUCH, MotorState.Id.TURN_IN_PLACE]
	if on:
		var dir := -1 if angle_difference(body_yaw, aim_yaw) > 0.0 else 1      # -1 = turning left
		if dir != _turn_dir:
			if _turn_dir != 0 and inertial:
				inertial.trigger()
			_turn_dir = dir
			_turn_from = body_yaw
			_turn_p = 0.0
		var done := absf(angle_difference(_turn_from, body_yaw))
		var rest := absf(angle_difference(body_yaw, aim_yaw))
		_turn_p = maxf(_turn_p, done / maxf(done + rest, 0.01))
	elif _turn_dir != 0:
		_turn_p = move_toward(_turn_p, 1.0, delta * 2.0)
	# In quickly (the feet must start stepping as the body starts turning), out over ~0.3 s.
	_turn_w = move_toward(_turn_w, 1.0 if on else 0.0, delta * (8.0 if on else 3.5))
	if _turn_w <= 0.0:
		_turn_dir = 0
	var amt := float(_turn_dir) * smoothstep(0.0, 1.0, _turn_w)
	# The turn clip's own quick steps are real motion (played from the body's turn): don't
	# smooth them as if they were jumps.
	if inertial:
		inertial.detect = _turn_w < 0.05
	for n: Array in _turn_nodes:
		tree.set(n[0] + "_turn/blend_amount", amt)
		if _turn_dir != 0:
			var i := 0 if _turn_dir < 0 else 1
			tree.set("%s_seek%d/seek_request" % [n[0], i], _turn_time(n[1 + i], _turn_p))


# ---------------------------------------------------------------- neutral locomotion

## Square-on, upright walking: forward / back / side clips (one each, the side one mirrored) and
## a forward jog + sprint line. Each direction plays one real clip with the hips turned the rest
## of the way (<= 45 deg + hysteresis); faster than the walk going forward runs up the line.
## (No neutral 8-way set exists on Mixamo; blending two directions shortens the stride.)
const NEUTRAL_ROLES: Array[StringName] = [&"n_walk_f", &"n_walk_b", &"n_side", &"n_jog_f", &"n_sprint_f"]
var _neutral := false
var _nw_ring := PackedVector2Array()      ## F, R, B, L walk points (x = right, y = forward)
var _nw_line := PackedVector2Array()      ## forward: walk, jog, sprint
var _nw_side_clip: Array[StringName] = [&"", &""]   ## right-going, left-going side clips


func _build_neutral(bs: AnimationNodeBlendSpace2D) -> void:
	bs.auto_triangles = false
	var wf := anim_set.speed_of(&"n_walk_f", 1.4)
	var wb := anim_set.speed_of(&"n_walk_b", 0.97)
	var ws := anim_set.speed_of(&"n_side", 0.8)
	var side := _clip(&"n_side")
	# Which way does the side clip go? (model +X = the character's left)
	var goes_right := _travel_model(side).x < 0.0
	var mirrored := _mirrored(side)
	_nw_side_clip[0] = side if goes_right else mirrored
	_nw_side_clip[1] = mirrored if goes_right else side
	_nw_ring = PackedVector2Array([Vector2(0, wf), Vector2(ws, 0), Vector2(0, -wb), Vector2(-ws, 0)])
	_nw_line = PackedVector2Array([Vector2(0, wf), Vector2(0, anim_set.speed_of(&"n_jog_f", 4.8)), Vector2(0, anim_set.speed_of(&"n_sprint_f", 7.1))])
	var sr := _anim(&"n_side")
	sr.animation = _nw_side_clip[0]
	sr.start_offset = 0.0
	var sl := _anim(&"n_side")
	sl.animation = _nw_side_clip[1]
	sl.start_offset = 0.0
	bs.add_blend_point(_anim(&"n_walk_f"), _nw_ring[0], -1, &"walk")         # 0
	bs.add_blend_point(sr, _nw_ring[1], -1, &"side_r")                        # 1
	bs.add_blend_point(_anim(&"n_walk_b"), _nw_ring[2], -1, &"back")          # 2
	bs.add_blend_point(sl, _nw_ring[3], -1, &"side_l")                        # 3
	bs.add_blend_point(_anim(&"n_jog_f"), _nw_line[1], -1, &"jog")            # 4
	bs.add_blend_point(_anim(&"n_sprint_f"), _nw_line[2], -1, &"sprint")      # 5
	bs.add_triangle(3, 0, 1)
	bs.add_triangle(3, 1, 2)
	bs.add_triangle(3, 0, 4)
	bs.add_triangle(0, 1, 4)
	bs.add_triangle(3, 4, 5)
	bs.add_triangle(4, 1, 5)
	_walk_speed = wf
	_back_speed = wb
	_sprint_speed = _nw_line[2].y
	_hull = PackedVector2Array([_nw_line[2], _nw_ring[1], _nw_ring[2], _nw_ring[3]])


## [hips warp, blend point, rate] for the neutral set.
func _neutral_point(theta: float, speed: float, moving: bool) -> Array:
	# Stopping: hold the last direction while the move weight eases out (jumping back to the
	# forward walk snapped the legs round).
	if not moving:
		return [_nw_hold[0], _nw_hold[1], 1.0] if not _nw_hold.is_empty() else [0.0, _nw_ring[0], 1.0]
	_nw_hold = _neutral_point_moving(theta, speed)
	return _nw_hold


var _nw_hold := []
var _bl_hold := []


func _neutral_point_moving(theta: float, speed: float) -> Array:
	var snapped := _snap_dir(theta, _nw_ring, "n")
	var warp := angle_difference(snapped, theta)
	var k := 0
	for i in 4:
		if is_equal_approx(atan2(_nw_ring[i].x, _nw_ring[i].y), snapped):
			k = i
	var p := _nw_ring[k]
	if k == 0 and speed > p.y:
		var y := minf(speed, _nw_line[2].y)
		return [warp, Vector2(0, y), clampf(speed / y, 1.0, 1.4)]
	return [warp, p, clampf(speed / p.length(), 0.45, 2.0)]


## Travel direction of a clip in model space (x = the character's left, y = forward), from the
## planted foot sliding under the body.
func _travel_model(clip: StringName) -> Vector2:
	var a := _lib_anim(clip)
	if a == null:
		return Vector2.ZERO
	var feet := [skeleton.find_bone("LeftToes"), skeleton.find_bone("RightToes")]
	var n := 60
	var ps := [[], []]
	for k in n:
		UltraPoseSampler.pose(a, skeleton, a.length * k / n)
		for f in 2:
			ps[f].append(UltraPoseSampler.global_pose(skeleton, feet[f]).origin)
	for b in skeleton.get_bone_count():
		skeleton.reset_bone_pose(b)
	var miny := [INF, INF]
	for f in 2:
		for q: Vector3 in ps[f]:
			miny[f] = minf(miny[f], q.y)
	var sum := Vector2.ZERO
	for k in n:
		var j := (k + 1) % n
		var lo := 0 if (ps[0][k] as Vector3).y <= (ps[1][k] as Vector3).y else 1
		if (ps[lo][k] as Vector3).y > miny[lo] + 0.03 or (ps[lo][j] as Vector3).y > miny[lo] + 0.03:
			continue
		sum += Vector2((ps[lo][j] as Vector3).x - (ps[lo][k] as Vector3).x, (ps[lo][j] as Vector3).z - (ps[lo][k] as Vector3).z)
	return -sum.normalized()


## [hips warp, blend point, rate] for the bladed 8-way set: the nearest clip direction (with
## hysteresis), hips turned the rest; sprints the same among the sprint clips.
func _ring_point(theta: float, speed: float, moving: bool) -> Array:
	if _bl_walk.is_empty():
		return [0.0, Vector2.ZERO, 1.0]
	if not moving:
		return [_bl_hold[0], _bl_hold[1], 1.0] if not _bl_hold.is_empty() else [0.0, _bl_walk[0], 1.0]
	_bl_hold = _ring_point_moving(theta, speed)
	return _bl_hold


func _ring_point_moving(theta: float, speed: float) -> Array:
	var snapped := _snap_dir(theta, _bl_walk, "b")
	var warp := angle_difference(snapped, theta)
	var dir := Vector2(sin(snapped), cos(snapped))
	var r_walk := _ring_radius(_bl_walk, dir)
	var r_run := _ring_radius(_bl_run, dir)
	var best := _bl_sprint[0] if not _bl_sprint.is_empty() else Vector2.ZERO
	for sp_pt in _bl_sprint:
		if absf(angle_difference(atan2(sp_pt.x, sp_pt.y), theta)) < absf(angle_difference(atan2(best.x, best.y), theta)):
			best = sp_pt
	# Run -> sprint squares the hips up (~40 deg): eased, so it takes a few tenths of a second.
	var sprinting := not _bl_sprint.is_empty() and speed > r_run * 1.05 and absf(theta) < deg_to_rad(75.0)
	var kk := _ease_w(&"b_sprint", smoothstep(r_run * 1.05, best.length() * 0.95, speed) if sprinting else 0.0, get_process_delta_time())
	var base: Array
	if speed < r_walk:
		base = [warp, dir * r_walk, maxf(speed / r_walk, 0.45)]
	else:
		var sp := minf(speed, r_run)
		base = [warp, dir * sp, clampf(speed / sp, 1.0, 1.5)]
	if kk > 0.001:
		var w8 := clampf(angle_difference(atan2(best.x, best.y), theta), -deg_to_rad(30.0), deg_to_rad(30.0))
		var c8: Vector2 = (base[1] as Vector2).lerp(best, kk)
		return [lerp_angle(warp, w8, kk), c8, lerpf(base[2], clampf(speed / maxf(c8.length(), 0.01), 0.8, 1.4), kk)]
	return base


## The travel direction pulled onto a clip direction of the walk ring: the current clip holds
## until the travel is more than EIGHT_WAY_HYST past halfway to a neighbour, then it switches
## in one go (the inertial blend smooths the pose; mixing two neighbouring clips skates).
const EIGHT_WAY_HYST := deg_to_rad(6.0)
var _snap := {}
func _snap_dir(theta: float, ring: PackedVector2Array, key: String) -> float:
	var angs: Array[float] = []
	for p in ring:
		angs.append(atan2(p.x, p.y))
	var _snap_ang: float = _snap.get(key, NAN)
	var best := angs[0]
	for a in angs:
		if absf(angle_difference(a, theta)) < absf(angle_difference(best, theta)):
			best = a
	if is_nan(_snap_ang):
		_snap_ang = best
	elif best != _snap_ang:
		# Halfway to the neighbour is |gap|/2 from the current clip: switch past that + hysteresis.
		var gap := absf(angle_difference(_snap_ang, best))
		if absf(angle_difference(_snap_ang, theta)) > gap * 0.5 + EIGHT_WAY_HYST:
			_snap_ang = best
			if inertial:
				inertial.trigger()
	_snap[key] = _snap_ang
	return _snap_ang


# ---------------------------------------------------------------- eight-way locomotion

## The bladed stance: an 8-direction walk / run (+ forward sprints) set from one capture (the
## Mixamo rifle pack, pelvis ~40 deg off the travel direction, as authored). Used under
## two-handed weapons whose own clips are bladed, so legs and torso agree.
const EIGHT_WAY_DIRS := ["f", "fr", "r", "br", "b", "bl", "l", "fl"]
var EIGHT_WAY_ROLES: Array[StringName] = _eight_roles()
var _eight_way := false
var _bl_walk := PackedVector2Array()
var _bl_run := PackedVector2Array()
var _bl_sprint := PackedVector2Array()
var _bl_hull := PackedVector2Array()
var _stance_w := 0.0
## 0..1: sprinting with a bladed (rifle) item: the item layer holds the rifle sprint carry
## (first person follows the body then, so both views show the same carry).
var sprint_carry := 0.0
const SPRINT_CARRY_SPEED := 4.2
const UNARMED_STEADY := 0.45           ## torso_steady at a run with nothing in hand
const ITEM_STEADY := 0.72              ## ... with a one-handed item (0.85 looked frozen)
const SPRINT_CARRY_T := 0.225          ## s into e_sprint_f: mid arm pump, rifle level across the chest
const BLADED_HIPS := 0.4             ## rad: an item clip whose hips turn this far = bladed stance


static func _eight_roles() -> Array[StringName]:
	var out: Array[StringName] = []
	for gait in ["walk", "run"]:
		for d: String in EIGHT_WAY_DIRS:
			out.append(StringName("e_%s_%s" % [gait, d]))
	return out


func _build_eight_way(bs: AnimationNodeBlendSpace2D) -> void:
	bs.auto_triangles = false
	var rings := {}
	for gait in ["walk", "run", "sprint"]:
		# One turn per gait (the set's mean stance): the directions stay evenly spread (the
		# stance differs a little per direction; turning clips one by one would bunch them up).
		var mean := Vector2.ZERO
		for d: String in EIGHT_WAY_DIRS:
			var role0 := StringName("e_%s_%s" % [gait, d])
			if _role_anim(role0) != null:
				var f := _hips_facing(_clip(role0))
				mean += Vector2(sin(f), cos(f))
		# Walk / run: turned to stand exactly like the two-handed aiming clip (rifle_aim), so the
		# torso needs no twist on top; sprints stay as authored (a sprinting rifleman squares up).
		var turn := 0.0
		if gait != "sprint" and _role_anim(&"rifle_aim") != null and mean.length() > 0.01:
			turn = angle_difference(atan2(mean.x, mean.y), _hips_facing(_clip(&"rifle_aim")))
		var pts := []
		for d: String in EIGHT_WAY_DIRS:
			var role := StringName("e_%s_%s" % [gait, d])
			if _role_anim(role) == null:
				continue
			var a := _anim(role)
			a.animation = _turned(a.animation, turn)
			var tdir := _travel_of(role).rotated(turn)           # (blend space x = right)
			var p := tdir * anim_set.speed_of(role, 1.7 if gait == "walk" else 4.5)
			pts.append([p, a, StringName("%s_%s" % [gait, d])])
		pts.sort_custom(func(x: Array, y: Array) -> bool: return atan2((x[0] as Vector2).x, (x[0] as Vector2).y) < atan2((y[0] as Vector2).x, (y[0] as Vector2).y))
		rings[gait] = pts
	var idx := {}
	for gait in ["walk", "run", "sprint"]:
		var ids := []
		for e: Array in rings[gait]:
			ids.append(bs.get_blend_point_count())
			bs.add_blend_point(e[1], e[0], -1, e[2])
		idx[gait] = ids
	var w: Array = idx["walk"]
	var r: Array = idx["run"]
	var n := w.size()
	for i in n:
		var j := (i + 1) % n
		bs.add_triangle(w[i], w[j], r[j])
		bs.add_triangle(w[i], r[j], r[i])
	_bl_walk = PackedVector2Array(rings["walk"].map(func(e: Array) -> Vector2: return e[0]))
	_bl_run = PackedVector2Array(rings["run"].map(func(e: Array) -> Vector2: return e[0]))
	# Sprints (forward-ish only): fan out from the run points nearest to them.
	var hull := _bl_run.duplicate()
	for k in (rings["sprint"] as Array).size():
		var sp: Vector2 = rings["sprint"][k][0]
		var near := 0
		for i in n:
			if _bl_run[i].normalized().dot(sp.normalized()) > _bl_run[near].normalized().dot(sp.normalized()):
				near = i
		hull[near] = sp
		var nb := (near + 1) % n
		var pb := (near - 1 + n) % n
		bs.add_triangle(r[near], r[nb], idx["sprint"][k])
		bs.add_triangle(r[pb], r[near], idx["sprint"][k])
	_bl_hull = hull
	_bl_sprint = PackedVector2Array(rings["sprint"].map(func(e: Array) -> Vector2: return e[0]))


## The clip's travel direction in blend space (x = right, y = forward), from its role name.
func _travel_of(role: StringName) -> Vector2:
	var d := String(role).get_slice("_", 2)
	var v := Vector2.ZERO
	if d.contains("f"):
		v.y += 1.0
	if d.contains("b"):
		v.y -= 1.0
	if d.contains("r"):
		v.x += 1.0
	if d.contains("l"):
		v.x -= 1.0
	return v.normalized()


## Mean facing of a clip's hip line (radians, + = toward the character's left / -x).
func _hips_facing(clip: StringName) -> float:
	var a := _lib_anim(clip)
	if a == null:
		return 0.0
	var l := skeleton.find_bone("LeftUpperLeg")
	var r := skeleton.find_bone("RightUpperLeg")
	var sum := Vector2.ZERO
	for k in 12:
		UltraPoseSampler.pose(a, skeleton, a.length * k / 12.0)
		var f := Vector3.UP.cross(UltraPoseSampler.global_pose(skeleton, r).origin - UltraPoseSampler.global_pose(skeleton, l).origin)
		sum += Vector2(f.x, f.z).normalized()
	for b in skeleton.get_bone_count():
		skeleton.reset_bone_pose(b)
	return atan2(sum.x, sum.y)


## A copy of `clip` turned `angle` radians about the vertical (Hips rotation + position).
func _turned(clip: StringName, angle: float) -> StringName:
	var s := String(clip)
	var lib := s.get_slice("/", 0) if s.contains("/") else ""
	var clip_name := s.get_slice("/", 1) if s.contains("/") else s
	var l := player.get_animation_library(lib)
	if l == null or not l.has_animation(clip_name) or absf(angle) < 0.01:
		return clip
	var rname := "%s_turn%d" % [clip_name, int(round(rad_to_deg(angle)))]
	if not l.has_animation(rname):
		var a := l.get_animation(clip_name).duplicate(true) as Animation
		var q := Quaternion(Vector3.UP, angle)
		for t in a.get_track_count():
			if String(a.track_get_path(t).get_concatenated_subnames()) != "Hips":
				continue
			for k in a.track_get_key_count(t):
				match a.track_get_type(t):
					Animation.TYPE_ROTATION_3D:
						a.track_set_key_value(t, k, q * (a.track_get_key_value(t, k) as Quaternion))
					Animation.TYPE_POSITION_3D:
						a.track_set_key_value(t, k, q * (a.track_get_key_value(t, k) as Vector3))
		l.add_animation(rname, a)
	return StringName((lib + "/" if lib != "" else "") + rname)


func _lib_anim(clip: StringName) -> Animation:
	var s := String(clip)
	var lib := s.get_slice("/", 0) if s.contains("/") else ""
	var clip_name := s.get_slice("/", 1) if s.contains("/") else s
	var l := player.get_animation_library(lib)
	return l.get_animation(clip_name) if l and l.has_animation(clip_name) else null


## The walking side-step used by the limp space: the neutral set's side clips, or the classic
## strafe clips.
func _side_walk_anim(right: bool, sr: AnimationNodeAnimation) -> AnimationNodeAnimation:
	if _neutral:
		var a := _anim(&"n_side")
		a.animation = _nw_side_clip[0 if right else 1]
		a.start_offset = 0.0
		return a
	return sr.duplicate() if right else _anim(&"strafe_l")


static func _ring_radius(ring: PackedVector2Array, dir: Vector2) -> float:
	for i in ring.size():
		var hit: Variant = Geometry2D.segment_intersects_segment(Vector2.ZERO, dir * 50.0, ring[i], ring[(i + 1) % ring.size()])
		if hit != null:
			return maxf((hit as Vector2).length(), 0.1)
	return ring[0].length()


func _clamp_to_hull(p: Vector2, hull := PackedVector2Array()) -> Vector2:
	var h := _hull if hull.is_empty() else hull
	if Geometry2D.is_point_in_polygon(p, h):
		return p
	var best := p
	var best_d := INF
	var dir := p.normalized()
	for i in h.size():
		var a := h[i]
		var b := h[(i + 1) % h.size()]
		var hit: Variant = Geometry2D.segment_intersects_segment(Vector2.ZERO, dir * 50.0, a, b)
		if hit != null:
			var d := (hit as Vector2).length()
			if d < best_d:
				best_d = d
				best = hit
	return best


func _drive_body(delta: float) -> void:
	if modifier == null:
		return
	# Lean from acceleration in body space, through a soft spring so it swings and settles.
	var la := _to_local(accel)
	var target := Vector2(clampf(la.x * 0.022, -0.16, 0.16), clampf(la.y * 0.018, -0.12, 0.12))
	if state in [MotorState.Id.JUMP, MotorState.Id.FALL, MotorState.Id.ROOT_MOTION, MotorState.Id.SWIM, MotorState.Id.DIVE]:
		target = Vector2.ZERO
	# Limp: weight off the bad leg (lean over the good one while the bad foot is down).
	if limp > 0.0:
		target.x += (1.0 if limp_left else -1.0) * limp * (0.11 if _bad_stance else 0.03)
	var k := 60.0
	var c := 2.0 * sqrt(k) * 0.7
	_lean_vel += ((target - _lean) * k - _lean_vel * c) * delta
	_lean += _lean_vel * delta
	_drive_item(delta)
	# Feet: full grounding when standing / walking, easing off at a run, off in the air.
	var foot_w := 0.0
	var Id := MotorState.Id
	if state in [Id.IDLE, Id.MOVE, Id.CROUCH, Id.LAND, Id.TURN_IN_PLACE]:
		var sp := Vector2(velocity.x, velocity.z).length()
		foot_w = lerpf(1.0, 0.55, smoothstep(2.0, 6.5, sp))
	_foot_w = move_toward(_foot_w, foot_w * ik_scale, delta * (10.0 if foot_w < _foot_w else 4.0))
	if foot_ik:
		foot_ik.weight = _foot_w
		foot_ik.lock_weight = 0.0 if on_platform else 1.0
	modifier.lean_roll = _lean.x
	modifier.lean_pitch = _lean.y
	modifier.hunch = injury_hunch
	var gsp := Vector2(velocity.x, velocity.z).length()
	modifier.sway_weight = smoothstep(0.3, 1.2, gsp) if state in [MotorState.Id.MOVE, MotorState.Id.IDLE, MotorState.Id.CROUCH] else 0.0
	modifier.warp_yaw = _warp
	_aim_w = move_toward(_aim_w, aim_weight, delta * 4.0)
	var yaw_off := clampf(-angle_difference(body_yaw, aim_yaw), -deg_to_rad(80.0), deg_to_rad(80.0))
	# Climbing / hanging: look with the head, not the chest (the hands stay on the wall).
	var climbing := state in [MotorState.Id.LADDER, MotorState.Id.WALL_CLIMB, MotorState.Id.LEDGE_HANG,
		MotorState.Id.LEDGE_CLIMB, MotorState.Id.MANTLE, MotorState.Id.ROPE]
	_climb_look = move_toward(_climb_look, 1.0 if climbing else 0.0, delta * 4.0)
	modifier.spine_aim_scale = lerpf(1.0, 0.15, smoothstep(0.0, 1.0, _climb_look))
	var pitch_lim := lerpf(1.35, 0.95, _climb_look)
	modifier.aim_pitch = clampf(aim_pitch, -pitch_lim, pitch_lim) * _aim_w
	modifier.aim_yaw = yaw_off * _aim_w
	if look and skeleton:
		# Free third person: the head (not the spine) follows where the player looks.
		var head_w := (1.0 - _aim_w) * 0.85
		var dir := Vector3(-sin(aim_yaw) * cos(aim_pitch), sin(aim_pitch), -cos(aim_yaw) * cos(aim_pitch))
		var head_pos := skeleton.global_transform * skeleton.get_bone_global_pose(skeleton.find_bone("Head")).origin
		look.glance_target = head_pos + dir * 8.0
		look.glance_weight = head_w
	if state == MotorState.Id.ROOT_MOTION:
		modifier.aim_yaw = 0.0
		modifier.aim_pitch *= 0.3
	# Down / getting up / dead: the clip (or the ragdoll) owns the head and spine entirely -
	# no aim offset, no glances, no stabiliser fighting the motion.
	var body_owned := state in [MotorState.Id.RAGDOLL, MotorState.Id.DEAD, MotorState.Id.GET_UP]
	_owned_w = move_toward(_owned_w, 1.0 if body_owned else 0.0, delta * (8.0 if body_owned else 2.0))
	if _owned_w > 0.0:
		var kk := 1.0 - _owned_w
		modifier.aim_yaw *= kk
		modifier.aim_pitch *= kk
		modifier.lean_roll *= kk
		modifier.lean_pitch *= kk
		modifier.stabilize_w = kk
		if look:
			look.glance_weight *= kk
			look.want_weight *= kk
	else:
		modifier.stabilize_w = 1.0
	modifier.head_calm = move_toward(modifier.head_calm, 0.8 if state == MotorState.Id.GET_UP else 0.0, delta * 3.0)
	_teeter_w = move_toward(_teeter_w, 1.0 if teeter > 0.05 else 0.0, delta * (6.0 if teeter > 0.05 else 3.0))
	if tree.get("parameters/teeter/blend_amount") != null:
		tree.set("parameters/teeter/blend_amount", smoothstep(0.0, 1.0, _teeter_w))


func _drive_item(delta: float) -> void:
	if held_def != _held_roles_for or item_left != _item_left_for:
		_held_roles_for = held_def
		_item_left_for = item_left
		if held_def and not held_def.anim_roles.is_empty():
			_set_item_clips(held_def.anim_roles)
		elif modifier:
			modifier.item_hips_yaw = NAN
	var has_layer := held_def != null and not held_def.anim_roles.is_empty()
	var want := 0.0
	if has_layer:
		match item_action:
			UltraActionLayer.Action.EQUIPPING, UltraActionLayer.Action.READY, UltraActionLayer.Action.RELOADING, UltraActionLayer.Action.MELEE:
				want = 1.0
	if state in [MotorState.Id.ROOT_MOTION, MotorState.Id.SLIDE, MotorState.Id.CRAWL]:
		want = 0.0
	# Eased (springs, ~0.3 s): raising / lowering the weapon moves the arms, the stance and the
	# shouldered gun pose together - a linear ramp started and stopped them with a jolt.
	_item_w = _ease_w(&"item", want, delta)
	_pose_w = _ease_w(&"pose", item_ready_pose, delta)
	# Sprinting in the bladed (rifle) stance: the sprint clip carries the gun with its own arms -
	# the item's low-ready clip on sprinting legs twisted the chest and tipped the head over,
	# and first person (camera-placed gun) showed a different carry altogether.
	var gsp := Vector2(velocity.x, velocity.z).length()
	var carry := _stance_w > 0.5 and item_ready_pose < 0.5 and item_action == UltraActionLayer.Action.READY 		and gsp > SPRINT_CARRY_SPEED and state in [MotorState.Id.MOVE, MotorState.Id.IDLE]
	sprint_carry = _ease_w(&"carry", 1.0 if carry and _role_anim(&"e_sprint_f") else 0.0, delta)
	var cw := smoothstep(0.0, 1.0, sprint_carry)
	tree.set("parameters/upper/blend_amount", smoothstep(0.0, 1.0, _item_w) * (1.0 - cw))
	tree.set("parameters/upper_src/pose/blend_amount", _pose_w)
	tree.set("parameters/upper_src/carry/blend_amount", 0.0)
	tree.set("parameters/carry_arms/blend_amount", cw * smoothstep(0.0, 1.0, _item_w))
	tree.set("parameters/carry_arms_seek/seek_request", SPRINT_CARRY_T)
	tree.set("parameters/carry_arms_hold/scale", 0.0)
	tree.set("parameters/carry_chest/blend_amount", cw * smoothstep(0.0, 1.0, _item_w))
	tree.set("parameters/carry_chest_seek/seek_request", 0.0)
	tree.set("parameters/carry_chest_hold/scale", 0.0)
	if modifier:
		modifier.weapon_aim = _item_w * _pose_w * (1.0 - smoothstep(0.0, 1.0, swing_w))
		# A held item's static upper body on running legs: steady the torso against the swing
		# (a little less with a one-handed item: the pistol run looked frozen).
		# Unarmed, part of it too: the sprint clip rocks the shoulders and head side to side.
		var steady := lerpf(UNARMED_STEADY, 0.85 if _stance_w > 0.5 else ITEM_STEADY, smoothstep(0.0, 1.0, _item_w))
		modifier.torso_steady = steady * smoothstep(1.5, 4.0, gsp) if state in [MotorState.Id.MOVE, MotorState.Id.IDLE, MotorState.Id.CROUCH] else 0.0


func _set_item_clips(roles: Dictionary) -> void:
	var item := (tree.tree_root as AnimationNodeBlendTree).get_node("upper_src") as AnimationNodeBlendTree
	var pairs := {"low": "idle", "aim": "aim", "fire_clip": "fire", "reload_clip": "reload"}
	for node_name: String in pairs:
		var role := StringName(roles.get(pairs[node_name], ""))
		if role != &"":
			(item.get_node(node_name) as AnimationNodeAnimation).animation = _mirrored(_clip(role)) if item_left else _clip(role)
	if modifier:
		modifier.item_hips_yaw = _hips_yaw((item.get_node("aim") as AnimationNodeAnimation).animation)
		# The bladed stance stands on the item's own aiming legs.
		var gt := (tree.tree_root as AnimationNodeBlendTree).get_node("loco").get_node("ground") as AnimationNodeBlendTree
		if gt.has_node("idle_b_src"):
			(gt.get_node("idle_b_src") as AnimationNodeAnimation).animation = (item.get_node("aim") as AnimationNodeAnimation).animation


## Hips yaw a clip was made with (skeleton space), from its first Hips rotation key.
func _hips_yaw(clip: StringName) -> float:
	var a := player.get_animation(clip) if player.has_animation(clip) else null
	if a == null:
		return NAN
	for t in a.get_track_count():
		if a.track_get_type(t) == Animation.TYPE_ROTATION_3D and String(a.track_get_path(t).get_concatenated_subnames()) == "Hips":
			var q: Quaternion = a.rotation_track_interpolate(t, 0.0)
			var z := Basis(q).z
			return atan2(z.x, z.z)
	return NAN


# ---------------------------------------------------------------- hanging and ladders

var _hang_dir := 0.0
var _shimmy_speed := 0.3            ## m/s one shimmy cycle covers at rate 1
var _ladder_speed := 0.6            ## m/s one climb cycle covers at rate 1
const LADDER_HANDS_Y := 1.25        ## mean hand height above the feet origin while laddering


## Ledge hang: braced idle <-> left / right shimmy (BlendSpace1D on the shimmy direction), all
## shifted so the hands sit on the ledge edge (traversal.gd HANG_DROP / HANG_BACK).
func _build_hang(loco: AnimationNodeStateMachine) -> void:
	if not (_role_anim(&"shimmy_l") and _role_anim(&"shimmy_r") and _role_anim(&"hang_idle")):
		return
	var hands := Vector3(0.0, UltraTraversal.HANG_DROP + 0.03, UltraTraversal.HANG_BACK + 0.03)
	var bs := AnimationNodeBlendSpace1D.new()
	bs.min_space = -1.0
	bs.max_space = 1.0
	bs.sync = true
	var idle_src := _role_anim(&"hang_idle")
	var idle := AnimationNodeAnimation.new()
	# The catch's last frame, held. (Its last 0.05 s looped with the hold snapped the body 2 cm
	# back every 0.55 s: a jitter while hanging still.)
	idle.animation = _refit(_segment(_clip(&"hang_idle"), idle_src.length - 0.004, idle_src.length, 0.55), "hang", hands, Vector3.ONE)
	idle.use_custom_timeline = true
	idle.loop_mode = Animation.LOOP_LINEAR
	idle.timeline_length = 0.55
	bs.add_blend_point(idle, 0.0, -1, &"idle")
	for spec: Array in [[&"shimmy_l", -1.0], [&"shimmy_r", 1.0]]:   # Shimmy_L moves to the character's left
		var a := _anim(spec[0])
		a.animation = _refit(a.animation, "hang", hands, Vector3.ONE)
		bs.add_blend_point(a, spec[1], -1, StringName(spec[0]))
	var bt := AnimationNodeBlendTree.new()
	bt.add_node("side", bs, Vector2(0, 0))
	bt.add_node("rate", AnimationNodeTimeScale.new(), Vector2(200, 0))
	bt.connect_node("rate", 0, "side")
	bt.connect_node("output", 0, "rate")
	loco.replace_node("hang", bt)


## Ladder: the climb cycle shifted so the hands meet the ladder in front of the capsule.
func _build_ladder(loco: AnimationNodeStateMachine) -> void:
	var src := _role_anim(&"ladder_climb")
	if src == null or not String(anim_set.clip(&"ladder_climb")).contains("/"):
		return
	var a := _anim(&"ladder_climb")
	# Hands on the ladder plane (0.36 in front of the capsule), feet ~on the capsule's base.
	a.animation = _refit(a.animation, "ladder", Vector3(0, LADDER_HANDS_Y, 0.36), Vector3.ONE)
	_ladder_speed = anim_set.speed_of(&"ladder_climb", 0.65)
	var bt := AnimationNodeBlendTree.new()
	bt.add_node("clip", a, Vector2(0, 0))
	bt.add_node("rate", AnimationNodeTimeScale.new(), Vector2(200, 0))
	bt.connect_node("rate", 0, "clip")
	bt.connect_node("output", 0, "rate")
	loco.replace_node("ladder", bt)


## A copy of `clip` whose Hips position track is shifted so the hands' average position (model
## space, +Z forward, feet at the origin) lands on `hands` along the axes set in `axes`. A clip
## authored facing the other way (some Mixamo ladder / wall clips) is turned round first.
func _refit(clip: StringName, tag: String, hands: Vector3, axes: Vector3) -> StringName:
	var s := String(clip)
	var lib := s.get_slice("/", 0) if s.contains("/") else ""
	var clip_name := s.get_slice("/", 1) if s.contains("/") else s
	var l := player.get_animation_library(lib)
	if l == null or not l.has_animation(clip_name):
		return clip
	var rname := "%s_fit_%s" % [clip_name, tag]
	if not l.has_animation(rname):
		var a := l.get_animation(clip_name).duplicate(true) as Animation
		var hips_pos := -1
		var hips_rot := -1
		for t in a.get_track_count():
			if String(a.track_get_path(t).get_concatenated_subnames()) == "Hips":
				if a.track_get_type(t) == Animation.TYPE_POSITION_3D:
					hips_pos = t
				elif a.track_get_type(t) == Animation.TYPE_ROTATION_3D:
					hips_rot = t
		UltraPoseSampler.pose(a, skeleton, 0.0)
		var side := UltraPoseSampler.global_pose(skeleton, skeleton.find_bone("RightUpperLeg")).origin 			- UltraPoseSampler.global_pose(skeleton, skeleton.find_bone("LeftUpperLeg")).origin
		if Vector3.UP.cross(side).z < 0.0 and hips_rot >= 0:
			var turn := Quaternion(Vector3.UP, PI)
			for k in a.track_get_key_count(hips_rot):
				a.track_set_key_value(hips_rot, k, turn * (a.track_get_key_value(hips_rot, k) as Quaternion))
			if hips_pos >= 0:
				for k in a.track_get_key_count(hips_pos):
					a.track_set_key_value(hips_pos, k, turn * (a.track_get_key_value(hips_pos, k) as Vector3))
		var lh := skeleton.find_bone("LeftHand")
		var rh := skeleton.find_bone("RightHand")
		var mean := Vector3.ZERO
		var n := 12
		for k in n:
			UltraPoseSampler.pose(a, skeleton, a.length * k / n)
			mean += (UltraPoseSampler.global_pose(skeleton, lh).origin + UltraPoseSampler.global_pose(skeleton, rh).origin) * 0.5
		mean /= n
		var delta := (hands - mean) * axes / maxf(skeleton.motion_scale, 0.001)
		if hips_pos >= 0:
			for k in a.track_get_key_count(hips_pos):
				a.track_set_key_value(hips_pos, k, (a.track_get_key_value(hips_pos, k) as Vector3) + delta)
		l.add_animation(rname, a)
		for b in skeleton.get_bone_count():
			skeleton.reset_bone_pose(b)
	return StringName((lib + "/" if lib != "" else "") + rname)


## A forward segment of a clip (first frame held `hold` s), made once, kept in its library.
func _segment(clip: StringName, from: float, to: float, hold := 0.0) -> StringName:
	var s := String(clip)
	var lib := s.get_slice("/", 0) if s.contains("/") else ""
	var clip_name := s.get_slice("/", 1) if s.contains("/") else s
	var l := player.get_animation_library(lib)
	if l == null or not l.has_animation(clip_name):
		return clip
	var rname := "%s_seg_%d_%d_%d" % [clip_name, int(from * 100), int(to * 100), int(hold * 100)]
	if not l.has_animation(rname):
		l.add_animation(rname, UltraAnimMirror.segment(l.get_animation(clip_name), from, to, hold))
	return StringName((lib + "/" if lib != "" else "") + rname)


## A reversed segment of a clip, made once and kept in the same library.
func _reversed(clip: StringName, from: float, to: float) -> StringName:
	var s := String(clip)
	var lib := s.get_slice("/", 0) if s.contains("/") else ""
	var clip_name := s.get_slice("/", 1) if s.contains("/") else s
	var l := player.get_animation_library(lib)
	if l == null or not l.has_animation(clip_name):
		return clip
	var rname := "%s_rev_%d_%d" % [clip_name, int(from * 100), int(to * 100)]
	if not l.has_animation(rname):
		l.add_animation(rname, UltraAnimMirror.reversed_segment(l.get_animation(clip_name), from, to))
	return StringName((lib + "/" if lib != "" else "") + rname)


## A left/right mirrored copy of a clip, made once and kept in the same library.
## For an upper-body one-shot: a copy of `clip` whose Spine also carries `share` of the clip's
## hip lean. (Upper-body layers ride on the locomotion's hips: a clip that leans the whole body
## - Push leans the hips ~40 deg into the wall - would otherwise lift the arms overhead.)
func _upper_lean(clip: StringName, share: float) -> StringName:
	var s := String(clip)
	var lib := s.get_slice("/", 0) if s.contains("/") else ""
	var clip_name := s.get_slice("/", 1) if s.contains("/") else s
	var l := player.get_animation_library(lib)
	if l == null or not l.has_animation(clip_name):
		return clip
	var out := "%s_lean%d" % [clip_name, int(share * 100)]
	if not l.has_animation(out):
		var a := (l.get_animation(clip_name) as Animation).duplicate(true) as Animation
		var ht := _bone_track(a, "Hips", Animation.TYPE_ROTATION_3D)
		var st := _bone_track(a, "Spine", Animation.TYPE_ROTATION_3D)
		var hb := skeleton.find_bone("Hips")
		var sb := skeleton.find_bone("Spine")
		if st < 0 and ht >= 0 and sb >= 0:
			# (A spine at rest has no track - the import drops rest-constant ones.)
			st = a.add_track(Animation.TYPE_ROTATION_3D)
			a.track_set_path(st, NodePath(String(a.track_get_path(ht)).replace(":Hips", ":Spine")))
			var sr := skeleton.get_bone_rest(sb).basis.get_rotation_quaternion()
			for k in a.track_get_key_count(ht):
				a.rotation_track_insert_key(st, a.track_get_key_time(ht, k), sr)
		if ht >= 0 and st >= 0 and hb >= 0:
			var rest := skeleton.get_bone_rest(hb).basis.get_rotation_quaternion()
			for k in a.track_get_key_count(st):
				var hq: Quaternion = a.rotation_track_interpolate(ht, a.track_get_key_time(st, k))
				var lean := rest.slerp(hq, share)
				var sq: Quaternion = a.track_get_key_value(st, k)
				a.track_set_key_value(st, k, (rest.inverse() * lean * sq).normalized())
		l.add_animation(out, a)
	return StringName((lib + "/" if lib != "" else "") + out)


## The track animating `bone` (whatever the library spells the skeleton path as).
static func _bone_track(a: Animation, bone: String, type: int) -> int:
	for t in a.get_track_count():
		if a.track_get_type(t) == type and String(a.track_get_path(t).get_concatenated_subnames()) == bone:
			return t
	return -1


func _mirrored(clip: StringName) -> StringName:
	var s := String(clip)
	var lib := s.get_slice("/", 0) if s.contains("/") else ""
	var clip_name := s.get_slice("/", 1) if s.contains("/") else s
	var l := player.get_animation_library(lib)
	if l == null or not l.has_animation(clip_name):
		return clip
	var mname := clip_name + "_M"
	if not l.has_animation(mname):
		l.add_animation(mname, UltraAnimMirror.mirror(l.get_animation(clip_name)))
	return StringName((lib + "/" if lib != "" else "") + mname)


## Item events from the action layer (predicted locally, from snapshots remotely).
## Hit reaction on the upper body: a head snap or a body jolt.
func play_hit(head: bool) -> void:
	if tree == null:
		return
	var root := tree.tree_root as AnimationNodeBlendTree
	var src := root.get_node("hit_src") as AnimationNodeAnimation
	var want := _clip(&"hit_head" if head else &"hit_chest")
	if src.animation != want:
		src.animation = want
	tree.set("parameters/hit/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)


## A strike (swing `sw` from UltraActionLayer.melee_swing): its clip role's segment `seg`
## [from, to], played so the clip's `contact` time lands on the sim's `hit_from`; it fades out
## when the simulated swing is over (`time`) unless the next swing of a combo takes over.
## Swings without a clip (or whose role has no animation) play nothing.
func play_swing(sw: Dictionary) -> void:
	var role := StringName(sw.get("clip", &""))
	if tree == null or role == &"" or _role_anim(role) == null or fp_gun:
		return
	var seg: Vector2 = sw.get("seg", Vector2(0.0, _role_anim(role).length))
	var contact := float(sw.get("contact", seg.x + float(sw.hit_from)))
	var rate := clampf((contact - seg.x) / maxf(float(sw.hit_from), 0.05), 0.4, 3.0)
	var clip := _segment(_clip(role), seg.x, seg.y)
	var root := tree.tree_root as AnimationNodeBlendTree
	var up := root.get_node("swing_src") as AnimationNodeAnimation
	var full := root.get_node("swing_full_src") as AnimationNodeAnimation
	var lean := _upper_lean(clip, 0.6)
	if up.animation != lean:
		up.animation = lean
	if full.animation != clip:
		full.animation = clip
	for k: String in ["swing_src", "swing_full_src"]:
		tree.set("parameters/%s_seek/seek_request" % k, 0.0)
		tree.set("parameters/%s_ts/scale" % k, rate)
	_swing_left = float(sw.time)
	_swing_len = (seg.y - seg.x) / rate
	if swing_w < 0.05:
		_stand_w = _swing_stand_target()        # (decided as it starts; eased after)
	inertial.trigger()


var _swing_left := 0.0
var _swing_len := 0.0
## First person with a camera-placed gun (EquipmentVisual): its strikes are procedural.
var fp_gun := false
## 0..1: how much a strike is showing (EquipmentVisual lets the procedural aim / gun pose go).
var swing_w := 0.0
var _stand_w := 0.0
var _swing_speed := 0.0
const SWING_IN := 0.07
const SWING_OUT := 0.28


## Full body when standing still or barely moving on the ground, upper body over a run.
func _swing_stand_target() -> float:
	if state not in [MotorState.Id.IDLE, MotorState.Id.MOVE, MotorState.Id.CROUCH]:
		return 0.0
	return 1.0 - smoothstep(0.5, 2.2, _swing_speed)


func _drive_swing(speed: float, delta: float) -> void:
	_swing_speed = speed
	var on := false
	if _swing_left > 0.0:
		_swing_left -= delta
		_swing_len -= delta
		on = _swing_len > SWING_OUT * 0.5
	swing_w = move_toward(swing_w, 1.0 if on else 0.0, delta / (SWING_IN if on else SWING_OUT))
	_stand_w = move_toward(_stand_w, _swing_stand_target(), delta * 3.0)
	var w := smoothstep(0.0, 1.0, swing_w)
	tree.set("parameters/swing/blend_amount", w)
	tree.set("parameters/swing_full/blend_amount", w * smoothstep(0.0, 1.0, _stand_w))


func item_event(kind: StringName, data := {}) -> void:
	match kind:
		&"melee":
			if held_def:
				play_swing(UltraActionLayer.melee_swing(held_def, int(data.get("combo", 0)) & 0x3F))
		&"melee_cancel":
			_swing_left = 0.0
		&"fire":
			tree.set("parameters/upper_src/fire/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
		&"reload":
			tree.set("parameters/upper_src/reload/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
		&"reload_cancel":
			tree.set("parameters/upper_src/reload/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FADE_OUT)
		&"throw":
			if tree.get("parameters/push/request") != null:
				tree.set("parameters/push/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
				_push_t = PUSH_HOLD


