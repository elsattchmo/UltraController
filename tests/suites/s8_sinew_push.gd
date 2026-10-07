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
	_press(c, 3)
	await ticks(8)
	var drv := c.anim as SinewAnimDriver
	check(drv.upper_busy(), "the arms go out (push one-shot)")
	await ticks(60)
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
