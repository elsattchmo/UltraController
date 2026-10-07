extends UltraTestSuite
## Sinew stage 4: limb awareness and procedural control on a SinewCharacter - an arm reaches for
## a point, the head looks at one, both mixed into the animation by the muscles; the body knows
## which limbs touch the level; probes see the level (never the body).


func _sinew(at: Vector3) -> SinewCharacter:
	var c := SinewCharacter.new()
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


## The way the body faces, flat (world).
func _fwd(c: SinewCharacter) -> Vector3:
	var z := 1.0 if c.body_profile == null or c.body_profile.model_faces_positive_z else -1.0
	var f := c.skeleton.global_basis * Vector3(0, 0, z)
	return Vector3(f.x, 0, f.z).normalized()


func test_an_arm_reaches_for_a_point() -> void:
	load_playground()
	var c := _sinew(marker("spawn").global_position)
	await ticks(60)
	var r := c.ragdoll as SinewRagdoll
	var chest := r.pose_now[r._part("UpperChest")].origin
	var fwd := _fwd(c)
	var right := fwd.cross(Vector3.UP)
	var goal := chest + fwd * 0.42 + right * 0.15 + Vector3.UP * 0.05
	var start: Vector3 = r.limb_state(SinewRagdoll.Limb.ARM_R).end_position
	var miss := INF
	for i in 90:
		r.reach(SinewRagdoll.Limb.ARM_R, goal)
		await ticks(1)
		miss = (r.limb_state(SinewRagdoll.Limb.ARM_R).end_position as Vector3).distance_to(goal)
	info("right hand: %.2f m from the goal at the start, %.3f m after 1.5 s of reaching" % [start.distance_to(goal), miss])
	check(start.distance_to(goal) > 0.2, "the goal is away from where the clip holds the hand")
	check(miss < 0.08, "the hand reaches it (%.3f m off)" % miss)
	var left: Vector3 = r.limb_state(SinewRagdoll.Limb.ARM_L).end_position
	check(left.distance_to(goal) > 0.3, "the other arm carries on with the clip")
	# Let go: back to the animation.
	await ticks(60)
	var back: Vector3 = r.limb_state(SinewRagdoll.Limb.ARM_R).end_position
	check(back.distance_to(goal) > 0.15, "released, the arm goes back to the clip (%.2f m from the goal)" % back.distance_to(goal))


func test_the_head_looks_at_a_point() -> void:
	load_playground()
	var c := _sinew(marker("spawn").global_position + Vector3(2, 0, 0))
	await ticks(60)
	var r := c.ragdoll as SinewRagdoll
	var n := r._part("Neck")
	var z := 1.0 if c.body_profile.model_faces_positive_z else -1.0
	var fwd_local: Vector3 = (r.parts[n].rest as Transform3D).basis.inverse() * Vector3(0, 0, z)
	var head := r.pose_now[n].origin
	var target := head + _fwd(c) * 2.0 + Vector3.UP.cross(_fwd(c)) * 1.5 + Vector3.UP * 0.6
	for i in 60:
		r.look_toward(target)
		await ticks(1)
	var looking := (r.pose_now[n].basis * fwd_local).normalized()
	var want := (target - r.pose_now[n].origin).normalized()
	var off := rad_to_deg(looking.angle_to(want))
	info("head %.1f deg off the look target" % off)
	check(off < 15.0, "the head turns to look at it (%.1f deg off)" % off)


func test_the_body_knows_what_touches_the_level() -> void:
	load_playground()
	var c := _sinew(marker("spawn").global_position + Vector3(-2, 0, 0))
	await ticks(20)
	var r := c.ragdoll as SinewRagdoll
	c.knock_down(Vector3(0, 1.0, -4.0))
	var touching := []
	for i in 120:
		await ticks(1)
	for p in r.parts:
		if not r.part_contacts(p.name).is_empty():
			touching.append(p.name)
	info("lying: %s touch the floor" % [touching])
	check(touching.size() >= 4, "several parts lie on the floor (%d)" % touching.size())
	var spine := r.limb_state(SinewRagdoll.Limb.SPINE)
	var contact_kind := -1
	for p in touching:
		var cs := r.part_contacts(p)
		contact_kind = int(cs[0].kind)
		break
	check(contact_kind == 0, "against the static level")
	check(not spine.is_empty() and spine.attached and float(spine.health) > 0.0, "limb state reads (spine health %.2f)" % float(spine.get("health", 0)))


func test_probes_see_the_level_not_the_body() -> void:
	load_playground()
	var c := _sinew(marker("spawn").global_position)
	await ticks(20)
	var phys = (c.ragdoll as SinewRagdoll).world.physics
	var g: Dictionary = phys.call("ground_below", c.state.pos + Vector3.UP * 1.5, 3.0)
	check(bool(g.hit) and absf((g.point as Vector3).y - c.state.pos.y) < 0.05, "the ground under the player, through its body (%.3f)" % ((g.point as Vector3).y - c.state.pos.y))
	var eta: float = phys.call("impact_eta", c.state.pos + Vector3(0, 5, 0), Vector3.ZERO, 3.0)
	check(absf(eta - sqrt(2.0 * 5.0 / 9.81)) < 0.08, "time to impact from 5 m: %.2f s" % eta)
