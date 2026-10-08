extends UltraTestSuite
## Marksman V7: carrying a prop - both palms on it (MarksmanGunPass._carry_hands), standing and walking, and letting go
## of it lets the arms go back to the animation. OFFLINE session (the grab is server code), as m5_physics.

var c: UltraCharacter


func before_each() -> void:
	load_playground()
	UltraNet.world_root = self
	UltraNet.spawn_transform = func(_p: NetPlayer) -> Transform3D: return marker("sandbox").global_transform
	UltraNet.character_factory = func(_p: NetPlayer) -> UltraCharacter:
		var ch := MarksmanCharacter.new()
		ch.motion_matching = true
		ch.profile = (load("res://addons/ultra_controller/profiles/fps.tres") as MovementProfile).duplicate(true)
		ch.body_profile = CharacterModels.body_profile("mannequin")
		ch.build_visuals = true
		return ch
	UltraNet.local_input_factory = func(_i: int) -> InputSource: return BotInputSource.new()
	UltraNet.start_offline(1)
	c = UltraNet.local_players[0].character
	(c.input_source as BotInputSource).body = c
	await ticks(40)


func after_each() -> void:
	UltraNet.stop()
	UltraNet.character_factory = Callable()
	UltraNet.local_input_factory = Callable()
	UltraNet.spawn_transform = Callable()
	await super.after_each()


func _id(rb: Node) -> int:
	return (rb.find_child("NetObject", false, false) as NetObject).net_id


func test_hands_on_the_carried_prop() -> void:
	var rb := map.find_child("Crate5kg", true, false) as RigidBody3D
	var yaw := 0.0
	var fwd := Vector3(-sin(yaw), 0, -cos(yaw))
	c.teleport(Vector3(rb.global_position.x, 0.06, rb.global_position.z) - fwd * 1.2, yaw)
	await ticks(10)
	var b := c.input_source as BotInputSource
	b.set_steps([{"ticks": 2, "yaw": yaw, "pitch": -0.3, "target": _id(rb), "tap": InputFrame.B_GRAB}, {"ticks": 60, "yaw": yaw, "pitch": -0.2}])
	await ticks(62)
	if not check(c.state.held_id == _id(rb), "grabbed the crate"):
		return
	var gp := (c.ragdoll as MarksmanRagdoll).gun_pass
	var sk := c.skeleton
	var worst := {"stand": 0.0, "walk": 0.0}
	var gap := {"stand": 9.0, "walk": 9.0}
	var phase := ["stand"]
	var errs := {"stand": [], "walk": []}
	var probe := func() -> void:
		worst[phase[0]] = maxf(float(worst[phase[0]]), gp.carry_error)
		(errs[phase[0]] as Array).append(gp.carry_error)
		# (The palms on the prop: each hand's distance from the prop's surface - its collision shape - as shown.)
		for h in ["LeftHand", "RightHand"]:
			var p := sk.global_transform * sk.get_bone_global_pose(sk.find_bone(h)).origin
			gap[phase[0]] = minf(float(gap[phase[0]]), p.distance_to(rb.global_position))
	sk.skeleton_updated.connect(probe)
	b.set_steps([{"ticks": 60, "yaw": yaw, "pitch": -0.2}])
	await ticks(60)
	phase[0] = "walk"
	b.set_steps([{"ticks": 90, "yaw": yaw, "pitch": -0.2, "move": Vector2(0, 1)}])
	await ticks(90)
	sk.skeleton_updated.disconnect(probe)
	for k: String in errs:
		var a: Array = errs[k]
		a.sort()
		info("%s: hand off its spot median %.1f cm, 90th %.1f, worst %.1f" % [k, float(a[a.size() / 2]) * 100.0, float(a[int(a.size() * 0.9)]) * 100.0, float(a[-1]) * 100.0])
	info("carrying: hands off their spots up to %.1f cm standing, %.1f walking; carry weight %.2f" % [worst.stand * 100.0, worst.walk * 100.0, gp.carry_w])
	check(gp.carry_w > 0.99, "the hands are on the prop (%.2f)" % gp.carry_w)
	check(float(worst.stand) < 0.03 and float(worst.walk) < 0.05, "both palms on it, standing and walking (%.1f / %.1f cm)" % [worst.stand * 100.0, worst.walk * 100.0])
	# Let go: the arms return to the animation.
	b.set_steps([{"ticks": 2, "yaw": yaw, "tap": InputFrame.B_DROP}, {"ticks": 40, "yaw": yaw}])
	await ticks(42)
	info("dropped: held %d, carry weight %.2f" % [c.state.held_id, gp.carry_w])
	check(c.state.held_id == 0 and gp.carry_w < 0.01, "dropping it lets the hands go (%.2f)" % gp.carry_w)
