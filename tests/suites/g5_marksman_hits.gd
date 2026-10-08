extends UltraTestSuite
## Marksman stage V5: hits under the simulation policy. A struck chain goes physical for a moment (Sinew); with a gun up
## the hands come back onto it - the support hand within a second, a gun arm that was hit lets go of its aim and comes
## back - no part flies off, and the body flinches.


func _marksman(at: Vector3, mm := false) -> MarksmanCharacter:
	var c := MarksmanCharacter.new()
	c.motion_matching = mm
	c.profile = (load("res://addons/ultra_controller/profiles/fps.tres") as MovementProfile).duplicate(true)
	c.body_profile = CharacterModels.body_profile("mannequin")
	c.build_visuals = true
	var b := BotInputSource.new()
	b.name = "InputSource"
	c.add_child(b)
	c.input_source = b
	c.position = at
	add_child(c)
	b.body = c
	chars.append(c)
	return c


func _slot(c: MarksmanCharacter, item: StringName) -> int:
	UltraItems.give(c, item)
	for i in c.inventory.size():
		var it := c.inventory.get_slot(i)
		if it and it.def_id == item:
			return i + 1
	return 0


func _hit(c: UltraCharacter, region: int, amount: float, dir: Vector3) -> void:
	var d := UltraCombat.DamageInfo.new()
	d.amount = amount
	d.region = region
	d.kind = &"bullet"
	d.dir = dir
	d.point = c.state.pos + Vector3.UP * 1.3
	var limb_hp := c.state.limb_hp[region]
	c.apply_damage(d)
	# (The knock, not the injury: a crippled arm would put the gun in one hand - V6, suite g7.)
	c.state.limb_hp[region] = limb_hp
	c.react_to_hit(region, dir, amount, d.kind)        # (UltraEffects does it on every machine: not in a test scene)


## (Measures; the checks are in the tests below.) Frames after a hit: the support hand's offset from where it holds
## the gun (gun frame, vs before), the barrel's error to the aim, the fastest part.
func _after_hit(c: MarksmanCharacter, region: int, amount: float, frames: int) -> Dictionary:
	var eq := c.get_node("Equipment") as UltraEquipmentVisual
	var gp := (c.ragdoll as MarksmanRagdoll).gun_pass
	var r := c.ragdoll as MarksmanRagdoll
	var sk := c.skeleton
	var lh := sk.find_bone("LeftHand")
	var rel0 := [Vector3.INF]
	var out := {"support": [], "aim": [], "speed": 0.0}
	var grab := func() -> void:
		if eq.held_node == null:
			return
		var g := eq.held_node.global_transform
		var rel := g.affine_inverse() * (sk.global_transform * sk.get_bone_global_pose(lh).origin)
		if rel0[0] == Vector3.INF:
			rel0[0] = rel
		(out.support as Array).append(rel.distance_to(rel0[0]))
		var barrel := -g.basis.z.normalized()
		var to_aim := (gp.aim_point - (g * UltraPoseSampler.marker(eq.held_node, "M_Muzzle").origin)).normalized()
		(out.aim as Array).append(rad_to_deg(barrel.angle_to(to_aim)))
		out.speed = maxf(out.speed, r.max_speed())
		if OS.get_environment("G5_DBG") != "" and (out.aim as Array).size() % 5 == 1:
			var rh := gp._part("RightHand")
			var shown := sk.get_bone_global_pose(r.parts[rh].bone)
			print("G5 f%d hand off target %.1f cm, part_w %.2f / %.2f, aim %.1f deg, support %.1f cm, grip_w %.2f, post_off %.1f" % [(out.aim as Array).size(), shown.origin.distance_to(r.modifier.anim_pose[rh].origin) * 100.0,
					r.part_w[rh], r.part_w[gp._part("RightUpperArm")], (out.aim as Array).back(), (out.support as Array).back() * 100.0, gp.grip_w, gp.post_off * 100.0])
	sk.skeleton_updated.connect(grab)
	await ticks(2)
	_hit(c, region, amount, Vector3(1, 0, 0.3).normalized())
	await ticks(frames)
	sk.skeleton_updated.disconnect(grab)
	return out


func _first_under(a: Array, limit: float, from := 0) -> int:
	for i in range(from, a.size()):
		var ok := true
		for j in range(i, mini(i + 6, a.size())):
			if float(a[j]) > limit:
				ok = false
				break
		if ok:
			return i
	return -1


