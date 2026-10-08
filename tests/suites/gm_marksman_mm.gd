extends UltraTestSuite
## Marksman with motion matching (MarksmanCharacter.motion_matching): the legs the player asks for are matched clips;
## what happens TO the body is still Sinew's - a push hands the legs to the gait's catching steps (and may trip it),
## a ball / hard hit staggers it through the balancer - and the matcher takes the legs back afterwards.

const Id := MotorState.Id


func _marksman(at: Vector3, mm := true) -> MarksmanCharacter:
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


func _pusher(at: Vector3) -> SinewCharacter:
	var c := SinewCharacter.new()
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


## Hold the throw button for `hold` ticks facing -Z, then let go.
func _press(c: SinewCharacter, hold: int) -> void:
	(c.input_source as BotInputSource).set_steps([{"ticks": hold, "yaw": 0.0, "buttons": InputFrame.B_THROW}, {"ticks": 120, "yaw": 0.0}])


## The target faces the pusher (+Z) and stands still.
func _stand(t: MarksmanCharacter) -> void:
	bot(t).live_yaw = PI
	bot(t).set_steps([{"ticks": 600, "yaw": PI}])


func test_matching_has_the_legs() -> void:
	load_playground()
	var c := _marksman(marker("spawn").global_position + Vector3(-6, 0, 0))
	await ticks(60)
	var r := c.ragdoll as MarksmanRagdoll
	var drv := c.anim as MarksmanAnimDriver
	check(drv.mm != null and r.mm_legs(), "the matcher walks the unarmed stance")
	bot(c).set_steps([{"ticks": 90, "move": Vector2(0, 1)}])
	await ticks(90)
	check(drv._cur_loco == "mm" and r.gait_w < 0.01, "walking shows matched clips, not the gait (loco %s, gait %.2f)" % [drv._cur_loco, r.gait_w])


func test_a_tap_steps_back_then_matching_resumes() -> void:
	load_playground()
	var at := marker("spawn").global_position + Vector3(-6, 0, 0)
	var p := _pusher(at)
	var t := _marksman(at + Vector3(0, 0, -0.85))
	_stand(t)
	await ticks(60)
	var r := t.ragdoll as MarksmanRagdoll
	var from := t.state.pos
	var tripped := [false]
	t.tripped.connect(func(_v: Vector3) -> void: tripped[0] = true)
	_press(p, 3)
	var gait_took := false
	var stepped := false
	var furthest := 0.0
	for i in 150:
		await ticks(1)
		furthest = maxf(furthest, -(t.state.pos.z - from.z))
		gait_took = gait_took or (r.stumbling_gait() and r.gait_w > 0.5)
		if r.gait_w > 0.5:
			var st: Dictionary = r.world.physics.call("character_gait_state", r._id)
			stepped = stepped or not bool(st.planted_l) or not bool(st.planted_r)
	info("tap on a matched Marksman: back %.2f m, gait took the legs %s, stepped %s, state %s" % [furthest, gait_took, stepped, Id.keys()[t.state.state]])
	check(gait_took and stepped, "the gait's catching steps took the legs")
	check(furthest > 0.2 and furthest < 1.2, "a step or two back (%.2f m)" % furthest)
	check(not tripped[0] and t.state.state in [Id.IDLE, Id.MOVE], "and it stayed on its feet")
	await ticks(90)
	var drv := t.anim as MarksmanAnimDriver
	check(not r.stumbling_gait() and r.gait_w < 0.01 and drv._cur_loco == "mm" and drv.mm_pass.weight > 0.95,
			"then the matcher has the legs again (stumble %s, gait %.2f, pass %.2f)" % [r.stumbling_gait(), r.gait_w, drv.mm_pass.weight])


func test_a_full_push_stumbles_then_trips() -> void:
	load_playground()
	var at := marker("spawn").global_position + Vector3(-9, 0, 0)
	var p := _pusher(at)
	var t := _marksman(at + Vector3(0, 0, -0.85))
	_stand(t)
	await ticks(60)
	var from := t.state.pos
	var tripped_at := [Vector3.INF]
	t.tripped.connect(func(_v: Vector3) -> void: tripped_at[0] = t.state.pos)
	_press(p, 50)
	var down := false
	for i in 150:
		await ticks(1)
		down = down or t.state.state == Id.RAGDOLL
	var went: float = -((tripped_at[0] as Vector3).z - from.z) if tripped_at[0] != Vector3.INF else 0.0
	info("full push on a matched Marksman: stumbled %.2f m, then %s" % [went, "tripped" if tripped_at[0] != Vector3.INF else "caught itself"])
	check(tripped_at[0] != Vector3.INF and down, "it trips and goes down")
	check(went > 0.15, "after stumbling back first (%.2f m)" % went)


func test_a_ball_staggers_then_matching_resumes() -> void:
	load_playground()
	var at := marker("spawn").global_position + Vector3(-12, 0, -3)
	var shooter := _pusher(at + Vector3(0, 0, 6))
	var t := _marksman(at)
	_stand(t)
	await ticks(120)
	var r := t.ragdoll as MarksmanRagdoll
	var chest := r._part("Chest")
	var hips0: Vector3 = r.pose_now[0].origin
	var from: Vector3 = r.pose_now[chest].origin + Vector3(0, 0, 4.0)
	SinewBall.launch(shooter, from, r.pose_now[chest].origin - from, ItemDB.get_def(&"ball_launcher"))
	var stag := false
	var back := 0.0
	for i in 90:
		await ticks(1)
		stag = stag or r.staggering()
		back = maxf(back, hips0.z - r.pose_now[0].origin.z)
	info("ball on a matched Marksman's chest: staggered %s, hips back %.2f m, state %s" % [stag, back, Id.keys()[t.state.state]])
	check(stag and back > 0.02, "the balancer took it (staggered, rocked back %.2f m)" % back)
	check(t.state.state not in [Id.RAGDOLL, Id.DEAD], "one ball doesn't floor it")
	await ticks(120)
	var drv := t.anim as MarksmanAnimDriver
	check(not r.staggering() and drv._cur_loco == "mm" and drv.mm_pass._w > 0.95,
			"then the matcher has the legs again (staggering %s, pass %.2f)" % [r.staggering(), drv.mm_pass._w])
	# And it walks off on matched clips.
	var p0 := t.state.pos
	bot(t).set_steps([{"ticks": 60, "move": Vector2(0, 1), "yaw": PI}])
	await ticks(60)
	check(t.state.pos.distance_to(p0) > 0.5 and r.gait_w < 0.01, "and walks off on matched clips (%.2f m)" % t.state.pos.distance_to(p0))


