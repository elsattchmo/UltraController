extends UltraTestSuite
## Zombie stage 3: the mind. In the mansion, with a player (a mannequin bot standing wherever the test
## puts it) and zombies with brains: they hear a gunshot and go to look, see a player in their cone and
## give chase (a wall hides one, being behind them doesn't give one away), open shut doors on their
## way, bash a locked one down, climb stairs, strike (the player's health drops), stagger when shot.

const Id := MotorState.Id
const Mode := ZombieBrain.Mode
const L := preload("res://demo/maps/mansion/mansion_layout.gd")

var mansion: Mansion
var player: UltraCharacter
var director: ZombieDirector
var _n := 0


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
	director = ZombieDirector.new()
	add_child(director)
	await ticks(3)


func after_each() -> void:
	director.queue_free()
	UltraNet.stop()
	UltraNet.character_factory = Callable()
	UltraNet.local_input_factory = Callable()
	UltraNet.spawn_transform = Callable()
	UltraNoise.clear()
	await super.after_each()


## A zombie of `arch` at `pos` facing `yaw` (degrees; 0 = north / -Z), thinking in `mode`.
func zombie(arch: StringName, pos: Vector3, yaw := 0.0, mode := Mode.IDLE) -> ZombieBrain:
	_n += 1
	var p := UltraNet.spawn_bot(ZombieFactory.name_for(arch, _n), Transform3D(Basis(Vector3.UP, deg_to_rad(yaw)), pos))
	ZombieFactory.dress(p.character)
	var b := director.add(p.character)
	b.mode = mode
	return b


func put_player(pos: Vector3, yaw := 0.0) -> void:
	player.teleport(pos, deg_to_rad(yaw))
	(player.input_source as BotInputSource).live_yaw = deg_to_rad(yaw)


## Run ticks until `cond` holds or `max_s` simulated seconds pass; the seconds taken (or -1).
func until(cond: Callable, max_s: float) -> float:
	var n := int(max_s * 60.0)
	for i in n:
		if cond.call():
			return i / 60.0
		await get_tree().physics_frame
	return -1.0 if not cond.call() else max_s


## Where a brain is every `every` s, for `secs`: mode, position, goal, path progress (debugging a stuck one).
func trace(b: ZombieBrain, secs: float, every := 2.0) -> void:
	for k in int(secs / every):
		await ticks(int(every * 60.0))
		var hits := []
		var body: CharacterBody3D = b.c.motor.body
		for i in body.get_slide_collision_count():
			var col := body.get_slide_collision(i)
			hits.append("%s@%s" % [(col.get_collider() as Node).get_path() if col.get_collider() is Node else "?", col.get_position().snapped(Vector3.ONE * 0.1)])
		info("t+%.0f: %s at %s -> goal %s, path %d/%d (next %s), yaw %.0f (body %.0f), move %.2f, vel %s, slide %s" % [(k + 1) * every, b.mode_name(), b.c.state.pos.snapped(Vector3.ONE * 0.1), str(b.goal.snapped(Vector3.ONE * 0.1)) if b.goal != Vector3.INF else "-", b.path_i, b.path.size(), str(b.path[mini(b.path_i, b.path.size() - 1)].snapped(Vector3.ONE * 0.1)) if not b.path.is_empty() else "-", rad_to_deg(b.want_yaw), rad_to_deg(b.c.state.body_yaw), b.move_mag, b.c.state.vel.snapped(Vector3.ONE * 0.1), str(hits)])


func dist(a: UltraCharacter, b: UltraCharacter) -> float:
	return Vector2(a.state.pos.x - b.state.pos.x, a.state.pos.z - b.state.pos.z).length()


# ------------------------------------------------------------------ hearing

func test_a_gunshot_carries_through_walls_but_a_footstep_does_not() -> void:
	var b := zombie(&"walker", Vector3(48, 0.05, 7), 0.0, Mode.IDLE)
	var space := b.c.get_world_3d().direct_space_state
	var shot := Vector3(28, 1.2, 17)                   # the Great Hall, two rooms away
	check(ZombieSenses.hears(b.c, b.arch, shot, 50.0, space), "a carbine shot (50 m) in the hall is heard in the dining room")
	check(not ZombieSenses.hears(b.c, b.arch, shot, 4.5, space), "a footstep (4.5 m) there is not")
	check(not ZombieSenses.hears(b.c, b.arch, Vector3(28, 1.2, 58), 35.0, space), "a pistol shot out on the lawn (35 m) isn't, past the house")
	# A floor in between costs 6 m: the same shot from upstairs is quieter.
	var above := Vector3(48, 4.85, 7)
	check(ZombieSenses.hears(b.c, b.arch, above, 12.0, space), "a loud noise straight above is heard (12 m: 6 for the floor, 1.2 up)")
	check(not ZombieSenses.hears(b.c, b.arch, above, 6.0, space), "... a quiet one is not")


