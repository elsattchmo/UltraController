class_name UltraLiteAnimDriver
extends UltraAnimDriver
## The small animation stack for NPCs (BodyProfile.Tier.LITE): one AnimationTree of ~15 nodes and
## FootIK, nothing else (no BodyDynamics / ArmClear / WeaponPose / HandIK / Look / inertial blend).
## It is a drop-in for UltraAnimDriver wherever the character, BodyFX and the ragdoll touch it
## (state fields, play_hit, root_jumped, item_event), but only knows the roles an enemy needs:
##
##   idle, walk_f, run_f, limp_f        ground blend: idle <-> walk <-> run, limp mixed over (by leg damage)
##   crawl, lie                         lying: the crawl cycle <-> a held pose (lie = frame 0 of its clip)
##   get_up, get_up_front               face up / face down stand-up, stretched to MovementProfile.get_up_time
##   hit_chest, hit_head                upper-body flinch one-shot
##   atk_*  (play_attack)               strike one-shot: whole body standing, arms and chest lying
##   emote_* (play_emote)               whole-body one-shot: scream, alert, stagger ...
##
## Roles that the AnimationSet lacks fall back to idle, so a partial set still builds. Rates follow
## the speed actually moved over each cycle's measured authored speed (AnimationSet.authored_speed).

const GROUND := "parameters/loco/ground/"
const CRAWLING := "parameters/loco/crawl/"
const HIT_HOLD := 0.7                        ## s of a hit clip before it fades out (they run ~2 s)
const WALK_TO_RUN := Vector2(1.25, 0.75)     ## walk -> run blend: from x * walk speed to y * run speed

## Presentation flags set by whoever drives the body (the zombie brain):
var lying_still := false                     ## flat on the ground, not crawling (dormant)

var _walk_ref := 0.8
var _run_ref := 3.0
var _limp_ref := 1.2
var _crawl_ref := 0.6
var _hit_t := 0.0
var _hit_flip := false
var _atk_left := 0.0
var _emote_left := 0.0
var _w_crawl := 0.0
var _w_move := 0.0
var _w_run := 0.0
var _w_limp := 0.0


func setup(p_player: AnimationPlayer, p_skeleton: Skeleton3D) -> void:
	player = p_player
	skeleton = p_skeleton
	if library and not player.has_animation_library(library_name):
		player.add_animation_library(library_name, library)
	for k: String in extra_libraries:
		if not player.has_animation_library(k):
			player.add_animation_library(k, extra_libraries[k])
	_walk_ref = anim_set.speed_of(&"walk_f", 0.8)
	_run_ref = anim_set.speed_of(&"run_f", 3.0)
	_limp_ref = anim_set.speed_of(&"limp_f", 1.2)
	_crawl_ref = anim_set.speed_of(&"crawl", 0.6)
	tree = AnimationTree.new()
	tree.name = "AnimationTree"
	player.get_parent().add_child(tree)
	tree.anim_player = tree.get_path_to(player)
	tree.root_node = player.root_node
	tree.deterministic = true
	tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE
	# (No Root bone on a Mixamo skeleton, and nothing here plays root motion: no root_motion_track.)
	tree.tree_root = _build_lite()
	tree.active = true
	_loco = tree.get(LOCO + "playback")
	foot_ik = FootIKModifier.new()
	foot_ik.name = "FootIK"
	skeleton.add_child(foot_ik)


## The role's clip as a looping node, idle when the role (or its clip) is missing.
func _loop(role: StringName) -> AnimationNodeAnimation:
	return _anim(role if _role_anim(role) != null else &"idle")


## A pose held still: the first `at` frame of the role's clip (a 40 ms loop of it).
func _hold(role: StringName, at := 0.0) -> AnimationNodeAnimation:
	var a := AnimationNodeAnimation.new()
	var r := role if _role_anim(role) != null else &"idle"
	a.animation = _clip(r)
	a.use_custom_timeline = true
	a.loop_mode = Animation.LOOP_LINEAR
	a.start_offset = at
	a.timeline_length = 0.04
	return a


func _once(role: StringName) -> AnimationNodeAnimation:
	var a := AnimationNodeAnimation.new()
	var r := role if _role_anim(role) != null else &"idle"
	a.animation = _clip(r)
	return a


## A clip node with its own TimeScale: `<name>` and `<name>_ts` in `bt`, output of the pair is `<name>_ts`.
func _scaled(bt: AnimationNodeBlendTree, key: String, node: AnimationNodeAnimation, at: Vector2) -> void:
	bt.add_node(key, node, at)
	bt.add_node(key + "_ts", AnimationNodeTimeScale.new(), at + Vector2(180, 0))
	bt.connect_node(key + "_ts", 0, key)