## Shots are felt through the body: a light one rocks it / pushes the feet, a leg shot goes into the leg (knocked,
## weak for a moment) with the balancer holding the body up on the other - how it ends is simulated, not scripted:
## the same shot at different moments of the stride can be caught or can floor the body.
func test_leg_shots_are_simulated() -> void:
	load_playground()
	var rows := []
	var outcomes := {}
	var min_moved := INF
	var lurch := 0.0
	for dmg: float in [8.0, 16.0, 30.0, 60.0]:
		for region: int in [UltraLimbs.Region.SHIN_L, UltraLimbs.Region.THIGH_R]:
			for delay: int in [0, 9, 18, 27]:
				var t := _marksman(marker("spawn").global_position + Vector3(-14 + delay * 0.1, 0, -2 - dmg * 0.05), OS.get_environment("GM_NOMM") == "")
				await ticks(40)
				var r := t.ragdoll as MarksmanRagdoll
				bot(t).set_steps([{"ticks": 400, "move": Vector2(0, 1), "yaw": 0.0}])
				await ticks(45 + delay)
				var hit_at := t.state.pos
				var v0 := Vector2(t.state.vel.x, t.state.vel.z).length()
				t.react_to_hit(region, Vector3(0, 0, 1), dmg)
				var moved := 0.0
				var peak := 0.0
				var stag := false
				var stumble := false
				var fell := false
				var why := ""
				for i in 150:
					await ticks(1)
					if r.staggering():
						var bs: Dictionary = r.balance_state()
						why = "%s fallen=%s steps=%s err=%.2f" % [bs.get("reason", "?"), bs.get("fallen", false), bs.get("steps", 0), float(bs.get("capture_error", 0.0))]
					stag = stag or r.staggering()
					stumble = stumble or r.stumbling_gait()
					fell = fell or t.state.state == Id.RAGDOLL
					if i == 59:
						moved = -(t.state.pos.z - hit_at.z)
					if i < 40:
						peak = maxf(peak, -t.state.vel.z)
				if not fell:
					min_moved = minf(min_moved, moved)
				lurch = maxf(lurch, peak - v0)
				var how := "fell" if fell else ("staggered" if stag else ("stumbled" if stumble else "flinched"))
				rows.append("%3.0f dmg %-7s +%2d ticks: %s  (%s)" % [dmg, UltraLimbs.NAMES[region], delay, how, why])
				var key := "%d" % dmg
				if not outcomes.has(key):
					outcomes[key] = {}
				outcomes[key][how] = int(outcomes[key].get(how, 0)) + 1
				chars.erase(t)
				t.queue_free()
				await ticks(3)
	for line: String in rows:
		info(line)
	info("outcomes by damage: %s; on its feet it went on at least %.2f m in the second after (walking 1.35); lurch up to +%.2f m/s" % [outcomes, min_moved, lurch])
	check(not (outcomes["8"] as Dictionary).has("fell"), "a graze doesn't floor (%s)" % [outcomes["8"]])
	# (On the move a leg hit is a stumble the way it's going, never a stagger on the spot: the body doesn't stop dead.)
	for k: String in outcomes:
		check(not (outcomes[k] as Dictionary).has("staggered"), "%s dmg on the move: no stagger on the spot (%s)" % [k, outcomes[k]])
	check(int((outcomes["30"] as Dictionary).get("stumbled", 0)) + int((outcomes["30"] as Dictionary).get("fell", 0)) > 0, "a solid leg hit stumbles it (%s)" % [outcomes["30"]])
	check(min_moved > 0.7 and lurch > 0.3, "it stumbles on along its way - no freeze (at least %.2f m in 1 s, lurch +%.2f m/s)" % [min_moved, lurch])
	check((outcomes["60"] as Dictionary).size() > 1 or not (outcomes["60"] as Dictionary).has("fell"),
			"even a heavy leg hit isn't a guaranteed fall: the outcome depends on the moment (%s)" % [outcomes["60"]])
	var falls := func(k: String) -> int: return int((outcomes[k] as Dictionary).get("fell", 0))
	check(falls.call("16") <= falls.call("30") and falls.call("30") <= falls.call("60"),
			"harder leg hits floor the body more often (%d / %d / %d of 8)" % [falls.call("16"), falls.call("30"), falls.call("60")])



## Feet on the ground with matched clips (MarksmanMMPass ground fit): the playground's stairs and ramps up and down,
## unarmed and with the rifle, measured like s10 (SinewMoveMetrics: soles probed from above, calibrated on the
## idle; legs as capsules; hips).
const GROUND_SEGS := ["@flat", "idle unarmed", "@reset", "walk fwd", "@stairs", "stairs up", "stairs down",
		"@ramp:20:up", "ramp 20 up", "@ramp:20:down", "ramp 20 down", "@ramp:30:up", "ramp 30 up", "@ramp:30:down", "ramp 30 down"]
## Sink into the ground past flat walking (m) and hips below standing, per kind.
const GROUND_LIMITS := {"stairs": {"sink": 0.20, "hips": 0.30}, "ramp": {"sink": 0.03, "hips": 0.22}}