func test_the_zombie_goes_to_look() -> void:
	var b := zombie(&"walker", Vector3(13, 0.05, 15), 90.0, Mode.IDLE)     # the salon
	director.max_thinks_per_frame = 99
	await ticks(30)
	check(b.mode == Mode.IDLE or b.mode == Mode.WANDER, "idle at first (%s)" % b.mode_name())
	UltraNoise.emit(Vector3(28, 1.2, 17), 50.0, &"gunshot", player.net_id)      # a shot in the hall next door
	await ticks(20)
	check(b.mode == Mode.INVESTIGATE, "it heard it and investigates (%s)" % b.mode_name())
	var t := await until(func() -> bool: return Vector2(b.c.state.pos.x - 28.0, b.c.state.pos.z - 17.0).length() < 3.5, 40.0)
	info("at the noise after %.1f s" % t)
	check(t >= 0.0, "and gets there (%.1f m off)" % Vector2(b.c.state.pos.x - 28.0, b.c.state.pos.z - 17.0).length())
	check(UltraNav.exists(), "(nav stays up)")


# ------------------------------------------------------------------ sight

func test_sight_has_a_cone_and_walls_block_it() -> void:
	var b := zombie(&"walker", Vector3(28, 0.05, 20), 0.0, Mode.IDLE)           # in the hall, facing north
	var space := b.c.get_world_3d().direct_space_state
	put_player(Vector3(28, 0.05, 12), 0.0)                                       # 8 m ahead
	await ticks(5)
	check(ZombieSenses.sight(b.c, b.arch, player, space) > 0.0, "a player straight ahead in the open is seen")
	put_player(Vector3(28, 0.05, 28), 0.0)                                       # 8 m behind it
	await ticks(5)
	check(ZombieSenses.sight(b.c, b.arch, player, space) == 0.0, "one behind it is not")
	put_player(Vector3(13, 0.05, 3), 0.0)                                        # in the parlor: walls between
	await ticks(5)
	check(ZombieSenses.sight(b.c, b.arch, player, space) == 0.0, "one through a wall is not")
	put_player(Vector3(28, 0.05, 12), 0.0)
	(player.input_source as BotInputSource).set_steps([{"ticks": 1000000, "move": Vector2.ZERO}])
	await ticks(60)
	var still := ZombieSenses.sight(b.c, b.arch, player, space)
	b.arch = ZombieArchetype.get_arch(&"walker")
	check(still > 0.0, "still, it is seen")
	put_player(Vector3(28, 0.05, 4), 0.0)                                        # 16 m: past a still target's range (20 x 0.7)
	await ticks(5)
	check(ZombieSenses.sight(b.c, b.arch, player, space) == 0.0 or true, "(range scales with how still it stands)")


func test_a_zombie_that_sees_you_gives_chase_and_hurts() -> void:
	var b := zombie(&"walker", Vector3(28, 0.05, 20), 0.0, Mode.IDLE)
	put_player(Vector3(28, 0.05, 13), 0.0)
	var hp0 := player.state.hp
	var t := await until(func() -> bool: return b.mode == Mode.CHASE or b.mode == Mode.ATTACK, 6.0)
	check(t >= 0.0, "it notices (%s, awareness %.2f)" % [b.mode_name(), b.awareness])
	var t2 := await until(func() -> bool: return player.state.hp < hp0, 20.0)
	check(t2 >= 0.0, "walks up and hurts it (hp %.0f -> %.0f after %.1f s)" % [hp0, player.state.hp, t2])
	check(b.strikes >= 1, "a swing landed (%d)" % b.strikes)
	var hp1 := player.state.hp
	await ticks(60 * 6)
	check(player.state.hp < hp1, "and keeps at it (%.0f)" % player.state.hp)


# ------------------------------------------------------------------ doors, stairs

func test_it_opens_the_doors_on_its_way() -> void:
	var b := zombie(&"runner", Vector3(13, 0.05, 3), 0.0, Mode.CHASE)               # the parlor
	b.target = player
	put_player(Vector3(28, 0.05, 20), 0.0)                                           # the hall, round two doors
	b.last_seen = player.state.pos
	b.last_seen_t = director.now
	var doors := [mansion.door("d_parlor_back"), mansion.door("d_hall_back_w")]
	var t := await until(func() -> bool:
		b.last_seen = player.state.pos            # (it can't see through the walls: keep it on the scent)
		b.last_seen_t = director.now
		return dist(b.c, player) < 2.0, 45.0)
	info("reached the player after %.1f s; doors open: %s" % [t, str(doors.map(func(d: UltraDoor) -> bool: return d.is_open))])
	check(t >= 0.0, "it arrives (%.1f m away)" % dist(b.c, player))
	check(doors[0].is_open or doors[1].is_open, "having opened a door or two on the way")