func _armed(item := &"rifle") -> MarksmanCharacter:
	var c := _marksman(marker("spawn").global_position + Vector3(-16, 0, -3), true)
	await ticks(40)
	var sl := _slot(c, item)
	bot(c).set_steps([{"ticks": 600, "slot": sl, "yaw": 0.0}])
	await ticks(110)
	return c


func _done(c: MarksmanCharacter) -> void:
	chars.erase(c)
	c.queue_free()
	await ticks(3)


## A round to the body with a rifle up: the chest flinches (physical), the arms ride on it and the gun rocks off the aim -
## back within 0.75 s; the support hand stays on the gun (it's brought back onto the gun as shown); nothing flies.
func test_body_hit_flinches_and_the_hands_hold() -> void:
	load_playground()
	var c: MarksmanCharacter = await _armed()
	var m: Dictionary = await _after_hit(c, UltraLimbs.Region.TORSO, 25.0, 90)
	var sup: Array = m.support
	var aim: Array = m.aim
	info("torso: gun off the aim up to %.1f deg, back < 2 at frame %d; support hand off the grip up to %.1f cm (< 2 at %d); fastest part %.1f m/s" % [
			aim.max(), _first_under(aim, 2.0, 3), (sup.max() as float) * 100.0, _first_under(sup, 0.02, 3), m.speed])
	check(aim.max() > 5.0, "the gun rocks with the body (%.1f deg)" % aim.max())
	var back := _first_under(aim, 2.0, 3)
	check(back >= 0 and back <= 45, "and is back on the aim within 0.75 s (frame %d)" % back)
	check(sup.max() < 0.1 and _first_under(sup, 0.02, 3) <= 60, "the support hand holds on (%.1f cm at most)" % ((sup.max() as float) * 100.0))
	check(m.speed < 25.0, "no part faster than 25 m/s (%.1f)" % m.speed)
	await _done(c)


## A round to an arm with a gun up: the gun arm's knocks the gun off its line (back within 0.5 s, the support hand
## going with it); the support arm's knocks that hand off the grip and it takes hold again; a hard one makes it let go.
func test_arm_hits_kick_and_the_hand_regrips() -> void:
	load_playground()
	var c: MarksmanCharacter = await _armed()
	var m: Dictionary = await _after_hit(c, UltraLimbs.Region.FOREARM_R, 25.0, 60)
	var aim: Array = m.aim
	info("gun forearm: gun kicked %.1f deg, back < 2 at frame %d; support hand off it up to %.1f cm; fastest part %.1f m/s" % [
			aim.max(), _first_under(aim, 2.0, 3), ((m.support as Array).max() as float) * 100.0, m.speed])
	check(aim.max() > 5.0 and _first_under(aim, 2.0, 3) <= 30, "the gun is knocked off its line and comes back (%.1f deg)" % aim.max())
	check((m.support as Array).max() < 0.03, "the support hand goes with the gun")
	await _done(c)
	c = await _armed()
	m = await _after_hit(c, UltraLimbs.Region.FOREARM_L, 25.0, 60)
	var sup: Array = m.support
	info("support forearm: hand knocked %.1f cm off the grip, back < 2 cm at frame %d; gun off the aim %.1f deg" % [
			(sup.max() as float) * 100.0, _first_under(sup, 0.02, 3), (m.aim as Array).max()])
	check(sup.max() > 0.04 and _first_under(sup, 0.02, 3) <= 60, "the support hand is knocked off the grip and takes it again within 1 s")
	check((m.aim as Array).max() < 2.0, "the gun hand keeps the aim")
	await _done(c)
	# A hard one: the hand lets go, then takes hold again.
	c = await _armed()
	var gp := (c.ragdoll as MarksmanRagdoll).gun_pass
	var low := [1.0]
	var probe := func() -> void: low[0] = minf(low[0], gp.grip_w)
	c.skeleton.skeleton_updated.connect(probe)
	m = await _after_hit(c, UltraLimbs.Region.FOREARM_L, 60.0, 75)
	c.skeleton.skeleton_updated.disconnect(probe)
	info("hard hit on the support forearm: hold down to %.2f, back to %.2f; hand off the grip up to %.1f cm, back < 2 cm at frame %d" % [
			low[0], gp.grip_w, ((m.support as Array).max() as float) * 100.0, _first_under(m.support, 0.02, 3)])
	check(low[0] < 0.2 and gp.grip_w > 0.99, "a hard hit makes the hand let go, and it takes hold again")
	await _done(c)
