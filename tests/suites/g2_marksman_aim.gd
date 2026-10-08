extends UltraTestSuite
## Marksman stage V2: holding and aiming a two-handed gun. The gun pass (MarksmanGunPass) points the barrel at the
## aim point with the body and puts the support hand back on the gun. Measured on the shown skeleton (at
## skeleton_updated), independent of the pass's own numbers: the barrel (-Z of the right hand x the grip) against the
## line from the muzzle to the aim point, the support hand against its grip, the arm parts animated (kinematic).

const MOVES := {"standing": Vector2.ZERO, "walking": Vector2(0, 1), "strafing": Vector2(1, 0)}
const PITCHES := [-0.35, 0.0, 0.3]


func _marksman(at: Vector3) -> MarksmanCharacter:
	var c := MarksmanCharacter.new()
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


## Per frame at skeleton_updated: the barrel's error to the aim point (rad) and the support hand's distance to
## its grip (m), while `frames` frames pass.
func _measure(c: MarksmanCharacter, frames: int) -> Dictionary:
	var r := c.ragdoll as MarksmanRagdoll
	var gp := r.gun_pass
	var sk := c.skeleton
	var eq := c.get_node("Equipment") as UltraEquipmentVisual
	var rh := sk.find_bone("RightHand")
	var lh := sk.find_bone("LeftHand")
	var out := {"aim": [], "support": [], "weight": [], "arm_w": 0.0, "stock": []}
	var arm_parts := []
	for i in r.parts.size():
		if String(r.parts[i].name).contains("Arm") or String(r.parts[i].name).contains("Hand"):
			arm_parts.append(i)
	var cb := func() -> void:
		if eq.held_node == null or eq.held_def == null:
			return
		var gun := sk.global_transform * sk.get_bone_global_pose(rh) * eq.grip()
		var muzzle := gun * UltraPoseSampler.marker(eq.held_node, "M_Muzzle").origin
		var barrel := -gun.basis.z.normalized()
		var to_aim := gp.aim_point - muzzle
		out.aim.append(barrel.angle_to(to_aim.normalized()) if to_aim.length() > 0.1 else 0.0)
		var target: Vector3 = sk.global_transform * gp.support_target.origin
		out.support.append((sk.global_transform * sk.get_bone_global_pose(lh)).origin.distance_to(target))
		out.weight.append(gp.weight)
		if eq.held_node.find_child("M_Stock", true, false) != null:
			var stock := gun * UltraPoseSampler.marker(eq.held_node, "M_Stock").origin
			out.stock.append(stock.distance_to(sk.global_transform * gp.pocket))
		for i: int in arm_parts:
			out.arm_w = maxf(out.arm_w, r.part_w[i] if i < r.part_w.size() else 0.0)
	sk.skeleton_updated.connect(cb)
	for k in frames:
		await get_tree().process_frame
	sk.skeleton_updated.disconnect(cb)
	return out


func _worst(a: Array) -> float:
	var w := 0.0
	for x in a:
		w = maxf(w, float(x))
	return w


func test_barrel_on_the_aim_and_support_hand_on_the_gun() -> void:
	load_playground()
	var c := _marksman(marker("spawn").global_position + Vector3(-16, 0, -3))
	await ticks(40)
	if not check((c.ragdoll as MarksmanRagdoll).gun_pass != null, "the gun pass is in place"):
		return
	for item: StringName in [&"rifle", &"shotgun", &"pistol"]:
		var sl := _slot(c, item)
		for crouch in [false, true]:
			for mv: String in MOVES:
				for pitch: float in PITCHES:
					c.teleport(marker("spawn").global_position + Vector3(-16, 0, -3), 0.0)
					bot(c).live_yaw = 0.0
					var buttons := InputFrame.B_CROUCH if crouch else 0
					bot(c).set_steps([{"ticks": 70, "slot": sl, "yaw": 0.0, "pitch": pitch, "buttons": buttons}])
					await ticks(70)
					bot(c).set_steps([{"ticks": 61, "slot": sl, "yaw": 0.0, "pitch": pitch, "buttons": buttons, "move": MOVES[mv]}])
					await ticks(20)
					var m := await _measure(c, 40)
					var label := "%s %s %s pitch %+.2f" % [item, "crouched" if crouch else "standing", mv, pitch]
					var aim := rad_to_deg(_worst(m.aim))
					var sup := _worst(m.support) * 100.0
					var limit := 1.0 if mv == "standing" else 2.0
					info("%-40s barrel %.2f deg, support hand %.2f cm, pass %.2f, arms physical %.2f" % [label, aim, sup, _worst(m.weight), m.arm_w])
					check(not (m.aim as Array).is_empty() and _worst(m.weight) > 0.99, "%s: the gun is up and the pass on" % label)
					check(aim <= limit, "%s: the barrel on the aim point (%.2f deg, limit %.0f)" % [label, aim, limit])
					check(sup <= 1.5, "%s: the support hand on its grip (%.2f cm)" % [label, sup])
					if not (m.stock as Array).is_empty():
						check(_worst(m.stock) <= 0.03, "%s: the stock in the shoulder pocket (%.1f cm)" % [label, _worst(m.stock) * 100.0])
					check(m.arm_w <= 0.01, "%s: the arms holding the gun are animated, not physics (%.2f)" % [label, m.arm_w])