func test_feet_on_stairs_and_ramps() -> void:
	var map := load_playground()
	for item: StringName in [&"", &"rifle"]:
		var c := _marksman(marker("spawn").global_position)
		await ticks(40)
		var sl := 0
		if item != &"":
			UltraItems.give(c, item)
			for i in c.inventory.size():
				var it := c.inventory.get_slot(i)
				if it and it.def_id == item:
					sl = i + 1
		var m := SinewMoveMetrics.new(c)
		var b := bot(c)
		for s: Array in SinewMoveSegments.all():
			var label: String = s[0]
			if not label in GROUND_SEGS:
				continue
			var inp: Dictionary = s[2]
			if label.begins_with("@"):
				m.label = ""
				var at := SinewMoveSegments.place(label, map)
				if not at.is_empty():
					c.teleport(at[0], at[1])
					b.live_yaw = at[1]
			else:
				m.label = label
			var step := {"ticks": int(s[1]) + 1, "move": inp.get("move", Vector2.ZERO), "slot": sl}
			if inp.has("yaw"):
				step["yaw"] = deg_to_rad(float(inp.yaw))
			b.set_steps([step])
			await ticks(int(s[1]))
		m.label = ""
		m.detach()
		m.calibrate("idle unarmed")
		var dump := OS.get_environment("GM_DUMP")
		if dump != "":
			for f: Dictionary in m.frames:
				if String(f.label).contains(dump) and SinewMoveMetrics.legs_gap(f.bones) < 0.0:
					var bs: Dictionary = f.bones
					var h: Vector3 = bs.Hips
					var y := float(f.body)
					var rt := Vector3(cos(y), 0, -sin(y))
					var fw := Vector3(-sin(y), 0, -cos(y))
					var loc := func(p: Vector3) -> String: return "(r%+.2f f%+.2f u%+.2f)" % [(p - h).dot(rt), (p - h).dot(fw), p.y - h.y]
					print("GAP %s t%d %.1f cm %s kneeL %s kneeR %s footL %s footR %s" % [f.label, f.t, SinewMoveMetrics.legs_gap(bs) * 100.0, SinewMoveMetrics.legs_gap_pair(bs),
							loc.call(bs.LeftLowerLeg), loc.call(bs.RightLowerLeg), loc.call(bs.LeftFoot), loc.call(bs.RightFoot)])
		var name := "unarmed" if item == &"" else String(item)
		info("%s, matched:\n%s" % [name, m.table()])
		var flat: float = m.summary("walk fwd").sink
		for lab: String in m.labels():
			var kind := "stairs" if lab.contains("stairs") else ("ramp" if lab.contains("ramp") else "")
			if kind == "":
				continue
			var sm := m.summary(lab)
			var lim: Dictionary = GROUND_LIMITS[kind]
			# (Legs: the unarmed clips' shins graze ~1 cm on flat ground already - walk fwd -0.6 cm.)
			check(float(sm.sink) - flat <= float(lim.sink) and float(sm.hips_drop) <= float(lim.hips) and float(sm.gap_min) >= -0.016,
					"%s %s: sink %.1f cm, hips -%.1f cm, legs gap %.1f cm" % [name, lab, (float(sm.sink) - flat) * 100.0, float(sm.hips_drop) * 100.0, float(sm.gap_min) * 100.0])
		chars.erase(c)
		c.queue_free()
		await ticks(3)


