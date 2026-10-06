extends UltraTestSuite
## Melee and knockouts: blunt trauma to the head (or a heavy blow) knocks you out cold - limp,
## blacked out - for longer each time; gun-butt strikes and melee weapons (a bat that knocks
## out, a machete that cuts). OFFLINE session, so the server code paths run.

const Id := MotorState.Id
const R := UltraLimbs.Region

var c: UltraCharacter


func before_each() -> void:
	load_playground()
	UltraNet.world_root = self
	UltraNet.spawn_transform = func(_p: NetPlayer) -> Transform3D: return marker("speed_start").global_transform
	UltraNet.character_factory = func(_p: NetPlayer) -> UltraCharacter:
		var ch := UltraCharacter.new()
		ch.profile = (load("res://addons/ultra_controller/profiles/fps.tres") as MovementProfile).duplicate(true)
		ch.body_profile = load("res://assets/characters/mannequin/mannequin_body_profile.tres")
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
	await super.after_each()


func _bot() -> BotInputSource:
	return c.input_source as BotInputSource


## A dummy standing at `pos` facing `yaw`.
func dummy(pos: Vector3, yaw := 0.0) -> UltraCharacter:
	var p := UltraNet.spawn_bot("Dummy", Transform3D(Basis(Vector3.UP, yaw), pos))
	(p.character.input_source as BotInputSource).set_steps([{"ticks": 100000}])
	return p.character


func hit(t: UltraCharacter, region: int, amount: float, kind := &"blunt", dir := Vector3.FORWARD) -> void:
	var d := UltraCombat.DamageInfo.new()
	d.amount = amount
	d.region = region
	d.kind = kind
	d.dir = dir
	d.point = t.state.pos + Vector3.UP
	t.apply_damage(d)


## A blunt blow to the head knocks you out: limp, no getting up until it wears off, then up.
## A bullet of the same weight doesn't; a second knockout lasts longer.
func test_knockout() -> void:
	var t := dummy(Vector3(-24, 0.05, -70))
	await ticks(10)
	hit(t, R.HEAD, 10.0)
	await ticks(5)
	check(not t.state.has(MotorState.F_UNCONSCIOUS) and t.state.state != Id.RAGDOLL, "a light knock to the head: still up")
	hit(t, R.TORSO, 20.0, &"bullet")
	await ticks(5)
	check(not t.state.has(MotorState.F_UNCONSCIOUS), "a bullet doesn't knock out")
	hit(t, R.HEAD, 24.0)
	await ticks(2)
	var ko := t.state.ko_t
	check(t.state.state == Id.RAGDOLL and t.state.has(MotorState.F_UNCONSCIOUS), "blunt to the head: out cold (%s)" % Id.keys()[t.state.state])
	var n := 0
	while t.state.has(MotorState.F_UNCONSCIOUS) and n < 60 * 30:
		await ticks(10)
		n += 10
		if t.state.state != Id.RAGDOLL:
			break
	info("first knockout: %.1f s set, out for %.1f s" % [ko, n / 60.0])
	check(absf(n / 60.0 - ko) < 0.3, "stays down for the whole knockout (%.1f of %.1f s)" % [n / 60.0, ko])
	var m := 0
	while t.state.state != Id.IDLE and m < 60 * 10:
		await ticks(10)
		m += 10
	check(t.state.state == Id.IDLE, "comes round and gets up (%.1f s later)" % (m / 60.0))
	hit(t, R.HEAD, 24.0)
	await ticks(2)
	info("second knockout: %.1f s" % t.state.ko_t)
	check(t.state.ko_t > ko * 1.3, "a second knockout lasts longer (%.1f vs %.1f)" % [t.state.ko_t, ko])


## Knocked out, the state survives the codec (prediction / snapshots) and the HUD blacks out.
func test_knockout_blackout_and_codec() -> void:
	c.teleport(Vector3(-24, 0.05, -60), 0.0)
	await ticks(5)
	var hud := UltraHUD.new()
	hud.character = c
	add_child(hud)
	hit(c, R.HEAD, 30.0)
	await ticks(40)
	var b := StreamPeerBuffer.new()
	c.state.encode(b)
	b.seek(0)
	var copy := MotorState.new()
	copy.decode(b)
	check(copy.has(MotorState.F_UNCONSCIOUS) and absf(copy.ko_t - c.state.ko_t) < 0.002 and copy.ko_count == c.state.ko_count, "knockout state round-trips")
	info("blackout %.2f while out cold" % hud.blackout())
	check(hud.blackout() > 0.95, "the knockout screen is up (double vision, dim)")
	hud.queue_free()


func _slot(item: StringName) -> int:
	for k in c.inventory.size():
		var it := c.inventory.get_slot(k)
		if it and it.def_id == item:
			return k + 1
	return 0


