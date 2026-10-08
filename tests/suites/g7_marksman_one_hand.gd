extends UltraTestSuite
## Marksman stage V6: one working arm (an arm crippled or lost - UltraInjury.weapon_hand / two_hands, the sim's say). The
## gun goes to the hand that works (the equipment re-attaches it; MarksmanGunPass works on that side), the other arm hangs
## limp (MarksmanRagdoll: physical at LIMP_TONE) or is gone. A pistol is held out on the one arm, a long gun braced under
## it (no ADS); a reload pins the gun against the body while the hand does the work, 1.8x slower (UltraInjury.reload_mult).

const G6 := preload("res://tests/suites/g6_marksman_arms.gd")
const R := UltraLimbs.Region


func _marksman(at: Vector3) -> MarksmanCharacter:
	var c := MarksmanCharacter.new()
	c.motion_matching = true
	c.profile = (load("res://addons/ultra_controller/profiles/fps.tres") as MovementProfile).duplicate(true)
	c.body_profile = CharacterModels.body_profile("mannequin")
	c.build_visuals = true
	var b := BotInputSource.new()
	b.name = "InputSource"
	c.add_child(b)
	c.input_source = b
	c.position = at
	add_child(c)
	b.body = c
	chars.append(c)
	return c


func _slot(c: MarksmanCharacter, item: StringName) -> int:
	UltraItems.give(c, item)
	for ammo: StringName in [&"ammo_9mm", &"ammo_556", &"ammo_12g"]:
		UltraItems.give(c, ammo, 200)
	for i in c.inventory.size():
		var it := c.inventory.get_slot(i)
		if it and it.def_id == item:
			return i + 1
	return 0


func _cripple(c: UltraCharacter, left: bool) -> void:
	c.state.limb_hp[R.FOREARM_L if left else R.FOREARM_R] = 0


func _heal(c: UltraCharacter) -> void:
	c.state.severed = 0
	for r in UltraLimbs.COUNT:
		c.state.limb_hp[r] = 100


func _bone(sk: Skeleton3D, n: String) -> Vector3:
	return sk.global_transform * sk.get_bone_global_pose(sk.find_bone(n)).origin


func _part_w(c: MarksmanCharacter, n: String) -> float:
	var rg := c.ragdoll as MarksmanRagdoll
	var i := rg._part(n)
	return rg.part_w[i] if i >= 0 and i < rg.part_w.size() else -1.0


func _done(c: MarksmanCharacter) -> void:
	chars.erase(c)
	c.queue_free()
	await ticks(3)


