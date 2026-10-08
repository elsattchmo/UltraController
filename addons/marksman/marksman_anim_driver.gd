class_name MarksmanAnimDriver
extends SinewAnimDriver
## Marksman's animation driver: plays the referenced clips as they are (Sinew's way - no IK passes on the
## skeleton; procedural work happens on Sinew's pose), per stance. Moving on the ground or crouched, the gait
## walks the stance's reference cycles (MarksmanRagdoll); the tree supplies what the gait doesn't:
## - standing / crouched still: the stance's own idle (unarmed, rifle, pistol) - the clip feet the gait stands
##   on and the upper body;
## - prone: an 8-way crawl (forward / back clips, sideways the prone pivot clip in place), the rifle prone set
##   with a gun, the plain crawl without.

## Stance weights shown now (eased): rifle and pistol over unarmed.
var rifle_w := 0.0
var pistol_w := 0.0
## The rifle's aim clip over its idle (how far the gun is up, eased).
var aim_w := 0.0
var _stance := "unarmed"


func _build_sinew() -> AnimationNodeBlendTree:
	var root := super._build_sinew()
	var loco := root.get_node("loco") as AnimationNodeStateMachine
	# --- ground: the unarmed blend (Sinew's) with the armed stances' idles over it
	var g := loco.get_node("ground") as AnimationNodeBlendTree
	g.disconnect_node("output", 0)
	_stance_chain(g, "move_ts", &"r_idle", &"r_aim", &"p_idle", Vector2(450, 0))
	# --- crouched: the stance's crouch idle over the unarmed still / walk mix, as on the ground (the gait shows
	# the legs; moving, its upper body comes in by speed). Over "still" only, a start showed the unarmed crouch
	# walk's arms until the gait's upper body was in: the rifle dipped.
	var c := loco.get_node("crouch") as AnimationNodeBlendTree
	c.disconnect_node("output", 0)
	_stance_chain(c, "mix", &"rc_idle", &"rc_aim", &"pc_idle", Vector2(650, 60))
	# --- prone: 8 ways
	loco.replace_node("prone", _build_prone())
	# --- in the air: the legs reach down for the ground as it comes (Jump_Land's first frame: legs long, feet under the
	# hips) - the air clip has them tucked 40 cm up, so a touchdown came down on folded legs
	var air := loco.get_node("air") as AnimationNodeBlendTree
	air.disconnect_node("output", 0)
	air.add_node("ready_clip", _role_node(&"jump_land", false), Vector2(0, 160))
	air.add_node("ready_seek", AnimationNodeTimeSeek.new(), Vector2(200, 160))
	air.add_node("ready_ts", AnimationNodeTimeScale.new(), Vector2(400, 160))
	air.connect_node("ready_seek", 0, "ready_clip")
	air.connect_node("ready_ts", 0, "ready_seek")
	var ready := AnimationNodeBlend2.new()
	ready.filter_enabled = true
	for b in _leg_bones():
		ready.set_filter_path(NodePath("%" + String(skeleton.name) + ":" + b), true)
	air.add_node("ready", ready, Vector2(600, 60))
	air.connect_node("ready", 0, "clip_ts")
	air.connect_node("ready", 1, "ready_ts")
	air.connect_node("output", 0, "ready")
	# --- landing: as deep as the impact (Jump_Land squats 45 cm - for a hop, a little of it over the idle)
	var land := loco.get_node("land") as AnimationNodeBlendTree
	land.disconnect_node("output", 0)
	land.add_node("stand", _role_node(&"idle"), Vector2(0, 160))
	land.add_node("depth", AnimationNodeBlend2.new(), Vector2(450, 60))
	land.connect_node("depth", 0, "stand")
	land.connect_node("depth", 1, "clip_ts")
	land.connect_node("output", 0, "depth")
	_add_parity_nodes(loco)
	# --- motion matching (spike, MarksmanCharacter.motion_matching): one clip node the matcher re-points and seeks
	if _mm_on():
		var m := AnimationNodeBlendTree.new()
		# (Plain: each clip's own length and loop - a custom timeline kept the first clip's length and froze a shorter
		# clip on its last frame.)
		var clip_node := AnimationNodeAnimation.new()
		clip_node.animation = _clip(&"idle")
		m.add_node("clip", clip_node, Vector2(0, 0))
		m.add_node("seek", AnimationNodeTimeSeek.new(), Vector2(200, 0))
		m.add_node("rate", AnimationNodeTimeScale.new(), Vector2(400, 0))
		m.connect_node("seek", 0, "clip")
		m.connect_node("rate", 0, "seek")
		# (Arms laid over it for the sets that borrow another stance's legs: MarksmanMotionMatcher.ARMS.)
		var arms := AnimationNodeBlend2.new()
		arms.filter_enabled = true
		for b in _arm_bones():
			arms.set_filter_path(NodePath("%" + String(skeleton.name) + ":" + b), true)
		m.add_node("arms", arms, Vector2(600, 0))
		for an: String in ["arms_still", "arms_move"]:
			var a := AnimationNodeAnimation.new()        # (plain: each clip's own length and loop)
			a.animation = _clip(&"idle")
			m.add_node(an, a, Vector2(200, 160 if an == "arms_still" else 280))
		m.add_node("arms_mix", AnimationNodeBlend2.new(), Vector2(400, 200))
		m.connect_node("arms_mix", 0, "arms_still")
		m.connect_node("arms_mix", 1, "arms_move")
		# (The limp layer: a second matched clip, blended over by how hurt the worse leg is - _drive_limp.)
		var lc := AnimationNodeAnimation.new()
		lc.animation = _clip(&"idle")
		m.add_node("limp_clip", lc, Vector2(0, 400))
		m.add_node("limp_seek", AnimationNodeTimeSeek.new(), Vector2(200, 400))
		m.add_node("limp_rate", AnimationNodeTimeScale.new(), Vector2(400, 400))
		m.connect_node("limp_seek", 0, "limp_clip")
		m.connect_node("limp_rate", 0, "limp_seek")
		m.add_node("limp", AnimationNodeBlend2.new(), Vector2(500, 100))
		m.connect_node("limp", 0, "rate")
		m.connect_node("limp", 1, "limp_rate")
		m.connect_node("arms", 0, "limp")
		m.connect_node("arms", 1, "arms_mix")
		# (Per clip, natural arms over a clip that holds its hands up - MarksmanMotionMatcher.CLIP_ARMS - seeked in step.)
		var ca := AnimationNodeAnimation.new()
		ca.animation = _clip(&"idle")
		m.add_node("carms_clip", ca, Vector2(200, 520))
		m.add_node("carms_seek", AnimationNodeTimeSeek.new(), Vector2(400, 520))
		m.connect_node("carms_seek", 0, "carms_clip")
		var carms := AnimationNodeBlend2.new()
		carms.filter_enabled = true
		for b in _arm_bones():
			carms.set_filter_path(NodePath("%" + String(skeleton.name) + ":" + b), true)
		m.add_node("carms", carms, Vector2(800, 0))
		m.connect_node("carms", 0, "arms")
		m.connect_node("carms", 1, "carms_seek")
		# (Turning on the spot: the stance's turn clip, in place, seeked by how far the body has turned - _drive_mk_turn.)
		_mk_turn_setup()
		for k in 2:
			var tc := AnimationNodeAnimation.new()
			tc.animation = _clip(&"idle")
			m.add_node("turn_clip%d" % k, tc, Vector2(600, 600 + k * 120))
			m.add_node("turn_seek%d" % k, AnimationNodeTimeSeek.new(), Vector2(800, 600 + k * 120))
			m.connect_node("turn_seek%d" % k, 0, "turn_clip%d" % k)
		var tb := AnimationNodeBlend3.new()
		tb.filter_enabled = true
		for b in _leg_bones():
			tb.set_filter_path(NodePath("%" + String(skeleton.name) + ":" + b), true)
		tb.set_filter_path(NodePath("%" + String(skeleton.name) + ":Hips"), true)
		m.add_node("turn", tb, Vector2(1000, 0))
		m.connect_node("turn", 0, "turn_seek0")
		m.connect_node("turn", 1, "carms")
		m.connect_node("turn", 2, "turn_seek1")
		m.connect_node("output", 0, "turn")
		loco.add_node("mm", m, Vector2(0, 200))
		for n in loco.get_node_list():
			if n == &"mm" or n == &"Start" or n == &"End":
				continue
			for pair: Array in [[n, &"mm"], [&"mm", n]]:
				var t := AnimationNodeStateMachineTransition.new()
				t.xfade_time = XFADE
				t.xfade_curve = _ease_curve()
				loco.add_transition(pair[0], pair[1], t)
	# --- letting go of a rope: the arms come down off it slowly (the grip pose is overhead; at the plain cross-fade the
	# hands swept down 17 cm a frame) - after every node is in (the leap / fall nodes came later and got 0.2 s)
	for ti in loco.get_transition_count():
		if loco.get_transition_from(ti) == &"rope":
			loco.get_transition(ti).xfade_time = ROPE_LET_GO_XFADE
	# (Into and out of the drop to hang: always a cut - the capsule is already 2 m down at the end; a cross-fade from the
	# standing pose drew the body 2 m down and rising.)
	for ti in loco.get_transition_count():
		if loco.get_transition_from(ti) == &"drop_hang" or loco.get_transition_to(ti) == &"drop_hang":
			loco.get_transition(ti).xfade_time = 0.0
	return root