func _blend(bt: AnimationNodeBlendTree, key: String, a: String, b: String, at: Vector2) -> void:
	bt.add_node(key, AnimationNodeBlend2.new(), at)
	bt.connect_node(key, 0, a)
	bt.connect_node(key, 1, b)


func _build_lite() -> AnimationNodeBlendTree:
	var root := AnimationNodeBlendTree.new()
	var loco := AnimationNodeStateMachine.new()
	loco.state_machine_type = AnimationNodeStateMachine.STATE_MACHINE_TYPE_ROOT

	# --- ground: idle <-> walk <-> run, limp over the top
	var g := AnimationNodeBlendTree.new()
	g.add_node("idle", _anim(&"idle"), Vector2(0, 0))
	_scaled(g, "walk", _loop(&"walk_f"), Vector2(0, 120))
	_scaled(g, "run", _loop(&"run_f"), Vector2(0, 240))
	_scaled(g, "limp", _loop(&"limp_f"), Vector2(0, 360))
	_blend(g, "b_walk", "idle", "walk_ts", Vector2(420, 60))
	_blend(g, "b_run", "b_walk", "run_ts", Vector2(600, 120))
	_blend(g, "b_limp", "b_run", "limp_ts", Vector2(780, 180))
	g.connect_node("output", 0, "b_limp")
	loco.add_node("ground", g, Vector2(0, 0))

	# --- lying: the held pose <-> the crawl cycle (rate follows the speed)
	var c := AnimationNodeBlendTree.new()
	c.add_node("lie", _hold(&"lie"), Vector2(0, 0))
	_scaled(c, "crawl", _loop(&"crawl"), Vector2(0, 120))
	_blend(c, "mix", "lie", "crawl_ts", Vector2(420, 60))
	c.connect_node("output", 0, "mix")
	loco.add_node("crawl", c, Vector2(0, 150))

	# --- the pose the ragdoll fades into / out of (idle), and the two stand-ups
	loco.add_node("fall", _anim(&"idle"), Vector2(300, 0))
	for spec: Array in [["getup", &"get_up"], ["getup_front", &"get_up_front"]]:
		var gu := AnimationNodeBlendTree.new()
		gu.add_node("clip", _once(spec[1]), Vector2(0, 0))
		gu.add_node("speed", AnimationNodeTimeScale.new(), Vector2(200, 0))
		gu.connect_node("speed", 0, "clip")
		gu.connect_node("output", 0, "speed")
		loco.add_node(spec[0], gu, Vector2(300, 100 if spec[0] == "getup" else 200))

	var names := ["ground", "crawl", "fall", "getup", "getup_front"]
	for a_name: String in names:
		for b_name: String in names:
			if a_name == b_name:
				continue
			var t := AnimationNodeStateMachineTransition.new()
			t.xfade_time = 0.5 if (a_name == "crawl" or b_name == "crawl") else 0.25
			t.xfade_curve = _ease_curve()
			loco.add_transition(a_name, b_name, t)
	loco.add_transition("Start", "ground", AnimationNodeStateMachineTransition.new())
	root.add_node("loco", loco, Vector2(0, 0))

	# --- strike: whole body standing, arms and chest lying (filter switched when it fires)
	var atk := AnimationNodeOneShot.new()
	atk.fadein_time = 0.12
	atk.fadeout_time = 0.3
	atk.fadein_curve = _ease_curve()
	atk.fadeout_curve = _ease_curve()
	atk.filter_enabled = false
	for b in _strike_bones():
		atk.set_filter_path(NodePath("%GeneralSkeleton:" + b), true)
	root.add_node("atk", atk, Vector2(300, 0))
	root.add_node("atk_src", _once(&"idle"), Vector2(150, 300))
	root.add_node("atk_seek", AnimationNodeTimeSeek.new(), Vector2(250, 300))
	root.add_node("atk_ts", AnimationNodeTimeScale.new(), Vector2(350, 300))
	root.connect_node("atk_seek", 0, "atk_src")
	root.connect_node("atk_ts", 0, "atk_seek")
	root.connect_node("atk", 0, "loco")
	root.connect_node("atk", 1, "atk_ts")

	# --- emote (scream, alert, stagger): whole body, no filter
	var em := AnimationNodeOneShot.new()
	em.fadein_time = 0.2
	em.fadeout_time = 0.35
	em.fadein_curve = _ease_curve()
	em.fadeout_curve = _ease_curve()
	root.add_node("emote", em, Vector2(500, 0))
	root.add_node("emote_src", _once(&"idle"), Vector2(150, 420))
	root.add_node("emote_seek", AnimationNodeTimeSeek.new(), Vector2(250, 420))
	root.add_node("emote_ts", AnimationNodeTimeScale.new(), Vector2(350, 420))
	root.connect_node("emote_seek", 0, "emote_src")
	root.connect_node("emote_ts", 0, "emote_seek")
	root.connect_node("emote", 0, "atk")
	root.connect_node("emote", 1, "emote_ts")

	# --- flinch: upper body
	var hit := AnimationNodeOneShot.new()
	hit.fadein_time = 0.06
	hit.fadeout_time = 0.3
	hit.fadein_curve = _ease_curve()
	hit.fadeout_curve = _ease_curve()
	hit.filter_enabled = true
	for b in _upper_body_bones():
		hit.set_filter_path(NodePath("%GeneralSkeleton:" + b), true)
	root.add_node("hit", hit, Vector2(700, 0))
	root.add_node("hit_src", _once(&"hit_chest"), Vector2(150, 540))
	root.add_node("hit_ts", AnimationNodeTimeScale.new(), Vector2(350, 540))
	root.connect_node("hit_ts", 0, "hit_src")
	root.connect_node("hit", 0, "emote")
	root.connect_node("hit", 1, "hit_ts")
	root.connect_node("output", 0, "hit")
	return root