## Holds with one arm: the gun in the working hand, on the aim; the other arm limp and off the gun; a long gun's stock
## braced under the arm and outside the body; the gun arm out of the body.
func test_one_handed_holds() -> void:
	load_playground()
	var bad := []
	var cases := [[&"pistol", true], [&"rifle", true], [&"pistol", false], [&"rifle", false], [&"shotgun", false]]
	for cs: Array in cases:
		var item: StringName = cs[0]
		var left_out: bool = cs[1]
		var c := _marksman(marker("spawn").global_position + Vector3(-16, 0, -3))
		await ticks(40)
		var sl := _slot(c, item)
		_cripple(c, left_out)
		var eq := c.get_node("Equipment") as UltraEquipmentVisual
		var gp := (c.ragdoll as MarksmanRagdoll).gun_pass
		var sk := c.skeleton
		var gun_side := "Right" if left_out else "Left"
		var off_side := "Left" if left_out else "Right"
		var label := "%-8s %s arm out" % [item, off_side.to_lower()]
		for walk in [false, true]:
			var step := {"ticks": 400, "slot": sl, "yaw": 0.0}
			if walk:
				step["move"] = Vector2(0, 1)
			bot(c).set_steps([step])
			await ticks(150 if not walk else 60)
			var m := {"err": 0.0, "off_hand": 9.0, "stock": 0.0, "stock_in": 0.0, "limp": 1.0, "depth": 0.0, "limp_depth": 0.0, "nan": false}
			var probe := func() -> void:
				if eq.held_node == null:
					return
				var g := eq.held_node.global_transform
				if not g.origin.is_finite():
					m.nan = true
				m.err = maxf(m.err, rad_to_deg(gp.aim_error))
				m.off_hand = minf(m.off_hand, _bone(sk, off_side + "Hand").distance_to(g.origin))
				m.limp = minf(m.limp, _part_w(c, off_side + "LowerArm"))
				var f := G6.torso_frame(sk)
				for p in [_bone(sk, gun_side + "LowerArm"), _bone(sk, gun_side + "Hand")]:
					m.depth = maxf(m.depth, G6.depth(f, p))
				# (The limp arm hangs at the side, not into the belly.)
				for p in [_bone(sk, off_side + "LowerArm"), _bone(sk, off_side + "Hand")]:
					m.limp_depth = maxf(m.limp_depth, G6.depth(f, p))
				if gp._has_stock:
					var st_w := g * gp._stock_local.origin
					var pk := sk.global_transform * gp.pocket
					m.stock = maxf(m.stock, st_w.distance_to(pk))
					m.stock_in = maxf(m.stock_in, G6.depth(f, st_w))
			sk.skeleton_updated.connect(probe)
			await ticks(60)
			sk.skeleton_updated.disconnect(probe)
			var attach := String(eq.held_node.get_parent().name) if eq.held_node else "-"
			var row := "%s %s: in %s, barrel %.2f deg, off hand %.0f cm from the gun, off forearm physics %.2f, gun arm in body %.1f cm, limp arm %.1f cm" % [
					label, "walking" if walk else "standing", attach, m.err, m.off_hand * 100.0, m.limp, m.depth * 100.0, m.limp_depth * 100.0]
			if gp._has_stock:
				row += ", stock %.1f cm off the armpit point (%.1f cm in the body)" % [m.stock * 100.0, m.stock_in * 100.0]
			info(row)
			if m.nan:
				bad.append("%s: NaN" % label)
			if attach != gun_side + "HandAttach":
				bad.append("%s: gun in %s" % [label, attach])
			if m.err > (2.0 if not walk else 3.0):
				bad.append("%s: barrel %.2f deg off" % [label, m.err])
			if m.off_hand < 0.15:
				bad.append("%s: the limp hand %.0f cm from the gun" % [label, m.off_hand * 100.0])
			if m.limp < 0.9:
				bad.append("%s: the off arm isn't limp (%.2f)" % [label, m.limp])
			if m.depth > 0.02:
				bad.append("%s: gun arm %.1f cm in the body" % [label, m.depth * 100.0])
			if m.limp_depth > 0.02:
				bad.append("%s: limp arm %.1f cm in the body" % [label, m.limp_depth * 100.0])
			if gp._has_stock and (m.stock > 0.05 or m.stock_in > 0.01):
				bad.append("%s: stock %.1f cm off the armpit, %.1f cm in the body" % [label, m.stock * 100.0, m.stock_in * 100.0])
		await _done(c)
	check(bad.is_empty(), "one-handed holds: gun in the working hand, on the aim, the other arm limp (%s)" % "; ".join(bad.slice(0, 10)))


## A lost hand takes the gun to the other one (severed: no limp arm to show - its pieces are gone; no NaN).
func test_lost_hand_shoots_left() -> void:
	load_playground()
	var c := _marksman(marker("spawn").global_position + Vector3(-16, 0, -3))
	await ticks(40)
	var sl := _slot(c, &"pistol")
	var eq := c.get_node("Equipment") as UltraEquipmentVisual
	var gp := (c.ragdoll as MarksmanRagdoll).gun_pass
	bot(c).set_steps([{"ticks": 400, "slot": sl, "yaw": 0.0}])
	await ticks(100)
	var d := UltraCombat.DamageInfo.new()
	d.amount = 400.0
	d.region = R.HAND_R
	d.kind = &"blade"
	d.dir = Vector3(1, 0, 0)
	d.point = c.state.pos + Vector3.UP * 1.0
	c.apply_damage(d)
	c.state.hp = 100.0
	await ticks(120)
	var errs := []
	var probe := func() -> void: errs.append(rad_to_deg(gp.aim_error))
	c.skeleton.skeleton_updated.connect(probe)
	await ticks(30)
	c.skeleton.skeleton_updated.disconnect(probe)
	var attach := String(eq.held_node.get_parent().name) if eq.held_node else "-"
	var worst: float = errs.max() if not errs.is_empty() else 99.0
	info("right hand %s: weapon hand %d, gun in %s, barrel %.2f deg" % [UltraLimbs.STATUS_NAMES[UltraLimbs.status(c.state, R.HAND_R)], UltraInjury.weapon_hand(c.state), attach, worst])
	check(UltraInjury.weapon_hand(c.state) == -1 and attach == "LeftHandAttach", "a lost right hand: the gun in the left (%s)" % attach)
	check(worst < 2.0, "and on the aim (%.2f deg)" % worst)
	await _done(c)


