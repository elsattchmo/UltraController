extends UltraTestSuite
## Sinew stage 2: a SinewCharacter's body is a Sinew (Box3D) body. Standing it follows the
## animation; knocked down it falls as muscled physics on Sinew's mirror of the level, settles,
## and hands back to the get-up clip - the UltraRagdoll's job, same interface.

const Id := MotorState.Id

## s2 checks the kinematic standing body; s3 (extends this) runs the same cases powered.
var powered := false


func _sinew(at: Vector3, model := "mannequin") -> SinewCharacter:
	var c := SinewCharacter.new()
	c.profile = (load("res://addons/ultra_controller/profiles/fps.tres") as MovementProfile).duplicate(true)
	c.body_profile = CharacterModels.body_profile(model)
	c.build_visuals = true
	var b := BotInputSource.new()
	b.name = "InputSource"
	c.add_child(b)
	c.input_source = b
	c.position = at
	add_child(c)
	b.body = c
	chars.append(c)
	if c.ragdoll is SinewRagdoll:
		(c.ragdoll as SinewRagdoll).powered = powered
	return c


func _head_y(c: SinewCharacter) -> float:
	var r := c.ragdoll as SinewRagdoll
	var head := r._part("Neck")
	return r.pose_now[head].origin.y if head >= 0 and not r.pose_now.is_empty() else NAN


func test_the_body_is_sinew_and_follows_the_animation() -> void:
	load_playground()
	var c := _sinew(marker("spawn").global_position)
	await ticks(20)
	if not check(c.ragdoll is SinewRagdoll, "the ragdoll is Sinew's (got %s)" % [c.ragdoll]):
		return
	var r := c.ragdoll as SinewRagdoll
	check(r.parts.size() == 19, "19 body parts from the mannequin's skeleton (%d)" % r.parts.size())
	check(c.skeleton.get_node_or_null("Ragdoll") == null, "the old PhysicalBoneSimulator3D is gone")
	var mods := []
	for n in c.skeleton.get_children():
		if n is SkeletonModifier3D:
			mods.append(String(n.name))
	check(mods.find("Sinew") >= 0 and mods.find("Sinew") < mods.find("Dismember"), "Sinew sits before Dismember (%s)" % [mods])
	# Standing: the parts ride the animated pose (the hips within a few cm of the skeleton's).
	var hips_bone: int = r.parts[0].bone
	var skel_hips := c.skeleton.global_transform * c.skeleton.get_bone_global_pose(hips_bone)
	check(r.pose_now[0].origin.distance_to(skel_hips.origin) < 0.08, "the physics hips track the animated hips (%.3f m)" % r.pose_now[0].origin.distance_to(skel_hips.origin))
	if not powered:
		check(not r.active and r.modifier.blend == 0.0, "standing, the animation shows")


func test_knocked_down_falls_on_the_level_and_gets_up() -> void:
	load_playground()
	var c := _sinew(marker("spawn").global_position)
	await ticks(15)
	var r := c.ragdoll as SinewRagdoll
	var floor_y := c.state.pos.y
	c.knock_down(Vector3(0, 2.0, -5.0))
	var trace: Array[String] = []
	var last := -1
	var settled_at := -1
	var lowest := INF
	var worst_gap := 0.0
	for i in 420:
		await ticks(1)
		if c.state.state != last:
			trace.append("%d:%s" % [i, Id.keys()[c.state.state]])
			last = c.state.state
		if r.active and not r._getting_up:
			for p in r.pose_now:
				lowest = minf(lowest, p.origin.y)
			worst_gap = maxf(worst_gap, r.world.physics.call("character_worst_joint_gap", r._id))
			if settled_at < 0 and i > 20 and r.max_speed() < 0.25:
				settled_at = i
		if c.state.state == Id.IDLE and i > 30:
			break
	info("knockdown: %s; settled at %.2f s, lowest part %.2f m above the floor, worst joint gap %.1f mm" % [" ".join(trace), settled_at / 60.0, lowest - floor_y, worst_gap * 1000.0])
	check(trace.size() >= 3 and c.state.state == Id.IDLE, "knocked down, got up again")
	check(settled_at > 0 and settled_at < 240, "the body settles within 4 s")
	check(lowest > floor_y - 0.12, "it lies ON the floor (Sinew's mirror of the level), not through it")
	check(worst_gap < 0.01, "and in one piece")
	check(not r.active and (r.modifier.blend == 0.0 or powered), "back on its feet, the animation shows again")


func test_dead_body_goes_limp_and_lies_flat() -> void:
	load_playground()
	var c := _sinew(marker("spawn").global_position + Vector3(2, 0, 0))
	await ticks(15)
	var info_d := UltraCombat.DamageInfo.new()
	info_d.point = c.state.pos + Vector3.UP
	info_d.amount = 500.0
	info_d.region = UltraLimbs.Region.TORSO
	info_d.dir = Vector3(0, 0, -1)
	info_d.kind = &"bullet"
	c.apply_damage(info_d)
	await ticks(240)
	var r := c.ragdoll as SinewRagdoll
	check(c.state.state == Id.DEAD and r.active, "dead: the Sinew body has it")
	var head_y := _head_y(c)
	check(head_y < c.state.pos.y + 0.45, "lying down (head %.2f m above the floor)" % (head_y - c.state.pos.y))
	check(r.max_speed() < 0.3, "and still (%.2f m/s)" % r.max_speed())


func test_a_cut_limb_leaves_the_sinew_body() -> void:
	load_playground()
	var c := _sinew(marker("spawn").global_position + Vector3(-2, 0, 0))
	await ticks(15)
	var r := c.ragdoll as SinewRagdoll
	var arm := r._part("LeftUpperArm")
	var d := UltraCombat.DamageInfo.new()
	d.point = c.state.pos + Vector3.UP
	d.amount = 400.0
	d.region = UltraLimbs.Region.ARM_L
	d.dir = Vector3(1, 0, 0)
	d.kind = &"buckshot"
	c.apply_damage(d)
	await ticks(5)
	check(c.state.severed & (1 << UltraLimbs.Region.ARM_L) != 0, "the shotgun took the left arm")
	check(not bool(r.world.physics.call("character_attached", r._id, arm)), "Sinew's left arm is off too")


func test_zombie_model_gets_its_own_sinew_rig() -> void:
	load_playground()
	var c := _sinew(marker("spawn").global_position + Vector3(0, 0, 3), "zombie")
	await ticks(15)
	var r := c.ragdoll as SinewRagdoll
	check(r is SinewRagdoll and r.parts.size() == 19, "the Mixamo zombie maps onto the same 19 parts")
	c.knock_down(Vector3(3, 1.0, 0))
	var lowest := INF
	for i in 150:
		await ticks(1)
		if r.active and not r._getting_up:
			lowest = minf(lowest, _head_y(c) - c.state.pos.y)
	check(lowest < 0.5, "and goes down as a Sinew body (head down to %.2f m)" % lowest)
