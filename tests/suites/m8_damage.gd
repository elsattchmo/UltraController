extends UltraTestSuite
## Per-limb damage, injuries, dismemberment, ragdoll. OFFLINE session (server code paths run);
## targets are server-spawned bots with full visuals.

const Id := MotorState.Id
const R := UltraLimbs.Region
const S := UltraLimbs.Status

var c: UltraCharacter


func before_each() -> void:
	load_playground()
	UltraNet.world_root = self
	UltraNet.spawn_transform = func(_p: NetPlayer) -> Transform3D: return marker("spawn").global_transform
	UltraNet.character_factory = func(_p: NetPlayer) -> UltraCharacter:
		var ch := UltraCharacter.new()
		ch.profile = (load("res://addons/ultra_controller/profiles/fps.tres") as MovementProfile).duplicate(true)
		ch.body_profile = load("res://assets/characters/mannequin/mannequin_body_profile.tres")
		return ch
	UltraNet.local_input_factory = func(_i: int) -> InputSource: return BotInputSource.new()
	UltraNet.start_offline(1)
	c = UltraNet.local_players[0].character
	(c.input_source as BotInputSource).body = c
	await ticks(3)


func after_each() -> void:
	for g in get_tree().get_nodes_in_group(&"ultra_gib"):
		g.queue_free()
	UltraNet.stop()
	UltraNet.character_factory = Callable()
	UltraNet.local_input_factory = Callable()
	UltraNet.spawn_transform = Callable()
	await super.after_each()


## Final (modified) bone pose: only valid while the skeleton is updating, so sample it there.
func final_pose(sk: Skeleton3D, bone: int) -> Transform3D:
	var out := [Transform3D()]
	var grab := func() -> void: out[0] = sk.get_bone_global_pose(bone)
	sk.skeleton_updated.connect(grab)
	await get_tree().process_frame
	await get_tree().process_frame
	sk.skeleton_updated.disconnect(grab)
	return out[0]


## A dummy standing at `pos` facing -Z (yaw 0).
func dummy(pos: Vector3, yaw := 0.0) -> UltraCharacter:
	var p := UltraNet.spawn_bot("Dummy", Transform3D(Basis(Vector3.UP, yaw), pos))
	(p.character.input_source as BotInputSource).set_steps([{"ticks": 100000}])
	return p.character


func hurt(t: UltraCharacter, region: int, amount: float, kind := &"bullet", dir := Vector3.FORWARD) -> void:
	var d := UltraCombat.DamageInfo.new()
	d.amount = amount
	d.region = region
	d.kind = kind
	d.dir = dir
	d.point = t.state.pos + Vector3.UP
	t.apply_damage(d)


func capsule_mid(t: UltraCharacter, region: int) -> Vector3:
	for cap in UltraHitboxes.capsules(t, t.state.pos):
		if cap.region == region:
			return ((cap.a as Vector3) + (cap.b as Vector3)) * 0.5
	return t.state.pos


func test_shots_hit_the_right_limb() -> void:
	var t := dummy(Vector3(0, 0.05, -40))
	c.teleport(Vector3(0, 0.05, -34), 0.0)          # 6 m in front, facing it (-Z)
	await ticks(10)
	var pistol := ItemDB.get_def(&"pistol")
	var eye := c.state.pos + Vector3.UP * 1.6
	check(capsule_mid(t, R.THIGH_L).x < t.state.pos.x and capsule_mid(t, R.ARM_R).x > t.state.pos.x,
		"hit capsules are on the right sides (facing -Z: left is -X)")
	var results := []
	for r: int in [R.TORSO, R.FOREARM_L, R.ARM_R, R.THIGH_L, R.SHIN_R, R.HEAD]:
		var before := t.state.limb_hp.duplicate()
		var aim := capsule_mid(t, r)
		var hit := UltraCombat.hitscan(c, eye, (aim - eye).normalized(), pistol)
		await ticks(2)
		var changed: Array[int] = []
		for k in UltraLimbs.COUNT:
			if t.state.limb_hp[k] != before[k]:
				changed.append(k)
		results.append("%s->%s" % [UltraLimbs.NAMES[r], ",".join(changed.map(func(k: int) -> String: return UltraLimbs.NAMES[k]))])
		check(hit.get("collider") == t and int(hit.get("region", -1)) == r and changed == [r], "a shot at the %s damages only the %s" % [UltraLimbs.NAMES[r], UltraLimbs.NAMES[r]])
		if t.state.state == Id.DEAD:
			break
	info(" ".join(results))
	# Between the legs: the shot passes the body by.
	t.respawn(t.global_transform)
	await ticks(5)
	var gap := t.state.pos + Vector3.UP * 0.35
	var miss := UltraCombat.hitscan(c, eye, (gap - eye).normalized(), pistol)
	check(miss.get("collider") != t and UltraLimbs.is_whole(t.state), "a shot between the legs misses the body")


