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

var tree: AnimationTree
var player: AnimationPlayer
var modifier: BodyDynamicsModifier
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
var _turn_blend := 0.0


func setup(p_player: AnimationPlayer, p_skeleton: Skeleton3D) -> void:
	player = p_player
	skeleton = p_skeleton
	if library and not player.has_animation_library(library_name):
		player.add_animation_library(library_name, library)
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
	modifier = BodyDynamicsModifier.new()
	modifier.name = "BodyDynamics"
	skeleton.add_child(modifier)


func _clip(role: StringName) -> StringName:
	var c := anim_set.clip(role)
	if library_name != &"" and c != &"":
		return StringName("%s/%s" % [library_name, c])
	return c


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
		Vector2(anim_set.speed_of(&"strafe_r", 0.85), 0),
		Vector2(0, -_back_speed),
		Vector2(-anim_set.speed_of(&"strafe_l", 0.69), 0),
	])


func _anim(role: StringName, loop := true) -> AnimationNodeAnimation:
	var a := AnimationNodeAnimation.new()
	a.animation = _clip(role)
	if loop:
		a.use_custom_timeline = true
		a.loop_mode = Animation.LOOP_LINEAR
		var lib_anim := library.get_animation(anim_set.clip(role)) if library and anim_set.clip(role) != &"" else null
		if lib_anim:
			a.timeline_length = lib_anim.length
			# Align every cycle so the left foot plants at phase 0 (keeps synced blends in step).
			a.start_offset = float(anim_set.plant_phase.get(String(anim_set.clip(role)), 0.0)) * lib_anim.length
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
	bs.add_blend_point(_anim(&"walk_f"), Vector2(0, _walk_speed), -1, &"walk")
	bs.add_blend_point(_anim(&"jog_f"), Vector2(0, anim_set.speed_of(&"jog_f", 4.7)), -1, &"jog")
	bs.add_blend_point(_anim(&"sprint_f"), Vector2(0, _sprint_speed), -1, &"sprint")
	bs.add_blend_point(_anim(&"walk_b"), Vector2(0, -_back_speed), -1, &"back")
	bs.add_blend_point(_anim(&"strafe_r"), _hull[1], -1, &"strafe_r")
	bs.add_blend_point(_anim(&"strafe_l"), _hull[3], -1, &"strafe_l")
	ground.add_node("move", bs, Vector2(0, 0))
	ground.add_node("rate", AnimationNodeTimeScale.new(), Vector2(200, 0))
	ground.connect_node("rate", 0, "move")
	var turn := AnimationNodeBlend3.new()
	ground.add_node("idle", _anim(&"idle"), Vector2(0, 200))
	ground.add_node("turn_l", _anim(&"turn_l90"), Vector2(0, 300))
	ground.add_node("turn_r", _anim(&"turn_r90"), Vector2(0, 400))
	ground.add_node("turn_rate", AnimationNodeTimeScale.new(), Vector2(400, 300))
	ground.add_node("turn", turn, Vector2(200, 300))
	ground.connect_node("turn", 0, "turn_l")
	ground.connect_node("turn", 1, "idle")
	ground.connect_node("turn", 2, "turn_r")
	ground.connect_node("turn_rate", 0, "turn")
	ground.add_node("mix", AnimationNodeBlend2.new(), Vector2(600, 100))
	ground.connect_node("mix", 0, "turn_rate")
	ground.connect_node("mix", 1, "rate")
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
		bt.connect_node("mix", 0, "idle_rate" if spec[0] == "crawl" else "idle")
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
	loco.add_node("fall", _anim(&"jump_air"), Vector2(400, 200))
	loco.add_node("land", _anim(&"jump_land", false), Vector2(600, 0))
	loco.add_node("land_heavy", _anim(&"land_heavy", false), Vector2(600, 200))

	# --- slide
	var slide := AnimationNodeStateMachine.new()
	slide.add_node("start", _anim(&"slide_start", false), Vector2(0, 0))
	slide.add_node("loop", _anim(&"slide"), Vector2(200, 0))
	var sl := AnimationNodeStateMachineTransition.new()
	sl.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_AT_END
	sl.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO
	sl.xfade_time = 0.1
	slide.add_transition("start", "loop", sl)
	var sl_in := AnimationNodeStateMachineTransition.new()
	sl_in.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO
	slide.add_transition("Start", "start", sl_in)
	loco.add_node("slide", slide, Vector2(800, 0))

	# --- root motion one-shots (clip swapped at runtime); two slots so back-to-back moves blend
	for n in ["rm_a", "rm_b"]:
		var a := AnimationNodeAnimation.new()
		a.animation = _clip(&"roll")
		loco.add_node(n, a, Vector2(800, 200))

	# Fully connected so travel() always crossfades directly.
	var names := ["ground", "crouch", "crawl", "air", "fall", "land", "land_heavy", "slide", "rm_a", "rm_b"]
	for a_name in names:
		for b_name in names:
			if a_name == b_name:
				continue
			var t := AnimationNodeStateMachineTransition.new()
			t.xfade_time = _xfade(a_name, b_name)
			t.xfade_curve = null
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
	root.add_node("upper_src", _anim(&"idle"), Vector2(150, 200))
	root.connect_node("upper", 0, "loco")
	root.connect_node("upper", 1, "upper_src")

	var hit := AnimationNodeOneShot.new()
	hit.fadein_time = 0.06
	hit.fadeout_time = 0.25
	hit.filter_enabled = true
	for b in _upper_body_bones():
		hit.set_filter_path(NodePath("%GeneralSkeleton:" + b), true)
	root.add_node("hit", hit, Vector2(500, 0))
	root.add_node("hit_src", _anim(&"hit_chest", false), Vector2(350, 200))
	root.connect_node("hit", 0, "upper")
	root.connect_node("hit", 1, "hit_src")
	root.connect_node("output", 0, "hit")
	return root


