extends UltraTestSuite
## Marksman stage V4: firing and reloading through the body (MarksmanGunPass). A shot kicks the gun back and up in the
## hands and rocks the chest, recovering with the recoil spring; a reload keeps the gun in the hands - brought in and
## rolled to the left hand, which takes the magazine out (it drops), fetches a fresh one from the pouch and seats it,
## or loads a tube a shell at a time - and goes back onto the gun.

const Id := MotorState.Id


func _marksman(at: Vector3, mm := false) -> MarksmanCharacter:
	var c := MarksmanCharacter.new()
	c.motion_matching = mm
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
	for i in c.inventory.size():
		var it := c.inventory.get_slot(i)
		if it and it.def_id == item:
			return i + 1
	return 0


## The gun's frame as shown (world), read at skeleton_updated.
func _gun_now(eq: UltraEquipmentVisual) -> Transform3D:
	return eq.held_node.global_transform if eq.held_node else Transform3D()


func test_a_shot_goes_through_the_body() -> void:
	load_playground()
	for item: StringName in [&"rifle", &"pistol", &"shotgun"]:
		var c := _marksman(marker("spawn").global_position + Vector3(-16, 0, -3))
		await ticks(40)
		var sl := _slot(c, item)
		var eq := c.get_node("Equipment") as UltraEquipmentVisual
		var gp := (c.ragdoll as MarksmanRagdoll).gun_pass
		var sk := c.skeleton
		bot(c).set_steps([{"ticks": 90, "slot": sl, "yaw": 0.0}, {"ticks": 2, "slot": sl, "yaw": 0.0, "buttons": InputFrame.B_PRIMARY}, {"ticks": 200, "slot": sl, "yaw": 0.0}])
		await ticks(85)
		var rest := {"gun": Transform3D(), "chest": Vector3.ZERO}
		var now := {"gun": Transform3D(), "chest": Vector3.ZERO}
		var grab := func() -> void:
			now.gun = _gun_now(eq)
			now.chest = sk.global_transform * sk.get_bone_global_pose(sk.find_bone("Neck")).origin
		sk.skeleton_updated.connect(grab)
		await ticks(4)
		rest = now.duplicate()
		var back := 0.0
		var rise := 0.0
		var chest := 0.0
		var err_late := 0.0
		for i in 40:
			await ticks(1)
			var g0: Transform3D = rest.gun
			var g: Transform3D = now.gun
			var fwd0 := -g0.basis.z.normalized()
			back = maxf(back, -(g.origin - g0.origin).dot(fwd0))
			rise = maxf(rise, rad_to_deg(asin(clampf((-g.basis.z.normalized()).y, -1.0, 1.0)) - asin(clampf(fwd0.y, -1.0, 1.0))))
			chest = maxf(chest, ((rest.chest as Vector3) - (now.chest as Vector3)).dot(Vector3(fwd0.x, 0.0, fwd0.z).normalized()))
			if i >= 24:
				err_late = maxf(err_late, rad_to_deg(gp.aim_error))
		sk.skeleton_updated.disconnect(grab)
		info("%-8s shot: gun back %.1f cm, muzzle up %.1f deg, chest back %.1f cm; 0.4 s on, barrel %.2f deg off the aim" % [item, back * 100.0, rise, chest * 100.0, err_late])
		check(back > 0.01 and rise > 1.0, "%s: the shot kicks the gun back and its muzzle up in the hands (%.1f cm, %.1f deg)" % [item, back * 100.0, rise])
		check(chest > 0.003, "%s: the chest rocks back with it (%.1f cm)" % [item, chest * 100.0])
		check(err_late < 1.0, "%s: and the barrel comes back onto the aim (%.2f deg 0.4 s on)" % [item, err_late])
		chars.erase(c)
		c.queue_free()
		await ticks(3)


