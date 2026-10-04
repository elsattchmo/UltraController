extends UltraTestSuite
## Physical interaction: hold, carry, throw, push, team lift (OFFLINE session = server code).

var c: UltraCharacter


func before_each() -> void:
	load_playground()
	UltraNet.world_root = self
	UltraNet.spawn_transform = func(_p: NetPlayer) -> Transform3D: return marker("sandbox").global_transform
	UltraNet.character_factory = func(_p: NetPlayer) -> UltraCharacter:
		var ch := UltraCharacter.new()
		ch.profile = (load("res://addons/ultra_controller/profiles/fps.tres") as MovementProfile).duplicate(true)
		ch.body_profile = load("res://assets/characters/mannequin/mannequin_body_profile.tres")
		ch.build_visuals = false
		return ch
	UltraNet.local_input_factory = func(_i: int) -> InputSource: return BotInputSource.new()
	UltraNet.start_offline(1)
	c = UltraNet.local_players[0].character
	(c.input_source as BotInputSource).body = c
	await ticks(30)


func after_each() -> void:
	UltraNet.stop()
	UltraNet.character_factory = Callable()
	UltraNet.local_input_factory = Callable()
	UltraNet.spawn_transform = Callable()
	await super.after_each()


func _prop(n: String) -> RigidBody3D:
	return map.find_child(n, true, false) as RigidBody3D


func _id(rb: Node) -> int:
	return (rb.find_child("NetObject", false, false) as NetObject).net_id


func _run(steps: Array) -> void:
	(c.input_source as BotInputSource).set_steps(steps)
	var n := 0
	for s: Dictionary in steps:
		n += int(s.get("ticks", 1))
	await ticks(n + 1)


## Stand 1.2 m in front of a prop, facing it, and grab it.
func _grab(rb: RigidBody3D, yaw := 0.0) -> void:
	var fwd := Vector3(-sin(yaw), 0, -cos(yaw))
	c.teleport(Vector3(rb.global_position.x, 0.06, rb.global_position.z) - fwd * 1.2, yaw)
	await ticks(5)
	await _run([{"ticks": 2, "yaw": yaw, "pitch": -0.3, "target": _id(rb), "tap": InputFrame.B_GRAB}, {"ticks": 50, "yaw": yaw, "pitch": -0.2}])


func test_hold_is_steady() -> void:
	var rb := _prop("Crate5kg")
	await _grab(rb)
	check(c.state.held_id == _id(rb), "grabbed the 5 kg crate")
	var pts: Array[Vector3] = []
	(c.input_source as BotInputSource).set_steps([{"ticks": 130, "yaw": 0.0, "pitch": -0.2}])
	await ticks(10)
	for i in 120:
		await ticks(1)
		pts.append(rb.global_position - UltraGrab.hold_target(c, rb))
	var mean := Vector3.ZERO
	for p in pts:
		mean += p
	mean /= pts.size()
	var dev := 0.0
	for p in pts:
		dev += (p - mean).length_squared()
	dev = sqrt(dev / pts.size())
	info("hold offset %.3f m, jitter %.4f m" % [mean.length(), dev])
	check(dev < 0.01, "held crate is steady (jitter %.4f m)" % dev)
	check(mean.length() < 0.12, "held where it should be (%.3f m off)" % mean.length())


func _carry_speed(n: String) -> float:
	var rb := _prop(n)
	await _grab(rb)
	if c.state.held_id != _id(rb):
		return -1.0
	await _run([{"ticks": 150, "yaw": 0.0, "move": Vector2(0, 1)}])
	var v := Vector2(c.state.vel.x, c.state.vel.z).length()
	await _run([{"ticks": 2, "tap": InputFrame.B_DROP}, {"ticks": 20}])
	return v


func test_carry_speed_falls_with_mass() -> void:
	var speeds := []
	for n in ["Crate1kg", "Crate20kg", "PlateCrateB"]:
		speeds.append(await _carry_speed(n))
	info("carry speeds 1/20/45 kg: %s" % [speeds])
	check(speeds[0] > speeds[1] and speeds[1] > speeds[2] and speeds[2] > 0.5, "heavier is slower")


