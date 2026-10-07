class_name SinewAnimDriver
extends UltraAnimDriver
## A Sinew character's animation: the referenced clips (SinewAnimationSet) played as they are - NO IK
## and no procedural passes (no foot / hand IK, weapon pose, body dynamics, look, arm clearance,
## inertial blend). One small AnimationTree: a state machine over the motor states, a directional
## ground blend, an upper-body item layer and a few one-shots. Sinew does the rest: the gait (S6c)
## replaces the ground cycle, item holding (S6d) the upper-body layer.
##
## It stands in for UltraAnimDriver wherever the character, the equipment and BodyFX talk to it (the
## state fields the character writes each frame, play_hit / play_swing, item_event, root_jumped).
## `hand_ik` stays null (the equipment then leaves the hands to the clip); `prop_hand_ik` is an
## INACTIVE HandIKModifier (never processed, outside the skeleton) that SinewCharacter lends it while
## a physics prop is carried - that path of the equipment calls it unguarded.

const GROUND := "parameters/loco/ground/"
const XFADE := 0.2
const HIT_HOLD := 0.7

var _ref_walk := 0.8
var _ref_run := 4.8
var _ref_sprint := 7.1
var _hit_left := 0.0
var _sw_left := 0.0
var _item_clip_role := &""
var item_w := 0.0
var prop_hand_ik: HandIKModifier


func setup(p_player: AnimationPlayer, p_skeleton: Skeleton3D) -> void:
	player = p_player
	skeleton = p_skeleton
	if library and not player.has_animation_library(library_name):
		player.add_animation_library(library_name, library)
	for k: String in extra_libraries:
		if not player.has_animation_library(k):
			player.add_animation_library(k, extra_libraries[k])
	_ref_walk = anim_set.speed_of(&"walk_f", 0.8)
	_ref_run = anim_set.speed_of(&"jog_f", 4.8)
	_ref_sprint = anim_set.speed_of(&"sprint_f", 7.1)
	tree = AnimationTree.new()
	tree.name = "AnimationTree"
	player.get_parent().add_child(tree)
	tree.anim_player = tree.get_path_to(player)
	tree.root_node = player.root_node
	tree.deterministic = true
	tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE
	# The motor plays root motion from its baked curves: the tree only strips it from the pose.
	if skeleton.find_bone("Root") >= 0:
		tree.root_motion_track = NodePath("%" + String(skeleton.name) + ":Root")
	tree.tree_root = _build_sinew()
	tree.active = true
	_loco = tree.get(LOCO + "playback")
	# Inactive and outside the skeleton's stack: never processed (see the class notes).
	prop_hand_ik = HandIKModifier.new()
	prop_hand_ik.name = "PropHandIK_unused"
	prop_hand_ik.active = false
	add_child(prop_hand_ik)


## A role's clip as a node; a missing role plays idle.
func _role_node(role: StringName, loop := true) -> AnimationNodeAnimation:
	return _anim(role if _role_anim(role) != null else &"idle", loop)


func _with_rate(bt: AnimationNodeBlendTree, key: String, node: AnimationNode, at: Vector2) -> void:
	bt.add_node(key, node, at)
	bt.add_node(key + "_ts", AnimationNodeTimeScale.new(), at + Vector2(200, 0))
	bt.connect_node(key + "_ts", 0, key)