# ------------------------------------------------------------------ V7: the UltraController's other states

## The states the Sinew tree shows with one clip (or not at all), built as the UltraController builds them (its helpers
## are inherited): the running leap (`air_run`, seeked by the vertical speed), a plain fall, the heavy landing, the slide
## dropping in from Slide_Start, lowering over an edge (`drop_hang`, Standing Drop To Freehang fitted to our hang), the
## ledge hang's shimmy blend and the ladder refit (UltraAnimDriver._build_hang / _build_ladder), the dive.
func _add_parity_nodes(loco: AnimationNodeStateMachine) -> void:
	if _role_anim(&"leap"):
		var rj := AnimationNodeBlendTree.new()
		var rja := AnimationNodeAnimation.new()
		rja.animation = _segment(_clip(&"leap"), RUN_JUMP_SEG.x, RUN_JUMP_SEG.y)
		rj.add_node("clip", rja, Vector2(0, 0))
		rj.add_node("seek", AnimationNodeTimeSeek.new(), Vector2(200, 0))
		rj.add_node("hold", AnimationNodeTimeScale.new(), Vector2(400, 0))
		rj.connect_node("seek", 0, "clip")
		rj.connect_node("hold", 0, "seek")
		var arms := AnimationNodeBlend2.new()
		arms.filter_enabled = true
		for bn in _arm_bones():
			arms.set_filter_path(NodePath("%" + String(skeleton.name) + ":" + bn), true)
		rj.add_node("arms", arms, Vector2(600, 0))
		rj.add_node("arms_src", _anim(&"jump_air"), Vector2(400, 150))
		rj.connect_node("arms", 0, "hold")
		rj.connect_node("arms", 1, "arms_src")
		rj.connect_node("output", 0, "arms")
		_add_loco(loco, "air_run", rj)
	_add_loco(loco, "fall", _anim(&"jump_air"))
	if _role_anim(&"land_heavy"):
		_add_loco(loco, "land_heavy", _anim_from(&"land_heavy", 0.45))
	if _role_anim(&"slide_start"):
		var slide := AnimationNodeStateMachine.new()
		var ss := _anim(&"slide_start", false)
		ss.animation = _segment(ss.animation, 0.0, 0.40)       # (Slide_Start is a whole slide: only the drop into it)
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
		loco.replace_node("slide", slide)
	if _role_anim(&"drop_hang"):
		var dh := AnimationNodeBlendTree.new()
		var da := AnimationNodeAnimation.new()
		da.animation = _offset_hips(_segment(_clip(&"drop_hang"), DROP_SEG.x, DROP_SEG.y), DROP_CLIP_FIT)
		dh.add_node("clip", da, Vector2(0, 0))
		dh.add_node("seek", AnimationNodeTimeSeek.new(), Vector2(200, 0))
		dh.add_node("speed", AnimationNodeTimeScale.new(), Vector2(400, 0))
		dh.connect_node("seek", 0, "clip")
		dh.connect_node("speed", 0, "seek")
		dh.connect_node("output", 0, "speed")
		_add_loco(loco, "drop_hang", dh, 0.0, 0.0)
	_build_hang(loco)
	_build_ladder(loco)
	# Getting down to prone / back up to a crouch (Mixamo PR_FromCrouch / PR_ToCrouch, played over the motor's
	# PRONE_TRANSITION while the capsule's height eases) - the matcher / prone set cut straight from one to the other.
	for spec: Array in [["prone_down", &"prone_down"], ["prone_up", &"prone_up"]]:
		if _role_anim(spec[1]):
			var tb := AnimationNodeBlendTree.new()
			tb.add_node("clip", _anim(spec[1], false), Vector2(0, 0))
			tb.add_node("seek", AnimationNodeTimeSeek.new(), Vector2(200, 0))
			tb.add_node("speed", AnimationNodeTimeScale.new(), Vector2(400, 0))
			tb.connect_node("seek", 0, "clip")
			tb.connect_node("speed", 0, "seek")
			tb.connect_node("output", 0, "speed")
			_add_loco(loco, spec[0], tb, 0.15, 0.15)
	var dive := AnimationNodeBlendTree.new()
	dive.add_node("clip", _anim(&"swim_f"), Vector2(0, 0))
	dive.add_node("rate", AnimationNodeTimeScale.new(), Vector2(200, 0))
	dive.connect_node("rate", 0, "clip")
	dive.connect_node("output", 0, "rate")
	_add_loco(loco, "dive", dive)


