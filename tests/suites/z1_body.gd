extends UltraTestSuite
## Zombie stage 1: the body. A zombie is a lite-tier bot (ZombieFactory): it walks at its
## archetype's speed, crawls without legs, soaks body shots and dies to the head, loses limbs to
## the damage we deal, limps on a ruined leg. OFFLINE session on a flat floor, so the server code
## paths run; visual cases build the real Romero body.

const Id := MotorState.Id
const R := UltraLimbs.Region

var c: UltraCharacter                 ## the attacker (a mannequin, no body)
var _floor: StaticBody3D
var _visuals := false


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
	UltraNet.spawn_transform = func(_p: NetPlayer) -> Transform3D: return Transform3D(Basis(), Vector3(0, 0.05, 20))
	UltraNet.character_factory = func(p: NetPlayer) -> UltraCharacter:
		if ZombieFactory.is_zombie(p):
			return ZombieFactory.make(p, _visuals)
		var ch := UltraCharacter.new()
		ch.profile = (load("res://addons/ultra_controller/profiles/fps.tres") as MovementProfile).duplicate(true)
		ch.body_profile = load("res://assets/characters/mannequin/mannequin_body_profile.tres")
		ch.build_visuals = false
		return ch
	UltraNet.local_input_factory = func(_i: int) -> InputSource: return BotInputSource.new()
	UltraNet.start_offline(1)
	c = UltraNet.local_players[0].character
	(c.input_source as BotInputSource).body = c
	await ticks(3)


func after_each() -> void:
	for g in get_tree().get_nodes_in_group(&"ultra_gib"):
		g.queue_free()
	UltraNet.stop()
	UltraNet.character_factory = Callable()
	UltraNet.local_input_factory = Callable()
	UltraNet.spawn_transform = Callable()
	if is_instance_valid(_floor):
		_floor.queue_free()
	await super.after_each()


var _n := 0


## A zombie of `arch` at `pos` facing -Z (its bot idle).
func zombie(arch: StringName, pos := Vector3(0, 0.05, 0), yaw := 0.0, visuals := false) -> UltraCharacter:
	_visuals = visuals
	_n += 1
	var p := UltraNet.spawn_bot(ZombieFactory.name_for(arch, _n), Transform3D(Basis(Vector3.UP, yaw), pos))
	_visuals = false
	ZombieFactory.dress(p.character)
	(p.character.input_source as BotInputSource).set_steps([{"ticks": 100000, "yaw": yaw}])
	return p.character


func walk(z: UltraCharacter, n: int, move := Vector2(0, 1.0), buttons := 0) -> void:
	var b := z.input_source as BotInputSource
	b.set_steps([{"ticks": n + 100000, "move": move, "yaw": z.state.body_yaw, "buttons": buttons}])
	await ticks(n)


func hit(t: UltraCharacter, amount: float, region: int, kind := &"bullet", dir := Vector3(0, 0, 1)) -> void:
	var d := UltraCombat.DamageInfo.new()
	d.amount = amount
	d.region = region
	d.kind = kind
	d.melee = kind in [&"blade", &"blunt"]
	d.dir = dir
	d.point = t.state.pos + Vector3.UP * 1.2
	d.attacker_id = c.net_id
	t.apply_damage(d)


# ------------------------------------------------------------------ the body

func test_lite_body_builds() -> void:
	var z := zombie(&"walker", Vector3(0, 0.05, 0), 0.0, true)
	await ticks(10)
	check(z.anim is UltraLiteAnimDriver, "a zombie gets the lite animation driver")
	check(z.skeleton != null and z.body_fx != null and z.ragdoll != null, "skeleton, body FX and ragdoll exist")
	check(z.get_node_or_null("Equipment") == null and z.get_node_or_null("TraversalHands") == null, "no equipment / traversal visuals")
	check(z.skeleton.find_child("HandIK", false, false) == null and z.skeleton.find_child("BodyDynamics", false, false) == null, "no IK / dynamics modifiers on the skeleton")
	check(z.anim.foot_ik != null, "foot IK stays (stairs)")
	check(z.body_node.find_child("BodyMesh", true, false) != null, "BodyMesh found")
	var tree := z.anim.tree as AnimationTree
	check(tree != null and tree.active, "animation tree active")
	check(String(tree.root_motion_track) == "", "no root motion track (no Root bone)")