## Ledges (the user's rules): crouched, walking up to a drop takes the climb-down; standing it doesn't - the feet keep
## to the lip, and walking on, the body goes over with Sinew's balancer meeting the ground (no canned fall clip).
func test_ledges() -> void:
	load_playground()
	var top := marker("drop_2").global_position           # a 4 x 4 m block 2 m high, facing its +Z edge (2 m ahead)
	# Crouched: the climb-down.
	var c := _marksman(top, true)
	bot(c).live_yaw = PI
	bot(c).set_steps([{"ticks": 40, "yaw": PI, "buttons": InputFrame.B_CROUCH}, {"ticks": 160, "move": Vector2(0, 1), "yaw": PI, "buttons": InputFrame.B_CROUCH}])
	var climbed := false
	for i in 200:
		await ticks(1)
		climbed = climbed or c.state.state == Id.LEDGE_CLIMB
	check(climbed, "crouched, walking up to the 2 m drop climbs down (state %s)" % Id.keys()[c.state.state])
	chars.erase(c)
	c.queue_free()
	await ticks(3)
	# Standing: up to the lip and stop - the planted feet stay on the block.
	c = _marksman(top, true)
	var r := c.ragdoll as MarksmanRagdoll
	bot(c).live_yaw = PI
	bot(c).set_steps([{"ticks": 40, "yaw": PI}, {"ticks": 600, "move": Vector2(0, 0.5), "yaw": PI}])
	await ticks(40)
	var stopped := false
	for i in 300:
		await ticks(1)
		if c.state.pos.z > top.z + 1.72:                     # the capsule 0.28 m short of the edge: stop there
			bot(c).set_steps([{"ticks": 600, "yaw": PI}])
			stopped = true
			break
	await ticks(60)
	var sk := c.skeleton
	var off_edge := 0
	# (The shown pose is only readable at skeleton_updated: read later, the bones are the clip's, before any pass.)
	var shown := {}
	var grab := func() -> void:
		for side in ["Left", "Right"]:
			for b in ["Foot", "Toes"]:
				shown[side + b] = (sk.global_transform * sk.get_bone_global_pose(sk.find_bone(side + b))).origin
	sk.skeleton_updated.connect(grab)
	await ticks(2)
	sk.skeleton_updated.disconnect(grab)
	for side in ["Left", "Right"]:
		var ankle: Vector3 = shown[side + "Foot"]
		var toe: Vector3 = shown[side + "Toes"]
		for p: Vector3 in [ankle, toe]:
			if p.z > top.z + 2.0 + 0.02:
				off_edge += 1
				info("past the edge: %s %s by %.1f cm" % [side, "ankle" if p == ankle else "toe", (p.z - top.z - 2.0) * 100.0])
	info("at the lip: capsule %.2f m from the edge, feet points past it: %d" % [top.z + 2.0 - c.state.pos.z, off_edge])
	check(stopped and off_edge == 0 and c.state.state in [Id.IDLE, Id.MOVE], "standing at the lip, the feet stay on the block (%d points past the edge)" % off_edge)
	# And walking on: no climb-down, and going off forward is on purpose - a plain drop, landed on its feet (the body meets
	# the landing - MarksmanRagdoll.land_brace - but no fall).
	bot(c).set_steps([{"ticks": 200, "move": Vector2(0, 1), "yaw": PI}])
	var down_move := false
	var stag_air := false
	var fell := false
	var states := {}
	for i in 200:
		await ticks(1)
		down_move = down_move or c.state.state == Id.LEDGE_CLIMB
		stag_air = stag_air or (r.staggering() and not c.state.is_grounded())
		fell = fell or c.state.state == Id.RAGDOLL
		states[Id.keys()[c.state.state]] = true
	info("standing, walked off the 2 m drop forward: Sinew's fall %s, went down %s, states %s" % [stag_air, fell, states.keys()])
	check(not down_move, "standing, no climb-down")
	check(not stag_air and not fell and c.state.pos.y < 0.3, "walking off forward is a plain drop, landed on its feet")
	chars.erase(c)
	c.queue_free()
	await ticks(3)
	# Backing off it is an accident: over the edge, Sinew has the body.
	c = _marksman(top, true)
	r = c.ragdoll as MarksmanRagdoll
	bot(c).live_yaw = 0.0
	bot(c).set_steps([{"ticks": 40, "yaw": 0.0}, {"ticks": 400, "move": Vector2(0, -1), "yaw": 0.0}])
	var stag := false
	for i in 300:
		await ticks(1)
		stag = stag or (r.staggering() and not c.state.is_grounded())
	var lay := (r.pose_now[0] as Transform3D).origin if not r.pose_now.is_empty() else c.state.pos
	info("backed off the 2 m drop: Sinew's fall %s, state %s, hips came to rest %.2f m out from the wall, %.2f m up" % [stag,
			Id.keys()[c.state.state], lay.z - (top.z + 2.0), lay.y])
	check(stag, "backing off the edge, the body is Sinew's (an accident)")
	check(lay.y < 1.0 and lay.z > top.z + 2.25, "and it went into the drop - down there, out from the wall (%.2f m)" % (lay.z - top.z - 2.0))
	chars.erase(c)
	c.queue_free()
	await ticks(3)
	# Below the ledge height (0.6 m) a drop is a step down, any way it's taken: off the 0.5 m wall backwards plainly. Off
	# the 1.0 m wall forward plainly, backwards Sinew's.
	for wall: Array in [[0.5, 58.0, -1, false], [1.0, 63.0, 1, false], [1.0, 63.0, -1, true]]:
		c = _marksman(Vector3(float(wall[1]), float(wall[0]) + 0.05, -30.0), true)
		r = c.ragdoll as MarksmanRagdoll
		var yaw := PI if int(wall[2]) > 0 else 0.0
		bot(c).live_yaw = yaw
		bot(c).set_steps([{"ticks": 40, "yaw": yaw}])
		await ticks(40)
		bot(c).set_steps([{"ticks": 250, "move": Vector2(0, float(wall[2])), "yaw": yaw}])
		var took := false
		var landed := false
		for i in 250:
			await ticks(1)
			took = took or (r.staggering() and not c.state.is_grounded())
			landed = landed or c.state.pos.y < 0.2
		var how := "forward" if int(wall[2]) > 0 else "backwards"
		info("off the %.1f m wall %s: Sinew took the body %s" % [wall[0], how, took])
		check(landed and took == bool(wall[3]), "off the %.1f m wall %s: %s" % [wall[0], how, "Sinew takes the body (an accident)" if wall[3] else "a plain drop"])
		chars.erase(c)
		c.queue_free()
		await ticks(3)


## Gaps (the gap walk: a 0.6 m high path with gaps of 0.4 / 0.7 / 1.0 / 1.4 m): one the legs can span along the way the
## body goes is crossed in a stride - no fall, no foot put down in it; one wider than that is a fall like any edge.
const GAPS := [[108.0, 107.6], [104.6, 103.9], [100.9, 99.9], [96.9, 95.5]]


## (Feet are counted only over the gaps meant to be strides at this pace: falling into a wider one they go down it.)
func _gap_run(sprint: bool, strides: int) -> Dictionary:
	var c := _marksman(marker("gap_walk").global_position, true)
	bot(c).live_yaw = 0.0
	await ticks(40)
	var sk := c.skeleton
	var res := {"crossed": [false, false, false, false], "fell_at": -1, "foot_in_gap": 0, "states": {}}
	var feet := [sk.find_bone("LeftFoot"), sk.find_bone("RightFoot")]
	var grab := func() -> void:
		for f: int in feet:
			var p := (sk.global_transform * sk.get_bone_global_pose(f)).origin
			if p.y < 0.6 + 0.12 and p.y > 0.4:            # a foot down at the path's height ..
				for gi in strides:
					var g: Array = GAPS[gi]
					if p.z < float(g[0]) - 0.03 and p.z > float(g[1]) + 0.03 and absf(p.x) < 1.0:
						res.foot_in_gap += 1          # .. over a gap
	sk.skeleton_updated.connect(grab)
	bot(c).set_steps([{"ticks": 600, "move": Vector2(0, 1), "yaw": 0.0, "buttons": InputFrame.B_SPRINT if sprint else 0}])
	for i in 600:
		await ticks(1)
		(res.states as Dictionary)[Id.keys()[c.state.state]] = true
		for k in GAPS.size():
			if c.state.pos.z < float(GAPS[k][1]) - 0.3 and c.state.pos.y > 0.5:
				res.crossed[k] = true
		if res.fell_at < 0 and c.state.pos.y < 0.4:
			res.fell_at = c.state.pos.z
		if c.state.pos.z < 92.0 or (res.fell_at >= 0 and i > 0 and c.state.state in [Id.IDLE, Id.MOVE, Id.GET_UP, Id.RAGDOLL] and c.state.pos.y < 0.2):
			break
	sk.skeleton_updated.disconnect(grab)
	chars.erase(c)
	c.queue_free()
	await ticks(3)
	return res


