extends UltraTestSuite
## Zombie stage 4: packs and the sandbox. The sandbox fills the mansion with sleeping packs, a pack wakes
## when the player enters one of its rooms, a wave wakes the near ones and brings corpses back in at the
## gates (no player ids spent), no more than four zombies swing at one target, thirty of them hunting
## for a minute stay sane (no NaN, nothing through the floor, nobody stuck for good), reset puts it back.

const Id := MotorState.Id
const Mode := ZombieBrain.Mode

var mansion: Mansion
var player: UltraCharacter
var sandbox: MansionSandbox


func before_each() -> void:
	UltraNoise.clear()
	mansion = load_map("res://demo/maps/mansion.tscn") as Mansion
	await UltraNav.wait_ready(get_tree())
	UltraNet.world_root = self
	UltraNet.spawn_transform = func(_p: NetPlayer) -> Transform3D: return Transform3D(Basis(), Vector3(28, 0.05, 58))
	UltraNet.character_factory = func(p: NetPlayer) -> UltraCharacter:
		if ZombieFactory.is_zombie(p):
			return ZombieFactory.make(p, false)
		var ch := UltraCharacter.new()
		ch.profile = (load("res://addons/ultra_controller/profiles/fps.tres") as MovementProfile).duplicate(true)
		ch.body_profile = load("res://assets/characters/mannequin/mannequin_body_profile.tres")
		ch.build_visuals = false
		return ch
	UltraNet.local_input_factory = func(_i: int) -> InputSource: return BotInputSource.new()
	UltraNet.start_offline(1)
	player = UltraNet.local_players[0].character
	(player.input_source as BotInputSource).body = player
	(player.input_source as BotInputSource).set_steps([{"ticks": 1000000}])
	await ticks(3)


func after_each() -> void:
	if is_instance_valid(sandbox):
		sandbox.queue_free()
	UltraNet.stop()
	UltraNet.character_factory = Callable()
	UltraNet.local_input_factory = Callable()
	UltraNet.spawn_transform = Callable()
	UltraNoise.clear()
	await super.after_each()


func start_sandbox() -> void:
	sandbox = MansionSandbox.new()
	add_child(sandbox)
	sandbox.start(mansion)
	var t := 0
	while not sandbox.ready_to_play and t < 600:
		await get_tree().physics_frame
		t += 1
	await ticks(10)


func until(cond: Callable, max_s: float) -> float:
	var n := int(max_s * 60.0)
	for i in n:
		if cond.call():
			return i / 60.0
		await get_tree().physics_frame
	return -1.0 if not cond.call() else max_s


func put_player(pos: Vector3, yaw := 0.0) -> void:
	player.teleport(pos, deg_to_rad(yaw))
	(player.input_source as BotInputSource).live_yaw = deg_to_rad(yaw)


func count_mode(m: int) -> int:
	var n := 0
	for b in sandbox.director.brains:
		if b.mode == m:
			n += 1
	return n


func kill(b: ZombieBrain) -> void:
	var d := UltraCombat.DamageInfo.new()
	d.amount = 200.0
	d.region = UltraLimbs.Region.HEAD
	d.kind = &"bullet"
	d.dir = Vector3.FORWARD
	d.point = b.c.state.pos + Vector3.UP * 1.5
	d.attacker_id = player.net_id
	b.c.apply_damage(d)


# ------------------------------------------------------------------ the sandbox

