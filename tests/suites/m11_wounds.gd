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


## Bullet fly-bys: the closer the round passes, the sharper set (close / mid / far); none
## past WHIZ_RADIUS or for the shooter's own rounds.
func test_whiz_by_distance() -> void:
	var fx := UltraEffects.new()
	add_child(fx)
	await ticks(1)
	var sfx := fx.sfx
	sfx.listener_override = Vector3(0, 1.6, 0)
	var got := []
	for miss: float in [0.5, 2.0, 4.5, 8.0]:
		sfx.last_whiz = ""
		sfx.whiz(Vector3(miss, 1.6, -40), Vector3(0, 0, 1), 100.0, false)
		got.append(sfx.last_whiz)
	info("fly-bys at 0.5 / 2 / 4.5 / 8 m: %s" % [got])
	check(got == ["whiz_close", "whiz_mid", "whiz_far", ""], "close / mid / far / none (%s)" % [got])
	sfx.last_whiz = ""
	sfx.whiz(Vector3(0.5, 1.6, -40), Vector3(0, 0, 1), 100.0, true)
	check(sfx.last_whiz == "", "your own rounds don't whiz past you")
	for n in ["whiz_close", "whiz_mid", "whiz_far"]:
		check(not sfx.streams(n).is_empty(), "%s has sounds" % n)
	fx.queue_free()


## A machine gun burst: each round's attack, then once it stops the ring-out; a distant gun
## uses the far render.
func test_auto_fire_sound() -> void:
	var fx := UltraEffects.new()
	add_child(fx)
	await ticks(1)
	var sfx := fx.sfx
	sfx.listener_override = Vector3.ZERO
	sfx.played.clear()
	for k in 5:
		sfx.shot(Vector3(0, 0, -2), "rifle", 7)
		await get_tree().create_timer(0.09).timeout
	await get_tree().create_timer(0.4).timeout
	var near := sfx.played.duplicate()
	info("burst close by: %s" % [near])
	check(near.count("rifle_fire_auto") == 5 and near.has("rifle_fire_tail"), "5 attacks then the tail")
	sfx.played.clear()
	sfx.shot(Vector3(0, 0, -200), "pistol", 8)
	await get_tree().create_timer(0.8).timeout
	info("a pistol 200 m off: %s" % [sfx.played])
	check(sfx.played.has("pistol_fire_far") and not sfx.played.has("pistol_fire"), "far away: only the far render")
	check(not sfx.streams("pistol_fire_far").is_empty() and not sfx.streams("rifle_fire_tail_far").is_empty(), "the far renders exist")
	fx.queue_free()


## Buckshot at range: the pattern opens up and each pellet does less.
func test_shotgun_falls_off_at_range() -> void:
	var sg := ItemDB.get_def(&"shotgun")
	var out := []
	for dist: float in [4.0, 12.0]:
		var t := dummy(Vector3(-24 + (4.0 if dist > 10.0 else 0.0), 0.05, -70), 0.0)
		await ticks(30)
		var chest := t.state.pos + Vector3.UP * 1.25
		var dirs := UltraActionLayer.pellet_dirs(c, c.state, Vector3(0, 0, 1), sg, 9)
		var hp0 := t.state.hp
		var hits := UltraCombat.hitscan_pellets(c, chest + Vector3(0, 0, -dist), dirs, sg)
		await ticks(2)
		var on_t := 0
		for h: Dictionary in hits:
			if UltraCharacter.of_collider(h.collider) == t:
				on_t += 1
		out.append([dist, on_t, hp0 - t.state.hp])
		await ticks(5)
	info("4 m: %d pellets on him, %.0f hp | 12 m: %d pellets, %.0f hp" % [out[0][1], out[0][2], out[1][1], out[1][2]])
	check(out[1][1] < out[0][1], "fewer pellets land at 12 m")
	check(out[1][2] > 0.0 and out[1][2] < 45.0, "far less damage at 12 m (%.0f)" % out[1][2])
	check(is_equal_approx(UltraCombat.falloff([[5.0, 1.0], [12.0, 0.55], [25.0, 0.3]], 25.0), 0.3), "falloff points")


