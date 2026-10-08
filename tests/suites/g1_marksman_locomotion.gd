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


## Known: crouched (the rifle pack's crouch walks: sideways they turn the hips ~75 deg, the diagonals borrow them)
## the thighs' capsules graze at the roots, <= 2 cm for a few ticks - the clips' own posture. Allowed there only:
## any other pair of leg capsules through each other fails.
func _judge_eight(m: SinewMoveMetrics, moved: Dictionary, prefix: String, hips_max: float) -> void:
	var crouch := prefix.ends_with("crouch")
	for d: String in DIRS:
		var s := m.summary(prefix + " " + d)
		var mv: Vector2 = moved[d]
		var along := mv.normalized().dot(DIRS[d]) if mv.length() > 0.05 else 0.0
		var roots := crouch and _overlaps_only_thighs(m, prefix + " " + d)
		var ok: bool = s.gap_min >= (-0.02 if roots else -0.01) and s.overlap <= (8 if roots else 0) and s.hips_drop <= hips_max \
				and s.leg_speed <= 25.0 and along > 0.9 and mv.length() > 0.5
		check(ok, "%s %s: moved %.2f m (%.2f along), gap %.1f cm, %d through%s, hips -%.1f cm, legs %.1f m/s" % [prefix, d, mv.length(), along,
				s.gap_min * 100.0, s.overlap, " (thigh roots)" if roots and s.overlap > 0 else "", s.hips_drop * 100.0, s.leg_speed])


## Every frame of `lab` with the legs through each other has the thighs as the closest pair.
func _overlaps_only_thighs(m: SinewMoveMetrics, lab: String) -> bool:
	for f: Dictionary in m.frames:
		if f.label == lab and SinewMoveMetrics.legs_gap(f.bones) < 0.0 and SinewMoveMetrics.legs_gap_pair(f.bones) != "thigh/thigh":
			return false
	return true


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
		# (Crouched, a move starts from the stance's crouch idle - the rifle's is a kneel, its hips 48 cm under the
		# standing idle's - and rises into the crouch walk as the gait comes in.)
		_judge_eight(m, crouch, name + " crouch", 0.5)
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
	bot(c).set_steps([{"ticks": 60, "move": Vector2(0, 1), "slot": 0, "yaw": 0.0}, {"ticks": 90, "move": Vector2(0, 1), "slot": sl, "yaw": 0.0},
			{"ticks": 90, "move": Vector2(0, 1), "slot": 0, "yaw": 0.0}])
	var rec := await _track_feet(c, 240)
	var pelvis_jump := 0.0
	var hips: Array = rec.hips
	var body: Array = rec.body
	for k in range(1, hips.size()):
		pelvis_jump = maxf(pelvis_jump, ((hips[k] as Vector3) - (hips[k - 1] as Vector3) - ((body[k] as Vector3) - (body[k - 1] as Vector3))).length())
	var slide := _worst_slide(rec)
	# (The same walk without the switches: the clips' own touchdown roll is the floor this is held to.)
	var plain := _marksman(marker("spawn").global_position + Vector3(-12, 0, -3))
	await ticks(40)
	UltraItems.give(plain, &"rifle")
	bot(plain).set_steps([{"ticks": 240, "move": Vector2(0, 1), "slot": sl, "yaw": 0.0}])
	await ticks(60)
	var walk_slide := _worst_slide(await _track_feet(plain, 150))
	info("draw / put away mid-walk: pelvis moves %.1f cm a tick off the body at most, planted foot %.1f mm a frame (a plain rifle walk: %.1f)" % [pelvis_jump * 100.0, slide, walk_slide])
	check(pelvis_jump < 0.03, "the pelvis doesn't jump (%.1f cm)" % (pelvis_jump * 100.0))
	check(slide < 8.0, "no planted foot slides (%.1f mm a frame, s7's walking limit 8)" % slide)
	check(walk_slide < 8.0, "a rifle walk's planted feet stay put (%.1f mm a frame)" % walk_slide)