func test_the_house_fills_with_sleeping_packs() -> void:
	var ids0 := UltraNet.players.size()
	await start_sandbox()
	var want := 0
	for pd: Dictionary in MansionLayout.PACKS:
		want += int(pd.count)
	info("%d zombies spawned (asked for %d), %d dormant, %d idle" % [sandbox.spawned, want, count_mode(Mode.DORMANT), count_mode(Mode.IDLE)])
	check(sandbox.spawned >= int(want * 0.85), "most of what the packs asked for found a place (%d of %d)" % [sandbox.spawned, want])
	check(UltraNet.players.size() == ids0 + sandbox.spawned, "each is one player id (%d)" % UltraNet.players.size())
	var off_mesh := 0
	var rooms := {}
	for b in sandbox.director.brains:
		var q := UltraNav.snap(b.c.state.pos)
		if Vector2(q.x - b.c.state.pos.x, q.z - b.c.state.pos.z).length() > 0.6:
			off_mesh += 1
		rooms[mansion.room_at(b.c.state.pos)] = true
	check(off_mesh == 0, "all stand on the navmesh (%d off)" % off_mesh)
	check(rooms.size() >= 12, "spread over the house (%d rooms)" % rooms.size())
	var inside_hunting := 0
	for b in sandbox.director.brains:
		if mansion.room_at(b.c.state.pos) != "" and b.mode in [Mode.CHASE, Mode.ATTACK, Mode.INVESTIGATE]:
			inside_hunting += 1
	check(inside_hunting == 0, "nobody inside the house is up yet (%d) - the lawn pack, out in the open, has seen the player at the gate" % inside_hunting)
	check(sandbox.kills == 0, "no kills")
	var packs_with := 0
	for pn: String in sandbox.packs:
		if (sandbox.packs[pn].brains as Array).size() > 0:
			packs_with += 1
	check(packs_with == MansionLayout.PACKS.size(), "every pack is there (%d)" % packs_with)


func test_a_pack_wakes_when_you_walk_into_its_room() -> void:
	await start_sandbox()
	var dining: Dictionary = sandbox.packs["dining"]
	var before := 0
	for b: ZombieBrain in dining.brains:
		if b.mode == Mode.DORMANT:
			before += 1
	check(before == (dining.brains as Array).size() and before > 0, "the dining pack sleeps (%d)" % before)
	put_player(Vector3(41.5, 0.05, 7.0), 90.0)                       # inside the dining room's door
	await ticks(60)
	var up := 0
	for b: ZombieBrain in dining.brains:
		if b.mode != Mode.DORMANT:
			up += 1
	check(up == before, "walking in wakes all of them (%d of %d)" % [up, before])
	var other := 0
	for b: ZombieBrain in sandbox.packs["boiler"].brains:
		if b.mode != Mode.DORMANT:
			other += 1
	check(other == 0, "a pack elsewhere sleeps on")


func test_a_wave_recycles_corpses_without_new_ids() -> void:
	await start_sandbox()
	var all: Array = sandbox.director.brains.duplicate()
	var victims := []
	for b: ZombieBrain in all:
		if victims.size() < 8 and b.c.state.pos.distance_to(Vector3(28, 0, 40)) > 14.0:
			victims.append(b)
	for b: ZombieBrain in victims:
		kill(b)
	await ticks(40)
	check(sandbox.kills == victims.size(), "kills counted (%d)" % sandbox.kills)
	for b: ZombieBrain in victims:
		check(b.c.state.state == Id.DEAD, "dead")
	var ids := UltraNet.players.size()
	put_player(Vector3(28, 0.05, 56), 0.0)                         # out on the lawn, near the gates
	await ticks(10)
	sandbox.trigger_wave(8)
	await ticks(30)
	check(UltraNet.players.size() == ids, "no player ids spent (%d)" % UltraNet.players.size())
	var revived := 0
	for b: ZombieBrain in victims:
		if b.c.state.state != Id.DEAD:
			revived += 1
			check(b.c.state.hp >= 99.0 and b.c.state.severed == 0 or b.arch.legs_gone, "a revived one is whole again")
	check(revived >= 6, "the corpses are back on their feet and hunting (%d of %d)" % [revived, victims.size()])
	check(sandbox.waves == 1, "wave counted")


func test_four_swing_at_once_not_more() -> void:
	await start_sandbox()
	# Ten walkers round the player in the middle of the Great Hall.
	var ring := []
	var tg := player
	put_player(Vector3(28, 0.05, 21), 0.0)
	for k in 10:
		var a := TAU * k / 10.0
		var p := UltraNet.spawn_bot(ZombieFactory.name_for(&"walker", 900 + k), Transform3D(Basis(Vector3.UP, a), Vector3(28 + sin(a) * 3.0, 0.05, 21 + cos(a) * 3.0)))
		ZombieFactory.dress(p.character)
		var b := sandbox.director.add(p.character)
		b.reset(Mode.CHASE, tg)
		ring.append(b)
	var most := 0
	var hp0 := player.state.hp
	for i in 60 * 14:
		await get_tree().physics_frame
		player.state.hp = maxf(player.state.hp, 60.0) if player.state.hp < 60.0 else player.state.hp       # (keep the target alive)
		var n := 0
		for b: ZombieBrain in ring:
			if b.mode == Mode.ATTACK:
				n += 1
		most = maxi(most, n)
	info("most swinging at once: %d; the player lost %.0f hp" % [most, hp0 - player.state.hp])
	check(most <= sandbox.director.max_attackers, "never more than %d at once (%d)" % [sandbox.director.max_attackers, most])
	check(most >= 2, "but a crowd does gang up (%d)" % most)
	check(player.state.hp < hp0, "and it hurts")