func test_reloads_are_done_by_hand() -> void:
	load_playground()
	for item: StringName in [&"rifle", &"pistol", &"shotgun"]:
		var c := _marksman(marker("spawn").global_position + Vector3(-16, 0, -3))
		await ticks(40)
		var sl := _slot(c, item)
		for ammo: StringName in [&"ammo_9mm", &"ammo_556", &"ammo_12g"]:
			UltraItems.give(c, ammo)
		var eq := c.get_node("Equipment") as UltraEquipmentVisual
		var gp := (c.ragdoll as MarksmanRagdoll).gun_pass
		var sk := c.skeleton
		# Empty a few rounds first (a full gun won't reload), then reload.
		bot(c).set_steps([{"ticks": 80, "slot": sl, "yaw": 0.0}, {"ticks": 40, "slot": sl, "yaw": 0.0, "buttons": InputFrame.B_PRIMARY},
				{"ticks": 30, "slot": sl, "yaw": 0.0}, {"ticks": 3, "slot": sl, "yaw": 0.0, "buttons": InputFrame.B_RELOAD}, {"ticks": 400, "slot": sl, "yaw": 0.0}])
		var hand := {"l": Vector3.ZERO, "mag": Vector3.INF}
		var grab := func() -> void:
			hand.l = sk.global_transform * sk.get_bone_global_pose(sk.find_bone("LeftHand")).origin
			var m := eq.held_node.find_child("Magazine", true, false) as Node3D if eq.held_node else null
			hand.mag = m.global_position if m and m.is_visible_in_tree() else Vector3.INF
		sk.skeleton_updated.connect(grab)
		var reloading := false
		var gun_held := 1.0
		var mag_near := 9.0
		var mag_off_gun := 0.0
		var shells := 0
		var done_at := -1
		var support_after := 9.0
		for i in 520:
			await ticks(1)
			if c.state.action == UltraActionLayer.Action.RELOADING:
				reloading = true
				gun_held = minf(gun_held, gp.weight)
				if hand.mag != Vector3.INF and eq._mag_hand != Transform3D():
					mag_near = minf(mag_near, (hand.l as Vector3).distance_to(hand.mag))
					mag_off_gun = maxf(mag_off_gun, (hand.mag as Vector3).distance_to(_gun_now(eq).origin))
				if gp._shell_mesh and gp._shell_mesh.visible:
					shells += 1
			elif reloading and done_at < 0:
				done_at = i
			if done_at >= 0 and i - done_at == 30:
				support_after = gp.support_error
				break
		sk.skeleton_updated.disconnect(grab)
		info("%-8s reload: seen %s, gun weight held >= %.2f, magazine in the left hand (%.1f cm from it, up to %.0f cm off the gun), shell frames %d, support hand %.1f cm off after" % [
				item, reloading, gun_held, mag_near * 100.0, mag_off_gun * 100.0, shells, support_after * 100.0])
		if not check(reloading, "%s: a reload ran" % item):
			chars.erase(c)
			c.queue_free()
			continue
		check(gun_held > 0.95, "%s: the gun stays in the hands through the reload (weight %.2f)" % [item, gun_held])
		if item == &"shotgun":
			check(shells > 10, "%s: shells carried to the load port by hand (%d frames)" % [item, shells])
		else:
			check(mag_off_gun > 0.1 and mag_near < 0.15, "%s: the magazine comes out in the left hand (%.0f cm off the gun, hand %.1f cm from it)" % [item, mag_off_gun * 100.0, mag_near * 100.0])
		check(support_after < 0.02, "%s: the left hand is back on the gun after (%.1f cm)" % [item, support_after * 100.0])
		chars.erase(c)
		c.queue_free()
		await ticks(3)


func _rig(c: MarksmanCharacter) -> UltraCameraRig:
	var rig := UltraCameraRig.new()
	add_child(rig)
	rig.attach(c)
	return rig