## Rounds fly: they take time to get there (muzzle velocity, drag) and fall (gravity) - a
## pistol aimed level at a dummy 60 m off lands about 0.18 s later and ~15 cm low; the
## carbine's faster round, sooner and flatter.
func test_bullet_flight_and_drop() -> void:
	var t := dummy(Vector3(-24, 0.05, -70), 0.0)
	await ticks(30)
	var got := []
	var cb := func(pos: Vector3, _n: Vector3, kind: StringName, _sid: int) -> void:
		if kind == &"flesh":
			got.append(pos)
	UltraNet.world.on_event(&"impact", cb)
	var res := {}
	for gun: StringName in [&"pistol", &"rifle"]:
		var def := ItemDB.get_def(gun)
		var aim := t.state.pos + Vector3.UP * 1.3
		var from := aim + Vector3(0, 0, 60.0)
		got.clear()
		var b := UltraBallistics.instance(get_tree())
		b.fire(c, from, [Vector3(0, 0, -1)], def)
		var n := 0
		while got.is_empty() and n < 120:
			await get_tree().physics_frame
			n += 1
		var y: float = (got[0] as Vector3).y if not got.is_empty() else INF
		res[gun] = [n / 60.0, aim.y - y]
		info("%s at 60 m: landed after %.3f s, %.3f m low" % [gun, n / 60.0, aim.y - y])
	UltraNet.world.off_event(&"impact", cb)
	check(float(res.pistol[0]) > 0.14 and float(res.pistol[0]) < 0.26, "the pistol round takes ~0.18 s")
	check(float(res.pistol[1]) > 0.08 and float(res.pistol[1]) < 0.3, "and drops ~15 cm")
	check(float(res.rifle[0]) < float(res.pistol[0]) * 0.6 and float(res.rifle[1]) < float(res.pistol[1]) * 0.4, "the carbine: sooner and flatter")


## Hands and feet are their own regions: cut one off and the rest of the limb stays; losing the
## weapon hand moves the weapon to the other; losing a foot puts you on the ground; the
## stumps and the parts get a cut-end mesh (not a ball).
func test_hand_and_foot_come_off() -> void:
	var t := dummy(Vector3(-24, 0.05, -70), 0.0)
	await ticks(30)
	blow(t, 60.0, Vector3(0, 0, 1), &"blade", true, R.HAND_R)
	await ticks(10)
	check((t.state.severed >> R.HAND_R) & 1 == 1, "the right hand came off")
	check((t.state.severed >> R.FOREARM_R) & 1 == 0, "the forearm stayed on")
	check(UltraInjury.weapon_hand(t.state) == -1, "the weapon goes to the left hand")
	# The pre-cut pieces (UltraCutBody): the hand piece hidden, the wrist's fitted end shown
	# right where the hand was, the forearm still on.
	var sk := t.skeleton
	var stump := sk.get_node_or_null("Cut_Cap_HAND_R_stump") as MeshInstance3D
	var hand := sk.get_node_or_null("Cut_Seg_HAND_R") as MeshInstance3D
	var fore := sk.get_node_or_null("Cut_Seg_FOREARM_R") as MeshInstance3D
	check(stump != null and stump.visible, "the wrist's cut end shows")
	check(hand != null and not hand.visible and fore != null and fore.visible, "hand piece gone, forearm on")
	check(not t.body_mesh().visible, "the one-piece body is swapped out")
	if stump:
		var tris: Array = []
		t.body_fx._collect_tris(stump, -1, tris)
		var mid := Vector3.ZERO
		for tr: Array in tris:
			mid += (tr[0] + tr[1] + tr[2]) / 3.0
		mid /= maxi(tris.size(), 1)
		var wrist := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("RightHand")).origin
		check(mid.distance_to(wrist) < 0.05, "the cut end sits on the wrist (%.3f m off)" % mid.distance_to(wrist))
	var gib_caps := 0
	for g in get_tree().get_nodes_in_group(&"ultra_gib"):
		for mi in (g as Node).find_children("*", "MeshInstance3D", true, false):
			var m := (mi as MeshInstance3D).mesh
			if m and m.get_surface_count() >= 3:          # skin + fat + meat + bone...
				gib_caps += 1
	check(gib_caps >= 1, "the hand that came off has its cut end")
	blow(t, 60.0, Vector3(0, 0, 1), &"blade", true, R.FOOT_L)
	await ticks(20)
	check((t.state.severed >> R.FOOT_L) & 1 == 1 and (t.state.severed >> R.SHIN_L) & 1 == 0, "a foot off, the shin on")
	check(UltraInjury.must_crawl(t.state), "no foot to stand on: down on the ground")
	info("hand + foot off: %s" % UltraLimbs.describe(t.state))


