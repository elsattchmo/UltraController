extends UltraTestSuite
## Wounds and their feedback: a held melee block, a shot through the heart, a shotgun blast
## that opens the torso, the dropped magazine on a reload, tunnel vision while bleeding and
## the death recap. OFFLINE session, so the server code paths run.

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


func _bot(ch: UltraCharacter) -> BotInputSource:
	return ch.input_source as BotInputSource


func _slot(ch: UltraCharacter, item: StringName) -> int:
	for k in ch.inventory.size():
		var it := ch.inventory.get_slot(k)
		if it and it.def_id == item:
			return k + 1
	return 0


func dummy(pos: Vector3, yaw := 0.0) -> UltraCharacter:
	var p := UltraNet.spawn_bot("Dummy", Transform3D(Basis(Vector3.UP, yaw), pos))
	_bot(p.character).set_steps([{"ticks": 100000}])
	return p.character


func blow(t: UltraCharacter, amount: float, dir: Vector3, kind := &"blade", melee := true, region := R.TORSO) -> void:
	var d := UltraCombat.DamageInfo.new()
	d.amount = amount
	d.region = region
	d.kind = kind
	d.melee = melee
	d.dir = dir
	d.point = t.state.pos + Vector3.UP * 1.2
	d.attacker_id = c.net_id
	t.apply_damage(d)


## Holding a melee weapon up with the secondary button blocks most of a melee blow from the
## front (no knockout); from behind it doesn't help, nor against a bullet.
func test_block() -> void:
	var t := dummy(Vector3(-24, 0.05, -70), 0.0)          # facing -Z
	UltraItems.give(t, &"machete", 1)
	await ticks(5)
	_bot(t).set_steps([{"ticks": 100000, "slot": _slot(t, &"machete"), "buttons": InputFrame.B_SECONDARY}])
	await ticks(60)
	check(t.state.has(MotorState.F_BLOCKING), "secondary with a machete up: blocking")
	var hp0 := t.state.hp
	blow(t, 40.0, Vector3(0, 0, 1))                         # coming at its face (travelling +Z)
	var front := hp0 - t.state.hp
	hp0 = t.state.hp
	blow(t, 40.0, Vector3(0, 0, -1))                        # from behind
	var back := hp0 - t.state.hp
	hp0 = t.state.hp
	blow(t, 10.0, Vector3(0, 0, 1), &"bullet", false)
	var shot := hp0 - t.state.hp
	info("blocked blow %.1f hp, from behind %.1f, a bullet %.1f" % [front, back, shot])
	check(front > 0.0 and front <= 40.0 * 0.25, "a blow on the block: ~20 %% (%.1f)" % front)
	check(back > 30.0, "from behind: the full blow (%.1f)" % back)
	check(shot > 5.0, "bullets aren't blocked (%.1f)" % shot)
	await ticks(5)
	var hp1 := t.state.hp
	blow(t, 30.0, Vector3(0, 0, 1), &"blunt", true, R.HEAD)
	check(not t.state.has(MotorState.F_UNCONSCIOUS), "a blocked blow to the head doesn't knock out")
	check(hp1 - t.state.hp < 15.0, "and barely hurts")
	_bot(t).set_steps([{"ticks": 100000, "slot": _slot(t, &"machete")}])
	await ticks(10)
	check(not t.state.has(MotorState.F_BLOCKING), "let go of secondary: not blocking")


## A shot through the heart (a small target in the chest, on the shot's line) bleeds out fast;
## a torso shot that misses it doesn't.
func test_heart_shot() -> void:
	var t := dummy(Vector3(-24, 0.05, -70), 0.0)
	await ticks(30)
	var heart := UltraHitboxes.heart(t, t.state.pos)
	check(heart != Vector3.INF, "the dummy has a heart")
	var rifle := ItemDB.get_def(&"rifle")
	# Off to the side of the chest first: no heart.
	var miss := heart + Vector3(0.12, 0.0, 0.0)
	UltraCombat.hitscan(c, miss + Vector3(0, 0, -3), Vector3(0, 0, 1), rifle)
	check(not t.state.has(MotorState.F_HEART), "a chest shot past the heart: no heart wound")
	UltraCombat.hitscan(c, heart + Vector3(0, 0, -3), Vector3(0, 0, 1), rifle)
	check(t.state.has(MotorState.F_HEART), "through the heart: F_HEART")
	var rate := UltraInjury.bleed_rate(t.state, t.damage_profile)
	check(rate >= t.damage_profile.heart_bleed_rate, "bleeding %.1f hp/s" % rate)
	var n := 0
	while t.state.state != Id.DEAD and n < 60 * 20:
		await ticks(30)
		n += 30
	info("dead %.1f s after the heart shot (hp left after the hit decided it)" % (n / 60.0))
	check(t.state.state == Id.DEAD and n < 60 * 12, "bleeds out within seconds")