## V4b lean: the spine bends sideways - the first-person eye (the camera) goes out 25-35 cm and the shot starts there.
func test_lean_moves_the_eye_and_the_shot() -> void:
	load_playground()
	var c := _marksman(marker("spawn").global_position + Vector3(-16, 0, -3))
	var rig := _rig(c)
	await ticks(40)
	var sl := _slot(c, &"rifle")
	bot(c).view_tp = false
	bot(c).live_yaw = 0.0
	bot(c).set_steps([{"ticks": 120, "slot": sl, "yaw": 0.0}])
	await ticks(110)
	var eye0: Vector3 = c.eye.eye
	var right := Vector3(cos(0.0), 0.0, -sin(0.0))       # (yaw 0 faces -Z: right is +X)
	var origin0: Vector3 = UltraActionLayer.aim_ray(c, c.state, c.last_input, c.held_def()).origin
	for side: Array in [["right", InputFrame.B_LEAN_R, 1.0], ["left", InputFrame.B_LEAN_L, -1.0]]:
		bot(c).set_steps([{"ticks": 90, "slot": sl, "yaw": 0.0, "buttons": side[1]}])
		await ticks(80)
		var out := (c.eye.eye - eye0).dot(right) * float(side[2])
		var shot := UltraActionLayer.aim_ray(c, c.state, c.last_input, c.held_def())
		var origin_out := ((shot.origin as Vector3) - origin0).dot(right) * float(side[2])
		info("lean %s: eye out %.1f cm, shot origin out %.1f cm (camera %.1f, aim_from %s)" % [side[0], out * 100.0, origin_out * 100.0,
				(rig.camera.global_position - eye0).dot(right) * float(side[2]) * 100.0, c.last_input.aim_from])
		check(out > 0.22 and out < 0.4, "lean %s: the eye goes out round the corner (%.1f cm)" % [side[0], out * 100.0])
		check(absf(origin_out - out) < 0.05, "lean %s: the shot starts where the eye is (%.1f vs %.1f cm)" % [side[0], origin_out * 100.0, out * 100.0])
		bot(c).set_steps([{"ticks": 60, "slot": sl, "yaw": 0.0}])
		await ticks(60)
	rig.queue_free()


## V4b: up against a wall the gun comes up out of its way and won't fire; a step back and it's down and firing again.
func test_gun_tucks_at_a_wall() -> void:
	load_playground()
	var wall := marker("ledge_250").global_position          # (a 2.5 m block: its face at z - 4)
	var c := _marksman(Vector3(wall.x, 0.05, wall.z - 3.55))
	await ticks(40)
	var sl := _slot(c, &"rifle")
	var gp := (c.ragdoll as MarksmanRagdoll).gun_pass
	bot(c).set_steps([{"ticks": 100, "slot": sl, "yaw": 0.0}])
	await ticks(100)
	var t_up := -1
	for i in 30:
		await ticks(1)
		if gp.tuck_w > 0.9 and t_up < 0:
			t_up = i
	var mag0 := c.state.mag
	bot(c).set_steps([{"ticks": 40, "slot": sl, "yaw": 0.0, "buttons": InputFrame.B_PRIMARY}, {"ticks": 100, "slot": sl, "yaw": 0.0}])
	await ticks(45)
	var fired_at_wall := mag0 - c.state.mag
	info("at the wall: tucked %.2f (in %d ticks), rounds fired holding the trigger: %d" % [gp.tuck_w, t_up, fired_at_wall])
	check(t_up >= 0 and t_up <= 18, "the gun comes up out of the wall's way within 0.3 s (%d ticks)" % t_up)
	check(fired_at_wall == 0, "and it won't fire into the wall (%d rounds)" % fired_at_wall)
	# A step back.
	bot(c).set_steps([{"ticks": 40, "slot": sl, "yaw": 0.0, "move": Vector2(0, -1)}, {"ticks": 30, "slot": sl, "yaw": 0.0},
			{"ticks": 20, "slot": sl, "yaw": 0.0, "buttons": InputFrame.B_PRIMARY}, {"ticks": 60, "slot": sl, "yaw": 0.0}])
	await ticks(70)
	var tuck_back := gp.tuck_w
	mag0 = c.state.mag
	await ticks(25)
	info("stepped back: tuck %.2f, rounds fired %d" % [tuck_back, mag0 - c.state.mag])
	check(tuck_back < 0.1 and mag0 - c.state.mag > 0, "a step back: the gun's down and fires (tuck %.2f, %d rounds)" % [tuck_back, mag0 - c.state.mag])


