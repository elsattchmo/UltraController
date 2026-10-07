extends UltraTestSuite
## Sinew stage 5: balance. A hard hit on a standing SinewCharacter opens a stagger - the legs
## turn physical and the balancer keeps the body up (shifting its weight, stepping) - then hands
## back to the animation; a blow it can't stand up to knocks it down (single player).

const Id := MotorState.Id


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


func _lowest_foot(r: SinewRagdoll) -> float:
	var y := INF
	for n in ["LeftFoot", "RightFoot"]:
		var i := r._part(n)
		if i >= 0 and i < r.pose_now.size():
			y = minf(y, r.pose_now[i].origin.y)
	return y


func test_a_hard_hit_staggers_and_recovers() -> void:
	load_playground()
	var c := _sinew(marker("spawn").global_position)
	await ticks(60)
	var r := c.ragdoll as SinewRagdoll
	var floor_y := c.state.pos.y
	var fwd := c.skeleton.global_basis * Vector3(0, 0, 1 if c.body_profile.model_faces_positive_z else -1)
	c.react_to_hit(UltraLimbs.Region.TORSO, -fwd, 50.0)     # 25 N s, from the front
	await ticks(2)
	check(r.staggering(), "a hard hit opens a stagger")
	var low := INF
	var bad := false
	var ended_at := -1
	var steps := 0
	for i in 300:
		await ticks(1)
		if r.staggering():
			low = minf(low, _lowest_foot(r) - floor_y)
			steps = maxi(steps, int(r.balance_state().get("steps", 0)))
		elif ended_at < 0:
			ended_at = i
		for p in r.pose_now:
			if not p.origin.is_finite():
				bad = true
	info("stagger: over after %.2f s, %d steps, lowest ankle %.3f m above the floor, state %s" % [ended_at / 60.0, steps, low, Id.keys()[c.state.state]])
	check(ended_at > 0, "the stagger ends (steady again)")
	check(c.state.state != Id.RAGDOLL and c.state.state != Id.GET_UP, "and it stayed on its feet")
	check(low > 0.0, "the feet never sank into the floor (ankles %.3f m up at the lowest)" % low)
	check(not bad, "no NaN")
	await ticks(30)
	var worst := 0.0
	var anim := r._anim_world()
	for i in mini(anim.size(), r.pose_now.size()):
		worst = maxf(worst, (anim[i] as Transform3D).origin.distance_to(r.pose_now[i].origin))
	check(worst < 0.12, "back on the animation afterwards (worst part %.3f m off)" % worst)


func test_a_blow_it_cannot_take_knocks_it_down() -> void:
	load_playground()
	var c := _sinew(marker("spawn").global_position + Vector3(2, 0, 0))
	await ticks(60)
	var r := c.ragdoll as SinewRagdoll
	r.start_stagger()
	var chest: int = r.world.physics.call("character_body", r._id, r._part("Chest"))
	r.world.physics.call("apply_impulse", chest, Vector3(0, 0, 250.0), r.pose_now[r._part("Chest")].origin)
	var fell_at := -1
	var active_after := false
	for i in 180:
		await ticks(1)
		if fell_at < 0 and c.state.state == Id.RAGDOLL:
			fell_at = i
		if fell_at >= 0 and i == fell_at + 5:
			active_after = r.active
	info("250 N s: knocked down after %.2f s" % (fell_at / 60.0))
	check(fell_at >= 0, "it loses its balance and goes down (a real knock-down)")
	check(active_after, "the Sinew body carries on into the fall")


func test_small_knocks_dont_stagger() -> void:
	load_playground()
	var c := _sinew(marker("spawn").global_position + Vector3(-2, 0, 0))
	await ticks(60)
	var r := c.ragdoll as SinewRagdoll
	c.react_to_hit(UltraLimbs.Region.ARM_L, Vector3(1, 0, 0), 8.0)     # 4 N s
	await ticks(2)
	check(not r.staggering(), "a light hit only rocks the struck limb")