func test_thirty_zombies_for_a_minute() -> void:
	await start_sandbox()
	# Every zombie hunts the player, who stands in the Great Hall and is kept alive.
	put_player(Vector3(28, 0.05, 21), 0.0)
	for b in sandbox.director.brains:
		b.reset(Mode.CHASE, player)
	var start := {}
	for b in sandbox.director.brains:
		start[b] = b.c.state.pos
	var ids := UltraNet.players.size()
	var worst_attackers := 0
	var bad := []
	for i in 60 * 60:
		await get_tree().physics_frame
		if i % 30 == 0:
			player.state.hp = 100.0
			for b in sandbox.director.brains:
				if b.mode == Mode.CHASE and b.target != null:
					b.last_seen = player.state.pos
					b.last_seen_t = sandbox.director.now
		if i % 60 == 0:
			var n := 0
			for b in sandbox.director.brains:
				var p := b.c.state.pos
				if not (is_finite(p.x) and is_finite(p.y) and is_finite(p.z)) or p.y < -5.0:
					bad.append("%s fell / NaN at %s" % [b.c.name, p])
				if b.mode == Mode.ATTACK:
					n += 1
			worst_attackers = maxi(worst_attackers, n)
	var near := 0
	var far_stuck := 0
	var modes := {}
	for b in sandbox.director.brains:
		modes[b.mode_name()] = int(modes.get(b.mode_name(), 0)) + 1
		var d := Vector2(b.c.state.pos.x - player.state.pos.x, b.c.state.pos.z - player.state.pos.z).length()
		if d < 8.0:
			near += 1
		elif b.mode == Mode.CHASE and b.c.state.pos.distance_to(start[b]) < 1.0:
			far_stuck += 1
	info("after a minute: %s; %d within 8 m; %d far and still at their start; most attackers at a sample %d" % [str(modes), near, far_stuck, worst_attackers])
	check(bad.is_empty(), "no NaN, nobody through the floor: " + str(bad.slice(0, 3)))
	check(UltraNet.players.size() == ids, "player ids constant (%d)" % UltraNet.players.size())
	check(near >= int(sandbox.director.brains.size() * 0.5), "most of the horde reached it (%d of %d)" % [near, sandbox.director.brains.size()])
	check(far_stuck <= 3, "hardly anyone stuck where it started (%d)" % far_stuck)
	check(worst_attackers <= sandbox.director.max_attackers, "token cap held (%d)" % worst_attackers)


func test_reset_puts_everything_back() -> void:
	await start_sandbox()
	put_player(Vector3(41.5, 0.05, 7.0), 90.0)
	await ticks(120)
	sandbox.trigger_wave(4)
	for b: ZombieBrain in sandbox.director.brains.slice(0, 6):
		kill(b)
	mansion.door("d_lib_corr").break_open()
	await ticks(60)
	check(sandbox.kills >= 6 and mansion.door("d_lib_corr").broken, "(a mess made: %d kills, a door broken)" % sandbox.kills)
	sandbox.reset()
	await ticks(30)
	check(sandbox.kills == 0, "kills back to 0")
	check(not mansion.door("d_lib_corr").broken, "doors repaired")
	var awake := 0
	var dead := 0
	var home_far := 0
	for b: ZombieBrain in sandbox.director.brains:
		if b.mode in [Mode.CHASE, Mode.ATTACK]:
			awake += 1
		if b.c.state.state == Id.DEAD:
			dead += 1
		if Vector2(b.c.state.pos.x - b.home_spawn.x, b.c.state.pos.z - b.home_spawn.z).length() > 1.5:
			home_far += 1
	check(dead == 0 and awake == 0, "every zombie alive and at rest (dead %d, hunting %d)" % [dead, awake])
	check(home_far == 0, "all back where they started (%d away)" % home_far)
	check(player.state.hp >= 99.0, "the player healed")
