extends UltraTestSuite
## Sinew physical motion: on the ground the capsule moves as the body's feet allow (Gait::drive):
## starting takes a step, a reversal carries on before it comes back, a walk settles at the speed
## the motor asks for, and physical_motion = false gives the motor's own movement back.

const Id := MotorState.Id


func _sinew(at: Vector3, physical := true) -> SinewCharacter:
	var c := SinewCharacter.new()
	c.profile = (load("res://addons/ultra_controller/profiles/fps.tres") as MovementProfile).duplicate(true)
	c.body_profile = CharacterModels.body_profile("mannequin")
	c.build_visuals = true
	c.physical_motion = physical
	var b := BotInputSource.new()
	b.name = "InputSource"
	c.add_child(b)
	c.input_source = b
	c.position = at
	add_child(c)
	b.body = c
	chars.append(c)
	return c


func _speed(c: UltraCharacter) -> float:
	return Vector2(c.state.vel.x, c.state.vel.z).length()


## Walk forward (-Z, yaw 0) from standing: the speed over time, per tick.
func _walk(c: SinewCharacter, move: Vector2, ticks_n: int) -> PackedFloat32Array:
	(c.input_source as BotInputSource).set_steps([{"ticks": ticks_n + 5, "move": move, "yaw": 0.0}])
	var out := PackedFloat32Array()
	for i in ticks_n:
		await ticks(1)
		out.append(_speed(c))
	return out


func test_starting_takes_a_step_and_settles_at_the_motor_speed() -> void:
	load_playground()
	var c := _sinew(marker("spawn").global_position)
	var m := _sinew(marker("spawn").global_position + Vector3(3, 0, 0), false)
	await ticks(40)
	var sp := await _walk(c, Vector2(0, 1), 150)
	var sm := await _walk(m, Vector2(0, 1), 150)
	var t90 := -1
	var t90m := -1
	for i in sp.size():
		if t90 < 0 and sp[i] > 0.9 * 1.35:
			t90 = i
		if t90m < 0 and sm[i] > 0.9 * 1.35:
			t90m = i
	var lo := 9.0
	var hi := 0.0
	for i in range(90, 150):
		lo = minf(lo, sp[i])
		hi = maxf(hi, sp[i])
	info("90%% of walking speed: physical %.2f s, motor %.2f s; steady %.2f..%.2f m/s" % [t90 / 60.0, t90m / 60.0, lo, hi])
	check(c._motion_on, "physical motion drives the capsule")
	check(t90 > t90m + 6, "starting takes longer than the motor's (it has to tip into a step)")
	check(t90 > 0 and t90 < 90, "but it gets going within a step or two")
	check(lo > 1.1 and hi < 1.6, "a steady walk at the motor's speed (%.2f..%.2f)" % [lo, hi])


func test_a_reversal_carries_on_then_comes_back() -> void:
	load_playground()
	var c := _sinew(marker("spawn").global_position + Vector3(-3, 0, 0))
	await ticks(40)
	await _walk(c, Vector2(0, 1), 120)
	var at := c.state.pos
	var furthest := 0.0
	var sp := PackedFloat32Array()
	(c.input_source as BotInputSource).set_steps([{"ticks": 200, "move": Vector2(0, -1), "yaw": 0.0}])
	for i in 150:
		await ticks(1)
		furthest = maxf(furthest, -(c.state.pos.z - at.z))     # (forward is -Z)
		sp.append(_speed(c))
	var back := c.state.pos.z - at.z
	info("reversal: carried on %.2f m, then %.2f m back in 2.5 s, now %.2f m/s, state %s" % [furthest, back, sp[-1], Id.keys()[c.state.state]])
	check(furthest > 0.1, "momentum carries it on before it turns (%.2f m)" % furthest)
	check(furthest < 0.8, "... braked within a step or two")
	check(back > 1.5, "then it goes back")
	check(sp[-1] > 0.9, "at walking pace")
	check(c.state.state in [Id.MOVE, Id.IDLE], "on its feet throughout")


func test_motor_movement_when_off() -> void:
	load_playground()
	var c := _sinew(marker("spawn").global_position + Vector3(6, 0, 0), false)
	await ticks(40)
	var sp := await _walk(c, Vector2(0, 1), 30)
	check(not c._motion_on, "off: the motor moves it")
	check(sp[15] > 1.2, "the motor's own quick start (%.2f m/s after 0.25 s)" % sp[15])
