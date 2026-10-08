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
