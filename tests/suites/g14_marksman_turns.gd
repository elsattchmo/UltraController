extends UltraTestSuite
## Marksman turning on the spot with every kind of kit (the user: "handgun, unarmed and melee turn on the spot animations
## are broken"): a slow quarter turn, a flick back, a half turn and a whole spin, each then still - the feet step round
## (no gliding on planted feet, no crossing through each other), nothing whips, the matcher has the legs back after.

const Id := MotorState.Id


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


## [name, from yaw (rad), to yaw, ticks to turn, ticks still after]
const MOVES := [["slow 90 left", 0.0, PI * 0.5, 60, 90], ["flick 90 right", PI * 0.5, 0.0, 4, 90],
		["180 left", 0.0, PI, 30, 120], ["spin 360 right", PI, -PI, 90, 120], ["small 25", -PI, -PI + 0.44, 8, 90]]


func test_turns_on_the_spot() -> void:
	load_playground()
	var bad := []
	var only := OS.get_environment("G14_ONLY")
	for item: StringName in [&"", &"pistol", &"machete", &"bat", &"rifle"]:
		var label := String(item) if item != &"" else "unarmed"
		if only != "" and only != label:
			continue
		var c := _marksman(marker("spawn").global_position + Vector3(-16, 0, -3))
		await ticks(30)
		var sl := 0
		if item != &"":
			UltraItems.give(c, item)
			for i in c.inventory.size():
				var it := c.inventory.get_slot(i)
				if it and it.def_id == item:
					sl = i + 1
		var drv := c.anim as MarksmanAnimDriver
		var sk := c.skeleton
		bot(c).set_steps([{"ticks": 100000, "slot": sl, "yaw": 0.0}])
		await ticks(90)
		var m := {"fast": 0.0, "fast_bone": "", "feet": {}, "hips": 0.0}
		var last := {}
		var probe := func() -> void:
			for b in sk.get_bone_count():
				var bn := sk.get_bone_name(b)
				if bn.contains("leaf") or bn == "Root":
					continue
				var p := sk.global_transform * sk.get_bone_global_pose(b).origin
				if last.has(b):
					var v: float = p.distance_to(last[b]) * 60.0
					if v > float(m.fast):
						m.fast = v
						m.fast_bone = bn
				last[b] = p
			m.hips = (sk.global_transform * sk.get_bone_global_pose(sk.find_bone("Hips")).origin).y - c.state.pos.y
			for f in ["LeftFoot", "RightFoot", "LeftToes", "RightToes"]:
				m.feet[f] = sk.global_transform * sk.get_bone_global_pose(sk.find_bone(f)).origin
		sk.skeleton_updated.connect(probe)
		await ticks(2)
		var stand_h: float = m.hips
		for mv: Array in MOVES:
			var low := INF
			m.fast = 0.0
			var n: int = int(mv[3]) + int(mv[4])
			var skate := [0.0, 0.0]
			var lifts := [0, 0]
			var lifted := [false, false]
			var gap_min := INF
			var prev := []
			var keys := {}
			for i in n:
				var y := lerpf(float(mv[1]), float(mv[2]), clampf(float(i + 1) / float(mv[3]), 0.0, 1.0))
				bot(c).set_steps([{"ticks": 100000, "slot": sl, "yaw": y}])
				await ticks(1)
				var ft := [m.feet.get("LeftFoot", Vector3.ZERO), m.feet.get("RightFoot", Vector3.ZERO)]
				if prev.size() == 2:
					for k in 2:
						var f: Vector3 = ft[k]
						var h := f.y - c.state.pos.y
						# (A foot down sliding slowly; a quick low shuffle - the rifle turn's 27 cm in 3 ticks at 10 cm up - is a step.)
						var mv_k := Vector2(f.x - prev[k].x, f.z - prev[k].z).length()
						if h < 0.11 and mv_k < 0.02:
							skate[k] += mv_k
						var up := h > 0.125
						if up and not lifted[k]:
							lifts[k] += 1
						lifted[k] = up
				prev = ft
				gap_min = minf(gap_min, Vector2(ft[0].x - ft[1].x, ft[0].z - ft[1].z).length())
				low = minf(low, float(m.hips))
				keys["%s/%s" % [drv._cur_loco, drv._mk_turn_key if drv.turn_w > 0.3 else "-"]] = true
				if OS.get_environment("G14_DUMP") == "%s:%s" % [label, mv[0]]:
					print("t%d %s yaw %.2f body %.2f feet_yaw %.2f dir %d p %.2f w %.2f key %s loco %s L %s R %s clip %s" % [i, Id.keys()[c.state.state],
							y, c.state.body_yaw, drv._mk_feet_yaw, drv._mk_turn_dir, drv._mk_turn_p, drv.turn_w, drv._mk_turn_key, drv._cur_loco,
							(ft[0] as Vector3).snappedf(0.01), (ft[1] as Vector3).snappedf(0.01),
							String(drv.mm.db.clips[drv.mm.clip].name).get_file() if drv.mm.clip >= 0 else "-"])
			var turned := absf(angle_difference(float(mv[1]), float(mv[2])))
			if is_equal_approx(turned, 0.0):
				turned = TAU
			info("%-8s %-15s skate L %.2f R %.2f m, steps %d / %d, feet gap min %.2f m, hips down %.1f cm, fastest %s %.1f m/s, facing off %.0f deg | %s" % [label, mv[0],
					skate[0], skate[1], lifts[0], lifts[1], gap_min, (stand_h - low) * 100.0, m.fast_bone, m.fast,
					rad_to_deg(absf(angle_difference(c.state.body_yaw, float(mv[2])))), " ".join(keys.keys())])
			if skate[0] > 0.15 or skate[1] > 0.15:
				bad.append("%s %s: feet glide %.2f / %.2f m" % [label, mv[0], skate[0], skate[1]])
			if turned > 1.0 and lifts[0] + lifts[1] < 2:
				bad.append("%s %s: no steps (%d / %d)" % [label, mv[0], lifts[0], lifts[1]])
			if stand_h - low > 0.06:
				bad.append("%s %s: crouches %.1f cm" % [label, mv[0], (stand_h - low) * 100.0])
			if gap_min < 0.08:
				bad.append("%s %s: feet through each other (%.2f m)" % [label, mv[0], gap_min])
			if float(m.fast) > 18.0:          # (a flick's fingers: 13-17 m/s)
				bad.append("%s %s: %s at %.1f m/s" % [label, mv[0], m.fast_bone, m.fast])
		sk.skeleton_updated.disconnect(probe)
		chars.erase(c)
		c.queue_free()
		await ticks(3)
	check(bad.is_empty(), "turns on the spot step cleanly with every kit (%s)" % "; ".join(bad))