func _build_sinew() -> AnimationNodeBlendTree:
	var root := AnimationNodeBlendTree.new()
	var loco := AnimationNodeStateMachine.new()
	loco.state_machine_type = AnimationNodeStateMachine.STATE_MACHINE_TYPE_ROOT
	# --- ground: idle and the directional cycles (x = right, y = forward; 1 = walk, 2 = run, 3 = sprint)
	var g := AnimationNodeBlendTree.new()
	var bs := AnimationNodeBlendSpace2D.new()
	bs.min_space = Vector2(-1.5, -1.5)
	bs.max_space = Vector2(1.5, 3.2)
	bs.sync = false
	for p: Array in [[&"idle", Vector2.ZERO], [&"walk_f", Vector2(0, 1)], [&"walk_b", Vector2(0, -1)],
			[&"strafe_l", Vector2(-1, 0)], [&"strafe_r", Vector2(1, 0)], [&"jog_f", Vector2(0, 2)], [&"sprint_f", Vector2(0, 3)]]:
		bs.add_blend_point(_role_node(p[0]), p[1], -1, p[0])
	_with_rate(g, "move", bs, Vector2(0, 0))
	g.connect_node("output", 0, "move_ts")
	loco.add_node("ground", g, Vector2(0, 0))
	# --- crouched, prone, swimming: idle <-> moving by speed
	for spec: Array in [["crouch", &"crouch_idle", &"crouch_f"], ["prone", &"prone_idle", &"crawl"], ["swim", &"swim_idle", &"swim_f"]]:
		var b := AnimationNodeBlendTree.new()
		b.add_node("still", _role_node(spec[1]), Vector2(0, 0))
		_with_rate(b, "go", _role_node(spec[2]), Vector2(0, 120))
		b.add_node("mix", AnimationNodeBlend2.new(), Vector2(450, 60))
		b.connect_node("mix", 0, "still")
		b.connect_node("mix", 1, "go_ts")
		b.connect_node("output", 0, "mix")
		loco.add_node(spec[0], b, Vector2(200, 0))
	# --- single clips: in the air, landing, climbing, sliding, the pose the ragdoll covers
	for spec: Array in [["air", &"jump_air", true], ["land", &"jump_land", false], ["hang", &"ledge_hang", true],
			["ladder", &"ladder_climb", true], ["wall", &"wall_climb", true], ["rope", &"pipe_climb", true],
			["slide", &"slide", true], ["down", &"idle", true]]:
		var b := AnimationNodeBlendTree.new()
		_with_rate(b, "clip", _role_node(spec[1], spec[2]), Vector2(0, 0))
		b.connect_node("output", 0, "clip_ts")
		loco.add_node(spec[0], b, Vector2(400, 0))
	# --- one-shot moves stretched to their duration: mantle / vault / climb up, roll, get-ups
	for spec: Array in [["climb_up", &"climb_up_1m"], ["vault", &"run_jump"], ["rm", &"roll"],
			["getup", &"get_up"], ["getup_front", &"get_up_front"]]:
		var b := AnimationNodeBlendTree.new()
		b.add_node("clip", _role_node(spec[1], false), Vector2(0, 0))
		b.add_node("seek", AnimationNodeTimeSeek.new(), Vector2(200, 0))
		b.add_node("speed", AnimationNodeTimeScale.new(), Vector2(400, 0))
		b.connect_node("seek", 0, "clip")
		b.connect_node("speed", 0, "seek")
		b.connect_node("output", 0, "speed")
		loco.add_node(spec[0], b, Vector2(600, 0))
	var names: Array[StringName] = []
	for n in loco.get_node_list():
		if n != &"Start" and n != &"End":
			names.append(n)
	for a_name in names:
		for b_name in names:
			if a_name != b_name:
				var t := AnimationNodeStateMachineTransition.new()
				t.xfade_time = XFADE
				t.xfade_curve = _ease_curve()
				loco.add_transition(a_name, b_name, t)
	loco.add_transition("Start", "ground", AnimationNodeStateMachineTransition.new())
	root.add_node("loco", loco, Vector2(0, 0))
	# --- upper body: the held item's own idle / aim clip (spine and arms)
	var item := AnimationNodeBlend2.new()
	item.filter_enabled = true
	for b in _upper_body_bones():
		item.set_filter_path(NodePath("%" + String(skeleton.name) + ":" + b), true)
	root.add_node("item", item, Vector2(300, 0))
	root.add_node("item_src", _role_node(&"idle"), Vector2(150, 200))
	root.connect_node("item", 0, "loco")
	root.connect_node("item", 1, "item_src")
	# --- melee swing: whole body
	var sw := AnimationNodeOneShot.new()
	sw.fadein_time = 0.1
	sw.fadeout_time = 0.25
	root.add_node("swing", sw, Vector2(500, 0))
	root.add_node("swing_src", _role_node(&"idle", false), Vector2(150, 320))
	root.add_node("swing_seek", AnimationNodeTimeSeek.new(), Vector2(250, 320))
	root.add_node("swing_ts", AnimationNodeTimeScale.new(), Vector2(350, 320))
	root.connect_node("swing_seek", 0, "swing_src")
	root.connect_node("swing_ts", 0, "swing_seek")
	root.connect_node("swing", 0, "item")
	root.connect_node("swing", 1, "swing_ts")
	# --- flinch: upper body
	var hit := AnimationNodeOneShot.new()
	hit.fadein_time = 0.06
	hit.fadeout_time = 0.3
	hit.filter_enabled = true
	for b in _upper_body_bones():
		hit.set_filter_path(NodePath("%" + String(skeleton.name) + ":" + b), true)
	root.add_node("hit", hit, Vector2(700, 0))
	root.add_node("hit_src", _role_node(&"hit_chest", false), Vector2(150, 440))
	root.add_node("hit_ts", AnimationNodeTimeScale.new(), Vector2(350, 440))
	root.connect_node("hit_ts", 0, "hit_src")
	root.connect_node("hit", 0, "swing")
	root.connect_node("hit", 1, "hit_ts")
	root.connect_node("output", 0, "hit")
	return root