## V4b: a reload on an empty magazine racks the bolt / slide after the new magazine is in - longer by about
## MarksmanCharacter.EMPTY_RACK, the round counted once (after the rack); a tactical reload (rounds left) doesn't.
func test_empty_reload_racks() -> void:
	load_playground()
	for item: StringName in [&"rifle", &"pistol"]:
		var took := {}
		for empty: bool in [false, true]:
			var c := _marksman(marker("spawn").global_position + Vector3(-16, 0, -3))
			await ticks(40)
			var sl := _slot(c, item)
			for ammo: StringName in [&"ammo_9mm", &"ammo_556"]:
				UltraItems.give(c, ammo)
			bot(c).set_steps([{"ticks": 80, "slot": sl, "yaw": 0.0}])
			await ticks(80)
			c.state.mag = 0 if empty else 5
			var eq := c.get_node("Equipment") as UltraEquipmentVisual
			var gp := (c.ragdoll as MarksmanRagdoll).gun_pass
			var sk := c.skeleton
			var part := eq.held_node.find_child("ChargingHandle", true, false) as Node3D
			if part == null:
				part = eq.held_node.find_child("Slide", true, false) as Node3D
			var seen := {"pull": 0.0, "back": 0.0, "hand": 9.0}
			var grab := func() -> void:
				if gp.rack_pull > 0.03:
					var lh := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("LeftHand")).origin
					seen.hand = minf(seen.hand, lh.distance_to(part.global_position))
				seen.pull = maxf(seen.pull, gp.rack_pull)
				if part and part.has_meta("rest"):
					var moved: Vector3 = (part.get_parent() as Node3D).global_transform.basis * (part.position - (part.get_meta("rest") as Vector3))
					seen.back = maxf(seen.back, moved.dot(eq.held_node.global_transform.basis.orthonormalized().z))
			sk.skeleton_updated.connect(grab)
			bot(c).set_steps([{"ticks": 3, "slot": sl, "yaw": 0.0, "buttons": InputFrame.B_RELOAD}, {"ticks": 400, "slot": sl, "yaw": 0.0}])
			var n := 0
			var mag_steps := 0
			var last_mag := c.state.mag
			var flag := false
			for i in 400:
				await ticks(1)
				if c.state.mag != last_mag:
					mag_steps += 1
					last_mag = c.state.mag
				if c.state.action == UltraActionLayer.Action.RELOADING:
					n += 1
					flag = flag or c.state.has(MarksmanCharacter.F_EMPTY_RELOAD)
				elif n > 0:
					break
			sk.skeleton_updated.disconnect(grab)
			took[empty] = n
			info("%-6s %s reload: %d ticks, magazine filled in %d step(s), empty flag %s, rack pulled %.1f cm (part back %.1f cm), hand %.1f cm from it" % [
					item, "empty" if empty else "tactical", n, mag_steps, flag, seen.pull * 100.0, seen.back * 100.0, seen.hand * 100.0])
			check(mag_steps == 1, "%s %s: the magazine is filled once (%d)" % [item, "empty" if empty else "tactical", mag_steps])
			check(flag == empty, "%s: the empty flag only on an empty reload (%s)" % [item, flag])
			if empty:
				check(seen.pull > 0.06 and seen.back > 0.05, "%s: the %s is pulled back (%.1f cm)" % [item, part.name if part else "?", seen.back * 100.0])
				check(seen.hand < 0.1, "%s: by the left hand (%.1f cm from it)" % [item, seen.hand * 100.0])
			else:
				check(seen.pull == 0.0, "%s: a tactical reload racks nothing" % item)
			chars.erase(c)
			c.queue_free()
			await ticks(3)
		var extra := (int(took[true]) - int(took[false])) / 60.0
		check(absf(extra - MarksmanCharacter.EMPTY_RACK) < 0.08, "%s: an empty reload takes %.2f s longer (%.2f)" % [item, extra, MarksmanCharacter.EMPTY_RACK])