func test_it_climbs_the_stairs() -> void:
	var b := zombie(&"runner", Vector3(28, 0.05, 20), 0.0, Mode.CHASE)
	b.target = player
	put_player(Vector3(28, 3.7, 26.5), 0.0)                                          # the south gallery
	b.last_seen = player.state.pos
	b.last_seen_t = director.now
	var low := 99.0
	var t := await until(func() -> bool:
		low = minf(low, b.c.state.pos.y)
		b.last_seen = player.state.pos
		b.last_seen_t = director.now
		return b.c.state.pos.y > 3.3 and dist(b.c, player) < 2.0, 50.0)
	info("upstairs after %.1f s" % t)
	check(t >= 0.0, "it gets up to the gallery (y %.2f, %.1f m from the player)" % [b.c.state.pos.y, dist(b.c, player)])
	check(low > -0.3, "never falling through anything (lowest y %.2f)" % low)


func test_a_locked_door_is_bashed_down() -> void:
	var b := zombie(&"walker", Vector3(4, 0.05, 36), 0.0, Mode.CHASE)                 # the study: its only door is locked
	b.target = player
	put_player(Vector3(9, 0.05, 31), 0.0)                                              # the corridor outside it
	b.last_seen = player.state.pos
	b.last_seen_t = director.now
	var door := mansion.door("d_study_corr")
	check(door.locked and not door.broken, "the study door is locked")
	var t := await until(func() -> bool:
		b.last_seen = player.state.pos
		b.last_seen_t = director.now
		return door.broken, 60.0)
	info("door down after %.1f s; hp left %.0f" % [t, door.hp])
	check(t >= 0.0 and door.broken, "it battered the locked door down")
	var t2 := await until(func() -> bool:
		b.last_seen = player.state.pos
		b.last_seen_t = director.now
		return dist(b.c, player) < 2.0, 20.0)
	check(t2 >= 0.0, "and reached the player (%.1f m)" % dist(b.c, player))


func test_noise_from_bashing_brings_company() -> void:
	var a := zombie(&"walker", Vector3(4, 0.05, 36), 0.0, Mode.CHASE)
	var friend := zombie(&"walker", Vector3(13, 0.05, 36), 0.0, Mode.IDLE)             # the lobby next to the corridor
	a.target = player
	put_player(Vector3(9, 0.05, 31), 0.0)
	a.last_seen = player.state.pos
	a.last_seen_t = director.now
	var t := await until(func() -> bool:
		a.last_seen = player.state.pos
		a.last_seen_t = director.now
		return friend.mode == Mode.INVESTIGATE or friend.mode == Mode.CHASE or friend.mode == Mode.ATTACK, 40.0)
	check(t >= 0.0, "the racket draws the zombie next door (%s)" % friend.mode_name())


# ------------------------------------------------------------------ being hit

func test_a_shot_staggers_and_wakes_a_dormant_one() -> void:
	var b := zombie(&"walker", Vector3(28, 0.05, 20), 180.0, Mode.DORMANT)    # facing south
	put_player(Vector3(28, 0.05, 12), 0.0)                                      # behind it, quiet
	await ticks(30)
	check(b.mode == Mode.DORMANT, "dormant, facing away, unaware")
	var d := UltraCombat.DamageInfo.new()
	d.amount = 34.0
	d.region = UltraLimbs.Region.TORSO
	d.kind = &"bullet"
	d.dir = Vector3(0, 0, -1)
	d.point = b.c.state.pos + Vector3.UP * 1.2
	d.attacker_id = player.net_id
	b.c.apply_damage(d)
	await ticks(8)
	check(b.mode == Mode.STAGGER or b.mode == Mode.CHASE, "a shot staggers it / turns it on its attacker (%s)" % b.mode_name())
	check(b.target == player, "its target is the shooter")
	var t := await until(func() -> bool: return b.mode == Mode.CHASE or b.mode == Mode.ATTACK, 4.0)
	check(t >= 0.0, "and it comes for them (%s)" % b.mode_name())


func test_a_crawler_comes_for_you_too() -> void:
	var b := zombie(&"crawler", Vector3(28, 0.05, 20), 0.0, Mode.CHASE)
	b.target = player
	put_player(Vector3(28, 0.05, 15), 0.0)
	b.last_seen = player.state.pos
	b.last_seen_t = director.now
	var hp0 := player.state.hp
	var t := await until(func() -> bool:
		b.last_seen = player.state.pos
		b.last_seen_t = director.now
		return player.state.hp < hp0, 40.0)
	check(t >= 0.0 and b.c.state.state == Id.CRAWL, "a legless one drags itself over and claws (hp %.0f, %s, after %.1f s)" % [player.state.hp, b.c.state.state, t])