# ------------------------------------------------------------------ per frame

func _process(delta: float) -> void:
	if tree == null:
		return
	var sp := Vector2(velocity.x, velocity.z).length()
	var want := _wanted()
	if want != _cur_loco:
		_go(want)
	match _cur_loco:
		"ground":
			_drive_moves(sp)
		"crouch", "prone", "swim":
			var moving := smoothstep(0.05, 0.4, sp)
			tree.set(LOCO + _cur_loco + "/mix/blend_amount", _ease_w(StringName(_cur_loco), moving, delta))
			var ref := anim_set.speed_of({"crouch": &"crouch_f", "prone": &"crawl", "swim": &"swim_f"}[_cur_loco], 0.6)
			tree.set(LOCO + _cur_loco + "/go_ts/scale", clampf(sp / maxf(ref, 0.05), 0.4, 2.5))
		"ladder", "wall", "rope":
			tree.set(LOCO + _cur_loco + "/clip_ts/scale", clampf(absf(climb_speed) / 0.6, 0.0, 2.0) * (1.0 if climb_speed >= 0.0 else -1.0))
	_drive_item_layer(delta)
	if _hit_left > 0.0:
		_hit_left -= delta
		if _hit_left <= 0.0:
			tree.set("parameters/hit/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FADE_OUT)
	_sw_left = maxf(_sw_left - delta, 0.0)


func _wanted() -> String:
	var Id := MotorState.Id
	match state:
		Id.CROUCH:
			return "crouch"
		Id.CRAWL:
			return "prone"
		Id.SWIM, Id.DIVE:
			return "swim"
		Id.JUMP, Id.FALL:
			# A brief ungrounded moment (a kerb, a step) is not a fall worth showing.
			return "air" if air_time >= 0.15 or _cur_loco == "air" else _cur_loco
		Id.LAND:
			return "land" if hard_landing or land_impact > 0.5 else "ground"
		Id.LEDGE_HANG:
			return "hang"
		Id.LADDER:
			return "ladder"
		Id.WALL_CLIMB:
			return "wall"
		Id.ROPE:
			return "rope"
		Id.SLIDE:
			return "slide"
		Id.MANTLE, Id.LEDGE_CLIMB:
			return "climb_up"
		Id.VAULT:
			return "vault"
		Id.ROOT_MOTION:
			return "rm"
		Id.RAGDOLL, Id.DEAD:
			return "down"
		Id.GET_UP:
			return "prone" if getup_crawl else ("getup_front" if getup_front else "getup")
	return "ground"


func _go(want: String) -> void:
	var timed := {"climb_up": &"climb_up_1m", "vault": &"run_jump", "getup": &"get_up", "getup_front": &"get_up_front"}
	if want == "rm":
		# The motor's root-motion move: its own clip, at the motor's rate.
		var c := anim_set.rm_curve(rm_clip)
		var node := (tree.tree_root as AnimationNodeBlendTree).get_node("loco") as AnimationNodeStateMachine
		var b := node.get_node("rm") as AnimationNodeBlendTree
		if c:
			(b.get_node("clip") as AnimationNodeAnimation).animation = c.clip if String(c.clip).contains("/") or library_name == &"" else StringName("%s/%s" % [library_name, c.clip])
		tree.set(LOCO + "rm/speed/scale", c.rate if c else 1.0)
		tree.set(LOCO + "rm/seek/seek_request", 0.0)
	elif timed.has(want):
		var dur := get_up_time if want.begins_with("getup") else climb_duration
		tree.set(LOCO + want + "/speed/scale", _clip_len(timed[want], 1.0) / maxf(dur, 0.2))
		tree.set(LOCO + want + "/seek/seek_request", 0.0)
	if want == "down" or want.begins_with("getup") or want == "rm" or timed.has(want):
		_loco.start(want, true)
	else:
		_loco.travel(want)
	_cur_loco = want


## The directional ground blend: the body-relative velocity on the walk / run / sprint scale, the
## cycle's rate matching the speed actually moved.
func _drive_moves(sp: float) -> void:
	var local := velocity.rotated(Vector3.UP, -body_yaw)
	var fwd := -local.z
	var side := local.x
	var dir := Vector2(side, fwd)
	var r := 0.0                              # 0 idle .. 1 walk .. 2 run .. 3 sprint
	if sp < _ref_walk:
		r = sp / maxf(_ref_walk, 0.05)
	elif sp < _ref_run:
		r = 1.0 + (sp - _ref_walk) / maxf(_ref_run - _ref_walk, 0.05)
	else:
		r = 2.0 + (sp - _ref_run) / maxf(_ref_sprint - _ref_run, 0.05)
	var pos := Vector2.ZERO
	if sp > 0.05:
		var n := dir.normalized()
		# Only forward goes past a walk (there are no backward / sideways runs among the defaults).
		pos = Vector2(n.x * minf(r, 1.0), n.y * (r if n.y > 0.7 else minf(r, 1.0)))
	tree.set(GROUND + "move/blend_position", pos)
	var at_speed := sp
	if r > 1.0 and absf(dir.normalized().y) < 0.7:
		at_speed = _ref_walk
	tree.set(GROUND + "move_ts/scale", clampf(sp / maxf(_speed_at(r), 0.05), 0.5, 2.0) if sp > 0.05 and at_speed == sp else 1.0)


func _speed_at(r: float) -> float:
	if r <= 1.0:
		return _ref_walk
	if r <= 2.0:
		return lerpf(_ref_walk, _ref_run, r - 1.0)
	return lerpf(_ref_run, _ref_sprint, minf(r - 2.0, 1.0))


## The held item's idle / aim clip on the spine and arms (as authored: the hands hold whatever the
## clip holds - Sinew's item holding, S6d, takes over from here).
func _drive_item_layer(delta: float) -> void:
	var role := &""
	if held_def and not held_def.anim_roles.is_empty():
		var key := "aim" if aim_weight > 0.5 and item_ready_pose > 0.5 else "idle"
		role = StringName(held_def.anim_roles.get(key, held_def.anim_roles.get("idle", "")))
	var on := role != &"" and _role_anim(role) != null and _cur_loco in ["ground", "crouch", "air", "land"]
	if on and role != _item_clip_role:
		var src := (tree.tree_root as AnimationNodeBlendTree).get_node("item_src") as AnimationNodeAnimation
		src.animation = _clip(role)
		_item_clip_role = role
	item_w = _ease_w(&"item", 1.0 if on else 0.0, delta)
	tree.set("parameters/item/blend_amount", item_w)


# ------------------------------------------------------------------ one-shots

func play_hit(head: bool, _blocked := false) -> void:
	if tree == null or state in [MotorState.Id.CRAWL, MotorState.Id.RAGDOLL, MotorState.Id.DEAD, MotorState.Id.GET_UP]:
		return
	var role := &"hit_head" if head else &"hit_chest"
	if _role_anim(role) == null:
		return
	(tree.tree_root as AnimationNodeBlendTree).get_node("hit_src").set("animation", _clip(role))
	tree.set("parameters/hit_ts/scale", 1.5)
	tree.set("parameters/hit/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	_hit_left = HIT_HOLD


## A melee swing: the swing's clip segment, timed so its contact lands on the sim's hit_from.
func play_swing(sw: Dictionary) -> void:
	var role := StringName(sw.get("clip", &""))
	var a := _role_anim(role)
	if tree == null or a == null:
		return
	var seg: Vector2 = sw.get("seg", Vector2.ZERO)
	if seg.y <= seg.x:
		seg = Vector2(0.0, a.length)
	var hit_from := float(sw.get("hit_from", 0.3))
	var contact := float(sw.get("contact", seg.x + hit_from))
	var rate := clampf((contact - seg.x) / maxf(hit_from, 0.05), 0.4, 3.0)
	var root := tree.tree_root as AnimationNodeBlendTree
	root.get_node("swing_src").set("animation", _segment(_clip(role), seg.x, seg.y))
	tree.set("parameters/swing_seek/seek_request", 0.0)
	tree.set("parameters/swing_ts/scale", rate)
	tree.set("parameters/swing/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	_sw_left = (seg.y - seg.x) / rate


## A one-shot owns the upper body (Sinew's gait leaves it to the clip meanwhile).
func upper_busy() -> bool:
	return _hit_left > 0.0 or _sw_left > 0.0


func item_event(_kind: StringName, _data := {}) -> void:
	pass


func root_jumped(_d: Vector3) -> void:
	pass