## A flying round (speed, drop) through the heart still finds it.
func test_heart_shot_with_a_flying_round() -> void:
	var t := dummy(Vector3(-24, 0.05, -70), 0.0)
	await ticks(30)
	var heart := UltraHitboxes.heart(t, t.state.pos)
	# 15 m off, aimed up by the drop over that flight (~0.05 cm at 880 m/s - negligible).
	UltraBallistics.instance(get_tree()).fire(c, heart + Vector3(0, 0.0015, -15.0), [Vector3(0, 0, 1)], ItemDB.get_def(&"rifle"))
	await ticks(10)
	check(t.state.has(MotorState.F_HEART), "a carbine round through the heart at 15 m")


## A point-blank blast through the middle that kills: the body comes apart at the waist - the
## two halves (pre-cut, sealed) shown, the ragdoll's spine let go so the halves part, guts out.
func test_blast_through_the_waist_halves_the_body() -> void:
	var t := dummy(Vector3(-24, 0.05, -70), 0.0)
	await ticks(30)
	var aim := t.state.pos + Vector3.UP * 1.05
	var from := aim + Vector3(0, 0, -0.5)
	var dirs := []
	for i in 9:
		dirs.append((aim - from).normalized())
	UltraCombat.hitscan_pellets(c, from, dirs, ItemDB.get_def(&"shotgun"))
	await ticks(5)
	check(t.state.state == MotorState.Id.DEAD, "killed")
	var cuts := t.body_fx.cuts
	check(cuts != null and cuts.torso == UltraCutBody.Torso.HALVED, "blown in two")
	var shown := []
	for n: String in cuts.parts:
		if (cuts.parts[n] as MeshInstance3D).visible:
			shown.append(n)
	info("shown: %s" % [shown])
	check("Seg_WAIST_UP" in shown and "Seg_WAIST_DOWN" in shown and "Cap_WAIST_up" in shown and "Seg_HEAD" in shown, "both halves, sealed, the rest on")
	check(t.ragdoll.split, "the ragdoll's spine let go")
	await ticks(90)
	var rd := t.ragdoll
	var pbs := {}
	for pb in rd.bones:
		pbs[pb.bone_name] = pb
	# (The physical bodies: the skeleton's posed bones only read right at skeleton_updated.)
	var gap := (pbs["Spine"] as Node3D).global_position.distance_to((pbs["Chest"] as Node3D).global_position)
	check(gap > 0.4 and gap < 6.0, "the halves came apart (%.2f m between the bodies, 0.15 joined)" % gap)
	var neck := (pbs["Chest"] as Node3D).global_position.distance_to((pbs["Head"] as Node3D).global_position)
	var hip := (pbs["Spine"] as Node3D).global_position.distance_to((pbs["Hips"] as Node3D).global_position)
	check(neck < 0.5 and hip < 0.3, "each half holds together (chest-head %.2f, spine-hips %.2f)" % [neck, hip])

	var guts := 0
	for n in get_tree().root.find_children("*", "UltraGuts", true, false):
		guts += 1
	check(guts >= 4, "guts out of both halves (%d)" % guts)