func test_gaps_are_strides() -> void:
	load_playground()
	var walk: Dictionary = await _gap_run(false, 2)
	info("walking the gap walk: crossed %s, fell at z %.1f, feet planted in a gap %d frames, states %s" % [walk.crossed, walk.fell_at, walk.foot_in_gap, (walk.states as Dictionary).keys()])
	check(walk.crossed[0] and walk.crossed[1], "walking, the 0.4 and 0.7 m gaps are strides")
	check(not walk.crossed[2] and walk.fell_at < 100.9 and walk.fell_at > 99.0, "the 1.0 m gap is wider than a walking stride: it falls there (z %.1f)" % walk.fell_at)
	check(walk.foot_in_gap == 0, "no foot put down in a gap (%d frames)" % walk.foot_in_gap)
	var run: Dictionary = await _gap_run(true, 4)
	info("sprinting the gap walk: crossed %s, fell at z %.1f, feet planted in a gap %d frames, states %s" % [run.crossed, run.fell_at, run.foot_in_gap, (run.states as Dictionary).keys()])
	check(run.crossed == [true, true, true, true] and run.fell_at < 0, "sprinting, every gap up to 1.4 m is a stride")
	check(run.foot_in_gap == 0, "no foot put down in a gap (%d frames)" % run.foot_in_gap)


## Motion matching covers every stance and posture: pistol standing, unarmed / rifle / pistol crouched - 8 ways each,
## the matched clips show (not the gait), the body goes where it's told, the legs don't go through each other.
func test_crouch_and_pistol_are_matched() -> void:
	load_playground()
	const D := 0.70710678
	var dirs := {"f": Vector2(0, 1), "fr": Vector2(D, D), "r": Vector2(1, 0), "br": Vector2(D, -D), "b": Vector2(0, -1),
			"bl": Vector2(-D, -D), "l": Vector2(-1, 0), "fl": Vector2(-D, D)}
	var spot := marker("spawn").global_position + Vector3(-16, 0, -3)
	for spec: Array in [[&"pistol", false], [&"", true], [&"rifle", true], [&"pistol", true]]:
		var c := _marksman(spot, true)
		await ticks(40)
		var sl := 0
		if spec[0] != &"":
			UltraItems.give(c, spec[0])
			for i in c.inventory.size():
				var it := c.inventory.get_slot(i)
				if it and it.def_id == spec[0]:
					sl = i + 1
		var buttons := InputFrame.B_CROUCH if spec[1] else 0
		var r := c.ragdoll as MarksmanRagdoll
		var drv := c.anim as MarksmanAnimDriver
		var m := SinewMoveMetrics.new(c)
		m.record_sinks = false
		var name := "%s %s" % ["unarmed" if spec[0] == &"" else String(spec[0]), "crouched" if spec[1] else "standing"]
		var bad := []
		for d: String in dirs:
			m.label = ""
			c.teleport(spot, 0.0)
			bot(c).live_yaw = 0.0
			bot(c).set_steps([{"ticks": 40, "buttons": buttons, "slot": sl, "yaw": 0.0}])
			await ticks(40)
			var from := c.state.pos
			m.label = d
			var shown := true
			bot(c).set_steps([{"ticks": 76, "move": dirs[d], "buttons": buttons, "slot": sl, "yaw": 0.0}])
			for i in 75:
				await ticks(1)
				if i > 15:
					shown = shown and drv._cur_loco == "mm" and r.gait_w < 0.05
			var moved := c.state.pos - from
			var want := Vector3(dirs[d].x, 0, -dirs[d].y)
			var s := m.summary(d)
			var ok: bool = shown and moved.normalized().dot(want) > 0.9 and moved.length() > 0.5 and float(s.gap_min) >= -0.02
			if not ok:
				bad.append("%s (shown %s, moved %.2f m at %.0f deg off, gap %.1f cm)" % [d, shown, moved.length(), rad_to_deg(moved.normalized().angle_to(want)), float(s.gap_min) * 100.0])
		m.label = ""
		m.detach()
		info("%s matched:\n%s" % [name, m.table()])
		check(bad.is_empty(), "%s: 8 ways on matched clips, legs clear (%s)" % [name, bad])
		chars.erase(c)
		c.queue_free()
		await ticks(3)


## A hurt leg limps in stages: the limp layer's weight is the leg's damage (UltraInjury.leg_damage), and the body
## lurches more over the stride the worse the leg (the injured walk's limp is in the body: its feet stay down equally long).
func test_limp_in_stages() -> void:
	load_playground()
	var rows := []
	var ratios := []
	for hp: float in [100.0, 70.0, 55.0, 25.0]:
		var c := _marksman(marker("spawn").global_position + Vector3(-16, 0, -3), true)
		await ticks(30)
		c.state.limb_hp[UltraLimbs.Region.THIGH_L] = hp
		var drv := c.anim as MarksmanAnimDriver
		var sk := c.skeleton
		var down := [0, 0]
		var gap := [9.0]
		var clips := {}
		var lurch := [9.0, -9.0]
		var grab := func() -> void:
			var b := {}
			for n in SinewMoveMetrics.BONES:
				var i := sk.find_bone(n)
				if i >= 0:
					b[n] = (sk.global_transform * sk.get_bone_global_pose(i)).origin
			gap[0] = minf(gap[0], SinewMoveMetrics.legs_gap(b))
			# The lurch: the head's sideways offset over the hips (body frame), its swing over the stride.
			var y := c.state.body_yaw
			var side := ((b.Head as Vector3) - (b.Hips as Vector3)).dot(Vector3(cos(y), 0, -sin(y)))
			lurch[0] = minf(lurch[0], side)
			lurch[1] = maxf(lurch[1], side)
			# (Down = planted in what shows: the clips' own contacts, the walk's or the limp's once it is most of it.)
			for k in 2:
				if drv.mm_pass._planted(k):
					down[k] += 1
			if drv.mm_limp.clip >= 0:
				var cn := String(drv.mm_limp.db.clips[drv.mm_limp.clip].name).get_file()
				clips[cn] = int(clips.get(cn, 0)) + 1
		bot(c).set_steps([{"ticks": 200, "move": Vector2(0, 1), "yaw": 0.0}])
		await ticks(50)
		sk.skeleton_updated.connect(grab)
		await ticks(150)
		sk.skeleton_updated.disconnect(grab)
		var ratio := float(lurch[1]) - float(lurch[0])                   # the head's sideways swing over the hips (m)
		var want := UltraInjury.leg_damage(c.state, true)
		rows.append("left thigh %3.0f %%: damage %.2f, limp layer %.2f, head lurch %.1f cm, feet down R %d / L %d, speed %.2f m/s, legs gap %.1f cm" % [hp, want, drv.limp_w, ratio * 100.0, down[1], down[0], Vector2(c.state.vel.x, c.state.vel.z).length(), gap[0] * 100.0])
		ratios.append(ratio)
		rows.append("   limp clips: %s" % [clips])
		check(absf(drv.limp_w - want) < 0.1, "left thigh at %.0f %%: the limp shows as much as the leg is hurt (%.2f vs %.2f)" % [hp, drv.limp_w, want])
		check(gap[0] >= -0.02, "left thigh at %.0f %%: legs clear (%.1f cm)" % [hp, gap[0] * 100.0])
		chars.erase(c)
		c.queue_free()
		await ticks(3)
	for r: String in rows:
		info(r)
	check(ratios[1] >= ratios[0] - 0.005 and ratios[2] >= ratios[1] - 0.005 and ratios[3] > ratios[0] * 1.5,
			"the worse the leg, the bigger the lurch (%.1f / %.1f / %.1f / %.1f cm)" % [ratios[0] * 100.0, ratios[1] * 100.0, ratios[2] * 100.0, ratios[3] * 100.0])