## Gun-butt: the melee button with a gun up strikes what's in front - the carbine's stock to
## the head knocks a man out; a pistol whip to the body hurts and rocks him back. The strike
## finishes and the gun comes back up.
func test_gun_butt() -> void:
	var res := []
	for spec: Array in [[&"rifle", 0.0, true], [&"pistol", -0.35, false]]:
		UltraItems.give(c, spec[0])
		c.teleport(Vector3(-24, 0.05, -60), 0.0)
		var t := dummy(Vector3(-24, 0.05, -61.05), PI)
		_bot().set_steps([{"ticks": 110, "slot": _slot(spec[0]), "yaw": 0.0, "pitch": spec[1]}])
		await ticks(112)
		check(c.state.action == UltraActionLayer.Action.READY, "%s up" % spec[0])
		var hp0 := t.state.hp
		var hits := []
		t.damaged.connect(func(d: UltraCombat.DamageInfo) -> void: hits.append([UltraLimbs.Region.keys()[d.region], d.amount, String(d.kind)]))
		var seq := c.state.melee_seq
		_bot().set_steps([{"ticks": 2, "slot": _slot(spec[0]), "yaw": 0.0, "pitch": spec[1], "tap": InputFrame.B_MELEE}, {"ticks": 60, "slot": _slot(spec[0]), "yaw": 0.0, "pitch": spec[1]}])
		var saw_melee := false
		for k in 62:
			await ticks(1)
			saw_melee = saw_melee or c.state.action == UltraActionLayer.Action.MELEE

		res.append("%s: hits %s, dummy hp %.0f -> %.0f, %s%s" % [spec[0], hits, hp0, t.state.hp, Id.keys()[t.state.state], " (out cold)" if t.state.has(MotorState.F_UNCONSCIOUS) else ""])
		check(saw_melee and c.state.melee_seq != seq, "%s: a strike" % spec[0])
		check(c.state.action == UltraActionLayer.Action.READY, "%s: back up after it" % spec[0])
		check(hits.size() == 1 and hits[0][2] == "blunt", "%s: one blunt blow lands (%s)" % [spec[0], hits])
		if spec[2]:
			check(t.state.has(MotorState.F_UNCONSCIOUS), "%s stock to the head: knocked out" % spec[0])
		else:
			check(not t.state.has(MotorState.F_UNCONSCIOUS) and t.state.hp < hp0, "%s whip to the body: hurt, not out" % spec[0])
		UltraNet.despawn_bot(t.net_id)
		await ticks(3)
	info("\n  ".join(res))


## Melee weapons: the attack button swings; pressing again chains the next swing (three).
## The bat to the head knocks out; the machete takes a weakened arm off.
func test_melee_weapons() -> void:
	var res := []
	for spec: Array in [[&"bat", 0.05, R.HEAD, 0.0], [&"machete", -0.2, -1, -0.3]]:
		UltraItems.give(c, spec[0])
		c.teleport(Vector3(-24, 0.05, -60), 0.0)
		var t := dummy(Vector3(-24, 0.05, -61.1), PI)
		_bot().set_steps([{"ticks": 110, "slot": _slot(spec[0]), "yaw": 0.0, "pitch": spec[1]}])
		await ticks(112)
		check(c.state.action == UltraActionLayer.Action.READY, "%s up (%d)" % [spec[0], c.state.action])
		if spec[2] < 0:
			# Weaken its arms, and aim at one (the blade finishes it).
			t.state.limb_hp[R.ARM_L] = 10
			t.state.limb_hp[R.ARM_R] = 10
			var arm := Vector3.ZERO
			for cap in UltraHitboxes.capsules(t, t.state.pos):
				if cap.region == R.FOREARM_L:
					arm = ((cap.a as Vector3) + (cap.b as Vector3)) * 0.5
			var to := arm - (c.state.pos + Vector3.UP * (c.state.height - 0.16))
			spec[3] = atan2(-to.x, -to.z)
			spec[1] = asin(to.normalized().y)
			t.state.limb_hp[R.FOREARM_L] = 10
		var hits := []
		t.damaged.connect(func(d: UltraCombat.DamageInfo) -> void: hits.append([UltraLimbs.Region.keys()[d.region], d.amount, String(d.kind)]))
		var combos := {}
		# Pressing again and again (a press in the back half of a swing queues the next): the
		# combo runs a, b, c.
		var steps := []
		for k in 14:
			steps.append({"ticks": 2, "slot": _slot(spec[0]), "yaw": spec[3], "pitch": spec[1], "tap": InputFrame.B_PRIMARY})
			steps.append({"ticks": 8, "slot": _slot(spec[0]), "yaw": spec[3], "pitch": spec[1]})
		steps.append({"ticks": 90, "slot": _slot(spec[0]), "yaw": spec[3], "pitch": spec[1]})
		_bot().set_steps(steps)
		for k in 200:
			await ticks(1)
			if c.state.action == UltraActionLayer.Action.MELEE:
				combos[c.state.melee_combo & 0x3F] = true
		res.append("%s: swings %s, hits %s; dummy %s hp %.0f severed %d%s" % [spec[0], combos.keys(), hits, Id.keys()[t.state.state], t.state.hp, t.state.severed, " (out cold)" if t.state.has(MotorState.F_UNCONSCIOUS) else ""])
		check(combos.size() == 3, "%s: the combo chains three swings (%s)" % [spec[0], combos.keys()])
		check(hits.size() >= 1, "%s: it lands" % spec[0])
		if spec[0] == &"bat":
			check(t.state.has(MotorState.F_UNCONSCIOUS) or t.state.state == Id.DEAD, "bat to the head: knocked out")
		else:
			check(t.state.severed != 0, "machete: an arm comes off")
		UltraNet.despawn_bot(t.net_id)
		await ticks(3)
	info("\n  ".join(res))