## V4b: holding the breath (sprint held, aiming down sights, standing still) steadies the gun on the aim; after
## HOLD_TIME it runs out - shakier than plain ADS until half the breath is back, and it can't be held meanwhile.
func test_hold_breath() -> void:
	load_playground()
	var c := _marksman(marker("spawn").global_position + Vector3(-16, 0, -3))
	await ticks(40)
	var sl := _slot(c, &"rifle")
	var ads := InputFrame.B_SECONDARY
	var hold := InputFrame.B_SECONDARY | InputFrame.B_SPRINT
	var amp := func(ticks_n: int) -> float:
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for i in ticks_n:
			await ticks(1)
			lo = Vector2(minf(lo.x, c.state.sway.x), minf(lo.y, c.state.sway.y))
			hi = Vector2(maxf(hi.x, c.state.sway.x), maxf(hi.y, c.state.sway.y))
		return rad_to_deg((hi - lo).length())
	bot(c).set_steps([{"ticks": 2000, "slot": sl, "yaw": 0.0, "buttons": ads}])
	await ticks(140)
	var plain: float = await amp.call(150)
	bot(c).set_steps([{"ticks": 2000, "slot": sl, "yaw": 0.0, "buttons": hold}])
	await ticks(30)
	var held: float = await amp.call(150)
	var bt := c.profile.breath_time
	var out_at := -1
	for i in 360:
		await ticks(1)
		if c.state.has(MarksmanCharacter.F_BREATH_OUT):
			out_at = i
			break
	var held_for := (180 + out_at) / 60.0
	bot(c).set_steps([{"ticks": 2000, "slot": sl, "yaw": 0.0, "buttons": ads}])
	var gasp: float = await amp.call(60)
	var back_at := -1
	for i in 600:
		await ticks(1)
		if not c.state.has(MarksmanCharacter.F_BREATH_OUT):
			back_at = i
			break
	info("sway in ADS %.3f deg, holding the breath %.3f deg; it ran out after %.1f s (breath %.1f / %.0f), out of breath %.3f deg, back after %.1f s more" % [
			plain, held, held_for, c.state.breath, bt, gasp, (60 + back_at) / 60.0])
	check(held < plain * 0.5, "holding the breath steadies the gun (%.3f vs %.3f deg)" % [held, plain])
	check(out_at >= 0 and absf(held_for - MarksmanCharacter.HOLD_TIME) < 0.6, "it runs out after ~%.0f s (%.1f)" % [MarksmanCharacter.HOLD_TIME, held_for])
	check(gasp > plain * 1.5, "out of breath the aim shakes (%.3f vs %.3f deg)" % [gasp, plain])
	check(back_at >= 0, "and settles once half the breath is back")
	chars.erase(c)
	c.queue_free()


## V4b freelook (MarksmanFreelook, `marksman_freelook`): held, the mouse turns the view and the head, not the aim - the
## shot goes where it did; let go and the view comes back onto the aim. (The bot's yaw_rate stands in for the mouse.)
func test_freelook_turns_the_head_not_the_aim() -> void:
	load_playground()
	var c := _marksman(marker("spawn").global_position + Vector3(-16, 0, -3))
	var rig := _rig(c)
	await ticks(40)
	var sl := _slot(c, &"rifle")
	bot(c).view_tp = false
	bot(c).set_steps([{"ticks": 100, "slot": sl, "yaw": 0.0}])
	await ticks(100)
	for i in 60:
		if c.eye and is_instance_valid(c.eye) and c.eye.freelook:
			break
		await ticks(1)
	if not check(c.eye != null and c.eye.freelook != null, "the first-person eye has a freelook"):
		rig.queue_free()
		return
	var fl := c.eye.freelook
	var sk := c.skeleton
	var yaw_of := func(v: Vector3) -> float: return atan2(-v.x, -v.z)
	var head_yaw := func() -> float:
		var neck := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("Neck")).origin
		var e := c.eye.eye - neck
		return atan2(-e.x, -e.z)
	var shot0 := UltraActionLayer.aim_ray(c, c.state, c.last_input, c.held_def())
	var head0: float = head_yaw.call()
	fl.force = true
	bot(c).set_steps([{"ticks": 60, "slot": sl, "yaw_rate": 1.2}, {"ticks": 200, "slot": sl}])
	await ticks(60)
	var cam_yaw: float = yaw_of.call(-rig.camera.global_transform.basis.z)
	var shot := UltraActionLayer.aim_ray(c, c.state, c.last_input, c.held_def())
	var shot_turn := (shot0.dir as Vector3).angle_to(shot.dir)
	var head_turn := angle_difference(head0, head_yaw.call())
	info("freelook: view off the aim %.2f rad (camera yaw %.2f), aim yaw %.3f, shot turned %.3f rad, head turned %.2f rad" % [
			fl.offset.x, cam_yaw, c.last_input.yaw, shot_turn, head_turn])
	check(fl.offset.x > 0.9 and absf(angle_difference(c.last_input.yaw, cam_yaw) - fl.offset.x) < 0.1, "the view turns (%.2f rad off the aim)" % fl.offset.x)
	check(absf(angle_difference(0.0, c.last_input.yaw)) < 0.03 and shot_turn < 0.04, "the aim and the shot stay (aim %.3f, shot %.3f rad)" % [c.last_input.yaw, shot_turn])
	check(head_turn > 0.6, "the head turns with the view (%.2f rad)" % head_turn)
	fl.force = false
	await ticks(40)
	cam_yaw = yaw_of.call(-rig.camera.global_transform.basis.z)
	info("let go: view off the aim %.3f rad, camera yaw %.3f, aim %.3f" % [fl.offset.x, cam_yaw, c.last_input.yaw])
	check(fl.offset.length() < 0.05 and absf(angle_difference(c.last_input.yaw, cam_yaw)) < 0.06, "let go, the view is back on the aim")
	rig.queue_free()
	chars.erase(c)
	c.queue_free()