## A blast into the belly from the front opens it (the pre-cut cavity), guts hang out of it.
func test_belly_blast_opens_the_cavity() -> void:
	var t := dummy(Vector3(-20, 0.05, -70), 0.0)
	await ticks(30)
	t.body_fx.torso_blast(t.state.pos + Vector3(0, 1.0, -0.14), Vector3(0, 0, 1), 60.0)
	await ticks(5)
	var cuts := t.body_fx.cuts
	check(cuts != null and cuts.torso == UltraCutBody.Torso.OPEN, "the belly is open")
	var open := cuts.part("Seg_TORSO_OPEN")
	check(open != null and open.visible and not cuts.part("Seg_TORSO").visible, "the opened torso shown")
	if open:
		var mats := []
		for si in open.mesh.get_surface_count():
			var m := open.get_active_material(si) as BaseMaterial3D
			mats.append("%s %s a%.2f" % [open.mesh.surface_get_material(si).resource_name if open.mesh.surface_get_material(si) else "-", m.transparency if m else -1, m.albedo_color.a if m else -1.0])
		info("surfaces: %s" % [mats])
	# The guts hang out of it, down the front - not up, not inside the body.
	await ticks(120)
	var top := -INF
	var inside := 0
	var caps: Array = t.body_fx.body_capsules()
	for g in get_tree().root.find_children("*", "UltraGuts", true, false):
		var gu := g as UltraGuts
		for i in range(gu.free_links, gu._p.size() - (gu.free_links if gu.anchor_b else 0)):
			var p: Vector3 = gu._p[i]
			top = maxf(top, p.y - t.state.pos.y)
			for c: Array in caps:
				var a: Vector3 = c[0]
				var ab: Vector3 = (c[1] as Vector3) - a
				var tt := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-8), 0.0, 1.0)
				if (p - (a + ab * tt)).length() < (c[2] as float) - 0.01:
					inside += 1
	info("guts: highest point %.2f m up, %d points inside the body" % [top, inside])
	check(top < 1.2, "the guts hang down (highest %.2f m)" % top)
	check(inside == 0, "no gut inside the body (%d points)" % inside)


## Halving is a one-off: after a respawn the body is whole again - a later death by a pistol
## round leaves it in one piece (the ragdoll's spine joint back, no skin stretched across).
func test_halved_body_is_whole_after_respawn() -> void:
	var t := dummy(Vector3(-28, 0.05, -70), 0.0)
	await ticks(30)
	var aim := t.state.pos + Vector3.UP * 1.05
	var dirs := []
	for i in 9:
		dirs.append(Vector3(0, 0, 1))
	UltraCombat.hitscan_pellets(c, aim + Vector3(0, 0, -0.5), dirs, ItemDB.get_def(&"shotgun"))
	await ticks(40)
	check(t.ragdoll.split, "halved first")
	t.respawn(Transform3D(Basis(), Vector3(-28, 0.05, -70)))
	await ticks(40)
	check(not t.ragdoll.split and (t.body_fx.cuts == null or not t.body_fx.cuts.active), "whole again after the respawn")
	for i in 6:
		UltraCombat.hitscan(c, t.state.pos + Vector3(0, 1.1, -3), Vector3(0, 0, 1), ItemDB.get_def(&"pistol"))
		await ticks(3)
	check(t.state.state == MotorState.Id.DEAD, "shot dead with a pistol")
	await ticks(90)
	check(not t.ragdoll.split, "not halved by a pistol")
	var pbs := {}
	for pb in t.ragdoll.bones:
		pbs[pb.bone_name] = pb
	var gap := (pbs["Spine"] as Node3D).global_position.distance_to((pbs["Chest"] as Node3D).global_position)
	check(gap < 0.25, "the spine holds together (%.2f m)" % gap)


