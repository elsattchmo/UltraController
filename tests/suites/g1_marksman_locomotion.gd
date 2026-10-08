extends UltraTestSuite
## Marksman stage V1: full 8-way locomotion per stance - unarmed, rifle, pistol; standing, crouched, prone.
## The gait walks the stance's reference cycles (MarksmanStanceSet.groups) standing and crouched; prone is the
## clips' 8-way crawl. Every move is measured with SinewMoveMetrics (legs as capsules, hips, sinking).

const D := 0.70710678
const DIRS := {"f": Vector2(0, 1), "fr": Vector2(D, D), "r": Vector2(1, 0), "br": Vector2(D, -D), "b": Vector2(0, -1),
		"bl": Vector2(-D, -D), "l": Vector2(-1, 0), "fl": Vector2(-D, D)}


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


## Puts `item` in hand (empty = hands free) and waits for it to come up.
func _arm(c: MarksmanCharacter, item: StringName) -> void:
	if item == &"":
		bot(c).set_steps([{"ticks": 40, "slot": 0}])
		await ticks(45)
		return
	UltraItems.give(c, item)
	var uid := 0
	for i in c.inventory.size():
		var it := c.inventory.get_slot(i)
		if it and it.def_id == item:
			uid = it.uid
	bot(c).set_steps([{"ticks": 50, "slot": c.inventory.find_uid(uid) + 1}])
	await ticks(55)


func _group_name(c: MarksmanCharacter) -> String:
	var r := c.ragdoll as MarksmanRagdoll
	var aset := c.anim.anim_set as MarksmanStanceSet
	return aset.groups[r.group].name if r.group >= 0 and r.group < aset.groups.size() else "?"


## Walks each of the 8 directions for `n` ticks (facing fixed), with `buttons` held, recording into `m`.
func _eight_ways(c: MarksmanCharacter, m: SinewMoveMetrics, prefix: String, buttons: int, slot: int, n := 75) -> Dictionary:
	var moved := {}
	for d: String in DIRS:
		m.label = ""
		c.teleport(marker("spawn").global_position + Vector3(-16, 0, -3), 0.0)
		bot(c).live_yaw = 0.0
		bot(c).set_steps([{"ticks": 30, "buttons": buttons, "slot": slot, "yaw": 0.0}])
		await ticks(30)
		var from := c.state.pos
		m.label = prefix + " " + d
		bot(c).set_steps([{"ticks": n + 1, "move": DIRS[d], "buttons": buttons, "slot": slot, "yaw": 0.0}])
		await ticks(n)
		var dv := c.state.pos - from
		moved[d] = Vector2(dv.x, -dv.z)
	m.label = ""
	return moved


func _slot(c: MarksmanCharacter, item: StringName) -> int:
	if item == &"":
		return 0
	for i in c.inventory.size():
		var it := c.inventory.get_slot(i)
		if it and it.def_id == item:
			return i + 1
	return 0


func test_stance_sets_are_built() -> void:
	load_playground()
	var c := _marksman(marker("spawn").global_position)
	await ticks(40)
	var aset := c.anim.anim_set as MarksmanStanceSet
	if not check(aset != null and aset.groups.size() == 6, "a MarksmanStanceSet with 6 groups (got %s)" % [aset.groups.size() if aset else -1]):
		return
	var r := c.ragdoll as MarksmanRagdoll
	var facts: Array = r.world.physics.call("character_gait_clip_report", r._id)
	var per := {}
	for f: Dictionary in facts:
		per[int(f.group)] = int(per.get(int(f.group), 0)) + 1
	info("cycles per group: %s" % [per])
	for gi in aset.groups.size():
		check(int(per.get(gi, 0)) >= 4, "%s: its cycles reached the gait (%d)" % [aset.groups[gi].name, int(per.get(gi, 0))])
	check(_group_name(c) == "unarmed_stand", "unarmed, standing: %s" % _group_name(c))


func test_stances_follow_the_item_and_posture() -> void:
	load_playground()
	var c := _marksman(marker("spawn").global_position)
	await ticks(40)
	for item: StringName in [&"rifle", &"pistol"]:
		await _arm(c, item)
		var stance := String(item)
		check(_group_name(c) == stance + "_stand", "%s drawn: the %s_stand cycles (got %s)" % [item, stance, _group_name(c)])
		bot(c).set_steps([{"ticks": 40, "buttons": InputFrame.B_CROUCH, "slot": _slot(c, item)}])
		await ticks(40)
		check(_group_name(c) == stance + "_crouch", "crouched: %s_crouch (got %s, state %s)" % [stance, _group_name(c), MotorState.Id.keys()[c.state.state]])
		bot(c).set_steps([{"ticks": 30, "slot": _slot(c, item)}])
		await ticks(30)
	await _arm(c, &"")
	check(_group_name(c) == "unarmed_stand", "put away: unarmed_stand (got %s)" % _group_name(c))