## Buckshot point blank into the torso: chunks off it, a wound on it, guts hanging out.
func test_shotgun_opens_the_torso() -> void:
	var t := dummy(Vector3(-24, 0.05, -70), 0.0)
	await ticks(30)
	var sg := ItemDB.get_def(&"shotgun")
	var chest := t.state.pos + Vector3.UP * 1.25
	var dirs := []
	for k in 9:
		dirs.append(Vector3(randf_range(-0.01, 0.01), randf_range(-0.01, 0.01), 1.0).normalized())
	UltraCombat.hitscan_pellets(c, chest + Vector3(0, 0, -1.5), dirs, sg)
	await ticks(20)
	var guts := 0
	for n in get_tree().root.find_children("*", "UltraGuts", true, false):
		guts += 1
	info("torso blast: %d gore nodes, %d gut strands, %d gibs" % [t.body_fx._gore.size(), guts, get_tree().get_nodes_in_group(&"ultra_gib").size()])
	check(t.body_fx._gore.size() > 0, "a wound on the torso")
	check(guts > 0, "guts out")
	check(get_tree().get_nodes_in_group(&"ultra_gib").size() >= 2, "chunks flew")


## A magazine reload drops the old magazine (a physics copy) out of the gun.
func test_reload_drops_the_mag() -> void:
	UltraItems.give(c, &"rifle", 1)
	UltraItems.give(c, &"ammo_556", 60)
	await ticks(3)
	var sl := _slot(c, &"rifle")
	_bot(c).set_steps([{"ticks": 60, "slot": sl}])
	await ticks(60)
	c.state.mag = 2
	var fx := UltraEffects.new()            # (no effects node in a test world otherwise)
	add_child(fx)
	await ticks(1)
	var before := fx._mags.size() if fx else 0
	_bot(c).set_steps([{"ticks": 2, "slot": sl, "buttons": InputFrame.B_RELOAD}, {"ticks": 200, "slot": sl}])
	await ticks(150)
	var after := fx._mags.size() if fx else 0
	info("magazines on the ground: %d -> %d" % [before, after])
	check(after > before, "the old magazine dropped")
	fx.queue_free()


## Bleeding closes the view in (tunnel vision); a kill cuts to black and lists how you died.
func test_tunnel_vision_and_death_recap() -> void:
	var hud := UltraHUD.new()
	hud.character = c
	add_child(hud)
	await ticks(5)
	var dmg := UltraCombat.DamageInfo.new()
	dmg.amount = 120.0
	dmg.region = R.THIGH_L
	dmg.kind = &"blade"
	dmg.dir = Vector3.FORWARD
	dmg.point = c.state.pos + Vector3.UP * 0.6
	var t := dummy(Vector3(-24, 0.05, -70), 0.0)
	await ticks(5)
	dmg.attacker_id = t.net_id
	c.state.hp = 100.0
	c.apply_damage(dmg)
	await ticks(150)
	var scr := hud.damage_screen()
	info("leg off: hp %.0f, tunnel %.2f" % [c.state.hp, scr.tunnel_amount()])
	check(scr.tunnel_amount() > 0.3, "bleeding: tunnel vision (%.2f)" % scr.tunnel_amount())
	var kill := UltraCombat.DamageInfo.new()
	kill.amount = 200.0
	kill.region = R.HEAD
	kill.kind = &"bullet"
	kill.dir = Vector3.FORWARD
	kill.point = c.state.pos + Vector3.UP * 1.7
	kill.attacker_id = t.net_id
	c.apply_damage(kill)
	await ticks(60)
	var text := scr.recap_text()
	info("recap:\n" + text)
	check(scr.death_shown() > 0.95, "cut to black")
	check(text.contains("Killed by") and text.contains("head"), "the killing hit, and where")
	check(text.contains("thigh L"), "the earlier wound")
	check(text.contains("Blood lost"), "the bleeding")
	hud.queue_free()