## A loco node with cross-fades to and from every other one.
func _add_loco(loco: AnimationNodeStateMachine, n: String, node: AnimationNode, xfade_in := XFADE, xfade_out := XFADE) -> void:
	var others := loco.get_node_list()
	loco.add_node(n, node, Vector2(1200, 200 + 100 * others.size()))
	for o in others:
		if o == &"Start" or o == &"End":
			continue
		for pair: Array in [[o, StringName(n)], [StringName(n), o]]:
			var t := AnimationNodeStateMachineTransition.new()
			t.xfade_time = xfade_in if pair[1] == StringName(n) else xfade_out
			t.xfade_curve = _ease_curve()
			loco.add_transition(pair[0], pair[1], t)


## The motor states the Sinew mapping folds together, told apart as the UltraController does.
func _parity_wanted(w: String) -> String:
	var Id := MotorState.Id
	var hsp := Vector2(velocity.x, velocity.z).length()
	var has_leap := _role_anim(&"leap") != null
	match state:
		Id.JUMP:
			if _cur_loco != "air" and _cur_loco != "air_run":
				_run_jump = hsp > RUN_JUMP_SPEED and has_leap
				_jump_vy0 = 0.0
			return "air_run" if _run_jump else "air"
		Id.FALL:
			var hop := _cur_loco in ["ground", "mm"] and velocity.y > 1.0 and hsp > RUN_JUMP_SPEED and has_leap
			if hop:
				_run_jump = true
				_jump_vy0 = 0.0
				return "air_run"
			if _cur_loco == "rope":
				return w          # (Marksman's own air clip off a rope, legs reaching for the landing - the leap, seeked by the
				                  # vertical speed, swung the body 9 cm a frame letting go: gm rope test)
			if _cur_loco == "air_run" and air_time < 1.3:
				return "air_run"
			if w == "air" and _cur_loco != "air":
				return "fall"
			return w
		Id.LAND:
			return "land_heavy" if hard_landing and _role_anim(&"land_heavy") else w
		Id.MANTLE, Id.LEDGE_CLIMB:
			return "drop_hang" if trav_kind in UltraTraversal.DOWN_MOVES and _role_anim(&"drop_hang") else w
		Id.DIVE:
			return "dive"
	return _prone_transition(w)


## Down to prone from standing / crouched, and back up: the transition clip first (the UltraController's way).
func _prone_transition(w: String) -> String:
	var upright := ["ground", "crouch", "land", "mm"]
	if w == "prone" and _cur_loco in upright and _role_anim(&"prone_down"):
		_prone_trans = PRONE_TRANSITION_TIME
		tree.set(LOCO + "prone_down/seek/seek_request", 0.0)
		tree.set(LOCO + "prone_down/speed/scale", _clip_len(&"prone_down", 1.8) / PRONE_TRANSITION_TIME)
		return "prone_down"
	if _cur_loco == "prone" and w in upright and _role_anim(&"prone_up"):
		_prone_trans = PRONE_TRANSITION_TIME
		tree.set(LOCO + "prone_up/seek/seek_request", 0.0)
		tree.set(LOCO + "prone_up/speed/scale", _clip_len(&"prone_up", 1.8) / PRONE_TRANSITION_TIME)
		return "prone_up"
	if _cur_loco in ["prone_down", "prone_up"] and _prone_trans > 0.0 and (w == "prone" or w in upright):
		return _cur_loco               # (let it finish)
	return w


func _drive_parity(delta: float) -> void:
	if _cur_loco == "air_run":
		# Rising: take-off -> apex; falling: apex -> touchdown pose (held for a longer fall); the falling arms come in last.
		_jump_vy0 = maxf(_jump_vy0, velocity.y)
		var v0 := maxf(_jump_vy0, 3.0)
		var seg := RUN_JUMP_SEG.y - RUN_JUMP_SEG.x
		var apex := RUN_JUMP_APEX - RUN_JUMP_SEG.x
		var t := lerpf(0.02, apex, clampf(1.0 - velocity.y / v0, 0.0, 1.0)) if velocity.y > 0.0 \
			else lerpf(apex, seg - 0.02, clampf(-velocity.y / v0, 0.0, 1.0))
		tree.set(LOCO + "air_run/seek/seek_request", t)
		tree.set(LOCO + "air_run/hold/scale", 0.0)
		var down := smoothstep(apex + (seg - apex) * 0.55, seg - 0.02, t) if velocity.y < 0.0 else 0.0
		_leap_arms = move_toward(_leap_arms, down * LEAP_ARMS, delta * 1.5)
		tree.set(LOCO + "air_run/arms/blend_amount", smoothstep(0.0, 1.0, _leap_arms / LEAP_ARMS) * LEAP_ARMS)
	else:
		_leap_arms = 0.0
	if _cur_loco == "hang":
		_hang_dir = move_toward(_hang_dir, clampf(climb_speed / 0.5, -1.0, 1.0), delta * 5.0)
		tree.set(LOCO + "hang/side/blend_position", _hang_dir)
		tree.set(LOCO + "hang/rate/scale", 1.0 if absf(_hang_dir) < 0.05 else maxf(absf(climb_speed) / _shimmy_speed, 0.4))
	if _cur_loco == "ladder":
		tree.set(LOCO + "ladder/rate/scale", climb_speed / _ladder_speed)
	if _cur_loco == "dive":
		tree.set(LOCO + "dive/rate/scale", clampf(velocity.length() / 1.8, 0.3, 1.6))


# ------------------------------------------------------------------ V7: actions (Sinew's driver ignores item events)

