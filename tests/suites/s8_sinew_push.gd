extends UltraTestSuite
## Sinew test tool: the unarmed push (the throw button with empty hands). A tap shoves a
## character back a step, a held (charged) push knocks it over, a loose prop gets pushed, the arms
## go out (the push one-shot), and nothing happens with a gun in hand.

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


func _target(at: Vector3) -> UltraCharacter:
	var c := UltraCharacter.new()
	c.profile = (load("res://addons/ultra_controller/profiles/fps.tres") as MovementProfile).duplicate(true)
	c.body_profile = CharacterModels.body_profile("mannequin")
	c.build_visuals = false
	var b := BotInputSource.new()
	b.name = "InputSource"
	c.add_child(b)
	c.input_source = b
	c.position = at
	add_child(c)
	b.body = c
	chars.append(c)
	return c


## Hold the throw button for `hold` ticks facing -Z, then let go.
func _press(c: SinewCharacter, hold: int) -> void:
	(c.input_source as BotInputSource).set_steps([
		{"ticks": hold, "yaw": 0.0, "buttons": InputFrame.B_THROW},
		{"ticks": 120, "yaw": 0.0}])


func _flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)


func test_a_tap_shoves_a_character_back() -> void:
	load_playground()
	var at := marker("spawn").global_position
	var c := _sinew(at)
	var t := _target(at + Vector3(0, 0, -0.85))
	await ticks(60)
	var from := t.state.pos
	var landed := [null]
	c.pushed.connect(func(o: Object, _s: Vector3) -> void: landed[0] = o)
	var r := c.ragdoll as SinewRagdoll
	var hand := r._part("RightHand")
	var fwd := Vector3(0, 0, -1)
	var rest: float = (r.pose_now[hand].origin - c.state.pos).dot(fwd)
	_press(c, 3)
	var out := rest
	for i in 20:
		await ticks(1)
		out = maxf(out, (r.pose_now[hand].origin - c.state.pos).dot(fwd))
	info("push: the hand %.2f m out in front (%.2f at rest)" % [out, rest])
	check(out > rest + 0.2 and out > 0.45, "the arms go out at the target (hand %.2f m in front)" % out)
	await ticks(48)
	var moved := _flat(t.state.pos - from)
	info("tap: target moved %.2f m (%.2f along the push), state %s" % [moved.length(), -moved.z, Id.keys()[t.state.state]])
	check(landed[0] == t, "the push found the character in front")
	check(-moved.z > 0.15, "it was shoved back (%.2f m)" % -moved.z)
	check(t.state.state not in [Id.RAGDOLL, Id.GET_UP], "a tap doesn't knock it over")
	check(t.state.hp == 100.0, "and doesn't hurt (hp %.1f)" % t.state.hp)


func test_a_charged_push_knocks_over() -> void:
	load_playground()
	var at := marker("spawn").global_position + Vector3(3, 0, 0)
	var c := _sinew(at)
	var t := _target(at + Vector3(0, 0, -0.85))
	await ticks(60)
	_press(c, 45)
	var down := false
	for i in 90:
		await ticks(1)
		down = down or t.state.state == Id.RAGDOLL
	check(down, "a full push knocks the target down")
	check(c.state.state not in [Id.RAGDOLL, Id.GET_UP], "the pusher stays up")


func test_pushes_a_prop() -> void:
	load_playground()
	var at := marker("spawn").global_position + Vector3(-3, 0, 0)
	var c := _sinew(at)
	var rb := RigidBody3D.new()
	rb.mass = 8.0
	rb.collision_layer = UltraLayers.WORLD_DYNAMIC
	rb.collision_mask = UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.4, 0.4, 0.4)
	cs.shape = box
	rb.add_child(cs)
	add_child(rb)
	rb.global_position = at + Vector3(0, 1.2, -0.65)
	await ticks(60)
	rb.global_position = at + Vector3(0, 1.2, -0.65)    # (held up at chest height, no floor under it)
	rb.linear_velocity = Vector3.ZERO
	rb.gravity_scale = 0.0
	_press(c, 3)
	await ticks(30)
	info("prop: velocity %s" % rb.linear_velocity)
	check(rb.linear_velocity.z < -1.0, "the prop is pushed away (%.2f m/s)" % -rb.linear_velocity.z)
	rb.queue_free()


func test_no_push_with_a_gun_in_hand() -> void:
	load_playground()
	var at := marker("spawn").global_position + Vector3(6, 0, 0)
	var c := _sinew(at)
	var t := _target(at + Vector3(0, 0, -0.85))
	await ticks(30)
	var pistol := ItemDB.index_of(&"pistol")
	c.state.equipped = pistol
	check(pistol > 0 and not c.can_push(), "armed: no push")
	var from := t.state.pos
	_press(c, 3)
	for k in 40:
		c.state.equipped = pistol
		await ticks(1)
	check(_flat(t.state.pos - from).length() < 0.05, "the target wasn't moved")


func _sinew_target(at: Vector3) -> SinewCharacter:
	var t := _sinew(at)
	(t.input_source as BotInputSource).set_steps([{"ticks": 600, "yaw": PI}])   # facing the pusher
	return t


