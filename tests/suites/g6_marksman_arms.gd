extends UltraTestSuite
## Marksman: the arms never go into the body (the user: "we don't really want the arms to clip into the body"). Measured
## with UltraArmClear's torso (an ellipse round the hips -> neck line, measured off the mannequin's mesh, the limb's
## thickness included): how deep the elbow, the middle of the forearm and the hand get into it - and the middle of the
## upper arm beyond its own shoulder - per arm, through the gun states: idle, walking, strafing, crouched, ADS, reloads,
## hits. And every elbow keeps out from the body (elbow_out: the normalised distance, 1 = on the torso's surface).


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
	for i in c.inventory.size():
		var it := c.inventory.get_slot(i)
		if it and it.def_id == item:
			return i + 1
	return 0


## [hips, axis, length, right, fwd] off the shown skeleton (UltraArmClear._torso_frame).
static func torso_frame(sk: Skeleton3D) -> Array:
	var hips := sk.get_bone_global_pose(sk.find_bone("Hips")).origin
	var neck := sk.get_bone_global_pose(sk.find_bone("Neck")).origin
	var axis := (neck - hips).normalized()
	var right := sk.get_bone_global_pose(sk.find_bone("RightUpperArm")).origin - sk.get_bone_global_pose(sk.find_bone("LeftUpperArm")).origin
	right = (right - axis * right.dot(axis)).normalized()
	return [hips, axis, (neck - hips).length(), right, axis.cross(right).normalized()]


## How deep `p` is in the torso (m; 0 = outside).
static func depth(f: Array, p: Vector3) -> float:
	var hips: Vector3 = f[0]
	var axis: Vector3 = f[1]
	var t := clampf((p - hips).dot(axis), 0.15, float(f[2]))
	if (p - hips).dot(axis) > float(f[2]) + 0.05:
		return 0.0            # (above the neck: the head's business)
	var d := p - (hips + axis * t)
	var k := clampf(t / maxf(float(f[2]), 0.001), 0.0, 1.0)
	var hw := lerpf(UltraArmClear.WAIST_HALF_WIDTH, UltraArmClear.TORSO_HALF_WIDTH, smoothstep(0.3, 0.8, k))
	var hd := lerpf(UltraArmClear.WAIST_HALF_DEPTH, UltraArmClear.TORSO_HALF_DEPTH, smoothstep(0.3, 0.8, k))
	var x := d.dot(f[3]) / hw
	var y := d.dot(f[4]) / hd
	var q := sqrt(x * x + y * y)
	return maxf(1.0 - q, 0.0) * minf(hw, hd)


## How far a point is OUT of the torso (normalised ellipse distance: 1 = on its surface).
static func outness(f: Array, p: Vector3) -> float:
	var hips: Vector3 = f[0]
	var axis: Vector3 = f[1]
	var t := clampf((p - hips).dot(axis), 0.15, float(f[2]))
	var d := p - (hips + axis * t)
	var k := clampf(t / maxf(float(f[2]), 0.001), 0.0, 1.0)
	var hw := lerpf(UltraArmClear.WAIST_HALF_WIDTH, UltraArmClear.TORSO_HALF_WIDTH, smoothstep(0.3, 0.8, k))
	var hd := lerpf(UltraArmClear.WAIST_HALF_DEPTH, UltraArmClear.TORSO_HALF_DEPTH, smoothstep(0.3, 0.8, k))
	return sqrt(pow(d.dot(f[3]) / hw, 2.0) + pow(d.dot(f[4]) / hd, 2.0))


## Worst depth per point over `frames` (measured at skeleton_updated, as shown).
func _watch(c: MarksmanCharacter, frames: int) -> Dictionary:
	var sk := c.skeleton
	var worst := {}
	var probe := func() -> void:
		var f := torso_frame(sk)
		for side in ["Left", "Right"]:
			var s := sk.get_bone_global_pose(sk.find_bone(side + "UpperArm")).origin
			var e := sk.get_bone_global_pose(sk.find_bone(side + "LowerArm")).origin
			var h := sk.get_bone_global_pose(sk.find_bone(side + "Hand")).origin
			var pts := {"elbow": e, "upper": s.lerp(e, 0.55), "forearm": e.lerp(h, 0.5), "hand": h}
			if OS.get_environment("G6_SHOULDER") != "":
				pts["shoulder"] = s
				pts["upper25"] = s.lerp(e, 0.25)
			var root := depth(f, s)
			for n: String in pts:
				var key: String = side[0] + " " + n
				# (The upper arm against its own shoulder: the torso ellipse is wider than the body at the shoulders - the
				# joint itself reads 2-6 cm "in" in every pose, unarmed idle too. It may not go deeper than where it hangs from.)
				var dd := depth(f, pts[n]) - (root if n.begins_with("upper") else 0.0)
				worst[key] = maxf(float(worst.get(key, 0.0)), dd)
			# (The elbow's way out from the body: smallest normalised distance; and how far it is to the side.)
			var ek: String = side[0] + " elbow_out"
			worst[ek] = minf(float(worst.get(ek, 9.0)), outness(f, e))
	sk.skeleton_updated.connect(probe)
	await ticks(frames)
	sk.skeleton_updated.disconnect(probe)
	return worst


