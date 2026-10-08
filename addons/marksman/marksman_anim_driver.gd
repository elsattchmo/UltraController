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
		m.connect_node("output", 0, "arms")
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
		# Switches dead-blend (first in the stack, so on the clip pose).
		inertial = InertialBlendModifier.new()
		inertial.name = "MMInertial"
		inertial.blend_time = MM_BLEND
		sk.add_child(inertial)
		sk.move_child(inertial, 0)


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
			if a.length() > 0.3 and b.length() > 0.3:
				want *= clampf(a.normalized().dot(b.normalized()), 0.0, 1.0)
	limp_w = _ease_w(&"mm_limp", want, delta)
	tree.set(LOCO + "mm/limp/blend_amount", limp_w)


## The set's own arms over its matched clip (MarksmanMotionMatcher.ARMS: still / moving by speed), else none.
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
	var w := super._wanted()
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