func test_injured_leg_limps() -> void:
	var t := dummy(Vector3(-24, 0.05, -14))
	await ticks(5)
	t.state.limb_hp[R.THIGH_L] = 40                  # hurt (<= 50 %)
	var b := t.input_source as BotInputSource
	b.set_steps([{"ticks": 600, "move": Vector2(0, 0.55)}])
	var sk := t.skeleton
	var lf := sk.find_bone("LeftFoot")
	var rf := sk.find_bone("RightFoot")
	var stance := [0, 0]
	var top := 0.0
	await ticks(60)
	for i in 300:
		await ticks(1)
		top = maxf(top, hspeed(t))
		var ly := sk.get_bone_global_pose(lf).origin.y
		var ry := sk.get_bone_global_pose(rf).origin.y
		stance[0 if ly < ry else 1] += 1
	var asym := absf(stance[0] - stance[1]) / float(maxi(stance[0], stance[1]))
	info("stance ticks L %d / R %d (asymmetry %.0f %%), top speed %.2f" % [stance[0], stance[1], asym * 100.0, top])
	check(stance[0] < stance[1] and asym >= 0.25, "short stance on the hurt left leg (>= 25 % difference)")
	check(not UltraInjury.can_sprint(t.state) and top <= t.profile.jog_speed * t.damage_profile.injured_leg_speed + 0.1, "hurt leg: no sprint, speed capped")


func test_crippled_legs() -> void:
	var t := dummy(Vector3(-24, 0.05, -14))
	await ticks(5)
	t.state.limb_hp[R.SHIN_R] = 0
	var b := t.input_source as BotInputSource
	b.set_steps([{"ticks": 40, "move": Vector2(0, 1), "buttons": InputFrame.B_SPRINT}, {"ticks": 2, "move": Vector2(0, 1), "tap": InputFrame.B_JUMP}, {"ticks": 60, "move": Vector2(0, 1)}])
	var jumped := false
	var top := 0.0
	for i in 100:
		await ticks(1)
		jumped = jumped or t.state.state == Id.JUMP
		top = maxf(top, hspeed(t))
	check(not jumped, "a crippled leg can't jump")
	check(top <= t.profile.jog_speed * t.damage_profile.crippled_leg_speed + 0.1, "crippled leg: hobbling speed (%.2f)" % top)
	t.state.limb_hp[R.THIGH_L] = 0
	await ticks(40)
	check(t.state.stance == MotorState.Stance.CRAWL, "both legs crippled: crawling")


func test_crippled_arm_hangs_and_climb_blocked() -> void:
	var t := dummy(Vector3(-24, 0.05, -14))
	await ticks(5)
	t.state.limb_hp[R.ARM_L] = 0
	var b := t.input_source as BotInputSource
	b.set_steps([{"ticks": 120, "move": Vector2(0, 1)}, {"ticks": 60}])
	var sk := t.skeleton
	var ua := sk.find_bone("LeftUpperArm")
	var worst := 0.0
	await ticks(30)
	for i in 40:
		await ticks(3)
		var pose: Transform3D = await final_pose(sk, ua)
		var dir := (sk.global_transform.basis * pose.basis.y).normalized()
		worst = maxf(worst, rad_to_deg(dir.angle_to(Vector3.DOWN)))
	info("crippled arm: max angle from hanging %.0f deg" % worst)
	check(worst < 35.0, "the crippled arm hangs (swings within 35 deg of straight down)")
	check(not UltraInjury.can_climb(t.state), "no ledge / ladder climbing with a crippled arm")
	check(UltraInjury.weapon_hand(t.state) == 1, "right hand still holds a weapon")
	t.state.limb_hp[R.FOREARM_R] = 0
	check(UltraInjury.weapon_hand(t.state) == 0, "no working arm: no weapon")