## Reloading one-handed: slower, the gun pinned against the body (steady on the chest, not in the hand) while the hand
## fetches the magazine / shells, then back in the hand and on the aim.
func test_one_handed_reloads() -> void:
	load_playground()
	var bad := []
	for cs: Array in [[&"rifle", true], [&"pistol", true], [&"rifle", false], [&"pistol", false], [&"shotgun", true]]:
		var item: StringName = cs[0]
		var left_out: bool = cs[1]
		var c := _marksman(marker("spawn").global_position + Vector3(-16, 0, -3))
		await ticks(40)
		var sl := _slot(c, item)
		_cripple(c, left_out)
		var eq := c.get_node("Equipment") as UltraEquipmentVisual
		var gp := (c.ragdoll as MarksmanRagdoll).gun_pass
		var sk := c.skeleton
		var gun_side := "Right" if left_out else "Left"
		var label := "%-8s %s hand" % [item, gun_side.to_lower()]
		bot(c).set_steps([{"ticks": 150, "slot": sl, "yaw": 0.0}])
		await ticks(150)
		c.state.mag = 2
		bot(c).set_steps([{"ticks": 3, "slot": sl, "yaw": 0.0, "buttons": InputFrame.B_RELOAD}, {"ticks": 900, "slot": sl, "yaw": 0.0}])
		var m := {"pinned": 0, "pin_drift": 0.0, "pin0": Vector3.INF, "mag_hand": 9.0, "mag_off": 0.0, "shells": 0, "nan": false, "depth": 0.0}
		var probe := func() -> void:
			if eq.held_node == null:
				return
			var g := eq.held_node.global_transform
			if not g.origin.is_finite():
				m.nan = true
			var chest := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("UpperChest"))
			var hand := _bone(sk, gun_side + "Hand")
			if gp.pinned:
				m.pinned += 1
				var rel: Vector3 = chest.affine_inverse() * g.origin
				if m.pin0 == Vector3.INF:
					m.pin0 = rel
				m.pin_drift = maxf(m.pin_drift, rel.distance_to(m.pin0))
				var f := G6.torso_frame(sk)
				m.depth = maxf(m.depth, G6.depth(f, _bone(sk, gun_side + "LowerArm")))
			var mag := eq.held_node.find_child("Magazine", true, false) as Node3D
			if mag and mag.is_visible_in_tree() and eq._mag_hand != Transform3D():
				m.mag_hand = minf(m.mag_hand, hand.distance_to(mag.global_position))
				m.mag_off = maxf(m.mag_off, mag.global_position.distance_to(g.origin))
			if gp._shell_mesh and gp._shell_mesh.visible:
				m.shells += 1
		sk.skeleton_updated.connect(probe)
		var started := -1
		var ended := -1
		for i in 900:
			await ticks(1)
			if c.state.action == UltraActionLayer.Action.RELOADING:
				if started < 0:
					started = i
			elif started >= 0:
				ended = i
				break
		await ticks(60)
		sk.skeleton_updated.disconnect(probe)
		var after_err := rad_to_deg(gp.aim_error)
		var top := eq.held_node.top_level if eq.held_node else true
		var secs := float(ended - started) / 60.0
		var def := eq.held_def
		var plain := float(def.stat("reload_time", 2.0)) if String(def.stat("reload_mode", "")) != "shell" else 0.0
		info("%s reload: %.2f s (plain %.2f), pinned %d frames (drift on the chest %.1f cm, gun forearm in the body %.1f cm), magazine %.1f cm from the hand / up to %.0f cm off the gun, shell frames %d; 1 s after: in the hand %s, barrel %.2f deg" % [
				label, secs, plain, m.pinned, m.pin_drift * 100.0, m.depth * 100.0, m.mag_hand * 100.0, m.mag_off * 100.0, m.shells, not top, after_err])
		if started < 0 or ended < 0:
			bad.append("%s: no reload / never ended" % label)
		if m.nan:
			bad.append("%s: NaN" % label)
		if plain > 0.0 and secs < plain * 1.6:
			bad.append("%s: not slower (%.2f s)" % [label, secs])
		if m.pinned < 30:
			bad.append("%s: the gun was never pinned (%d frames)" % [label, m.pinned])
		if m.pin_drift > 0.1:
			bad.append("%s: the pinned gun drifted %.1f cm on the chest" % [label, m.pin_drift * 100.0])
		if item == &"shotgun":
			if m.shells < 10:
				bad.append("%s: no shells carried (%d)" % [label, m.shells])
		elif m.mag_hand > 0.15 or m.mag_off < 0.1:
			bad.append("%s: the magazine isn't taken out by hand (%.1f cm from it, %.0f cm off the gun)" % [label, m.mag_hand * 100.0, m.mag_off * 100.0])
		if top or after_err > 2.0:
			bad.append("%s: not back in the hand on the aim (pinned %s, %.2f deg)" % [label, top, after_err])
		await _done(c)
	check(bad.is_empty(), "one-handed reloads: slower, gun pinned, magazine by hand, back on the aim (%s)" % "; ".join(bad.slice(0, 10)))