## Jumps and landings: in the air the legs come down to meet the ground before it arrives (the predicted landing), a
## hop or a running jump lands on the animation and the matcher carries on, a jump down a drop is landed by the body
## (Sinew powered a moment before touchdown, the balancer on: it catches itself or goes down - the simulation's).
func _jump_run(c: MarksmanCharacter, steps: Array, n: int) -> Dictionary:
	var r := c.ragdoll as MarksmanRagdoll
	var drv := c.anim as MarksmanAnimDriver
	var sk := c.skeleton
	var out := {"feet_at_touch": INF, "ready_max": 0.0, "braced": 0, "staggered": false, "down": false, "locos": {}, "air": false, "after": ""}
	var was_air := [false]
	var touch := [-1]
	var frame := [0]
	var feet := func() -> void:
		var lo := INF
		for b in ["LeftFoot", "RightFoot"]:
			lo = minf(lo, (sk.global_transform * sk.get_bone_global_pose(sk.find_bone(b))).origin.y)
		if touch[0] == frame[0]:
			out.feet_at_touch = lo - c.state.pos.y
	sk.skeleton_updated.connect(feet)
	var before := r.landed_braced
	bot(c).set_steps(steps)
	for i in n:
		frame[0] = i
		var air := not c.state.is_grounded()
		if was_air[0] and not air and touch[0] < 0:
			touch[0] = i + 1                     # (the shown pose a frame on: the first one drawn on the ground)
		was_air[0] = air
		out.air = out.air or air
		out.ready_max = maxf(out.ready_max, drv.legs_ready)
		out.staggered = out.staggered or r.staggering()
		out.down = out.down or c.state.state == Id.RAGDOLL
		out.locos[drv._cur_loco] = true
		if OS.get_environment("GM_DUMP") != "" and (r.staggering() or air):
			var bs := r.balance_state()
			print("t%d %s y %.2f vy %.2f %s fallen %s %s com %s comv %s" % [i, Id.keys()[c.state.state], c.state.pos.y, c.state.vel.y, drv._cur_loco,
					bs.get("fallen", "-"), bs.get("reason", ""), bs.get("com", ""), bs.get("com_velocity", "")])
		if touch[0] >= 0 and i == touch[0] + 50:
			out.after = drv._cur_loco
		await ticks(1)
	sk.skeleton_updated.disconnect(feet)
	out.braced = r.landed_braced - before
	return out


func test_jumps_and_landings() -> void:
	load_playground()
	# A hop on the spot.
	var c := _marksman(marker("spawn").global_position + Vector3(-6, 0, 0))
	await ticks(60)
	var o := await _jump_run(c, [{"ticks": 4, "buttons": InputFrame.B_JUMP}, {"ticks": 200}], 150)
	info("hop: legs ready %.2f, feet %.1f cm over the soles at touchdown, braced %d, after %s, locos %s" % [o.ready_max, o.feet_at_touch * 100.0, o.braced, o.after, o.locos.keys()])
	check(o.air and o.ready_max > 0.8, "a hop: the legs reach for the ground before touchdown (%.2f)" % o.ready_max)
	check(o.feet_at_touch < 0.15, "a hop lands on its feet, not folded legs (lowest ankle %.1f cm up)" % (o.feet_at_touch * 100.0))
	check(o.braced == 0 and not o.staggered and o.after == "mm", "a hop is the animation's (braced %d, after: %s)" % [o.braced, o.after])
	chars.erase(c)
	c.queue_free()
	await ticks(3)
	# A running jump on flat ground.
	c = _marksman(marker("spawn").global_position + Vector3(-6, 0, 0))
	await ticks(60)
	o = await _jump_run(c, [{"ticks": 70, "move": Vector2(0, 1), "buttons": InputFrame.B_SPRINT}, {"ticks": 4, "move": Vector2(0, 1), "buttons": InputFrame.B_JUMP},
			{"ticks": 200, "move": Vector2(0, 1)}], 170)
	info("running jump: legs ready %.2f, feet %.1f cm, braced %d, after %s, locos %s" % [o.ready_max, o.feet_at_touch * 100.0, o.braced, o.after, o.locos.keys()])
	check(o.air and o.braced == 0 and not o.down and o.after == "mm" and not o.locos.has("land"),
			"a running jump runs on: matched locomotion straight after (locos %s)" % [o.locos.keys()])
	chars.erase(c)
	c.queue_free()
	await ticks(3)
	# A jump down from the 2 m drop: the body meets it (upper body physical into the stop) and stays up; from the 4 m one
	# the balancer has the legs too (it may go down - the simulation's).
	for h in [2, 4]:
		var top := marker("drop_%d" % h).global_position
		c = _marksman(top)
		var r := c.ragdoll as MarksmanRagdoll
		bot(c).live_yaw = PI
		bot(c).set_steps([{"ticks": 40, "yaw": PI}])
		await ticks(40)
		var chest := r._part("Chest")
		var phys := [0.0]
		var watch := func() -> void:
			if c.state.is_grounded() and chest >= 0:
				phys[0] = maxf(phys[0], r.part_w[chest])
		get_tree().physics_frame.connect(watch)
		o = await _jump_run(c, [{"ticks": 70, "move": Vector2(0, 1), "yaw": PI}, {"ticks": 4, "move": Vector2(0, 1), "yaw": PI, "buttons": InputFrame.B_JUMP},
				{"ticks": 300, "yaw": PI}], 260)
		get_tree().physics_frame.disconnect(watch)
		info("jump down %d m: legs ready %.2f, braced %d, chest physical %.2f, staggered %s, went down %s, state now %s, locos %s" % [h, o.ready_max,
				o.braced, phys[0], o.staggered, o.down, Id.keys()[c.state.state], o.locos.keys()])
		check(o.air and o.braced == 1, "a jump down %d m is met by the body (braced %d)" % [h, o.braced])
		check(c.state.pos.y < 0.3, "and it's down there (y %.2f)" % c.state.pos.y)
		if h == 2:
			check(phys[0] > 0.9 and not o.staggered and not o.down, "2 m: the upper body takes the stop physically, the legs land it - on its feet")
		else:
			check(o.staggered, "4 m: the balancer has the legs")
		chars.erase(c)
		c.queue_free()
		await ticks(3)


