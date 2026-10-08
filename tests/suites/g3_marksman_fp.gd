extends UltraTestSuite
## Marksman stage V3: body-true first person and aiming down the sights. The camera is the posed head's eye
## (MarksmanEye after the camera rig); in ADS the gun pass bends the neck toward the stock and puts the gun's sight
## line on the eye, so the rear and front sights sit on the line to the aim point.

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


func _rig(c: MarksmanCharacter) -> UltraCameraRig:
	var rig := UltraCameraRig.new()
	add_child(rig)
	rig.attach(c)
	return rig


func test_first_person_eye_and_sights() -> void:
	await _fp(false)


## The same with motion matching on.
func test_first_person_with_motion_matching() -> void:
	await _fp(true)


func _fp(mm: bool) -> void:
	load_playground()
	var c := _marksman(marker("spawn").global_position + Vector3(-16, 0, -3), mm)
	var rig := _rig(c)
	await ticks(60)
	if not check(c.eye != null, "a MarksmanEye follows the camera rig"):
		rig.queue_free()
		return
	var eq := c.get_node("Equipment") as UltraEquipmentVisual
	var gp := (c.ragdoll as MarksmanRagdoll).gun_pass
	for item: StringName in [&"rifle", &"shotgun", &"pistol"]:
		var sl := _slot(c, item)
		for crouch in [false, true]:
			var buttons := InputFrame.B_CROUCH if crouch else 0
			c.teleport(marker("spawn").global_position + Vector3(-16, 0, -3), 0.0)
			bot(c).live_yaw = 0.0
			bot(c).view_tp = false
			# At the hip.
			bot(c).set_steps([{"ticks": 200, "slot": sl, "yaw": 0.0, "pitch": -0.05, "buttons": buttons}])
			await ticks(80)
			var label := "%s%s %s" % ["MM " if mm else "", item, "crouched" if crouch else "standing"]
			var cam := rig.camera.global_position
			check(cam.distance_to(c.eye.eye) <= 0.001 and c.eye.weight > 0.99,
					"%s: the first-person camera is the head's eye (%.1f mm, weight %.2f)" % [label, cam.distance_to(c.eye.eye) * 1000.0, c.eye.weight])
			var muzzle := eq.held_node.global_transform * UltraPoseSampler.marker(eq.held_node, "M_Muzzle").origin
			check(rig.camera.is_position_in_frustum(muzzle), "%s: the muzzle is in view at the hip" % label)
			var sk := c.skeleton
			var neck := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("Neck")).origin
			var chest := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("UpperChest")).origin
			check(c.eye.eye.distance_to(neck) > 0.1 and c.eye.eye.distance_to(chest) > 0.18,
					"%s: the eye is clear of the neck and chest (%.0f / %.0f cm)" % [label, c.eye.eye.distance_to(neck) * 100.0, c.eye.eye.distance_to(chest) * 100.0])
			# Down the sights.
			bot(c).set_steps([{"ticks": 200, "slot": sl, "yaw": 0.0, "pitch": -0.05, "buttons": buttons | InputFrame.B_SECONDARY}])
			await ticks(60)
			var worst := [0.0, 0.0, 0.0]
			for k in 10:
				await get_tree().process_frame
				var cam_p := rig.camera.global_position
				var g := eq.held_node.global_transform
				var rear := g * UltraPoseSampler.marker(eq.held_node, "M_RearSight").origin
				var front := g * UltraPoseSampler.marker(eq.held_node, "M_FrontSight").origin
				var to_aim := (gp.aim_point - cam_p).normalized()
				worst[0] = maxf(worst[0], rad_to_deg((rear - cam_p).normalized().angle_to(to_aim)))
				worst[1] = maxf(worst[1], rad_to_deg((front - cam_p).normalized().angle_to(to_aim)))
				worst[2] = maxf(worst[2], cam_p.distance_to(c.eye.eye) * 1000.0)
			info("%-18s ADS %.2f: rear sight %.2f deg, front sight %.2f deg off the aim line, camera %.1f mm off the eye" % [label, eq.ads, worst[0], worst[1], worst[2]])
			check(eq.ads > 0.99, "%s: down the sights (ads %.2f)" % [label, eq.ads])
			check(worst[0] <= 0.3 and worst[1] <= 0.3, "%s: the sights on the aim line (rear %.2f, front %.2f deg)" % [label, worst[0], worst[1]])
			check(worst[2] <= 1.0, "%s: in ADS the camera is still the eye (%.1f mm)" % [label, worst[2]])
			bot(c).set_steps([{"ticks": 30, "slot": sl, "yaw": 0.0, "buttons": buttons}])
			await ticks(30)
	rig.queue_free()