func test_walks_at_archetype_speed() -> void:
	var z := zombie(&"walker", Vector3(0, 0.05, 0), 0.0, true)
	await ticks(10)
	await walk(z, 150)
	var arch := ZombieArchetype.get_arch(&"walker")
	near(hspeed(z), arch.walk_speed, 0.08, "walker's ground speed")
	check(z.state.state == Id.MOVE, "state MOVE (%d)" % z.state.state)
	var a := z.anim as UltraLiteAnimDriver
	check(a._cur_loco == "ground", "anim in the ground node (%s)" % a._cur_loco)
	var rate := float(a.tree.get("parameters/loco/ground/walk_ts/scale"))
	near(rate, hspeed(z) / a.anim_set.speed_of(&"walk_f", 1.0), 0.15, "walk clip rate follows speed")
	check(float(a.tree.get("parameters/loco/ground/b_walk/blend_amount")) > 0.9, "walk blended in")


func test_a_gait_variant_does_not_re_clip_the_walkers() -> void:
	var walker := ZombieFactory._body_for(ZombieArchetype.get_arch(&"walker"))
	var before = walker.anim_set.roles[&"walk_f"]
	var shambler := ZombieFactory._body_for(ZombieArchetype.get_arch(&"shambler"))
	check(shambler.anim_set.roles[&"walk_f"] != before, "the shambler walks with its own clip")
	check(walker.anim_set.roles[&"walk_f"] == before, "and the walkers keep theirs")


func test_runner_sprints() -> void:
	var z := zombie(&"runner")
	await ticks(10)
	await walk(z, 180, Vector2(0, 1), InputFrame.B_SPRINT)
	var arch := ZombieArchetype.get_arch(&"runner")
	check(hspeed(z) > arch.run_speed - 0.25, "runner at %.2f m/s (wants %.2f)" % [hspeed(z), arch.run_speed])


func test_crawler_crawls() -> void:
	var z := zombie(&"crawler", Vector3(0, 0.05, 0), 0.0, true)
	await ticks(30)
	check(z.state.state == Id.CRAWL, "a legless zombie is crawling (state %d)" % z.state.state)
	await walk(z, 150)
	var arch := ZombieArchetype.get_arch(&"crawler")
	near(hspeed(z), arch.crawl_speed, 0.1, "crawl speed")
	var a := z.anim as UltraLiteAnimDriver
	check(a._cur_loco == "crawl", "anim in the crawl node (%s)" % a._cur_loco)
	check(float(a.tree.get("parameters/loco/crawl/mix/blend_amount")) > 0.8, "crawl cycle blended in")
	check(UltraInjury.must_crawl(z.state), "must_crawl")


func test_limper_limps() -> void:
	var z := zombie(&"limper", Vector3(0, 0.05, 0), 0.0, true)
	await ticks(10)
	await walk(z, 150)
	var a := z.anim as UltraLiteAnimDriver
	check(a.limp > 0.9, "a ruined leg: limp %.2f" % a.limp)
	check(float(a.tree.get("parameters/loco/ground/b_limp/blend_amount")) > 0.5, "limp clip blended in")
	check(hspeed(z) < ZombieArchetype.get_arch(&"limper").walk_speed, "slower on the bad leg (%.2f)" % hspeed(z))


# ------------------------------------------------------------------ damage

## Shots (of `amount` each, to `region`) until a fresh zombie of `arch` is dead; 99 = never.
func _shots_to_kill(arch: StringName, amount: float, region: int, kind := &"bullet") -> int:
	var z := zombie(arch)
	await ticks(5)
	var n := 0
	while z.state.state != Id.DEAD and n < 99:
		hit(z, amount, region, kind)
		n += 1
		await ticks(3)
	return n


func test_damage_matrix() -> void:
	var rows := []
	var table := {}
	for w: Array in [["pistol", 34.0], ["carbine", 30.0]]:
		for r: Array in [["head", R.HEAD], ["torso", R.TORSO], ["thigh", R.THIGH_L], ["forearm", R.FOREARM_R]]:
			var n: int = await _shots_to_kill(&"walker", w[1], r[1])
			table["%s %s" % [w[0], r[0]]] = n
			rows.append("%s to the %s: %s" % [w[0], r[0], str(n) if n < 99 else "never"])
	info("shots to kill a walker\n  " + "\n  ".join(rows))
	check(table["pistol head"] <= 3 and table["pistol head"] >= 2, "two or three pistol headshots (%d)" % table["pistol head"])
	check(table["carbine head"] <= 3 and table["carbine head"] >= 2, "two or three carbine headshots (%d)" % table["carbine head"])
	check(table["pistol torso"] >= 8 and table["pistol torso"] <= 14, "a body takes many pistol shots (%d)" % table["pistol torso"])
	check(table["carbine torso"] >= 8 and table["carbine torso"] <= 16, "... and carbine shots (%d)" % table["carbine torso"])
	check(table["pistol thigh"] >= 20 and table["pistol forearm"] >= 20, "limb shots alone barely hurt it (%d, %d)" % [table["pistol thigh"], table["pistol forearm"]])
	var brute: int = await _shots_to_kill(&"brute", 34.0, R.HEAD)
	check(brute > table["pistol head"], "a brute's head takes more than a walker's (%d vs %d)" % [brute, table["pistol head"]])


