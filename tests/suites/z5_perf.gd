extends UltraTestSuite
## Zombie stage 5: what do forty zombies cost? Headless wall time per frame (the script / animation /
## physics side; rendering is not measured here) with one cost driver switched off at a time. Reported, not
## asserted (`--suite=z5`); the numbers decide what the zombies' lighter paths drop.

const COUNT := 40

var _floor: StaticBody3D
var _ids: Array[int] = []


func _wanted() -> bool:
	return OS.get_cmdline_user_args().has("--suite=z5")


func before_each() -> void:
	_floor = StaticBody3D.new()
	_floor.collision_layer = UltraLayers.WORLD_STATIC
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(400, 1, 400)
	cs.shape = bs
	cs.position = Vector3(0, -0.5, 0)
	_floor.add_child(cs)
	add_child(_floor)
	UltraNet.world_root = self
	UltraNet.spawn_transform = func(_p: NetPlayer) -> Transform3D: return Transform3D(Basis(), Vector3(0, 0.05, 80))
	UltraNet.local_input_factory = func(_i: int) -> InputSource: return BotInputSource.new()
	await get_tree().physics_frame


func after_each() -> void:
	UltraNet.stop()
	UltraNet.character_factory = Callable()
	UltraNet.local_input_factory = Callable()
	UltraNet.spawn_transform = Callable()
	if is_instance_valid(_floor):
		_floor.queue_free()
	await super.after_each()


func _frames(n: int) -> Array:
	var ts: Array[float] = []
	var last := Time.get_ticks_usec()
	for i in n:
		await get_tree().physics_frame
		var now := Time.get_ticks_usec()
		ts.append((now - last) / 1000.0)
		last = now
	var sum := 0.0
	for t in ts:
		sum += t
	ts.sort()
	return [sum / n, ts[int(n * 0.95)], ts[n - 1]]


func _spawn(n: int, visuals: bool) -> Array[UltraCharacter]:
	var out: Array[UltraCharacter] = []
	UltraNet.character_factory = func(p: NetPlayer) -> UltraCharacter:
		if ZombieFactory.is_zombie(p):
			return ZombieFactory.make(p, visuals)
		var ch := UltraCharacter.new()
		ch.profile = (load("res://addons/ultra_controller/profiles/fps.tres") as MovementProfile).duplicate(true)
		ch.body_profile = load("res://assets/characters/mannequin/mannequin_body_profile.tres")
		ch.build_visuals = false
		return ch
	UltraNet.start_offline(1)
	for i in n:
		var ang := TAU * float(i) / maxf(n, 1.0)
		var at := Vector3(cos(ang), 0.05, sin(ang)) * (4.0 + 0.3 * n)
		var p := UltraNet.spawn_bot(ZombieFactory.name_for(&"walker", i), Transform3D(Basis(Vector3.UP, ang), at))
		ZombieFactory.dress(p.character)
		out.append(p.character)
	return out


func test_zombie_cost_breakdown() -> void:
	if not _wanted():
		return
	var rows := []
	var base_ms := 0.0
	var variants := [
		["server only (no body)", false, func(_c: UltraCharacter) -> void: pass],
		["full lite visuals", true, func(_c: UltraCharacter) -> void: pass],
		["... AnimationTree off", true, func(c: UltraCharacter) -> void: c.anim.tree.active = false],
		["... FootIK off", true, func(c: UltraCharacter) -> void: c.anim.foot_ik.active = false],
		["... BodyFX off", true, func(c: UltraCharacter) -> void:
			c.body_fx.set_process(false)
			c.body_fx.set_physics_process(false)],
		["... ragdoll node off", true, func(c: UltraCharacter) -> void:
			c.ragdoll.set_process(false)
			c.ragdoll.set_physics_process(false)],
		["... hitbox capture off", true, func(c: UltraCharacter) -> void:
			c.skeleton.skeleton_updated.disconnect(c._capture_hitboxes)],
		["... skeleton modifiers all off", true, func(c: UltraCharacter) -> void:
			for ch in c.skeleton.get_children():
				if ch is SkeletonModifier3D:
					(ch as SkeletonModifier3D).active = false],
		["... body mesh hidden", true, func(c: UltraCharacter) -> void: c.body_mesh().visible = false],
		["... AnimationTree + modifiers + BodyFX + ragdoll off", true, func(c: UltraCharacter) -> void:
			c.anim.tree.active = false
			c.anim.set_process(false)
			c.body_fx.set_process(false)
			c.ragdoll.set_process(false)
			c.ragdoll.set_physics_process(false)
			for ch in c.skeleton.get_children():
				if ch is SkeletonModifier3D:
					(ch as SkeletonModifier3D).active = false],
	]
	for v: Array in variants:
		var zs := await _spawn(COUNT, v[1])
		for z in zs:
			(v[2] as Callable).call(z)
			(z.input_source as BotInputSource).set_steps([{"ticks": 100000, "yaw": z.state.body_yaw}])    # standing
		await ticks(90)
		var m: Array = await _frames(180)
		rows.append("%-52s %6.2f ms per frame, p95 %.2f" % [v[0], m[0], m[1]])
		UltraNet.stop()
		await ticks(20)
	info("40 zombies standing (headless: no rendering)\n  " + "\n  ".join(rows))
	check(true, "recorded")