## Known: crouched side steps (the rifle pack's crouch-walk sideways turns the hips ~75 deg) graze the thigh roots
## ~1 cm for a few ticks on the first step - the clip's own posture.
func _judge_eight(m: SinewMoveMetrics, moved: Dictionary, prefix: String, hips_max: float) -> void:
	for d: String in DIRS:
		var s := m.summary(prefix + " " + d)
		var mv: Vector2 = moved[d]
		var along := mv.normalized().dot(DIRS[d]) if mv.length() > 0.05 else 0.0
		var side_crouch := prefix.ends_with("crouch") and d in ["l", "r"]
		var ok: bool = s.gap_min >= (-0.015 if side_crouch else -0.01) and s.overlap <= (8 if side_crouch else 0) and s.hips_drop <= hips_max \
				and s.leg_speed <= 25.0 and along > 0.9 and mv.length() > 0.5
		check(ok, "%s %s: moved %.2f m (%.2f along), gap %.1f cm, %d through, hips -%.1f cm, legs %.1f m/s" % [prefix, d, mv.length(), along,
				s.gap_min * 100.0, s.overlap, s.hips_drop * 100.0, s.leg_speed])


func test_eight_ways_standing_and_crouched_per_stance() -> void:
	load_playground()
	var c := _marksman(marker("spawn").global_position)
	await ticks(40)
	var m := SinewMoveMetrics.new(c)
	for item: StringName in [&"", &"rifle", &"pistol"]:
		await _arm(c, item)
		var name := "unarmed" if item == &"" else String(item)
		var sl := _slot(c, item)
		# (Each stance's own standing height: the rifle stance stands lower than the unarmed one.)
		c.teleport(marker("spawn").global_position + Vector3(-16, 0, -3), 0.0)
		bot(c).set_steps([{"ticks": 90, "slot": sl, "yaw": 0.0}])
		await ticks(30)
		m.label = "idle " + name
		await ticks(60)
		m.label = ""
		m.calibrate("idle " + name)
		var stand := await _eight_ways(c, m, name + " stand", 0, sl)
		var crouch := await _eight_ways(c, m, name + " crouch", InputFrame.B_CROUCH, sl)
		_judge_eight(m, stand, name + " stand", 0.22)
		_judge_eight(m, crouch, name + " crouch", 0.45)
	for line in m.table().split("\n"):
		info(line)
	# (Debugging: G1_DUMP=<label substring> prints those segments frame by frame.)
	var dump := OS.get_environment("G1_DUMP")
	if dump != "":
		for f: Dictionary in m.frames:
			if String(f.label).contains(dump):
				var bs: Dictionary = f.bones
				var h: Vector3 = bs.Hips
				var y := float(f.body)
				var fw := Vector3(-sin(y), 0, -cos(y))
				var rt := Vector3(cos(y), 0, -sin(y))
				var loc := func(p: Vector3) -> String: return "(%+.2f r %+.2f f %.2f)" % [(p - h).dot(rt), (p - h).dot(fw), p.y - (f.pos as Vector3).y]
				print("DUMP %s t%d gap %+.1f %s L%s R%s %s%s gaitgap %+.1f knees L%s R%s" % [f.label, f.t, SinewMoveMetrics.legs_gap(bs) * 100.0,
						SinewMoveMetrics.legs_gap_pair(bs), loc.call(bs.LeftFoot), loc.call(bs.RightFoot), "L" if f.planted_l else "-",
						"R" if f.planted_r else "-", f.gait_gap * 100.0, loc.call(bs.LeftLowerLeg), loc.call(bs.RightLowerLeg)])
	m.detach()