## The held item's events as the UltraController plays them: a melee swing (UltraActionLayer.melee_swing: the item's clip
## segment timed to the sim's contact), its cancel, a prop thrown (the push one-shot: arms out from the chest). Fire and
## reload are MarksmanGunPass's (the gun in the hands, procedural).
func item_event(kind: StringName, data := {}) -> void:
	match kind:
		&"melee":
			if held_def and held_def.kind == ItemDefinition.Kind.FIREARM:
				_play_strike(UltraActionLayer.melee_swing(held_def, 0))
			elif held_def:
				play_swing(UltraActionLayer.melee_swing(held_def, int(data.get("combo", 0)) & 0x3F))
		&"melee_cancel":
			if _sw_left > 0.0:
				tree.set("parameters/swing/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FADE_OUT)
				_sw_left = 0.0
		&"throw":
			play_push(PUSH_OUT_AT)


## Weapon melee with a gun (Marksman's own - the UltraController's gun-butt was a procedural hook in first person and a
## clip the shouldered-gun pose fought in third): the strike clip, both views (the eye is the head's), named here - not
## an item role. [clip, segment start, end, contact] - contact = the hand's speed peak driving the blow in
## (tools/measure_melee.gd): a long gun's stock driven in with a step (Mixamo "Advancing And Punching With Butt Of A
## Rifle": right hand fastest 1.0-1.07 s, out at 1.3), a pistol whipped overhand ("Overhand Strike With Pistol": 0.87-
## 0.93 s). The segment is time-scaled so contact lands on the sim's hit_from; the gun rides the clip's gun hand and the
## support hand is put on our gun (MarksmanGunPass._strike_support).
const STRIKES := {
	"long": ["mixamo/M_RiflePunch", 0.15, 2.3, 1.03],
	"pistol": ["mixamo/M_PistolStrike", 0.25, 1.6, 0.9],
}
var striking := 0.0                    ## (> 0) seconds of the strike clip left to play


func _play_strike(sw: Dictionary) -> void:
	var long := held_def.two_handed or held_def.equip_slots & ItemDefinition.EquipSlot.BACK
	var spec: Array = STRIKES["long" if long else "pistol"]
	var clip := StringName(spec[0])
	if tree == null or not player.has_animation(clip):
		return
	var seg := Vector2(float(spec[1]), float(spec[2]))
	var rate := clampf((float(spec[3]) - seg.x) / maxf(float(sw.get("hit_from", 0.4)), 0.05), 0.5, 3.0)
	var one := (tree.tree_root as AnimationNodeBlendTree).get_node("swing") as AnimationNodeOneShot
	var moving := Vector2(velocity.x, velocity.z).length() > SWING_UPPER_FROM
	if moving and not one.filter_enabled:
		for b in _upper_body_bones():
			one.set_filter_path(NodePath("%" + String(skeleton.name) + ":" + b), true)
	one.filter_enabled = moving
	(tree.tree_root as AnimationNodeBlendTree).get_node("swing_src").set("animation", _segment(clip, seg.x, seg.y))
	tree.set("parameters/swing_seek/seek_request", 0.0)
	tree.set("parameters/swing_ts/scale", rate)
	tree.set("parameters/swing/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	_sw_left = (seg.y - seg.x) / rate
	striking = _sw_left


## A swing standing is the whole body's (GTA / RDR play standing attacks full-body); on the move only the upper body
## swings over the legs' own gait (a whole-body swing stopped the run dead) - the one-shot's filter, set as it fires.
const SWING_UPPER_FROM := 1.2


func play_swing(sw: Dictionary) -> void:
	var one := (tree.tree_root as AnimationNodeBlendTree).get_node("swing") as AnimationNodeOneShot if tree else null
	if one:
		var moving := Vector2(velocity.x, velocity.z).length() > SWING_UPPER_FROM
		if moving and not one.filter_enabled:
			for b in _upper_body_bones():
				one.set_filter_path(NodePath("%" + String(skeleton.name) + ":" + b), true)
		one.filter_enabled = moving
	super.play_swing(sw)


# ------------------------------------------------------------------ turning on the spot

## Turn clips per stance [left, right] (registered as roles at build): each weapon type its own - the RFP pack's for the
## rifle stance (rifle, shotgun), the Mixamo axe pack's for a one-handed melee weapon, the plain standing / crouching
## turns unarmed and for the pistol (the pistol pack has none; its arms are the gun pass's).
const MK_TURNS := {
	"unarmed": ["mixamo/T_StandL90", "mixamo/T_StandR90"],
	"unarmed_crouch": ["mixamo/T_CrouchB_L", "mixamo/T_CrouchB_R"],
	"rifle": ["mixamo/RFP_Turn90Left", "mixamo/RFP_Turn90Right"],
	"rifle_crouch": ["mixamo/RFP_CrouchingTurn90Left", "mixamo/RFP_CrouchingTurn90Right"],
	"pistol": ["mixamo/T_StandL90", "mixamo/T_StandR90"],
	"pistol_crouch": ["mixamo/T_CrouchB_L", "mixamo/T_CrouchB_R"],
	"melee": ["mixamo/AXE_StandingTurnLeft90", "mixamo/AXE_StandingTurnRight90"],
	# Limping (the limp layer most of the picture): the injured pack's turns, the hurt leg the left - mirrored for the
	# right (a mirrored left turn is a right turn).
	"limp_l": ["mixamo/INJ_InjuredTurnLeft", "mixamo/INJ_InjuredTurnRight"],
	"limp_r": ["mirror:mixamo/INJ_InjuredTurnRight", "mirror:mixamo/INJ_InjuredTurnLeft"],
}
## Turned this far from where the feet were left (rad) and a turn clip starts; below it the planted feet pivot.
const MK_TURN_START := 0.35
var _mk_turns := {}              ## key -> [left in-place clip, right in-place clip]
var _mk_feet_yaw := NAN
var _mk_turn_dir := 0            ## -1 left, 1 right, 0 none
var _mk_turn_from := 0.0
var _mk_turn_p := 0.0
var _mk_turn_key := ""
var _mk_still := 0.0
var _mk_last_yaw := NAN
## How much a turn clip has the legs (0 .. 1).
var turn_w := 0.0


## A turn is stepping the feet now (the matched pass's foot locks stand aside; as it fades out they hold the feet where
## the turn left them - fading to the idle's stance slid them 25 cm).
func turn_stepping() -> bool:
	return _mk_turn_dir != 0


func _mk_turn_setup() -> void:
	_mk_turns.clear()
	for key: String in MK_TURNS:
		var pair := []
		for k in 2:
			var role := StringName("mk_turn_%s_%d" % [key, k])
			var src := String(MK_TURNS[key][k])
			anim_set.roles[role] = _mirrored(StringName(src.trim_prefix("mirror:"))) if src.begins_with("mirror:") else StringName(src)
			pair.append(_turn_clip(role) if _role_anim(role) != null else &"")
		if pair[0] != &"" and pair[1] != &"":
			_mk_turns[key] = pair


func _mk_turn_key_now() -> String:
	var c := get_parent() as UltraCharacter
	var d := c.held_def() if c else null
	if limp_w > 0.4 and c.state.stance != MotorState.Stance.CROUCH:
		return "limp_l" if UltraInjury.leg_damage(c.state, true) >= UltraInjury.leg_damage(c.state, false) else "limp_r"
	if d and d.kind == ItemDefinition.Kind.MELEE and not d.two_handed and c.state.stance != MotorState.Stance.CROUCH:
		return "melee"
	return MarksmanMotionMatcher.key_for(c)


func _drive_mk_turn(delta: float) -> void:
	var c := get_parent() as UltraCharacter
	var st := c.state
	var yaw := st.body_yaw
	var sp := Vector2(st.vel.x, st.vel.z).length()
	var key := _mk_turn_key_now()
	var standing := sp < 0.25 and st.is_grounded() and _mk_turns.has(key)
	var rate := absf(angle_difference(_mk_last_yaw, yaw)) / maxf(delta, 1e-3) if not is_nan(_mk_last_yaw) else 0.0
	_mk_last_yaw = yaw
	if not standing or is_nan(_mk_feet_yaw):
		_mk_feet_yaw = yaw
		_mk_turn_dir = 0
	elif _mk_turn_dir == 0:
		var off := angle_difference(_mk_feet_yaw, yaw)           # (+ = turned left: yaw grows anticlockwise)
		if absf(off) > MK_TURN_START:
			_mk_turn_dir = -1 if off > 0.0 else 1
			_mk_turn_from = _mk_feet_yaw
			_mk_turn_key = key
			_mk_turn_p = 0.0
			_mk_still = 0.0
			var node := ((tree.tree_root as AnimationNodeBlendTree).get_node("loco") as AnimationNodeStateMachine).get_node("mm") as AnimationNodeBlendTree
			for k in 2:
				(node.get_node("turn_clip%d" % k) as AnimationNodeAnimation).animation = _mk_turns[key][k]
	if _mk_turn_dir != 0:
		var clip: StringName = _mk_turns[_mk_turn_key][0 if _mk_turn_dir < 0 else 1]
		var tab: PackedFloat32Array = _turn_tabs.get(clip, PackedFloat32Array())
		var total := tab[tab.size() - 1] if tab.size() > 1 else PI * 0.5
		var signed := angle_difference(_mk_turn_from, yaw) * (-1.0 if _mk_turn_dir > 0 else 1.0)    # (+ = along the turn)
		if signed < -0.15:
			# Turned back the other way past where the feet are: a new turn that way.
			inertial.trigger(MM_BLEND)
			_mk_feet_yaw = yaw
			_mk_turn_dir = 0
		else:
			_mk_still = _mk_still + delta if rate < 0.3 else 0.0
			var want := clampf(signed / total, 0.0, 1.0)
			if _mk_still > 0.12:
				want = 1.0                                  # (stopped: the clip plays on - the feet catch up)
			_mk_turn_p = maxf(_mk_turn_p, move_toward(_mk_turn_p, want, delta * (2.2 if _mk_still > 0.12 else 30.0)))
			if _mk_turn_p >= 0.999:
				# A whole step done: the feet are under the body again. Still turning, the next step starts at once (waiting
				# for MK_TURN_START again left the feet gliding round on the idle in between); stopped, the turn's over.
				if _mk_still > 0.12:
					_mk_feet_yaw = yaw
					_mk_turn_dir = 0
				else:
					_mk_feet_yaw = _mk_turn_from + total * (-1.0 if _mk_turn_dir > 0 else 1.0)
					_mk_turn_from = _mk_feet_yaw
					_mk_turn_p = 0.0
	var side_w := 1.0 if _mk_turn_dir != 0 else 0.0
	turn_w = move_toward(turn_w, side_w, delta * (8.0 if side_w > 0.0 else 3.5))
	var amt := smoothstep(0.0, 1.0, turn_w) * float(_mk_turn_dir if _mk_turn_dir != 0 else signf(tree.get(LOCO + "mm/turn/blend_amount")))
	tree.set(LOCO + "mm/turn/blend_amount", amt)
	if _mk_turn_dir != 0:
		var k := 0 if _mk_turn_dir < 0 else 1
		var clip2: StringName = _mk_turns[_mk_turn_key][k]
		tree.set(LOCO + "mm/turn_seek%d/seek_request" % k, _turn_time(clip2, _mk_turn_p))


## Getting up: the clip MarksmanRagdoll picked for how the body lies, only its rising segment, over the get-up time.
## MarksmanCharacter keeps the visual root's last rotation up to this process frame.
var hold_visual_until := -1
## Loco node changes dead-blend over this long (s).
const LOCO_BLEND := 0.25


func _go(want: String) -> void:
	# (Not out of the drop to hang: the visual root turns round to the wall as it ends - the clip has turned itself round
	# - so the cut is continuous in the world, and a blend of local poses across the turn swung the body 1.1 m.)
	# (Into / out of the matcher too: a running landing handed to it moved the hands 0.7 m in a frame.)
	# (Not off a rope or out of a slide either: the dead blend carries the old motion on, and fast legs fling out - the
	# rope's pumping legs 9 cm a frame, the slide's kick put a toe 0.44 m under the floor; their own cross-fades do it.)
	if want != _cur_loco and _cur_loco != "" and inertial and not _cur_loco in ["drop_hang", "rope", "slide"]:
		inertial.trigger(LOCO_BLEND)
	if _cur_loco == "drop_hang" and want != "drop_hang":
		# (The visual root turns round the frame after the motor does, the tree shows the new node the frame after that:
		# the drop's last pose was drawn turned round for a frame - the body spun 1.1 m. Hold the old turn till then.)
		hold_visual_until = Engine.get_process_frames() + 1
	super._go(want)
	if want == "drop_hang":
		tree.set(LOCO + "drop_hang/seek/seek_request", 0.0)
		tree.set(LOCO + "drop_hang/speed/scale", (DROP_SEG.y - DROP_SEG.x) / maxf(climb_duration, 0.2))
	if not want.begins_with("getup"):
		return
	var r := (get_parent() as UltraCharacter).ragdoll as MarksmanRagdoll if get_parent() is UltraCharacter else null
	var v: Dictionary = r.getup_variant if r else {}
	if v.is_empty():
		return
	var pn := String(v.clip)
	var full := StringName(pn if pn.contains("/") or library_name == &"" else "%s/%s" % [library_name, pn])
	if not player.has_animation(full):
		return
	var node := ((tree.tree_root as AnimationNodeBlendTree).get_node("loco") as AnimationNodeStateMachine).get_node(want) as AnimationNodeBlendTree
	(node.get_node("clip") as AnimationNodeAnimation).animation = full
	tree.set(LOCO + want + "/seek/seek_request", float(v.from))
	tree.set(LOCO + want + "/speed/scale", (float(v.to) - float(v.from)) / maxf(get_up_time, 0.2))


## Both legs: thighs down (not the hips).
func _leg_bones() -> PackedStringArray:
	var out := PackedStringArray()
	if skeleton == null:
		return out
	var roots := [skeleton.find_bone("LeftUpperLeg"), skeleton.find_bone("RightUpperLeg")]
	for b in skeleton.get_bone_count():
		var p := b
		while p >= 0:
			if p in roots:
				out.append(skeleton.get_bone_name(b))
				break
			p = skeleton.get_bone_parent(p)
	return out


## `src` -> Blend2 (rifle idle / aim, by how far the gun is up) -> Blend2 (pistol idle) -> output.
func _stance_chain(bt: AnimationNodeBlendTree, src: String, rifle_role: StringName, rifle_aim: StringName, pistol_role: StringName, at: Vector2) -> void:
	bt.add_node("rifle_idle", _role_node(rifle_role), at + Vector2(-200, 100))
	bt.add_node("rifle_aim", _role_node(rifle_aim if _role_anim(rifle_aim) else rifle_role), at + Vector2(-200, 200))
	bt.add_node("rifle_src", AnimationNodeBlend2.new(), at + Vector2(0, 140))
	bt.connect_node("rifle_src", 0, "rifle_idle")
	bt.connect_node("rifle_src", 1, "rifle_aim")
	bt.add_node("pistol_src", _role_node(pistol_role), at + Vector2(0, 260))
	bt.add_node("st_rifle", AnimationNodeBlend2.new(), at + Vector2(200, 0))
	bt.add_node("st_pistol", AnimationNodeBlend2.new(), at + Vector2(400, 0))
	bt.connect_node("st_rifle", 0, src)
	bt.connect_node("st_rifle", 1, "rifle_src")
	bt.connect_node("st_pistol", 0, "st_rifle")
	bt.connect_node("st_pistol", 1, "pistol_src")
	bt.connect_node("output", 0, "st_pistol")


## Prone: x = right, y = forward (1 = the crawl's own speed). Armed: the rifle prone set; unarmed: the crawl
## (backwards = the crawl reversed). Sideways = the prone pivot clip in place, looped (mirrored to the right).
func _build_prone() -> AnimationNodeBlendTree:
	var b := AnimationNodeBlendTree.new()
	var side_l := _prone_side_clip() if _role_anim(&"prone_turn_l") else _clip(&"crawl")
	var side_r := _mirrored(side_l)
	for spec: Array in [["armed", &"prone_idle", &"prone_fwd", &"prone_back"], ["bare", &"crawl", &"crawl", &"crawl"]]:
		var bs := AnimationNodeBlendSpace2D.new()
		bs.min_space = Vector2(-1.2, -1.2)
		bs.max_space = Vector2(1.2, 1.2)
		bs.sync = false
		if spec[0] == "bare":
			# (The crawl held for lying still; reversed for crawling backwards: fixed time scales.)
			bs.add_blend_point(_scaled(_role_node(&"crawl")), Vector2.ZERO, -1, &"still")
			_scales.append([LOCO + "prone/bare/%d/ts/scale" % (bs.get_blend_point_count() - 1), 0.0])
		else:
			bs.add_blend_point(_role_node(spec[1]), Vector2.ZERO, -1, &"still")
		bs.add_blend_point(_role_node(spec[2]), Vector2(0, 1), -1, &"fwd")
		if spec[0] == "bare":
			bs.add_blend_point(_scaled(_role_node(&"crawl")), Vector2(0, -1), -1, &"back")
			_scales.append([LOCO + "prone/bare/%d/ts/scale" % (bs.get_blend_point_count() - 1), -1.0])
		else:
			bs.add_blend_point(_role_node(spec[3]), Vector2(0, -1), -1, &"back")
		bs.add_blend_point(_clip_node(side_l), Vector2(-1, 0), -1, &"left")
		bs.add_blend_point(_clip_node(side_r), Vector2(1, 0), -1, &"right")
		b.add_node(spec[0], bs, Vector2(0, 0 if spec[0] == "armed" else 160))
	b.add_node("armed_mix", AnimationNodeBlend2.new(), Vector2(260, 60))
	b.connect_node("armed_mix", 0, "bare")
	b.connect_node("armed_mix", 1, "armed")
	b.add_node("rate", AnimationNodeTimeScale.new(), Vector2(460, 60))
	b.connect_node("rate", 0, "armed_mix")
	b.connect_node("output", 0, "rate")
	return b


func _scaled(node: AnimationNode) -> AnimationNodeBlendTree:
	var t := AnimationNodeBlendTree.new()
	t.add_node("clip", node, Vector2(0, 0))
	t.add_node("ts", AnimationNodeTimeScale.new(), Vector2(200, 0))
	t.connect_node("ts", 0, "clip")
	t.connect_node("output", 0, "ts")
	return t


## [tree parameter path, value]: fixed time scales set once the tree exists.
var _scales: Array = []


func _clip_node(clip: StringName) -> AnimationNodeAnimation:
	var a := AnimationNodeAnimation.new()
	a.animation = clip
	a.use_custom_timeline = true
	a.loop_mode = Animation.LOOP_LINEAR
	var anim := player.get_animation(clip) if player and player.has_animation(clip) else null
	if anim:
		a.timeline_length = anim.length
	return a


func setup(p: AnimationPlayer, sk: Skeleton3D) -> void:
	super.setup(p, sk)
	for e: Array in _scales:
		tree.set(e[0], e[1])
	if _mm_on():
		mm = MarksmanMotionMatcher.new(get_parent() as UltraCharacter, self)
		mm_limp = MarksmanMotionMatcher.new(get_parent() as UltraCharacter, self)
		mm_limp.follow = mm
	# Switches dead-blend (first in the stack, so on the clip pose): the matcher's clip changes and every loco node
	# change (Sinew starts the timed moves - climb up, get-ups, the roll - with a cut: hang -> climb up moved a hand 1 m
	# in a frame).
	inertial = MarksmanInertial.new()
	inertial.name = "MMInertial"
	inertial.blend_time = MM_BLEND
	sk.add_child(inertial)
	sk.move_child(inertial, 0)


## The capsule jumped (a scripted move waiting at its end - the drop to hang puts it 2 m down at once - the clip offset
## back): the dead blend's history moves with it, and the physics picture goes at once (Sinew powers down for the move a
## tick later and fades it out - drawn on the new root it showed the body 2 m down).
func root_jumped(d: Vector3) -> void:
	if inertial:
		inertial.shift(d)
	var r := (get_parent() as UltraCharacter).ragdoll as SinewRagdoll if get_parent() is UltraCharacter else null
	if r and r.modifier and not r.active:
		r.modifier.blend = 0.0
	# (And the matched pass goes at once: easing out on the new root its ground fit pulled the body down to the floor
	# below - a drop to hang began 2 m down and climbed back up.)
	if mm_pass:
		mm_pass.weight = 0.0
		_mix[&"mm_pass"] = Vector2.ZERO


# ------------------------------------------------------------------ motion matching (spike)

var _mm_arms_key := ""


## How badly the worse leg is hurt shows as a limp in stages: UltraInjury.leg_damage (0 at 85 % hp .. 1 at 25 % / crippled /
## gone) is the limp layer's weight - a graze favours the leg a little, a ruined one is the full limp. Standing only
## (crouched, the crouch carries it); the layer's matcher follows the walk's (its feet in step) and picks from the bad
## leg's set (limp_l / limp_r, mirrored). Fades with a direction the limp clips don't have (sideways).
func _drive_limp(key: String, delta: float) -> void:
	var c := get_parent() as UltraCharacter
	var dl := UltraInjury.leg_damage(c.state, true)
	var dr := UltraInjury.leg_damage(c.state, false)
	var want := maxf(dl, dr) if not key.ends_with("_crouch") else 0.0
	if want > 0.01 or limp_w > 0.01:
		var lkey := "limp_l" if dl >= dr else "limp_r"
		var switched := mm_limp.update(delta, lkey)
		if mm_limp.clip >= 0:
			var lc: Dictionary = mm_limp.db.clips[mm_limp.clip]
			if switched or lc.name != _limp_clip:
				var node := ((tree.tree_root as AnimationNodeBlendTree).get_node("loco") as AnimationNodeStateMachine).get_node("mm") as AnimationNodeBlendTree
				(node.get_node("limp_clip") as AnimationNodeAnimation).animation = lc.name
				_limp_clip = lc.name
				tree.set(LOCO + "mm/limp_seek/seek_request", mm_limp.time)
			tree.set(LOCO + "mm/limp_rate/scale", mm_limp.rate)
			# (Only as far as the limp clip goes the way the walk does: there are no sideways limps.)
			var a: Vector2 = mm.clip_velocity()
			var b: Vector2 = lc.vel
			if a.length() > 0.3:
				# (A limp clip standing still under a walk - the matcher's idle for a sideways query - is no limp: the
				# procedural limp in MarksmanMMPass shows it then.)
				want *= clampf(a.normalized().dot(b.normalized()), 0.0, 1.0) if b.length() > 0.3 else 0.0
	limp_w = _ease_w(&"mm_limp", want, delta)
	tree.set(LOCO + "mm/limp/blend_amount", limp_w)


## The set's own arms over its matched clip (MarksmanMotionMatcher.ARMS: still / moving by speed), else none.
## The playing clip's borrowed arms (MarksmanMotionMatcher.CLIP_ARMS): the source clip at the same point of the stride -
## both locked on their left footfall - so the arms swing against the legs as they would in the source.
func _drive_clip_arms(delta: float) -> void:
	var c: Dictionary = mm.db.clips[mm.clip]
	var on := c.has("arms")
	if on:
		if c.arms != _carms_clip:
			_carms_clip = c.arms
			var node := ((tree.tree_root as AnimationNodeBlendTree).get_node("loco") as AnimationNodeStateMachine).get_node("mm") as AnimationNodeBlendTree
			(node.get_node("carms_clip") as AnimationNodeAnimation).animation = c.arms
		var phase := (mm.time - float(c.left_down)) / maxf(float(c.length), 1e-3)
		var al: float = c.arms_length
		tree.set(LOCO + "mm/carms_seek/seek_request", fposmod(float(c.arms_left_down) + phase * al, al))
	tree.set(LOCO + "mm/carms/blend_amount", _ease_w(&"mm_carms", 1.0 if on else 0.0, delta))


var _carms_clip := &""


func _drive_mm_arms(key: String, delta: float) -> void:
	var arms: Array = MarksmanMotionMatcher.ARMS.get(key, [])
	if key != _mm_arms_key:
		_mm_arms_key = key
		if not arms.is_empty():
			var node := ((tree.tree_root as AnimationNodeBlendTree).get_node("loco") as AnimationNodeStateMachine).get_node("mm") as AnimationNodeBlendTree
			for k in 2:
				var pn := String(arms[k])
				var full := StringName(pn if pn.contains("/") or library_name == &"" else "%s/%s" % [library_name, pn])
				(node.get_node("arms_still" if k == 0 else "arms_move") as AnimationNodeAnimation).animation = full
	var on := 0.0 if arms.is_empty() else 1.0
	tree.set(LOCO + "mm/arms/blend_amount", _ease_w(&"mm_arms", on, delta))
	var sp := Vector2(velocity.x, velocity.z).length()
	tree.set(LOCO + "mm/arms_mix/blend_amount", _ease_w(&"mm_arms_move", smoothstep(0.15, 0.6, sp), delta))

## Seconds a matched switch dead-blends over.
const MM_BLEND := 0.25
var mm: MarksmanMotionMatcher
var mm_pass: MarksmanMMPass
## The limp layer's matcher (in step with `mm`) and how much of it shows (0..1, eased: the limp's stage).
var mm_limp: MarksmanMotionMatcher
var limp_w := 0.0
var _limp_clip := &""
## (`inertial`, UltraAnimDriver's member - unused under Sinew - is the matcher's dead blend.)
var _mm_clip := &""


func _mm_on() -> bool:
	var c := get_parent() as MarksmanCharacter
	return c != null and c.motion_matching


## On the ground, standing or crouched, in a stance and posture the matcher has clips for.
func mm_active() -> bool:
	var c := get_parent() as UltraCharacter
	return mm != null and c != null and mm.has_stance(MarksmanMotionMatcher.key_for(c)) \
			and (state in MarksmanRagdoll.GROUND_STATES or state == MotorState.Id.CROUCH)


func _wanted() -> String:
	var w := _parity_wanted(super._wanted())
	# (A landing on the move runs on: the matcher picks it up, no stop-and-squat clip under a running body.)
	var running_land := w == "land" and not hard_landing and Vector2(velocity.x, velocity.z).length() > LAND_RUN_ON
	return "mm" if (w == "ground" or w == "crouch" or running_land) and mm_active() else w


## Landing faster than this (m/s, along the ground) under motion matching keeps the matched locomotion.
const LAND_RUN_ON := 1.2


func _drive_mm(delta: float) -> void:
	if mm_pass == null:
		var c := get_parent() as UltraCharacter
		var r := c.ragdoll as SinewRagdoll if c else null
		if r and r.modifier:
			mm_pass = MarksmanMMPass.new(c, r, mm)
			r.modifier.passes.insert(0, mm_pass)
	var on := _cur_loco == "mm"
	if mm_pass:
		mm_pass.weight = _ease_w(&"mm_pass", 1.0 if on else 0.0, delta)
	if not on:
		return
	# Staggering (the balancer has the legs): the matched pose holds still as its target, like the gait's frozen pose
	# (the body stands still meanwhile, so the matcher jumped to the idle mid-recovery).
	var r := (get_parent() as UltraCharacter).ragdoll as SinewRagdoll
	if r and (r.staggering() or r._handback_t >= 0.0):
		tree.set(LOCO + "mm/rate/scale", 0.0)
		return
	var key := MarksmanMotionMatcher.key_for(get_parent() as UltraCharacter)
	_drive_mm_arms(key, delta)
	if mm.update(delta, key) or mm.db.clips[mm.clip].name != _mm_clip:
		var c: Dictionary = mm.db.clips[mm.clip]
		var node := ((tree.tree_root as AnimationNodeBlendTree).get_node("loco") as AnimationNodeStateMachine).get_node("mm") as AnimationNodeBlendTree
		(node.get_node("clip") as AnimationNodeAnimation).animation = c.name
		_mm_clip = c.name
		tree.set(LOCO + "mm/seek/seek_request", mm.time)
		inertial.trigger(MM_BLEND)
	tree.set(LOCO + "mm/rate/scale", mm.rate)
	_drive_mk_turn(delta)
	_drive_clip_arms(delta)
	_drive_limp(key, delta)
	if OS.get_environment("MM_DUMP") != "":
		var v := Vector2(velocity.x, velocity.z).length()
		print("MM t%d v %.2f %s t %.2f rate %.2f cost %.2f keep %.2f contact %d lock %s warp %.0f" % [Engine.get_physics_frames(), v,
				String(mm.db.clips[mm.clip].name).get_file(), mm.time, mm.rate, mm.last_cost, mm.last_keep, mm.db.contact[mm.frame],
				str(mm_pass.locked) if mm_pass else "-", rad_to_deg(mm_pass.warp) if mm_pass else 0.0])


# ------------------------------------------------------------------ per frame

func _process(delta: float) -> void:
	super._process(delta)
	if tree == null:
		return
	_stance = MarksmanStance.of_item(held_def)
	rifle_w = _ease_w(&"st_rifle", 1.0 if _stance == "rifle" else 0.0, delta)
	pistol_w = _ease_w(&"st_pistol", 1.0 if _stance == "pistol" else 0.0, delta)
	tree.set(GROUND + "st_rifle/blend_amount", rifle_w)
	tree.set(GROUND + "st_pistol/blend_amount", pistol_w)
	tree.set(LOCO + "crouch/st_rifle/blend_amount", rifle_w)
	tree.set(LOCO + "crouch/st_pistol/blend_amount", pistol_w)
	# (The rifle's aim clip while the gun is up - the gun pass then points it; the idle carried low for a sprint.)
	var up := held_def != null and (UltraActionLayer.is_up(item_action) or item_action == UltraActionLayer.Action.EQUIPPING)
	aim_w = _ease_w(&"st_aim", item_ready_pose if up else 0.0, delta)
	tree.set(GROUND + "rifle_src/blend_amount", aim_w)
	tree.set(LOCO + "crouch/rifle_src/blend_amount", aim_w)
	if _cur_loco == "prone":
		_mk_drive_prone(delta)
	_drive_air(delta)
	_drive_parity(delta)
	_prone_trans = maxf(_prone_trans - delta, 0.0)
	striking = maxf(striking - delta, 0.0)
	if mm:
		_drive_mm(delta)


## In the air the legs come down to meet the ground over the last 0.4 s before touchdown (the character's predicted
## landing); landing, the squat is as deep as the impact.
func _drive_air(delta: float) -> void:
	var want := 0.0
	if _cur_loco == "air":
		var c := get_parent() as MarksmanCharacter
		var l: Dictionary = c.landing if c else {}
		if not l.is_empty():
			want = 1.0 - smoothstep(LEGS_READY.x, LEGS_READY.y, float(l.time))
		tree.set(LOCO + "air/ready_seek/seek_request", 0.0)
		tree.set(LOCO + "air/ready_ts/scale", 0.0)
	legs_ready = _ease_w(&"air_ready", want, delta) if _cur_loco == "air" else 0.0
	tree.set(LOCO + "air/ready/blend_amount", legs_ready)
	if _cur_loco == "land":
		tree.set(LOCO + "land/depth/blend_amount", smoothstep(LAND_DEPTH.x, LAND_DEPTH.y, land_impact))


const ROPE_LET_GO_XFADE := 0.5
## Seconds before touchdown the legs are fully down .. start coming down.
const LEGS_READY := Vector2(0.08, 0.4)
## Landing speed (m/s) for no squat .. the clip's full squat.
const LAND_DEPTH := Vector2(2.0, 10.0)
## How far the legs are reaching for the ground now (0 tucked .. 1).
var legs_ready := 0.0


func _mk_drive_prone(delta: float) -> void:
	var local := velocity.rotated(Vector3.UP, -body_yaw)
	var sp := Vector2(local.x, local.z).length()
	var ref := _crawl_ref()
	var dir := Vector2(local.x, -local.z) / maxf(sp, 1e-3)
	var amount := clampf(sp / maxf(ref, 0.05), 0.0, 1.0)
	tree.set(LOCO + "prone/armed/blend_position", dir * amount)
	tree.set(LOCO + "prone/bare/blend_position", dir * amount)
	tree.set(LOCO + "prone/armed_mix/blend_amount", _ease_w(&"prone_armed", 0.0 if _stance == "unarmed" else 1.0, delta))
	tree.set(LOCO + "prone/rate/scale", clampf(sp / maxf(ref, 0.05), 0.6, 2.0) if sp > 0.05 else 1.0)


## The crawl clips' own speed (the plain Crawl is in place: its speed is the root-motion version's).
func _crawl_ref() -> float:
	var crm := anim_set.rm_curve(anim_set.rm_index(&"crawl_rm"))
	return crm.total().length() / crm.length if crm and crm.length > 0.0 else 0.75


## The held item's own upper-body clips only for items without a stance (melee, tools): a gun's stance
## shows its arms through the stance idles and the gait's cycles.
func _drive_item_layer(delta: float) -> void:
	if MarksmanStance.of_item(held_def) != "unarmed":
		item_w = _ease_w(&"item", 0.0, delta)
		tree.set("parameters/item/blend_amount", item_w)
		return
	super._drive_item_layer(delta)
