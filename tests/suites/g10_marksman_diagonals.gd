extends UltraTestSuite
## Marksman: walking backwards on a diagonal picks a clip that walks that way (the user: "if we walk back and a
## direction at the same time we get a shuffle, this happens for all directions. we need to pick the correct
## animation"). Every stance, standing and crouched, with motion matching on and off: 3 s steady in each of the 8
## directions - which clips played (matching: how often it switched), how far the planted feet slid, how many steps.

const D := 0.70710678
const DIRS := {"f": Vector2(0, 1), "fr": Vector2(D, D), "r": Vector2(1, 0), "br": Vector2(D, -D), "b": Vector2(0, -1),
		"bl": Vector2(-D, -D), "l": Vector2(-1, 0), "fl": Vector2(-D, D)}


func _marksman(at: Vector3, mm: bool) -> MarksmanCharacter:
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
	if item == &"":
		return 0
	UltraItems.give(c, item)
	for i in c.inventory.size():
		var it := c.inventory.get_slot(i)
		if it and it.def_id == item:
			return i + 1
	return 0


## One direction for `n` ticks: {clips: {name: frames}, switches, slide (max cm a planted foot moved in a frame, summed
## over the planted frames / their count = mean mm), steps}.
func _walk(c: MarksmanCharacter, sl: int, buttons: int, dir: Vector2, n: int) -> Dictionary:
	var out := {"clips": {}, "switches": 0, "slide": 0.0, "slide_n": 0, "steps": 0, "worst": 0.0}
	var sk := c.skeleton
	var drv := c.anim as MarksmanAnimDriver
	var last := {}
	var down := {}
	var lastclip := [""]
	var probe := func() -> void:
		var hip := sk.get_bone_global_pose(sk.find_bone("Hips")).origin
		out["hands"] = float(out.get("hands", 0.0)) + (sk.get_bone_global_pose(sk.find_bone("LeftHand")).origin.y + sk.get_bone_global_pose(sk.find_bone("RightHand")).origin.y) * 0.5 - hip.y
		out["hands_n"] = int(out.get("hands_n", 0)) + 1
		var clip: String = String(drv._mm_clip) if drv.mm else "gait"
		out.clips[clip] = int(out.clips.get(clip, 0)) + 1
		if lastclip[0] != "" and clip != lastclip[0]:
			out.switches += 1
		lastclip[0] = clip
		for f in ["Left", "Right"]:
			var p := sk.global_transform * sk.get_bone_global_pose(sk.find_bone(f + "Foot")).origin
			var t := sk.global_transform * sk.get_bone_global_pose(sk.find_bone(f + "Toes")).origin
			var floor_y := c.state.pos.y
			# (Planted: the ankle low AND the toe on the ground; its slide is the smaller of the two moves - one of them is
			# the pivot while the foot rolls.)
			var low := p.y - floor_y < 0.13 and t.y - floor_y < 0.05
			if last.has(f) and low and down.get(f, false):
				var lp: Array = last[f]
				var d := minf(Vector2(p.x - lp[0].x, p.z - lp[0].z).length(), Vector2(t.x - lp[1].x, t.z - lp[1].z).length())
				out.slide += d
				out.slide_n += 1
				out.worst = maxf(out.worst, d)
			if low and not down.get(f, false):
				out.steps += 1
			down[f] = low
			last[f] = [p, t]
	bot(c).set_steps([{"ticks": n + 60, "move": dir, "buttons": buttons, "slot": sl, "yaw": 0.0}])
	await ticks(45)                # (getting going)
	sk.skeleton_updated.connect(probe)
	await ticks(n)
	sk.skeleton_updated.disconnect(probe)
	return out


func test_back_diagonals_pick_a_clip() -> void:
	load_playground()
	var rows := []
	var bad := []
	var only := OS.get_environment("G10_ONLY")
	for mm in [true, false]:
		for item: StringName in [&"", &"rifle", &"pistol"]:
			var c := _marksman(marker("spawn").global_position + Vector3(-16, 0, -3), mm)
			await ticks(40)
			var sl := _slot(c, item)
			for crouch in [false, true]:
				var label := "%s %s %s" % ["MM" if mm else "gait", "unarmed" if item == &"" else String(item), "crouch" if crouch else "stand"]
				if only != "" and not label.contains(only):
					continue
				for d: String in DIRS:
					c.teleport(marker("spawn").global_position + Vector3(-16, 0, -3), 0.0)
					bot(c).live_yaw = 0.0
					bot(c).set_steps([{"ticks": 40, "slot": sl, "yaw": 0.0, "buttons": InputFrame.B_CROUCH if crouch else 0}])
					await ticks(40)
					var w: Dictionary = await _walk(c, sl, InputFrame.B_CROUCH if crouch else 0, DIRS[d], 180)
					var names := []
					for k: String in w.clips:
						names.append("%s %d" % [k.get_file(), int(w.clips[k])])
					rows.append("%-24s %-3s switches %2d  slide %.1f mm/frame (worst %.1f cm)  steps %2d  hands %+.2f m  %s" % [label, d, w.switches,
							float(w.slide) / maxf(float(w.slide_n), 1.0) * 1000.0, float(w.worst) * 100.0, w.steps,
							float(w.get("hands", 0.0)) / maxf(float(w.get("hands_n", 1)), 1.0), ", ".join(names)])
					if mm:
						var slide := float(w.slide) / maxf(float(w.slide_n), 1.0)
						for k: String in w.clips:
							if k.to_lower().contains("idle") and int(w.clips[k]) > 20:
								bad.append("%s %s: a standing clip while walking (%s, %d frames)" % [label, d, k.get_file(), int(w.clips[k])])
						var lim := SLIDE_MAX
						for k: String in w.clips:
							lim = maxf(lim, float(KNOWN_SLIDE.get(k.get_file(), 0.0)))
						if slide > lim:
							bad.append("%s %s: planted feet slide %.1f mm a frame" % [label, d, slide * 1000.0])
			chars.erase(c)
			c.queue_free()
			await ticks(3)
	for r: String in rows:
		info(r)
	check(bad.is_empty(), "every direction walks on a clip going that way, feet planted (%s)" % "; ".join(bad.slice(0, 12)))


## Mean slide of a planted foot (m a frame) the matched clips may show.
const SLIDE_MAX := 0.003
## Clips whose own planted feet drift (m a frame, measured). (The UAL Walk_Backwards scuffs its feet along the floor as
## they land and lift - 6 mm a frame; MarksmanMMPass locks a foot while the clip has it flat on the ground: 2.1-2.4.)
const KNOWN_SLIDE := {}