## Shot in the leg at a sprint: it stumbles or goes down with the momentum it HAS - never flung faster than it ran.
func test_shot_while_sprinting() -> void:
	load_playground()
	var worst := 0.0
	var rows := []
	var falls := {}
	for dmg: float in [16.0, 30.0, 60.0]:
		for delay: int in [0, 7, 14, 21]:
			var t := _marksman(marker("spawn").global_position + Vector3(-20 + delay * 0.3, 0, 10 - dmg * 0.05))
			await ticks(40)
			var r := t.ragdoll as MarksmanRagdoll
			bot(t).set_steps([{"ticks": 400, "move": Vector2(0, 1), "yaw": 0.0, "buttons": InputFrame.B_SPRINT}])
			await ticks(100 + delay)
			var v0 := Vector2(t.state.vel.x, t.state.vel.z).length()
			t.react_to_hit(UltraLimbs.Region.THIGH_R, Vector3(0, 0, 1), dmg)
			var prev := (r.pose_now[0] as Transform3D).origin
			var top := 0.0
			var fell := false
			for i in 150:
				await ticks(1)
				if OS.get_environment("GM_DUMP") != "" and i < 60:
					var gs: Dictionary = r.world.physics.call("character_gait_state", r._id)
					print("t%d %s v %.2f margin %s stepping %s stumble %s" % [i, Id.keys()[t.state.state], Vector2(t.state.vel.x, t.state.vel.z).length(),
							gs.get("capture_margin", "-"), gs.get("stepping", "-"), t.stumbling()])
				var h := (r.pose_now[0] as Transform3D).origin
				top = maxf(top, Vector2(h.x - prev.x, h.z - prev.z).length() * 60.0)
				prev = h
				fell = fell or t.state.state == Id.RAGDOLL
			worst = maxf(worst, top - v0)
			rows.append("%2.0f dmg +%d: ran %.1f m/s, hips up to %.1f m/s, %s" % [dmg, delay, v0, top, "fell" if fell else "kept up"])
			falls[dmg] = int(falls.get(dmg, 0)) + (1 if fell else 0)
			chars.erase(t)
			t.queue_free()
			await ticks(3)
	for line: String in rows:
		info(line)
	check(worst < 2.5, "never flung: the hips at most %.1f m/s over the running speed" % worst)
	info("falls of 4 by damage: %s" % [falls])
	check(int(falls[16.0]) == 0 and int(falls[16.0]) <= int(falls[30.0]) and int(falls[30.0]) <= int(falls[60.0]) and int(falls[60.0]) > 0,
			"a graze runs on; harder hits trip more often (%s)" % [falls])


## Unarmed, the arms are the same kind of arms whichever way it walks or runs: the U_* strafe / run clips hold both hands
## up at the chest - their legs play under borrowed natural arms (MarksmanMotionMatcher.CLIP_ARMS).
func test_unarmed_arms_hang_every_way() -> void:
	load_playground()
	var rows := []
	var hands := {}
	for spec: Array in [["walk fwd", Vector2(0, 1), 0], ["strafe R", Vector2(1, 0), 0], ["strafe L", Vector2(-1, 0), 0],
			["run fwd", Vector2(0, 1), -1], ["run R", Vector2(1, 0), -1], ["run L", Vector2(-1, 0), -1]]:
		var c := _marksman(marker("spawn").global_position + Vector3(-10, 0, 6))
		if int(spec[2]) < 0:
			c.profile.default_gait = MovementProfile.Gait.JOG      # (a run: the U_Run_* clips)
			spec[2] = 0
		await ticks(40)
		var sk := c.skeleton
		var top := [-INF]
		var grab := func() -> void:
			var hy := (sk.global_transform * sk.get_bone_global_pose(sk.find_bone("Hips"))).origin.y
			for b in ["LeftHand", "RightHand"]:
				top[0] = maxf(top[0], (sk.global_transform * sk.get_bone_global_pose(sk.find_bone(b))).origin.y - hy)
		bot(c).set_steps([{"ticks": 200, "move": spec[1], "yaw": 0.0, "buttons": spec[2]}])
		await ticks(60)
		sk.skeleton_updated.connect(grab)
		await ticks(60)
		sk.skeleton_updated.disconnect(grab)
		var drv := c.anim as MarksmanAnimDriver
		hands[spec[0]] = top[0]
		rows.append("%-9s hands up to %.2f m over the hips (clip %s)" % [spec[0], top[0], String(drv._mm_clip).get_file()])
		chars.erase(c)
		c.queue_free()
		await ticks(3)
	for r: String in rows:
		info(r)
	for k: String in ["strafe R", "strafe L"]:
		check(float(hands[k]) < float(hands["walk fwd"]) + 0.12, "%s: the hands hang as walking forward (%.2f vs %.2f m)" % [k, hands[k], hands["walk fwd"]])
	# (A run pumps the arms - the sprint clip to 0.37 m; the U_Run clips' own guard held them at 0.6-0.68.)
	check(float(hands["run R"]) < 0.5 and float(hands["run L"]) < 0.5 and float(hands["run fwd"]) < 0.5 \
			and absf(float(hands["run R"]) - float(hands["run fwd"])) < 0.1 and absf(float(hands["run L"]) - float(hands["run fwd"])) < 0.1,
			"running: natural arms every way (forward %.2f, right %.2f, left %.2f m over the hips)" % [hands["run fwd"], hands["run R"], hands["run L"]])