func test_sever_each_region() -> void:
	var res := []
	for r: int in [R.ARM_L, R.FOREARM_R, R.THIGH_L, R.SHIN_R, R.HEAD]:
		var t := dummy(Vector3(-30 + r * 3.0, 0.05, -20))
		await ticks(8)
		hurt(t, r, 200.0, &"blade", Vector3.RIGHT)
		await ticks(6)
		var mask := UltraLimbs.sever_mask(r)
		var sk := t.skeleton
		var root := sk.find_bone(UltraLimbs.BONES[r][0])
		var fp: Transform3D = await final_pose(sk, root)
		var sc := fp.basis.get_scale().length()
		var cap := t.body_fx._caps.has(r)
		var gibs := get_tree().get_nodes_in_group(&"ultra_gib")
		res.append("%s:%s" % [UltraLimbs.NAMES[r], "cut" if (t.state.severed & mask) == mask else "-"])
		check((t.state.severed & mask) == mask, "%s: severed with what hangs off it" % UltraLimbs.NAMES[r])
		check(sc < 0.01 and cap, "%s: collapsed on the body with a cap (scale %.3f)" % [UltraLimbs.NAMES[r], sc])
		check(not gibs.is_empty(), "%s: flew off as a gib" % UltraLimbs.NAMES[r])
		if r == R.HEAD:
			check(t.state.state == Id.DEAD, "losing the head is fatal")
	await ticks(180)
	var still := 0
	for g: RigidBody3D in get_tree().get_nodes_in_group(&"ultra_gib"):
		if g.linear_velocity.length() < 0.15:
			still += 1
	info(" ".join(res) + "; gibs at rest after 3 s: %d" % still)
	check(still >= 4, "gibs settle within 3 s")


func test_gore_off_never_severs() -> void:
	var t := dummy(Vector3(-24, 0.05, -14))
	t.damage_profile = t.damage_profile.duplicate()
	t.damage_profile.gore = DamageProfile.Gore.OFF
	await ticks(5)
	hurt(t, R.ARM_R, 200.0, &"blade")
	await ticks(5)
	check(t.state.severed == 0 and UltraLimbs.status(t.state, R.ARM_R) == S.CRIPPLED, "gore off: crippled, not cut off")


func test_knockdown_ragdoll_and_get_up() -> void:
	var t := dummy(Vector3(-24, 0.05, -14))
	await ticks(10)
	t.knock_down(Vector3(0, 2.0, -5.0))
	var fastest := 0.0
	var settled_at := -1
	var trace: Array[String] = []
	var last := -1
	for i in 360:
		await ticks(1)
		if t.state.state != last:
			trace.append("%d:%s" % [i, Id.keys()[t.state.state]])
			last = t.state.state
		if t.ragdoll.active:
			fastest = maxf(fastest, t.ragdoll.max_speed())
			if settled_at < 0 and i > 20 and t.ragdoll.max_speed() < 0.25:
				settled_at = i
		if t.state.state == Id.IDLE and i > 30:
			break
	info("knockdown: %s; ragdoll settled at %.2f s, fastest bone %.1f m/s" % [" ".join(trace), settled_at / 60.0, fastest])
	check(trace.size() >= 3 and t.state.state == Id.IDLE, "knocked down, got up again")
	check(settled_at > 0 and settled_at < 180, "the ragdoll settles within 3 s")
	check(fastest < 30.0, "no bone faster than 30 m/s")
	check(not t.ragdoll.active and absf(t.state.height - t.profile.stand_height) < 0.05, "back on its feet")


func test_headshot_kills_and_ragdolls() -> void:
	var t := dummy(Vector3(0, 0.05, -40))
	c.teleport(Vector3(0, 0.05, -34), 0.0)
	await ticks(10)
	var eye := c.state.pos + Vector3.UP * 1.6
	var aim := capsule_mid(t, R.HEAD)
	UltraCombat.hitscan(c, eye, (aim - eye).normalized(), ItemDB.get_def(&"pistol"))
	await ticks(30)
	check(t.state.state == Id.DEAD and t.ragdoll.active, "a pistol headshot kills; the body ragdolls")


