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
		m.connect_node("output", 0, "rate")
		loco.add_node("mm", m, Vector2(0, 200))
		for n in loco.get_node_list():
			if n == &"mm" or n == &"Start" or n == &"End":
				continue
			for pair: Array in [[n, &"mm"], [&"mm", n]]:
				var t := AnimationNodeStateMachineTransition.new()
				t.xfade_time = XFADE
				t.xfade_curve = _ease_curve()
				loco.add_transition(pair[0], pair[1], t)
	return root


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
		# Switches dead-blend (first in the stack, so on the clip pose).
		inertial = InertialBlendModifier.new()
		inertial.name = "MMInertial"
		inertial.blend_time = MM_BLEND
		sk.add_child(inertial)
		sk.move_child(inertial, 0)


# ------------------------------------------------------------------ motion matching (spike)

## Seconds a matched switch dead-blends over.
const MM_BLEND := 0.25
var mm: MarksmanMotionMatcher
var mm_pass: MarksmanMMPass
## (`inertial`, UltraAnimDriver's member - unused under Sinew - is the matcher's dead blend.)
var _mm_clip := &""


func _mm_on() -> bool:
	var c := get_parent() as MarksmanCharacter
	return c != null and c.motion_matching


## Standing on the ground in a stance the matcher has clips for.
func mm_active() -> bool:
	return mm != null and mm.has_stance(MarksmanStance.of_item(held_def)) and state in MarksmanRagdoll.GROUND_STATES


func _wanted() -> String:
	var w := super._wanted()
	return "mm" if w == "ground" and mm_active() else w


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
	if mm.update(delta, MarksmanStance.of_item(held_def)) or mm.db.clips[mm.clip].name != _mm_clip:
		var c: Dictionary = mm.db.clips[mm.clip]
		var node := ((tree.tree_root as AnimationNodeBlendTree).get_node("loco") as AnimationNodeStateMachine).get_node("mm") as AnimationNodeBlendTree
		(node.get_node("clip") as AnimationNodeAnimation).animation = c.name
		_mm_clip = c.name
		tree.set(LOCO + "mm/seek/seek_request", mm.time)
		inertial.trigger(MM_BLEND)
	tree.set(LOCO + "mm/rate/scale", mm.rate)
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
	if mm:
		_drive_mm(delta)


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