## On a rope the body hangs from its hands: the arms are the climb clip's, everything below them physics - it lags the
## swing and swings out at its ends - and letting go it eases back into the animation (no snap).
func test_rope_swing_is_physical() -> void:
	load_playground()
	var c := _marksman(marker("parkour_rope").global_position)
	var r := c.ragdoll as MarksmanRagdoll
	var on_rope := [-1]
	var tick := [0]
	bot(c).driver = func(_t: int, _b: BotInputSource) -> InputFrame:
		tick[0] += 1
		var f := InputFrame.new()
		if c.state.state == Id.ROPE:
			if on_rope[0] < 0:
				on_rope[0] = tick[0]
			var k: int = tick[0] - on_rope[0]
			f.move = Vector2(0, 1.0 if c.state.vel.z < 0.0 else -1.0)
			# (Let go swinging back toward the start platform, near the top of the swing: a short drop.)
			if k > 300 and c.state.vel.z > 0.0 and absf(c.state.vel.z) < 1.5:
				f.buttons = InputFrame.B_JUMP
			return f
		if on_rope[0] >= 0:
			return f
		f.move = Vector2(0, 1)
		f.buttons = InputFrame.B_SPRINT | (InputFrame.B_JUMP if c.state.pos.z < -55.4 and c.state.is_grounded() else 0)
		return f
	# The pose as shown, in the skeleton's frame (relative to the character): how fast the limbs move about the body.
	var sk := c.skeleton
	var bones: Array[int] = []
	for b in ["Hips", "Head", "LeftHand", "RightHand", "LeftFoot", "RightFoot"]:
		bones.append(sk.find_bone(b))
	var shown := {"prev": [], "step": 0.0, "bone": 0}
	var grab := func() -> void:
		var now := []
		for b in bones:
			now.append(sk.get_bone_global_pose(b).origin)
		var st := 0.0
		if not (shown.prev as Array).is_empty():
			for k in now.size():
				var d := (now[k] as Vector3).distance_to(shown.prev[k])
				if d > st:
					st = d
					shown.bone = k
		shown.step = st
		shown.prev = now
	sk.skeleton_updated.connect(grab)
	var lag := 0.0
	var phys := false
	var rel_fast := 0.0
	var pop := 0.0
	var released := -1
	for i in 900:
		await ticks(1)
		if on_rope[0] < 0 or r.pose_now.is_empty():
			continue
		if c.state.state == Id.ROPE:
			phys = phys or r.on_rope_physics()
			var anim := r._anim_world()
			if not anim.is_empty():
				lag = maxf(lag, (r.pose_now[0] as Transform3D).origin.distance_to((anim[0] as Transform3D).origin))
			if tick[0] - on_rope[0] > 30:
				rel_fast = maxf(rel_fast, float(shown.step) * 60.0)
				if OS.get_environment("GM_DUMP") != "" and float(shown.step) * 60.0 > 4.0:
					print("R%d step %.1f m/s (%s) vz %.2f y %.2f" % [tick[0] - on_rope[0], float(shown.step) * 60.0, sk.get_bone_name(bones[int(shown.bone)]), c.state.vel.z, c.state.pos.y])
		elif released < 0:
			released = i
		if OS.get_environment("GM_DUMP") != "" and (released < 0 or i - released < 6) and r._anim_world().size() > 0:
			var ah: Vector3 = (r._anim_world()[0] as Transform3D).origin - sk.global_position
			print("A%d %s loco %s anim hips %s phys hips %s" % [i, Id.keys()[c.state.state], (c.anim as MarksmanAnimDriver)._cur_loco, ah.snappedf(0.01),
					((r.pose_now[0] as Transform3D).origin - sk.global_position).snappedf(0.01)])
		if released >= 0 and i - released < 40:
			pop = maxf(pop, float(shown.step))
			if OS.get_environment("GM_DUMP") != "":
				var drv := c.anim as MarksmanAnimDriver
				print("t%d %s loco %s step %.1f cm (%s) hips %s skel %s phys %s left %.2f" % [i - released, Id.keys()[c.state.state], drv._cur_loco, float(shown.step) * 100.0,
						sk.get_bone_name(bones[int(shown.bone)]),
						(shown.prev[0] as Vector3).snappedf(0.01), sk.global_position.snappedf(0.01), r.on_rope_physics(), r._rope_left])
		if released >= 0 and i - released > 60:
			break
	sk.skeleton_updated.disconnect(grab)
	info("rope: caught %s, hanging physics %s, hips swung up to %.2f m off the clip's, limbs about the body up to %.1f m/s, letting go: worst %.1f cm/frame, state %s" % [
			on_rope[0] >= 0, phys, lag, rel_fast, pop * 100.0, Id.keys()[c.state.state]])
	if not check(on_rope[0] >= 0, "caught the rope"):
		return
	check(phys and lag > 0.04, "the body below the hands hangs as physics (hips %.2f m off the clip's)" % lag)
	# (Caught at a run the legs swing on up past the hands - 8-9 m/s about the tilting body, smoothly - then 4-6 a swing.)
	check(rel_fast < 10.0, "nothing flails (limbs about the body <= %.1f m/s)" % rel_fast)
	check(released >= 0 and pop < 0.08, "letting go eases back into the animation (worst %.1f cm/frame about the body)" % (pop * 100.0))
