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
	for dmg: float in [8.0, 16.0, 30.0, 60.0]:
		for region: int in [UltraLimbs.Region.SHIN_L, UltraLimbs.Region.THIGH_R]:
			for delay: int in [0, 9, 18, 27]:
				var t := _marksman(marker("spawn").global_position + Vector3(-14 + delay * 0.1, 0, -2 - dmg * 0.05), OS.get_environment("GM_NOMM") == "")
				await ticks(40)
				var r := t.ragdoll as MarksmanRagdoll
				bot(t).set_steps([{"ticks": 400, "move": Vector2(0, 1), "yaw": 0.0}])
				await ticks(45 + delay)
				t.react_to_hit(region, Vector3(0, 0, 1), dmg)
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
	info("outcomes by damage: %s" % [outcomes])
	check(not (outcomes["8"] as Dictionary).has("fell") and not (outcomes["8"] as Dictionary).has("staggered"), "a graze doesn't stagger or floor (%s)" % [outcomes["8"]])
	check(int((outcomes["30"] as Dictionary).get("staggered", 0)) + int((outcomes["30"] as Dictionary).get("fell", 0)) > 0, "a solid leg hit staggers (%s)" % [outcomes["30"]])
	check((outcomes["60"] as Dictionary).size() > 1 or not (outcomes["60"] as Dictionary).has("fell"),
			"even a heavy leg hit isn't a guaranteed fall: the outcome depends on the moment (%s)" % [outcomes["60"]])



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