func test_crippled_right_arm_shoots_left_handed() -> void:
	c.teleport(Vector3(-24, 0.05, -14), 0.0)
	UltraItems.give(c, &"pistol")
	UltraItems.give(c, &"ammo_9mm", 12)
	var b := c.input_source as BotInputSource
	var eq := c.get_node("Equipment") as UltraEquipmentVisual
	b.set_steps([{"ticks": 100000, "slot": 1}])
	await ticks(60)
	var right_x := (c.visual_root.global_transform.affine_inverse() * eq.muzzle_transform().origin).x
	c.state.limb_hp[R.FOREARM_R] = 0
	await ticks(60)
	var in_left := eq.held_node != null and eq.held_node.get_parent() == eq.left_hand_attach
	var item := (c.anim.tree.tree_root as AnimationNodeBlendTree).get_node("upper_src") as AnimationNodeBlendTree
	var low := String((item.get_node("low") as AnimationNodeAnimation).animation)
	var muzzle_x := (c.visual_root.global_transform.affine_inverse() * eq.muzzle_transform().origin).x
	info("held in %s, idle clip %s, muzzle at x %.2f (right-handed %.2f)" % [eq.held_node.get_parent().name if eq.held_node else "-", low, muzzle_x, right_x])
	check(in_left and low.ends_with("_M"), "right arm out: the pistol is in the left hand, clips mirrored")
	check(right_x > 0.1 and absf(muzzle_x + right_x) < 0.06, "the gun sits where the right hand had it, mirrored")
	var mag0 := c.state.mag
	b.set_steps([{"ticks": 2, "slot": 1, "tap": InputFrame.B_PRIMARY}, {"ticks": 100000, "slot": 1}])
	await ticks(20)
	check(c.state.mag == mag0 - 1, "and it still fires (mag %d -> %d)" % [mag0, c.state.mag])


func test_left_handed_ads_aligns_sights() -> void:
	UltraItems.give(c, &"pistol")
	c.state.limb_hp[R.FOREARM_R] = 0
	var rig := UltraCameraRig.new()
	add_child(rig)
	rig.attach(c)
	(c.input_source as BotInputSource).set_steps([{"ticks": 40, "slot": 1, "pitch": 0.0}, {"ticks": 400, "slot": 1, "buttons": InputFrame.B_SECONDARY, "pitch": 0.0}])
	await ticks(110)
	await c.skeleton.skeleton_updated
	var eq := c.get_node("Equipment") as UltraEquipmentVisual
	var gun := eq.held_node
	var rear := gun.global_transform * UltraPoseSampler.marker(gun, "M_RearSight").origin
	var front := gun.global_transform * UltraPoseSampler.marker(gun, "M_FrontSight").origin
	var cam := rig.camera.global_transform
	var view := -cam.basis.z
	var a_rear := rad_to_deg(view.angle_to(rear - cam.origin))
	var a_front := rad_to_deg(view.angle_to(front - cam.origin))
	var sk := c.skeleton
	var sh := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("LeftUpperArm")).origin
	var goal: Transform3D = (c.anim.hand_ik.goals[0] as HandIKModifier.Goal).target
	info("left ADS: rear %.2f deg, front %.2f deg; shoulder->goal %.3f m; IK error %.4f m; goal rel cam %s" % [a_rear, a_front, sh.distance_to(goal.origin), c.anim.hand_ik.last_error[0], (cam.affine_inverse() * goal.origin).snappedf(0.01)])
	var lb := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("LeftHand"))
	var want := lb * eq.grip()
	info("gun vs lefthand*grip: pos %.4f m, rot %.2f deg; attach vs bone %.4f m; goal vs bone rot %.2f deg" % [gun.global_position.distance_to(want.origin), rad_to_deg(gun.global_basis.get_rotation_quaternion().angle_to(want.basis.get_rotation_quaternion())), eq.left_hand_attach.global_position.distance_to(lb.origin), rad_to_deg(goal.basis.get_rotation_quaternion().angle_to(lb.basis.get_rotation_quaternion()))])
	check(gun.get_parent() == eq.left_hand_attach and a_rear < 0.5 and a_front < 0.5, "left-handed: sights on the view ray")
	rig.queue_free()