func test_a_tap_makes_a_sinew_body_step_back() -> void:
	load_playground()
	var at := marker("spawn").global_position + Vector3(-6, 0, 0)
	var c := _sinew(at)
	var t := _sinew_target(at + Vector3(0, 0, -0.85))
	await ticks(60)
	check(t._motion_on, "the target stands under physical motion")
	var from := t.state.pos
	var st0: Dictionary = (t.ragdoll as SinewRagdoll).world.physics.call("character_gait_state", (t.ragdoll as SinewRagdoll)._id)
	var tripped := [false]
	t.tripped.connect(func(_v: Vector3) -> void: tripped[0] = true)
	_press(c, 3)
	var stepped := false
	var furthest := 0.0
	for i in 120:
		await ticks(1)
		furthest = maxf(furthest, -(t.state.pos.z - from.z))
		var st: Dictionary = (t.ragdoll as SinewRagdoll).world.physics.call("character_gait_state", (t.ragdoll as SinewRagdoll)._id)
		stepped = stepped or not bool(st.planted_l) or not bool(st.planted_r)
	info("tap on a Sinew body: back %.2f m, state %s" % [furthest, Id.keys()[t.state.state]])
	check(stepped, "it took steps to catch itself")
	check(furthest > 0.2 and furthest < 1.2, "a step or two back (%.2f m)" % furthest)
	check(not tripped[0] and t.state.state in [Id.IDLE, Id.MOVE], "and stayed on its feet")


func test_a_full_push_stumbles_then_trips_a_sinew_body() -> void:
	load_playground()
	var at := marker("spawn").global_position + Vector3(-9, 0, 0)
	var c := _sinew(at)
	var t := _sinew_target(at + Vector3(0, 0, -0.85))
	await ticks(60)
	var from := t.state.pos
	var tripped_at := [Vector3.INF]
	t.tripped.connect(func(_v: Vector3) -> void: tripped_at[0] = t.state.pos)
	_press(c, 50)
	var down := false
	for i in 150:
		await ticks(1)
		down = down or t.state.state == Id.RAGDOLL
	var went: float = -((tripped_at[0] as Vector3).z - from.z) if tripped_at[0] != Vector3.INF else 0.0
	info("full push on a Sinew body: stumbled %.2f m, then %s" % [went, "tripped" if tripped_at[0] != Vector3.INF else "caught itself"])
	check(tripped_at[0] != Vector3.INF and down, "it trips and goes down")
	check(went > 0.15, "after stumbling back first (%.2f m), not straight to the floor" % went)


## Fire a launcher ball at a world point from 4 m in front (+Z side) of it.
func _ball_at(shooter: SinewCharacter, p: Vector3) -> void:
	var from := p + Vector3(0, 0, 4.0)
	SinewBall.launch(shooter, from, p - from, ItemDB.get_def(&"ball_launcher"))


func test_balls_knock_the_part_they_hit() -> void:
	load_playground()
	check(ItemDB.get_def(&"ball_launcher") != null, "the ball launcher is an item")
	var at := marker("spawn").global_position + Vector3(-12, 0, -3)
	var shooter := _sinew(at + Vector3(0, 0, 6))
	var t := _sinew_target(at)
	var r := t.ragdoll as SinewRagdoll
	# (It turns round to face the shooter in real steps first: wait for its feet to settle.)
	await ticks(60)
	for i in 240:
		var gs: Dictionary = r.world.physics.call("character_gait_state", r._id)
		if not bool(gs.get("stepping", false)):
			break
		await ticks(1)
	await ticks(40)        # (the hips settle onto the stance at a capped rate)
	var arm := r._part("RightLowerArm")
	var chest := r._part("Chest")
	var pelvis := 0
	# An arm: knocked back by its own (simulated) mass - against the chest - while the body barely moves.
	var rel0: Vector3 = r.pose_now[arm].origin - r.pose_now[chest].origin
	var hips0: Vector3 = r.pose_now[pelvis].origin
	_ball_at(shooter, r.pose_now[arm].origin + (r.pose_now[r._part("RightHand")].origin - r.pose_now[arm].origin) * 0.5)
	var arm_moved := 0.0
	var body_moved := 0.0
	for i in 30:
		await ticks(1)
		arm_moved = maxf(arm_moved, ((r.pose_now[arm].origin - r.pose_now[chest].origin) - rel0).length())
		body_moved = maxf(body_moved, (r.pose_now[pelvis].origin - hips0).length())
	info("ball on the forearm: forearm knocked %.2f m against the chest, hips moved %.2f m" % [arm_moved, body_moved])
	check(arm_moved > 0.05, "the arm takes the ball (%.2f m)" % arm_moved)
	await ticks(150)
	# The chest: the body is rocked back (and may step) - it stays up for one ball.
	hips0 = r.pose_now[pelvis].origin
	_ball_at(shooter, r.pose_now[chest].origin)
	var back := 0.0
	var stag := false
	for i in 90:
		await ticks(1)
		back = maxf(back, hips0.z - r.pose_now[pelvis].origin.z)
		stag = stag or r.staggering()
	info("ball on the chest: hips back %.2f m, staggered %s, state %s" % [back, stag, Id.keys()[t.state.state]])
	check(stag, "the body took it physically (the balancer had to)")
	check(body_moved < back + 0.05, "a forearm hit moves the body less than a chest hit (%.2f vs %.2f m)" % [body_moved, back])
	check(back > 0.02, "a chest hit rocks the body back (%.2f m)" % back)
	check(t.state.state not in [Id.RAGDOLL, Id.DEAD], "one ball doesn't floor it")
	# Balls only last a couple of seconds.
	await ticks(150)
	check(SinewBall._live.is_empty(), "the balls are gone after a couple of seconds")