func _fmt(w: Dictionary) -> String:
	var parts := []
	var keys := w.keys()
	keys.sort()
	for k: String in keys:
		if k.ends_with("elbow_out") or k == "racked cm":
			parts.append("%s %.2f" % [k, float(w[k])])
		elif float(w[k]) > 0.005:
			parts.append("%s %.1f" % [k, float(w[k]) * 100.0])
	return ", ".join(parts) if not parts.is_empty() else "clear"


func _hit(c: UltraCharacter, region: int, amount: float) -> void:
	var d := UltraCombat.DamageInfo.new()
	d.amount = amount
	d.region = region
	d.kind = &"bullet"
	d.dir = Vector3(1, 0, 0.3).normalized()
	d.point = c.state.pos + Vector3.UP * 1.3
	c.apply_damage(d)
	c.react_to_hit(region, d.dir, amount, d.kind)


const LIMIT := 0.02
const ELBOW_OUT_MIN := 1.15


func test_arms_stay_out_of_the_body() -> void:
	load_playground()
	var rows := []
	var bad := []
	for item: StringName in [&"", &"rifle", &"pistol", &"shotgun"]:
		var c := _marksman(marker("spawn").global_position + Vector3(-16, 0, -3))
		await ticks(40)
		var sl := _slot(c, item) if item != &"" else 0
		for ammo: StringName in [&"ammo_9mm", &"ammo_556", &"ammo_12g"]:
			UltraItems.give(c, ammo, 200)          # (reloads' worth: a run on its own has no infinite ammo)
		var cases := [["idle", 0, 120, {}], ["walk", 0, 90, {"move": Vector2(0, 1)}], ["strafe", 0, 90, {"move": Vector2(1, 0)}],
				["crouch", InputFrame.B_CROUCH, 120, {}]]
		if item != &"":
			cases += [["ADS", InputFrame.B_SECONDARY, 90, {}], ["reload", -1, 200, {}], ["empty reload", -2, 230, {}], ["hits", -3, 150, {}]]
		bot(c).set_steps([{"ticks": 120, "slot": sl, "yaw": 0.0}])
		await ticks(120)
		for cs: Array in cases:
			var step := {"ticks": 400, "slot": sl, "yaw": 0.0}
			step.merge(cs[3])
			if int(cs[1]) > 0:
				step["buttons"] = int(cs[1])
			if int(cs[1]) == -1 or int(cs[1]) == -2:
				c.state.mag = 0 if int(cs[1]) == -2 else 3
				bot(c).set_steps([{"ticks": 3, "slot": sl, "yaw": 0.0, "buttons": InputFrame.B_RELOAD}, step])
			else:
				bot(c).set_steps([step])
			if int(cs[1]) == -3:
				await ticks(10)
				_hit(c, UltraLimbs.Region.TORSO, 25.0)
				await ticks(40)
				_hit(c, UltraLimbs.Region.FOREARM_R, 25.0)
				await ticks(40)
				_hit(c, UltraLimbs.Region.FOREARM_L, 60.0)
			var gp := (c.ragdoll as MarksmanRagdoll).gun_pass
			var racked := [0.0]
			var rprobe := func() -> void: racked[0] = maxf(racked[0], gp.rack_pull)
			c.skeleton.skeleton_updated.connect(rprobe)
			var w: Dictionary = await _watch(c, int(cs[2]))
			c.skeleton.skeleton_updated.disconnect(rprobe)
			if int(cs[1]) == -2:
				w["racked cm"] = racked[0] * 100.0
				if racked[0] < 0.05 and item != &"shotgun":      # (a tube, loaded a shell at a time: nothing to rack)
					bad.append("%s %s: the bolt / slide was never racked" % [String(item), cs[0]])
			var label := "%-8s %-12s" % [String(item) if item != &"" else "unarmed", cs[0]]
			rows.append("%s %s" % [label, _fmt(w)])
			for k: String in w:
				if k == "racked cm":
					continue
				if k.ends_with("elbow_out"):
					if float(w[k]) < ELBOW_OUT_MIN:
						bad.append("%s %s %.2f" % [label, k, float(w[k])])
				elif float(w[k]) > LIMIT:
					bad.append("%s %s %.1f cm" % [label, k, float(w[k]) * 100.0])
			bot(c).set_steps([{"ticks": 60, "slot": sl, "yaw": 0.0}])
			c.state.hp = 100.0
			for r in UltraLimbs.COUNT:
				c.state.limb_hp[r] = 100.0
			await ticks(60)
		chars.erase(c)
		c.queue_free()
		await ticks(3)
	for r: String in rows:
		info(r)
	check(bad.is_empty(), "no arm deeper than %.0f cm in the body (%s)" % [LIMIT * 100.0, "; ".join(bad.slice(0, 12))])