func _throw(n: String) -> float:
	var rb := _prop(n)
	await _grab(rb)
	if c.state.held_id != _id(rb):
		return -1.0
	var from := c.state.pos
	await _run([{"ticks": 60, "yaw": 0.0, "pitch": 0.35, "buttons": InputFrame.B_THROW}, {"ticks": 2, "yaw": 0.0, "pitch": 0.35}])
	check(c.state.held_id == 0, "%s released by the throw" % n)
	var best := 0.0
	for i in 150:
		await ticks(1)
		if i > 20 and rb.linear_velocity.length() < 0.3:
			break
	best = Vector2(rb.global_position.x - from.x, rb.global_position.z - from.z).length()
	return best


func test_throw_distance_by_mass() -> void:
	var d := []
	for n in ["Crate1kg", "Crate5kg", "Crate20kg"]:
		d.append(await _throw(n))
	info("throw distances 1/5/20 kg: %s" % [d])
	check(d[0] > d[1] and d[1] > d[2], "lighter flies further")
	check(d[0] > 4.0, "a full-charge 1 kg throw goes a fair way (%.1f m)" % d[0])


func _push(n: String) -> float:
	var rb := _prop(n)
	var start := rb.global_position
	c.teleport(Vector3(start.x, 0.06, start.z + 1.6), 0.0)
	await ticks(5)
	await _run([{"ticks": 200, "yaw": 0.0, "move": Vector2(0, 1), "buttons": InputFrame.B_SPRINT}])
	info("%s: char %s crate %s (start %s) frozen %s sleeping %s, char->crate %.2f" % [n, c.state.pos, rb.global_position, start, rb.freeze, rb.sleeping, c.state.pos.distance_to(rb.global_position)])
	return Vector2(rb.global_position.x - start.x, rb.global_position.z - start.z).length()


func test_push_light_vs_heavy() -> void:
	var light := await _push("Crate60kg")
	var heavy := await _push("Crate200kg")
	info("pushed 60 kg %.2f m, 200 kg %.2f m" % [light, heavy])
	check(light > 0.6, "60 kg crate moves when pushed")
	check(heavy < light * 0.5, "200 kg crate barely moves")


func test_cant_stand_on_held_prop() -> void:
	var rb := _prop("Crate20kg")
	await _grab(rb)
	check(c.state.held_id != 0, "holding the crate")
	c.teleport(rb.global_position + Vector3.UP * 0.8, 0.0)
	await ticks(30)
	check(c.state.held_id == 0, "standing on it makes you let go")


func test_team_lift() -> void:
	var beam := _prop("TeamBeam")
	var grips := UltraGrab.grip_points(beam)
	# Alone: only our end comes up.
	c.teleport(Vector3(grips[0].global_position.x - 0.5, 0.06, grips[0].global_position.z), -PI * 0.5)
	await ticks(5)
	await _run([{"ticks": 2, "yaw": -PI * 0.5, "target": _id(beam), "tap": InputFrame.B_GRAB}, {"ticks": 90, "yaw": -PI * 0.5}])
	check(c.state.held_id == _id(beam) and c.state.held_grip == 0, "took grip 0")
	var near := grips[0].global_position.y
	var far := grips[1].global_position.y
	info("alone: near end %.2f m, far end %.2f m" % [near, far])
	check(near > far + 0.3 and far < 0.4, "one person lifts only their end")
	# With the helper.
	var bot := UltraNet.spawn_bot("Helper", Transform3D(Basis(), grips[1].global_position + Vector3(2.5, 0.06 - grips[1].global_position.y, 0)))
	var _brain := UltraCompanion.new(bot.character, c)
	(c.input_source as BotInputSource).set_steps([{"ticks": 400, "yaw": -PI * 0.5}])
	var lifted := false
	for i in 400:
		await ticks(1)
		if bot.character.state.held_id == _id(beam) and grips[0].global_position.y > 0.6 and grips[1].global_position.y > 0.6:
			lifted = true
			break
	info("with helper: ends %.2f / %.2f m, shares %.2f + %.2f" % [grips[0].global_position.y, grips[1].global_position.y, c.state.team_share, bot.character.state.team_share])
	check(lifted, "two carriers lift the whole beam")
	check(absf(c.state.team_share + bot.character.state.team_share - 1.0) < 0.05, "load shares add up to 1")
	var start := beam.global_position
	await _run([{"ticks": 300, "yaw": -PI * 0.5, "move": Vector2(1, 0)}])
	info("carried the beam %.2f m" % beam.global_position.distance_to(start))
	check(beam.global_position.distance_to(start) > 1.0, "carried it together")
	bot.character.teleport(bot.character.state.pos + Vector3(4, 0, 4))
	await ticks(10)
	check(bot.character.state.held_id == 0, "pulled too far apart: the grip breaks")