## Only a blast at point blank INTO THE WAIST halves: the same load from 6 m opens the belly
## (from the front) and throws the body; point blank into the head or the chest doesn't halve.
func test_halving_needs_close_and_the_waist() -> void:
	var cases := [["far waist", 1.05, 6.0], ["close head", 1.62, 0.6], ["close chest", 1.38, 0.5]]
	var x := -40.0
	for cs: Array in cases:
		var t := dummy(Vector3(x, 0.05, -70), 0.0)
		x -= 4.0
		await ticks(30)
		var aim: Vector3 = t.state.pos + Vector3.UP * float(cs[1])
		var dirs := []
		for i in 9:
			dirs.append(Vector3(0, 0, 1))
		var start := t.state.pos
		UltraCombat.hitscan_pellets(c, aim + Vector3(0, 0, -float(cs[2])), dirs, ItemDB.get_def(&"shotgun"))
		await ticks(45)
		var cuts := t.body_fx.cuts
		var halved := cuts != null and cuts.torso == UltraCutBody.Torso.HALVED
		info("%s: dead %s, halved %s, torso %s, moved %.1f m" % [cs[0], t.state.state == MotorState.Id.DEAD, halved, cuts.torso if cuts else -1, t.state.pos.distance_to(start)])
		check(not halved and not t.ragdoll.split, "%s: not halved" % cs[0])
		if cs[0] == "far waist":
			check(cuts != null and cuts.torso == UltraCutBody.Torso.OPEN, "far waist: the belly opened")
			check(t.state.pos.distance_to(start) > 0.8, "far waist: thrown back")


## Halving mustn't bog the game down: the dozen guts it hangs out cost little while they swing
## and nothing once they lie still (they sleep). (Whole-frame times in this scene are too noisy
## to compare.)
func test_halving_is_cheap() -> void:
	var t := dummy(Vector3(-56, 0.05, -70), 0.0)
	await ticks(60)
	var aim := t.state.pos + Vector3.UP * 1.05
	var dirs := []
	for i in 9:
		dirs.append(Vector3(0, 0, 1))
	var t0 := Time.get_ticks_usec()
	UltraCombat.hitscan_pellets(c, aim + Vector3(0, 0, -0.5), dirs, ItemDB.get_def(&"shotgun"))
	await get_tree().process_frame
	await get_tree().process_frame
	info("the halving frames: %.1f ms" % ((Time.get_ticks_usec() - t0) / 1000.0))
	var mine := func() -> Array:
		var out := []
		for g in get_tree().root.find_children("*", "UltraGuts", true, false):
			var gu := g as UltraGuts
			if is_instance_valid(gu.anchor) and t.is_ancestor_of(gu.anchor):
				out.append(gu)
		return out
	var cost := func() -> float:
		var sum := 0.0
		for gu: UltraGuts in mine.call():
			sum += gu.cost_us
			gu.cost_us = 0
		return sum
	cost.call()
	await _frame_cost(60)
	var moving: float = cost.call() / 60000.0
	await ticks(110)                     # (the dummy respawns 5 s after dying: gore cleared)
	cost.call()
	await _frame_cost(40)
	var still: float = cost.call() / 40000.0
	var asleep := 0
	var all: Array = mine.call()
	for g: UltraGuts in all:
		if g._asleep:
			asleep += 1
	info("guts: %.2f ms a frame swinging, %.2f ms lying still (%d of %d asleep)" % [moving, still, asleep, all.size()])
	check(moving < 5.0, "swinging guts cost < 5 ms a frame (%.2f)" % moving)
	check(still < 0.5, "guts lying still cost next to nothing (%.2f ms)" % still)


func _frame_cost(n: int) -> float:
	var sum := 0.0
	for i in n:
		await get_tree().process_frame
		sum += Performance.get_monitor(Performance.TIME_PROCESS) + Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
	return sum / n * 1000.0