func test_limbs_come_off() -> void:
	var z := zombie(&"walker")
	await ticks(5)
	hit(z, 60.0, R.FOREARM_R, &"blade")
	check((z.state.severed >> R.FOREARM_R) & 1 == 1, "a blade takes off a forearm")
	check(z.state.state != Id.DEAD, "a forearm off doesn't kill it")
	hit(z, 90.0, R.THIGH_L, &"blade")
	check((z.state.severed >> R.THIGH_L) & 1 == 1, "a hard blade blow takes off a leg")
	await ticks(60)
	check(UltraInjury.must_crawl(z.state), "a leg gone: it must crawl")
	await ticks(60 * 8)
	check(z.state.state == Id.CRAWL, "it ends up crawling (state %d)" % z.state.state)
	check(z.state.state != Id.DEAD, "alive")


func test_undead_do_not_bleed_out() -> void:
	var z := zombie(&"walker")
	await ticks(5)
	hit(z, 60.0, R.ARM_L, &"blade")
	hit(z, 60.0, R.ARM_R, &"blade")
	var hp0 := z.state.hp
	await ticks(60 * 12)
	near(z.state.hp, hp0, 0.2, "no bleeding out with both arms gone")
	check(z.state.state != Id.DEAD, "still up")


func test_no_knockout_but_a_shove_knocks_down() -> void:
	var z := zombie(&"walker")
	await ticks(5)
	hit(z, 80.0, R.HEAD, &"blunt")
	check(not z.state.has(MotorState.F_UNCONSCIOUS), "a blow to the head doesn't knock a zombie out")
	var b := zombie(&"brute", Vector3(4, 0.05, 0))
	await ticks(60 * 5)
	var d := UltraCombat.DamageInfo.new()
	d.amount = 5.0
	d.region = R.TORSO
	d.kind = &"buckshot"
	d.dir = Vector3(0, 0, 1)
	d.shove = Vector3(0, 0, 5.0)
	d.point = b.state.pos + Vector3.UP
	b.apply_damage(d)
	check(b.state.state != Id.RAGDOLL, "a brute stays on its feet under a 5 m/s shove")
	var w := zombie(&"walker", Vector3(-4, 0.05, 0))
	await ticks(60 * 5)
	d.point = w.state.pos + Vector3.UP
	w.apply_damage(d)
	check(w.state.state == Id.RAGDOLL, "a walker goes down under it (state %d)" % w.state.state)


# ------------------------------------------------------------------ cut in half

func _waist_point(t: UltraCharacter) -> Vector3:
	for cp: Dictionary in UltraHitboxes.capsules(t, t.state.pos):
		if cp.region == R.TORSO:
			return (cp.a as Vector3).lerp(cp.b as Vector3, 0.72)
	return t.state.pos + Vector3.UP * 1.0


func _blast_at(t: UltraCharacter, at: Vector3, from_dist: float) -> void:
	var from := at + Vector3(0, 0, -from_dist)
	var dirs := []
	for i in 9:
		dirs.append(((at - from).normalized() + Vector3(randf_range(-0.01, 0.01), randf_range(-0.01, 0.01), 0)).normalized())
	UltraCombat.hitscan_pellets(c, from, dirs, ItemDB.get_def(&"shotgun"))