## The region capsules follow the posed body (here a crouch), so a shot at the head you see
## is a headshot - not a hit on wherever the head is in the idle pose.
func test_hitboxes_follow_the_pose() -> void:
	var t := dummy(Vector3(0, 0.05, -40), PI)        # facing the shooter (from behind, a crouch hides the head)
	(t.input_source as BotInputSource).set_steps([{"ticks": 100000, "buttons": InputFrame.B_CROUCH}])
	c.teleport(Vector3(0, 0.05, -34), 0.0)
	await ticks(60)
	check(t.has_live_hitboxes(), "the posed skeleton feeds the hit capsules")
	var sk := t.skeleton
	var head_b := sk.find_bone("Head")
	var hp := sk.global_transform * await final_pose(sk, head_b)
	var head := hp * Vector3(0, 0.12 / hp.basis.y.length(), 0)       # the middle of the skull
	var cap_head := capsule_mid(t, R.HEAD)
	info("crouched: head bone y %.2f, head capsule y %.2f" % [head.y, cap_head.y])
	check(head.distance_to(cap_head) < 0.2, "the head capsule sits on the posed head (%.2f m)" % head.distance_to(cap_head))
	var eye := c.state.pos + Vector3.UP * 1.6
	var hit := UltraCombat.hitscan(c, eye, (head - eye).normalized(), ItemDB.get_def(&"pistol"))
	check(int(hit.get("region", -1)) == R.HEAD, "a shot at the crouched head is a headshot (got %s)" % UltraLimbs.NAMES[int(hit.get("region", 0))])


func _throw_box_at(t: UltraCharacter, mass: float, speed: float) -> RigidBody3D:
	var rb := RigidBody3D.new()
	rb.mass = mass
	rb.collision_layer = UltraLayers.WORLD_DYNAMIC
	rb.collision_mask = UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC | UltraLayers.CHARACTER
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3.ONE * 0.4
	cs.shape = box
	rb.add_child(cs)
	add_child(rb)
	rb.global_position = t.state.pos + Vector3(0, 1.3, 3.0)
	rb.gravity_scale = 0.0
	rb.linear_velocity = Vector3(0, 0, -speed)
	UltraGrab.mark_thrown(rb, c.net_id)
	return rb


## Thrown props are felt: a light one shoves and hurts a little, a heavy fast one knocks the
## target over.
func test_thrown_props_hit_players() -> void:
	var t := dummy(Vector3(-24, 0.05, -14))
	await ticks(10)
	var rb := _throw_box_at(t, 2.0, 7.0)          # 14 kg m/s
	var traces := []
	for i in 50:
		await ticks(1)
	traces.append("light: hp %.0f state %s vel %.2f" % [t.state.hp, Id.keys()[t.state.state], Vector2(t.state.vel.x, t.state.vel.z).length()])
	check(t.state.hp < 100.0 and t.state.state != Id.RAGDOLL, "a light throw hurts a little, no knock-down")
	rb.queue_free()
	t.respawn(t.global_transform)
	await ticks(10)
	rb = _throw_box_at(t, 12.0, 6.0)              # 72 kg m/s
	var downed := false
	for i in 60:
		await ticks(1)
		downed = downed or t.state.state == Id.RAGDOLL
	traces.append("heavy: hp %.0f downed %s" % [t.state.hp, downed])
	info("; ".join(traces))
	check(downed, "a heavy, fast throw knocks the target into a ragdoll")
	rb.queue_free()


## Getting up off the face (Mixamo get-up, played faster to fit): the head turns with the
## body but doesn't whip about against the chest.
func test_getup_head_is_steady() -> void:
	var t := dummy(Vector3(-24, 0.05, -14))
	await ticks(10)
	t.knock_down(Vector3(0, 2.0, -6.0))
	var sk := t.skeleton
	var chest := sk.find_bone("Chest")
	var head := sk.find_bone("Head")
	var rels: Array[Quaternion] = []
	var front := [false]
	var grab := func() -> void:
		if t.state.state == Id.GET_UP:
			front[0] = front[0] or t.anim.getup_front
			rels.append(sk.get_bone_global_pose(chest).basis.get_rotation_quaternion().inverse() * sk.get_bone_global_pose(head).basis.get_rotation_quaternion())
	sk.skeleton_updated.connect(grab)
	for i in 400:
		await ticks(1)
		if t.state.state == Id.IDLE and i > 30:
			break
	sk.skeleton_updated.disconnect(grab)
	var speeds: Array[float] = []
	for k in range(1, rels.size()):
		speeds.append(rad_to_deg(rels[k - 1].angle_to(rels[k])) * 60.0)
	speeds.sort()
	check(speeds.size() > 60, "got up (%d frames)" % speeds.size())
	if speeds.is_empty():
		return
	var p90 := speeds[speeds.size() * 9 / 10]
	info("face-down get-up %s: head vs chest p90 %.0f, max %.0f deg/s" % [front[0], p90, speeds[-1]])
	check(front[0], "landed face down -> the face-down get-up")
	check(p90 < 85.0 and speeds[-1] < 140.0, "the head doesn't whip about (p90 %.0f, max %.0f deg/s)" % [p90, speeds[-1]])