static func _xfade(a: String, b: String) -> float:
	if b.begins_with("land"):
		return 0.08
	if a.begins_with("land") or b == "air":
		return 0.12
	if b.begins_with("rm") or a.begins_with("rm"):
		return 0.15
	if b == "slide" or a == "slide":
		return 0.12
	return 0.22


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
	_drive_ground(local_v, speed, delta)
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
			want = "air"
		Id.FALL:
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
		return
	_cur_rm = -1
	if want == "land" and stance != MotorState.Stance.STAND:
		want = "crouch"
	if want != _cur_loco:
		if want in ["air", "land", "land_heavy"]:
			_loco.travel(want)
			# Restart one-shots even when re-entering the same node.
			if want != "air":
				_loco.start(want, true)
		else:
			_loco.travel(want)
		_cur_loco = want


func _drive_ground(local_v: Vector2, speed: float, delta: float) -> void:
	var moving := speed > 0.12
	# Orientation warping: past a brisk walk the forward/back cycle plays and the hips turn
	# toward the travel direction, instead of over-speeding a strafe clip.
	var theta := atan2(local_v.x, local_v.y) if moving else 0.0
	var backwards := absf(theta) > deg_to_rad(105.0)
	var warp_w := smoothstep(_walk_speed * 1.4, _walk_speed * 2.6, speed)
	var target_warp := 0.0
	var blend_dir := theta
	if moving:
		var base := PI if backwards else 0.0
		var rel := angle_difference(base, theta)
		var max_warp := deg_to_rad(65.0)
		target_warp = clampf(rel, -max_warp, max_warp) * warp_w
		blend_dir = theta - target_warp
	_warp = lerp_angle(_warp, target_warp, 1.0 - exp(-10.0 * delta))
	var bp := Vector2(sin(blend_dir), cos(blend_dir)) * speed
	var clamped := _clamp_to_hull(bp)
	var rate := 1.0
	if clamped.length() > 0.01:
		rate = clampf(speed / clamped.length(), 1.0, 1.8)
	tree.set(LOCO + "ground/move/blend_position", clamped)
	tree.set(LOCO + "ground/rate/scale", rate)
	var idle_w := 1.0 - smoothstep(0.05, 0.45, speed)
	tree.set(LOCO + "ground/mix/blend_amount", 1.0 - idle_w)
	# Turn in place: shuffle feet while the motor swings the body round.
	var want_turn := 0.0
	if turning and not moving:
		want_turn = -1.0 if angle_difference(body_yaw, aim_yaw) > 0.0 else 1.0
	_turn_blend = move_toward(_turn_blend, want_turn, delta * 6.0)
	tree.set(LOCO + "ground/turn/blend_amount", _turn_blend)
	tree.set(LOCO + "ground/turn_rate/scale", 1.8)
	# Crouch / crawl cycles: forward clip, warped toward travel direction, rate-matched.
	var crouch_rate := clampf(speed / _crouch_speed, 0.3, 2.2) * (-1.0 if backwards else 1.0)
	tree.set(LOCO + "crouch/rate/scale", crouch_rate)
	tree.set(LOCO + "crouch/mix/blend_amount", smoothstep(0.05, 0.3, speed))
	var crawl_rate := clampf(speed / _crawl_speed, 0.0, 2.0) * (-1.0 if backwards else 1.0)
	tree.set(LOCO + "crawl/rate/scale", crawl_rate)
	tree.set(LOCO + "crawl/idle_rate/scale", 0.0)
	tree.set(LOCO + "crawl/mix/blend_amount", 1.0)
	if state in [MotorState.Id.CROUCH, MotorState.Id.CRAWL] and moving:
		var rel2 := angle_difference(PI if backwards else 0.0, theta)
		_warp = lerp_angle(_warp, clampf(rel2, -1.2, 1.2), 1.0 - exp(-10.0 * delta))


func _clamp_to_hull(p: Vector2) -> Vector2:
	if Geometry2D.is_point_in_polygon(p, _hull):
		return p
	var best := p
	var best_d := INF
	var dir := p.normalized()
	for i in _hull.size():
		var a := _hull[i]
		var b := _hull[(i + 1) % _hull.size()]
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
	if state in [MotorState.Id.JUMP, MotorState.Id.FALL, MotorState.Id.ROOT_MOTION]:
		target = Vector2.ZERO
	var k := 60.0
	var c := 2.0 * sqrt(k) * 0.7
	_lean_vel += ((target - _lean) * k - _lean_vel * c) * delta
	_lean += _lean_vel * delta
	modifier.lean_roll = _lean.x
	modifier.lean_pitch = _lean.y
	modifier.warp_yaw = _warp
	modifier.aim_pitch = aim_pitch
	modifier.aim_yaw = angle_difference(body_yaw, aim_yaw) * -1.0
	if state == MotorState.Id.ROOT_MOTION:
		modifier.aim_yaw = 0.0
		modifier.aim_pitch *= 0.3


func play_hit(role: StringName) -> void:
	var src := (tree.tree_root as AnimationNodeBlendTree).get_node("hit_src") as AnimationNodeAnimation
	src.animation = _clip(role)
	tree.set("parameters/hit/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