func test_cut_in_half_and_alive() -> void:
	var z := zombie(&"walker", Vector3(0, 0.05, 0), 0.0, true)
	await ticks(30)
	var gibs0 := get_tree().get_nodes_in_group(&"ultra_gib").size()
	_blast_at(z, _waist_point(z), 1.0)
	await ticks(10)
	check(z.state.has(MotorState.F_HALVED), "a blast through the waist halves it (F_HALVED)")
	check(z.state.state != Id.DEAD, "... and it is alive")
	check(z.state.hp <= z.damage_profile.halved_hp_cap + 0.01 and z.state.hp > 0.0, "health capped (%.1f)" % z.state.hp)
	check((z.state.severed >> R.THIGH_L) & 1 == 1 and (z.state.severed >> R.THIGH_R) & 1 == 1, "both legs gone with the lower half")
	check(z.body_fx.cuts != null and z.body_fx.cuts.torso == UltraCutBody.Torso.UPPER, "only the upper half is shown")
	check(get_tree().get_nodes_in_group(&"ultra_gib").size() > gibs0, "the lower half flew off as a gib")
	for n: String in ["Seg_WAIST_UP", "Cap_WAIST_up"]:
		check(z.body_fx.cuts.part(n) != null and z.body_fx.cuts.part(n).visible, n + " shown")
	for n: String in ["Seg_WAIST_DOWN", "Seg_THIGH_L", "Seg_SHIN_R", "Seg_TORSO"]:
		check(z.body_fx.cuts.part(n) == null or not z.body_fx.cuts.part(n).visible, n + " hidden")
	# The hit volume follows: the torso capsule starts at the waist, no leg capsules.
	var legs := 0
	var low := 99.0
	for cp: Dictionary in UltraHitboxes.capsules(z, z.state.pos):
		if cp.region in [R.THIGH_L, R.THIGH_R, R.SHIN_L, R.SHIN_R, R.FOOT_L, R.FOOT_R]:
			legs += 1
	check(legs == 0, "no leg capsules")
	await ticks(60 * 9)
	check(z.state.state == Id.CRAWL, "the upper half crawls (state %d)" % z.state.state)
	check(UltraInjury.must_crawl(z.state), "must_crawl")
	var p0 := z.state.pos
	await walk(z, 120)
	check(z.state.pos.distance_to(p0) > 0.3, "and gets about (%.2f m)" % z.state.pos.distance_to(p0))
	# A shot to the head still kills it.
	hit(z, 34.0, R.HEAD)
	hit(z, 34.0, R.HEAD)
	check(z.state.state == Id.DEAD, "two headshots kill the upper half")
	# Respawned: whole again.
	UltraNet.respawn_character(z)
	await ticks(30)
	check(not z.state.has(MotorState.F_HALVED) and z.state.severed == 0, "respawn: flag and limbs back")
	check(z.body_fx.cuts.torso == UltraCutBody.Torso.WHOLE, "respawn: the body is whole again")


func test_a_blade_halves_a_zombie_but_not_a_player() -> void:
	var z := zombie(&"walker")
	await ticks(10)
	var d := UltraCombat.DamageInfo.new()
	d.amount = 70.0
	d.region = R.TORSO
	d.kind = &"blade"
	d.melee = true
	d.dir = Vector3(0, 0, 1)
	d.point = _waist_point(z)
	d.attacker_id = c.net_id
	z.apply_damage(d)
	check(z.state.has(MotorState.F_HALVED), "a machete swing through the waist halves a zombie")
	# Too far from the waist: not.
	var y := zombie(&"walker", Vector3(5, 0.05, 0))
	await ticks(10)
	d.point = y.state.pos + Vector3.UP * 1.5
	y.apply_damage(d)
	check(not y.state.has(MotorState.F_HALVED), "a blow to the chest doesn't")
	# The player's profile never survives it.
	check(not c.damage_profile.halve_survives, "a player isn't undead")


func test_halve_far_away_does_not() -> void:
	var z := zombie(&"walker")
	await ticks(10)
	var sg := ItemDB.get_def(&"shotgun")
	var at := _waist_point(z)
	var from := at + Vector3(0, 0, -6.0)
	var dirs := []
	for i in 9:
		dirs.append((at - from).normalized())
	UltraCombat.hitscan_pellets(c, from, dirs, sg)
	await ticks(5)
	check(not z.state.has(MotorState.F_HALVED), "a blast from 6 m doesn't halve it")


# ------------------------------------------------------------------ health bars

func test_health_bar_shows_after_a_hit_and_fades() -> void:
	var bars := UltraWorldBars.new()
	add_child(bars)
	var z := zombie(&"walker")
	await ticks(10)
	check(bars.shown == 0, "an unhurt zombie shows no bar")
	hit(z, 34.0, R.TORSO)
	await ticks(4)
	check(bars.shown == 1, "a hurt one does (%d)" % bars.shown)
	# The bar's custom data carries the fill: hp / 100.
	var fill: float = bars._buf[12]
	near(fill, z.state.hp / 100.0, 0.02, "the bar's fill is its health")
	await ticks(60 * 6)
	check(bars.shown == 0, "and it fades away again (%d)" % bars.shown)
	hit(z, 5.0, R.TORSO)
	await ticks(4)
	check(bars.shown == 1, "a new hit brings it back")
	hit(z, 80.0, R.HEAD)
	await ticks(60 * 3)
	check(bars.shown == 0, "a dead zombie's bar is gone")
	bars.queue_free()