## The gun arm crippled mid-aim: the gun goes over to the other hand without a NaN or a pop of the body, and is back on
## the aim within a second.
func test_switching_hands_mid_hold() -> void:
	load_playground()
	var bad := []
	for item: StringName in [&"rifle", &"pistol"]:
		var c := _marksman(marker("spawn").global_position + Vector3(-16, 0, -3))
		await ticks(40)
		var sl := _slot(c, item)
		var eq := c.get_node("Equipment") as UltraEquipmentVisual
		var gp := (c.ragdoll as MarksmanRagdoll).gun_pass
		var sk := c.skeleton
		bot(c).set_steps([{"ticks": 600, "slot": sl, "yaw": 0.0}])
		await ticks(150)
		var bones := ["Hips", "Spine", "Chest", "UpperChest", "Neck", "Head", "LeftUpperArm", "RightUpperArm", "LeftLowerArm", "RightLowerArm"]
		var last := {}
		var m := {"jump": 0.0, "nan": false}
		var probe := func() -> void:
			for b: String in bones:
				var p := sk.get_bone_global_pose(sk.find_bone(b)).origin
				if not p.is_finite():
					m.nan = true
				if last.has(b):
					m.jump = maxf(m.jump, p.distance_to(last[b]))
				last[b] = p
		sk.skeleton_updated.connect(probe)
		await ticks(5)
		_cripple(c, false)
		var back_at := -1
		for i in 90:
			await ticks(1)
			if back_at < 0 and i > 5 and gp.weight > 0.95 and rad_to_deg(gp.aim_error) < 2.0:
				back_at = i
		sk.skeleton_updated.disconnect(probe)
		var attach := String(eq.held_node.get_parent().name) if eq.held_node else "-"
		info("%-8s right arm crippled mid-aim: gun in %s, back on the aim after %d ticks, biggest bone jump %.1f cm" % [item, attach, back_at, m.jump * 100.0])
		if m.nan or attach != "LeftHandAttach" or back_at < 0 or back_at > 60 or m.jump > 0.1:
			bad.append("%s: nan %s, %s, back %d, jump %.1f cm" % [item, m.nan, attach, back_at, m.jump * 100.0])
		await _done(c)
	check(bad.is_empty(), "the gun goes over to the other hand smoothly (%s)" % "; ".join(bad))


## Which hand is a pure function of the replicated limb statuses: a remote copy (pack -> unpack) agrees.
func test_hand_agrees_after_replication() -> void:
	var bad := []
	for setup: Array in [[], [R.FOREARM_R], [R.FOREARM_L], [R.HAND_R], [R.ARM_L, R.HAND_R]]:
		var s := MotorState.new()
		for r: int in setup:
			s.limb_hp[r] = 0
		var bits := UltraLimbs.pack(s)
		var s2 := MotorState.new()
		UltraLimbs.unpack_into(s2, bits)
		var a := [UltraInjury.weapon_hand(s), UltraInjury.two_hands(s)]
		var b := [UltraInjury.weapon_hand(s2), UltraInjury.two_hands(s2)]
		if a != b:
			bad.append("%s: %s vs %s" % [setup, a, b])
	check(bad.is_empty(), "weapon hand / two hands agree after replication (%s)" % "; ".join(bad))