## Per frame (at skeleton_updated): each foot's ankle, toe and heel (world), planted (the gait's say), the hips
## and the body's position. As s7 measures it.
func _track_feet(c: MarksmanCharacter, frames: int) -> Dictionary:
	var r := c.ragdoll as SinewRagdoll
	var sk := c.skeleton
	var feet := [sk.find_bone("LeftFoot"), sk.find_bone("RightFoot")]
	var toes := [sk.find_bone("LeftToes"), sk.find_bone("RightToes")]
	var hips := sk.find_bone("Hips")
	var rec := {"pos": [[], []], "toe": [[], []], "heel": [[], []], "ball": [[], []], "planted": [[], []], "hips": [], "body": [],
			"xf": [[], []], "lat": []}
	# (The heel: on the sole under the ankle, 6 cm back; the ball: on the sole under the toe joint - the Toes bone
	# sits ~2.6 cm over the sole and swings round the ball as the heel rises. In the foot bone's frame, from rest.)
	var heel_local := []
	var ball_local := []
	for i in 2:
		var rest := sk.get_bone_global_rest(feet[i])
		var toe_rest := sk.get_bone_global_rest(toes[i])
		heel_local.append(rest.affine_inverse() * Vector3(rest.origin.x, 0.0, rest.origin.z - 0.06))
		ball_local.append(rest.affine_inverse() * Vector3(toe_rest.origin.x, 0.0, toe_rest.origin.z))
		rec.lat.append(rest.basis.inverse() * Vector3.RIGHT)
	var cb := func() -> void:
		var st: Dictionary = r.world.physics.call("character_gait_state", r._id)
		rec.hips.append((sk.global_transform * sk.get_bone_global_pose(hips)).origin)
		if OS.get_environment("G1_FEET") != "":
			var lat: Vector3 = (sk.global_transform * sk.get_bone_global_pose(feet[0])).basis * (rec.lat[0] as Vector3)
			var lat_r: Vector3 = (sk.global_transform * sk.get_bone_global_pose(feet[1])).basis * (rec.lat[1] as Vector3)
			print("FEET t%d %s yaw %.0f aim %.0f gait_w %.2f legs %.2f footyaw L %.0f R %.0f planted %s%s anchor %d" % [Engine.get_physics_frames(),
					MotorState.Id.keys()[c.state.state], rad_to_deg(c.state.body_yaw), rad_to_deg(c.last_input.yaw), r.gait_w, r._legs_w(),
					rad_to_deg(atan2(lat.z, lat.x)), rad_to_deg(atan2(lat_r.z, lat_r.x)), "L" if st.get("planted_l", false) else "-",
					"R" if st.get("planted_r", false) else "-", r._clip_anchor.size()])
		rec.body.append(c.visual_root.global_position)
		for i in 2:
			var ft := sk.global_transform * sk.get_bone_global_pose(feet[i])
			rec.pos[i].append(ft.origin)
			rec.toe[i].append((sk.global_transform * sk.get_bone_global_pose(toes[i])).origin)
			rec.heel[i].append(ft * (heel_local[i] as Vector3))
			rec.ball[i].append(ft * (ball_local[i] as Vector3))
			rec.xf[i].append(ft)
			rec.planted[i].append(bool(st.get("planted_" + ("l" if i == 0 else "r"), false)))
	sk.skeleton_updated.connect(cb)
	for k in frames:
		await get_tree().process_frame
	sk.skeleton_updated.disconnect(cb)
	return rec


## Worst frame-to-frame move of a planted foot (planted 4 frames running), mm: the smallest of the heel's,
## the ankle's, the toe's and the ball's (the heel strike pivots on the heel, the push-off on the ball).
func _worst_slide(rec: Dictionary) -> float:
	var worst := 0.0
	for i in 2:
		var p: Array = rec.pos[i]
		var t: Array = rec.toe[i]
		var h: Array = rec.heel[i]
		var b: Array = rec.ball[i]
		var pl: Array = rec.planted[i]
		for k in range(3, p.size()):
			if pl[k] and pl[k - 1] and pl[k - 2] and pl[k - 3]:
				var d := minf(minf((p[k] as Vector3).distance_to(p[k - 1]), (t[k] as Vector3).distance_to(t[k - 1])),
						minf((h[k] as Vector3).distance_to(h[k - 1]), (b[k] as Vector3).distance_to(b[k - 1])))
				if d > 0.006 and OS.get_environment("G1_DUMP") != "":
					var run := 0
					while k - run >= 0 and pl[k - run]:
						run += 1
					print("SLIDE k%d %s run %d ankle %.1f toe %.1f heel %.1f ball %.1f  ankle y %.3f toe y %.3f heel y %.3f" % [k, "LR"[i], run,
							(p[k] as Vector3).distance_to(p[k - 1]) * 1000.0, (t[k] as Vector3).distance_to(t[k - 1]) * 1000.0,
							(h[k] as Vector3).distance_to(h[k - 1]) * 1000.0, (b[k] as Vector3).distance_to(b[k - 1]) * 1000.0, (p[k] as Vector3).y, (t[k] as Vector3).y, (h[k] as Vector3).y])
				worst = maxf(worst, d)
	return worst * 1000.0