func test_prone_eight_ways() -> void:
	load_playground()
	var c := _marksman(marker("spawn").global_position)
	await ticks(40)
	for item: StringName in [&"", &"rifle"]:
		await _arm(c, item)
		var sl := _slot(c, item)
		for d: String in DIRS:
			c.teleport(marker("spawn").global_position + Vector3(-16, 0, -3), 0.0)
			bot(c).live_yaw = 0.0
			bot(c).set_steps([{"ticks": 90, "buttons": InputFrame.B_CRAWL | InputFrame.B_CROUCH, "slot": sl, "yaw": 0.0}])
			await ticks(90)
			var from := c.state.pos
			bot(c).set_steps([{"ticks": 91, "move": DIRS[d], "buttons": InputFrame.B_CRAWL | InputFrame.B_CROUCH, "slot": sl, "yaw": 0.0}])
			await ticks(90)
			var dv := c.state.pos - from
			var mv := Vector2(dv.x, -dv.z)
			var drv := c.anim as MarksmanAnimDriver
			var bp: Vector2 = drv.tree.get(MarksmanAnimDriver.LOCO + "prone/armed/blend_position")
			check(c.state.state == MotorState.Id.CRAWL and drv._cur_loco == "prone", "%s prone %s: lying (%s, %s)" % [item, d, MotorState.Id.keys()[c.state.state], drv._cur_loco])
			check(mv.length() > 0.3 and mv.normalized().dot(DIRS[d]) > 0.85 and bp.normalized().dot(DIRS[d]) > 0.85,
					"%s prone %s: crawls that way (%.2f m, blend %s)" % [item, d, mv.length(), bp])


## Every stance's reference clips: the clip audit's rules, and the same as the committed baseline
## (addons/marksman/clip_audit.json; CLIP_AUDIT_WRITE=1 rewrites it after a deliberate change).
func test_clip_audit() -> void:
	load_playground()
	var c := _marksman(marker("spawn").global_position)
	await ticks(40)
	var entries := MarksmanClipAudit.report(c)
	for line in MarksmanClipAudit.table(entries).split("\n"):
		info(line)
	check(entries.size() >= 40, "the gait read every stance's cycles (%d)" % entries.size())
	for e: Dictionary in entries:
		check(e.role != "?", "cycle of %.2f m/s in group %s matched to a role" % [e.speed, e.group_name])
	for msg: String in MarksmanClipAudit.rules(entries, c.profile):
		check(false, msg)
	if OS.get_environment("CLIP_AUDIT_WRITE") != "":
		MarksmanClipAudit.save_baseline(entries)
		info("baseline written: " + MarksmanClipAudit.BASELINE)
		return
	var base := MarksmanClipAudit.load_baseline()
	check(not base.is_empty(), "a clip audit baseline exists (%s)" % MarksmanClipAudit.BASELINE)
	var changes := SinewClipAudit.diff(entries, base)
	for msg: String in changes:
		info("changed: " + msg)
	check(changes.is_empty(), "the reference clips read as in the baseline (%d changes; deliberate? CLIP_AUDIT_WRITE=1)" % changes.size())


## Drawing (and putting away) a rifle mid-walk: the gait switches stance per foot and fades its pose - the
## pelvis doesn't jump, no planted foot slides.
func test_draw_while_walking() -> void:
	load_playground()
	var c := _marksman(marker("spawn").global_position + Vector3(-16, 0, -3))
	await ticks(40)
	UltraItems.give(c, &"rifle")
	var sl := _slot(c, &"rifle")
	var m := SinewMoveMetrics.new(c)
	m.label = "draw"
	bot(c).set_steps([{"ticks": 60, "move": Vector2(0, 1), "slot": 0, "yaw": 0.0}, {"ticks": 90, "move": Vector2(0, 1), "slot": sl, "yaw": 0.0},
			{"ticks": 90, "move": Vector2(0, 1), "slot": 0, "yaw": 0.0}])
	await ticks(240)
	m.label = ""
	m.detach()
	var pelvis_jump := 0.0
	var slide := 0.0
	var prev: Dictionary = {}
	for f: Dictionary in m.frames:
		if not prev.is_empty():
			var b: Dictionary = f.bones
			var pb: Dictionary = prev.bones
			var body := (f.pos as Vector3) - (prev.pos as Vector3)
			pelvis_jump = maxf(pelvis_jump, ((b.Hips as Vector3) - (pb.Hips as Vector3) - body).length())
			for side in ["Left", "Right"]:
				var key := "planted_l" if side == "Left" else "planted_r"
				if f[key] and prev[key]:
					slide = maxf(slide, minf(((b[side + "Foot"] as Vector3) - (pb[side + "Foot"] as Vector3)).length(),
							((b[side + "Toes"] as Vector3) - (pb[side + "Toes"] as Vector3)).length()))
		prev = f
	info("draw / put away mid-walk: pelvis moves %.1f cm a tick off the body at most, planted foot %.1f mm" % [pelvis_jump * 100.0, slide * 1000.0])
	check(pelvis_jump < 0.03, "the pelvis doesn't jump (%.1f cm)" % (pelvis_jump * 100.0))
	check(slide < 0.005, "no planted foot slides (%.1f mm)" % (slide * 1000.0))
