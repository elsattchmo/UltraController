extends UltraTestSuite
## Breakables (UltraBreakable): crates, barrels, bottles and the window in the physics yard
## smash from shots, buckshot, blows, things thrown at them, falls - and the window from a body
## running through it. Broken replicates through the body's NetObject; drops spill out.

var c: UltraCharacter


func before_each() -> void:
	load_playground()
	UltraNet.world_root = self
	UltraNet.spawn_transform = func(_p: NetPlayer) -> Transform3D: return marker("sandbox").global_transform
	UltraNet.character_factory = func(_p: NetPlayer) -> UltraCharacter:
		var ch := UltraCharacter.new()
		ch.profile = (load("res://addons/ultra_controller/profiles/fps.tres") as MovementProfile).duplicate(true)
		ch.body_profile = load("res://assets/characters/mannequin/mannequin_body_profile.tres")
		return ch
	UltraNet.local_input_factory = func(_i: int) -> InputSource: return BotInputSource.new()
	UltraNet.start_offline(1)
	c = UltraNet.local_players[0].character
	(c.input_source as BotInputSource).body = c
	await ticks(70)                     # (breakables arm after a second: props settle first)


func after_each() -> void:
	for g in get_tree().get_nodes_in_group(&"ultra_debris"):
		g.queue_free()
	UltraNet.stop()
	UltraNet.character_factory = Callable()
	UltraNet.local_input_factory = Callable()
	UltraNet.spawn_transform = Callable()
	await super.after_each()


func _body(n: String) -> Node3D:
	return find_child(n, true, false) as Node3D


func _br(n: String) -> UltraBreakable:
	return _body(n).get_node("Breakable") as UltraBreakable


## Shoot from 2 m in front of the body's centre.
func _shoot(target: Node3D, gun: StringName) -> void:
	var def := ItemDB.get_def(gun)
	var to := target.global_position
	var from := to + Vector3(0, 0.1, 2.0)
	var dir := (to - from).normalized()
	if int(def.stat("pellets", 1)) > 1:
		var dirs := []
		for k in int(def.stat("pellets", 1)):
			dirs.append((dir + Vector3(randf_range(-0.03, 0.03), randf_range(-0.03, 0.03), 0)).normalized())
		UltraCombat.hitscan_pellets(c, from, dirs, def)
	else:
		UltraCombat.hitscan(c, from, dir, def)
	await ticks(2)


func _count(item: String) -> int:
	var n := 0
	for it in get_tree().get_nodes_in_group(&"ultra_interactable"):
		if it.get_parent() and str(it.get_parent().get("item_id")) == item:
			n += 1
	return n


func test_shots_and_drops() -> void:
	var crate := _body("WoodCrate0_1")          # the one with ammo in it
	var ammo0 := _count("ammo_9mm")
	var n := 0
	while not _br("WoodCrate0_1").broken and n < 10:
		await _shoot(crate, &"pistol")
		n += 1
	await ticks(10)
	var o := crate.get_node("NetObject") as NetObject
	var drops := _count("ammo_9mm") - ammo0
	var debris := get_tree().get_nodes_in_group(&"ultra_debris").size()
	info("pistol: crate broke after %d shots; net state %s; %d debris; ammo dropped %d" % [n, o.net_state(), debris, drops])
	check(_br("WoodCrate0_1").broken and n >= 2 and n <= 8, "a few pistol rounds smash a crate (%d)" % n)
	check(bool(o.net_state().get("broken", false)), "broken goes out in the net state")
	check(not crate.visible and (crate as CollisionObject3D).collision_layer == 0, "the crate is gone")
	check(debris >= 6, "it breaks into pieces (%d)" % debris)
	check(drops >= 1, "what was inside spills out")
	# A client hearing it: the same state applied to another breakable breaks it there too.
	var other := _body("WoodCrate1_0")
	(other.get_node("NetObject") as NetObject).apply_state({"broken": true})
	check(_br("WoodCrate1_0").broken and not other.visible, "a broken state from the server breaks it on a client")
	# Buckshot: one blast at 2 m.
	await _shoot(_body("WoodBarrel0"), &"shotgun")
	check(_br("WoodBarrel0").broken, "one shotgun blast smashes a barrel")
	# Glass: a single round.
	await _shoot(_body("Bottle2"), &"pistol")
	check(_br("Bottle2").broken, "a bottle goes with one shot")


## Knocks: a thrown crate takes out a bottle, a crate dropped from 4 m smashes, a bat smashes a
## crate, a body sprinting into the window goes through it.
func test_knocks() -> void:
	# Something thrown at it.
	var bottle := _body("Bottle0")
	var stone := _body("WoodCrate1_1") as RigidBody3D
	stone.global_position = bottle.global_position + Vector3(0, 0.2, 1.0)     # (clear of the table)
	stone.sleeping = false
	stone.linear_velocity = Vector3(0, 0.0, -7.0)
	var bv := 0.0
	for k in 40:
		await ticks(1)
		if not _br("Bottle0").broken:
			bv = maxf(bv, (bottle as RigidBody3D).linear_velocity.length())
		if _br("Bottle0").broken:
			break
	info("thrown: crate at %s, bottle at %s, bottle top speed %.2f" % [stone.global_position, bottle.global_position, bv])
	check(_br("Bottle0").broken, "a crate thrown into a bottle smashes it")
	# Dropped from a height.
	var crate := _body("WoodCrate1_2") as RigidBody3D
	crate.global_position = crate.global_position + Vector3(2.0, 4.0, 2.0)
	crate.sleeping = false
	crate.linear_velocity = Vector3.ZERO
	var broke := false
	for k in 120:
		await ticks(1)
		broke = broke or _br("WoodCrate1_2").broken
	check(broke, "a crate dropped from 4 m smashes")
	# A club.
	UltraItems.give(c, &"bat")
	var target := _body("WoodCrate1_0")         # (the top row: level with a swing)
	var hits := 0
	c.teleport(Vector3(target.global_position.x, 0.05, target.global_position.z + 1.15), 0.0)
	await ticks(3)
	var bot := c.input_source as BotInputSource
	var slot := 0
	for k in c.inventory.size():
		var it := c.inventory.get_slot(k)
		if it and it.def_id == &"bat":
			slot = k + 1
	bot.set_steps([{"ticks": 60, "slot": slot, "yaw": 0.0, "pitch": -0.45}])
	await ticks(62)
	for swing in 6:
		bot.set_steps([{"ticks": 2, "slot": slot, "yaw": 0.0, "pitch": -0.45, "tap": InputFrame.B_PRIMARY}, {"ticks": 40, "slot": slot, "yaw": 0.0, "pitch": -0.45}])
		await ticks(42)
		hits += 1
		if _br("WoodCrate1_0").broken:
			break
	info("bat: crate broke after %d swings" % hits)
	check(_br("WoodCrate1_0").broken and hits <= 4, "a few blows of a bat smash a crate")
	# Through the window at a sprint.
	var pane := _body("WindowPane")
	c.teleport(pane.global_position + Vector3(0, -1.39, 4.0), 0.0)
	await ticks(3)
	bot.set_steps([{"ticks": 120, "move": Vector2(0, 1), "buttons": InputFrame.B_SPRINT, "yaw": 0.0}])
	for k in 120:
		await ticks(1)
		if _br("WindowPane").broken:
			break
	info("window: broken %s, runner at z %.2f (pane %.2f)" % [_br("WindowPane").broken, c.state.pos.z, pane.global_position.z])
	check(_br("WindowPane").broken, "sprinting into the window goes through it")