## Feet pivot, never twist: a planted foot that turns must turn on its ball or its heel (that point stays put, as a
## real foot does), never round its middle; a swinging foot turns at a natural rate. Per move and stance:
## twist = the yaw a planted foot turned on frames where neither the ball nor the heel held (deg), spin = the
## fastest a swinging foot turned (deg a frame).
func test_feet_pivot_not_twist() -> void:
	load_playground()
	var c := _marksman(marker("spawn").global_position + Vector3(-16, 0, -3))
	await ticks(40)
	var rows := []
	for item: StringName in [&"", &"rifle", &"pistol"]:
		await _arm(c, item)
		var sl := _slot(c, item)
		var name := "unarmed" if item == &"" else String(item)
		var moves := [["start f", [{"ticks": 60, "move": Vector2(0, 1)}]],
				["turn 90 r + back", [{"ticks": 50, "yaw": -PI / 2.0}, {"ticks": 50, "yaw": 0.0}]],
				["turn 180", [{"ticks": 70, "yaw": PI}]],
				["step r", [{"ticks": 40, "move": Vector2(1, 0)}]],
				["step bl", [{"ticks": 40, "move": Vector2(-D, -D)}]],
				["stop", [{"ticks": 30, "move": Vector2(0, 1)}, {"ticks": 40}]],
				["crouch", [{"ticks": 50, "buttons": InputFrame.B_CROUCH}]],
				["crouch step r", [{"ticks": 40, "move": Vector2(1, 0), "buttons": InputFrame.B_CROUCH}]],
				["crouch turn 90 l", [{"ticks": 60, "yaw": PI / 2.0, "buttons": InputFrame.B_CROUCH}]]]
		if item != &"":
			moves.append(["draw on the spot", [{"ticks": 20, "slot": 0}, {"ticks": 50, "slot": sl}]])
		for mv: Array in moves:
			# (Debugging: G1_MOVE=<substring> runs just those moves; G1_FEET=1 traces each frame.)
			if OS.get_environment("G1_MOVE") != "" and not (name + " " + mv[0]).contains(OS.get_environment("G1_MOVE")):
				continue
			c.teleport(marker("spawn").global_position + Vector3(-16, 0, -3), 0.0)
			bot(c).live_yaw = 0.0
			bot(c).set_steps([{"ticks": 40, "slot": sl, "yaw": 0.0}])
			await ticks(40)
			var steps: Array = []
			var n := 0
			for s: Dictionary in mv[1]:
				var st := s.duplicate()
				if not st.has("slot"):
					st["slot"] = sl
				if not st.has("yaw"):
					st["yaw"] = float(steps.back().get("yaw", 0.0)) if not steps.is_empty() else 0.0
				steps.append(st)
				n += int(st.ticks)
			bot(c).set_steps(steps)
			if OS.get_environment("G1_FEET") != "":
				print("MOVE %s %s" % [name, mv[0]])
			var r := _twist(await _track_feet(c, n))
			rows.append([name + " " + mv[0], r])
	# (Limits: a planted foot turning with neither ball nor heel held is the measuring noise of a pivot point a
	# centimetre off - a few degrees; a swinging foot turns at most Gait's swing_turn_rate, 12 rad/s = 11.5 deg a
	# frame. Before: armed turns snapped the planted feet 35-111 deg in a frame, crouching twisted them 25-90 deg in
	# place, starts / side steps / stops spun a swinging foot 37-79 deg a frame. The pelvis column is information:
	# known pops of 6-9 cm a frame at hand-overs between the clip and the gait.)
	for row: Array in rows:
		var r: Dictionary = row[1]
		info("%-28s twist %5.1f deg (worst %4.1f/frame)  pivot %5.1f deg  spin %4.1f deg/frame  pelvis %.1f cm/frame" % [row[0], r.twist,
				r.twist_max, r.pivot, r.spin, r.pelvis * 100.0])
		check(r.twist_max <= 4.0 and r.twist <= 15.0, "%s: planted feet pivot, not twist (%.1f deg, %.1f a frame)" % [row[0], r.twist, r.twist_max])
		check(r.spin <= 12.0, "%s: a swinging foot turns at a foot's pace (%.1f deg a frame)" % [row[0], r.spin])


## From a _track_feet record: yaw of each foot from its sideways axis (pitch doesn't move it).
func _twist(rec: Dictionary) -> Dictionary:
	var out := {"twist": 0.0, "twist_max": 0.0, "pivot": 0.0, "spin": 0.0, "pelvis": 0.0}
	var hips: Array = rec.hips
	var body: Array = rec.body
	for k in range(1, hips.size()):
		out.pelvis = maxf(out.pelvis, ((hips[k] as Vector3) - (hips[k - 1] as Vector3) - ((body[k] as Vector3) - (body[k - 1] as Vector3))).length())
	for i in 2:
		var xf: Array = rec.xf[i]
		var pl: Array = rec.planted[i]
		var h: Array = rec.heel[i]
		var b: Array = rec.ball[i]
		for k in range(1, xf.size()):
			var lat_a := ((xf[k - 1] as Transform3D).basis * (rec.lat[i] as Vector3))
			var lat_b := ((xf[k] as Transform3D).basis * (rec.lat[i] as Vector3))
			var dy := absf(rad_to_deg(angle_difference(atan2(lat_a.z, lat_a.x), atan2(lat_b.z, lat_b.x))))
			if pl[k] and pl[k - 1]:
				if dy < 0.2:
					continue
				# (Pivoting on the ball or the heel by dy, that point stays put; round the middle both move ~ dy x 6 cm.)
				var held := minf((b[k] as Vector3).distance_to(b[k - 1]), (h[k] as Vector3).distance_to(h[k - 1]))
				if held > deg_to_rad(dy) * 0.05:
					out.twist += dy
					out.twist_max = maxf(out.twist_max, dy)
				else:
					out.pivot += dy
			elif not pl[k] and not pl[k - 1]:
				if dy > 15.0 and OS.get_environment("G1_FEET") != "":
					print("SPIN frame %d foot %d %.0f deg" % [k, i, dy])
				out.spin = maxf(out.spin, dy)
	return out