## 41 zombies hunting a player in the mansion (the real thing, headless): where does a frame go?
func test_awake_horde_cost() -> void:
	if not _wanted():
		return
	UltraNet.stop()
	await ticks(5)
	var mansion := load_map("res://demo/maps/mansion.tscn") as Mansion
	await UltraNav.wait_ready(get_tree())
	UltraNet.character_factory = func(p: NetPlayer) -> UltraCharacter:
		if ZombieFactory.is_zombie(p):
			return ZombieFactory.make(p, false)
		var ch := UltraCharacter.new()
		ch.profile = (load("res://addons/ultra_controller/profiles/fps.tres") as MovementProfile).duplicate(true)
		ch.body_profile = load("res://assets/characters/mannequin/mannequin_body_profile.tres")
		ch.build_visuals = false
		return ch
	UltraNet.spawn_transform = func(_p: NetPlayer) -> Transform3D: return Transform3D(Basis(), Vector3(28, 0.05, 20))
	UltraNet.start_offline(1)
	var player := UltraNet.local_players[0].character
	(player.input_source as BotInputSource).body = player
	(player.input_source as BotInputSource).set_steps([{"ticks": 1000000}])
	var sandbox := MansionSandbox.new()
	add_child(sandbox)
	sandbox.start(mansion)
	var t := 0
	while not sandbox.ready_to_play and t < 600:
		await get_tree().physics_frame
		t += 1
	for b in sandbox.director.brains:
		b.reset(ZombieBrain.Mode.CHASE, player)
	var keep := func() -> void:
		player.state.hp = 100.0
		for b in sandbox.director.brains:
			if b.mode == ZombieBrain.Mode.CHASE:
				b.last_seen = player.state.pos
				b.last_seen_t = sandbox.director.now
	for i in 60 * 14:
		await get_tree().physics_frame
		if i % 20 == 0:
			keep.call()
	var rows := []
	var near := 0
	for b in sandbox.director.brains:
		if Vector2(b.c.state.pos.x - player.state.pos.x, b.c.state.pos.z - player.state.pos.z).length() < 8.0:
			near += 1
	UltraProf.enabled = OS.get_cmdline_user_args().has("--prof")
	UltraProf.report(1)
	var base: Array = await _frames(180)
	rows.append("%-40s %6.2f ms per frame (%d within 8 m)" % ["all hunting", base[0], near])
	if UltraProf.enabled:
		print("PROF per physics tick (180 ticks):\n", UltraProf.report(180))
		UltraProf.enabled = false
	sandbox.director.set_physics_process(false)
	var m: Array = await _frames(120)
	rows.append("%-40s %6.2f ms per frame" % ["director off (brains frozen)", m[0]])
	sandbox.director.set_physics_process(true)
	for b in sandbox.director.brains:
		b.c.sim_skip = true
	m = await _frames(120)
	rows.append("%-40s %6.2f ms per frame" % ["no zombie simulated at all", m[0]])
	for b in sandbox.director.brains:
		b.c.sim_skip = false
	for b in sandbox.director.brains:
		b.c.profile.character_collision = MovementProfile.CharacterCollision.NONE
	m = await _frames(120)
	rows.append("%-40s %6.2f ms per frame" % ["soft collision off", m[0]])
	info("41 zombies hunting in the mansion (headless)\n  " + "\n  ".join(rows))
	check(true, "recorded")
	sandbox.queue_free()