## Leaning, the gun goes over with the body: its top cants the way of the lean and it moves out that way with the eye
## (the user: "leaning to the right - the gun needs to lean to the right too, currently it goes left. left lean is
## correct"). Rifle and pistol, at the hip and in ADS, first person.
func test_gun_leans_with_the_body() -> void:
	load_playground()
	var bad := []
	for item: StringName in [&"rifle", &"pistol"]:
		var c := _marksman(marker("spawn").global_position + Vector3(-16, 0, -3))
		var rig := _rig(c)
		await ticks(40)
		var sl := _slot(c, item)
		var eq := c.get_node("Equipment") as UltraEquipmentVisual
		bot(c).view_tp = false
		bot(c).live_yaw = 0.0
		for ads: int in [0, InputFrame.B_SECONDARY]:
			bot(c).set_steps([{"ticks": 120, "slot": sl, "yaw": 0.0, "buttons": ads}])
			await ticks(110)
			var g0 := eq.held_node.global_transform
			var e0: Vector3 = c.eye.eye
			var right := Vector3(1, 0, 0)          # (yaw 0 faces -Z: right is +X)
			for side: Array in [["right", InputFrame.B_LEAN_R, 1.0], ["left", InputFrame.B_LEAN_L, -1.0]]:
				bot(c).set_steps([{"ticks": 90, "slot": sl, "yaw": 0.0, "buttons": side[1] | ads}])
				await ticks(80)
				var g := eq.held_node.global_transform
				# Cant: the gun's up axis tipped toward the view's right (deg, + = top to the right), against unleaned.
				var up0 := g0.basis.y.normalized()
				var up := g.basis.y.normalized()
				var cant := rad_to_deg(asin(clampf(up.dot(right), -1.0, 1.0)) - asin(clampf(up0.dot(right), -1.0, 1.0)))
				var moved := (g.origin - g0.origin).dot(right)
				var eye := (c.eye.eye - e0).dot(right)
				var label := "%-7s %s lean %-5s" % [item, "ADS" if ads else "hip", side[0]]
				info("%s: gun cant %+.1f deg, gun out %+.1f cm, eye out %+.1f cm" % [label, cant, moved * 100.0, eye * 100.0])
				var s: float = side[2]
				if cant * s < 3.0:
					bad.append("%s: the gun cants %+.1f deg (the other way / not at all)" % [label, cant])
				if moved * s < 0.1:
					bad.append("%s: the gun moves %+.1f cm (should go out with the lean)" % [label, moved * 100.0])
				bot(c).set_steps([{"ticks": 60, "slot": sl, "yaw": 0.0, "buttons": ads}])
				await ticks(60)
		rig.queue_free()
		chars.erase(c)
		c.queue_free()
		await ticks(3)
	check(bad.is_empty(), "the gun leans with the body both ways (%s)" % "; ".join(bad))