## Chest and arms: what strikes while the body lies down (the clip's spine would sit it up).
func _strike_bones() -> PackedStringArray:
	var out := _arm_bones()
	for b in ["UpperChest", "Chest"]:
		if skeleton.find_bone(b) >= 0:
			out.append(b)
	return out


# ------------------------------------------------------------------ per-frame drive

func _process(delta: float) -> void:
	if tree == null:
		return
	var sp := Vector2(velocity.x, velocity.z).length()
	_drive_state_lite()
	_drive_gait(sp, delta)
	if _hit_t > 0.0:
		_hit_t -= delta
		if _hit_t <= 0.0:
			tree.set("parameters/hit/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FADE_OUT)
	_atk_left = maxf(_atk_left - delta, 0.0)
	_emote_left = maxf(_emote_left - delta, 0.0)
	var Id := MotorState.Id
	var foot_w := 0.0
	if state in [Id.IDLE, Id.MOVE, Id.LAND, Id.TURN_IN_PLACE] and _cur_loco == "ground":
		foot_w = lerpf(1.0, 0.55, smoothstep(2.0, 5.0, sp))
	_foot_w = move_toward(_foot_w, foot_w, delta * (10.0 if foot_w < _foot_w else 4.0))
	if foot_ik:
		foot_ik.weight = _foot_w
		foot_ik.lock_weight = 0.0 if on_platform else 1.0


func _drive_state_lite() -> void:
	var Id := MotorState.Id
	var want := "ground"
	match state:
		Id.CRAWL:
			want = "crawl"
		Id.RAGDOLL, Id.DEAD:
			want = "fall"
		Id.JUMP, Id.FALL:
			# A brief ungrounded moment (a kerb, a step) is not a fall worth showing.
			want = "fall" if air_time >= 0.15 or _cur_loco == "fall" else _cur_loco
		Id.GET_UP:
			want = "crawl" if getup_crawl else ("getup_front" if getup_front else "getup")
	if want == "":
		want = "ground"
	if want.begins_with("getup") and _cur_loco != want:
		var clip_len := _clip_len(&"get_up" if want == "getup" else &"get_up_front", 3.0)
		tree.set(LOCO + want + "/speed/scale", clip_len / maxf(get_up_time, 0.5))
		_loco.start(want, true)
		_cur_loco = want
		return
	if want != _cur_loco:
		_loco.travel(want)
		_cur_loco = want


func _drive_gait(sp: float, delta: float) -> void:
	# ground: move weight, run mix, limp mix
	var moving := sp > 0.08
	_w_move = _ease_w(&"move", smoothstep(0.05, 0.35, sp) if moving else 0.0, delta)
	var run_t := smoothstep(_walk_ref * WALK_TO_RUN.x, _run_ref * WALK_TO_RUN.y, sp) if _run_ref > _walk_ref * 1.5 else 0.0
	_w_run = _ease_w(&"run", run_t, delta)
	_w_limp = _ease_w(&"limp", clampf(limp, 0.0, 1.0) * (1.0 - _w_run), delta)
	tree.set(GROUND + "b_walk/blend_amount", _w_move * (1.0 - _w_run))
	tree.set(GROUND + "b_run/blend_amount", _w_run * _w_move)
	tree.set(GROUND + "b_limp/blend_amount", _w_limp * _w_move)
	tree.set(GROUND + "walk_ts/scale", clampf(sp / maxf(_walk_ref, 0.05), 0.4, 3.0))
	tree.set(GROUND + "run_ts/scale", clampf(sp / maxf(_run_ref, 0.05), 0.5, 1.8))
	tree.set(GROUND + "limp_ts/scale", clampf(sp / maxf(_limp_ref, 0.05), 0.4, 2.5))
	# lying: crawl cycle follows the speed, the held pose when still
	var crawl_t := smoothstep(0.04, 0.2, sp) if (state == MotorState.Id.CRAWL or _cur_loco == "crawl") and not lying_still else 0.0
	_w_crawl = _ease_w(&"crawl", crawl_t, delta)
	tree.set(CRAWLING + "mix/blend_amount", _w_crawl)
	tree.set(CRAWLING + "crawl_ts/scale", clampf(sp / maxf(_crawl_ref, 0.05), 0.3, 2.5))


# ------------------------------------------------------------------ one-shots

## Hit reaction: the upper body flinches (not while lying: the standing clip would bend the body).
func play_hit(head: bool, _blocked := false) -> void:
	if tree == null or state in [MotorState.Id.CRAWL, MotorState.Id.RAGDOLL, MotorState.Id.DEAD, MotorState.Id.GET_UP]:
		return
	var role := &"hit_head" if head else &"hit_chest"
	if not head and _hit_flip and _role_anim(&"hit_chest2"):
		role = &"hit_chest2"
	_hit_flip = not _hit_flip
	if _role_anim(role) == null:
		return
	(tree.tree_root as AnimationNodeBlendTree).get_node("hit_src").set("animation", _clip(role))
	tree.set("parameters/hit_ts/scale", 1.5)
	tree.set("parameters/hit/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	_hit_t = HIT_HOLD


## A strike: clip `role`, its segment `seg` [from, to] played so the clip's `contact` time lands
## `hit_from` seconds in (the sim's own swing timing). Lying, only the arms and chest play it.
func play_attack(role: StringName, seg: Vector2, contact: float, hit_from: float, lying := false) -> void:
	var a := _role_anim(role)
	if tree == null or a == null:
		return
	if seg.y <= seg.x:
		seg = Vector2(0.0, a.length)
	var rate := clampf((contact - seg.x) / maxf(hit_from, 0.05), 0.4, 3.0)
	var root := tree.tree_root as AnimationNodeBlendTree
	(root.get_node("atk") as AnimationNodeOneShot).filter_enabled = lying
	root.get_node("atk_src").set("animation", _segment(_clip(role), seg.x, seg.y))
	tree.set("parameters/atk_seek/seek_request", 0.0)
	tree.set("parameters/atk_ts/scale", rate)
	tree.set("parameters/atk/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	_atk_left = (seg.y - seg.x) / rate


func stop_attack() -> void:
	if tree and _atk_left > 0.0:
		tree.set("parameters/atk/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FADE_OUT)
	_atk_left = 0.0


func attacking() -> bool:
	return _atk_left > 0.0


## A whole-body one-shot (scream, alert, stagger...) of the role's clip segment, `rate` x speed.
func play_emote(role: StringName, rate := 1.0, seg := Vector2.ZERO) -> float:
	var a := _role_anim(role)
	if tree == null or a == null:
		return 0.0
	if seg.y <= seg.x:
		seg = Vector2(0.0, a.length)
	var root := tree.tree_root as AnimationNodeBlendTree
	root.get_node("emote_src").set("animation", _segment(_clip(role), seg.x, seg.y))
	tree.set("parameters/emote_seek/seek_request", 0.0)
	tree.set("parameters/emote_ts/scale", rate)
	tree.set("parameters/emote/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	_emote_left = (seg.y - seg.x) / maxf(rate, 0.1)
	return _emote_left


func stop_emote() -> void:
	if tree and _emote_left > 0.0:
		tree.set("parameters/emote/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FADE_OUT)
	_emote_left = 0.0


func emoting() -> bool:
	return _emote_left > 0.0


## Strike clips come from the AI (play_attack): the dictionary form of UltraAnimDriver.play_swing.
func play_swing(sw: Dictionary) -> void:
	var seg: Vector2 = sw.get("seg", Vector2.ZERO)
	play_attack(StringName(sw.get("clip", &"")), seg, float(sw.get("contact", seg.x + float(sw.get("hit_from", 0.3)))), float(sw.get("hit_from", 0.3)), state == MotorState.Id.CRAWL)


## No held items, no scripted moves.
func item_event(_kind: StringName, _data := {}) -> void:
	pass


func root_jumped(_d: Vector3) -> void:
	pass
