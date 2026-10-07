extends UltraTestSuite
## Sinew stage 6c: the procedural walk in the game. On the ground a SinewCharacter's pose comes from
## Sinew's gait - key poses sampled off the reference clips, footsteps from its motion - so a planted
## foot stays put on screen, the feet keep up, stairs put each foot on a step.


func _sinew(at: Vector3, gait := true) -> SinewCharacter:
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
	if c.ragdoll is SinewRagdoll and not gait:
		(c.ragdoll as SinewRagdoll).gait = false
		(c.ragdoll as SinewRagdoll)._setup_gait()
	return c


## Per frame (at skeleton_updated, where the shown pose is readable): each foot's ankle and toe
## (world), whether the gait has it planted, and how far the drawn ankle is from the gait's.
func _track_feet(c: SinewCharacter, frames: int) -> Dictionary:
	var r := c.ragdoll as SinewRagdoll
	var sk := c.skeleton
	var feet := [sk.find_bone("LeftFoot"), sk.find_bone("RightFoot")]
	var toes := [sk.find_bone("LeftToes"), sk.find_bone("RightToes")]
	var rec := {"pos": [[], []], "toe": [[], []], "heel": [[], []], "planted": [[], []], "off": 0.0}
	# The heel: on the sole under the ankle, 6 cm back (in the foot bone's frame, from the rest pose;
	# the model faces +Z in skeleton space).
	var heel_local := []
	for f in feet:
		var rest := sk.get_bone_global_rest(f)
		heel_local.append(rest.affine_inverse() * Vector3(rest.origin.x, 0.0, rest.origin.z - 0.06))
	var cb := func() -> void:
		var st: Dictionary = r.world.physics.call("character_gait_state", r._id)
		for i in 2:
			var side := "l" if i == 0 else "r"
			var a := (sk.global_transform * sk.get_bone_global_pose(feet[i])).origin
			rec.pos[i].append(a)
			rec.toe[i].append((sk.global_transform * sk.get_bone_global_pose(toes[i])).origin if toes[i] >= 0 else a)
			rec.heel[i].append(sk.global_transform * sk.get_bone_global_pose(feet[i]) * (heel_local[i] as Vector3))
			var planted := bool(st.get("planted_" + side, false))
			rec.planted[i].append(planted)
			if planted:
				rec.off = maxf(rec.off, a.distance_to(st["ankle_" + side]))
	sk.skeleton_updated.connect(cb)
	for k in frames:
		await get_tree().process_frame
	sk.skeleton_updated.disconnect(cb)
	return rec


## Worst frame-to-frame slide of a planted foot (both frames planted, not just after landing), mm:
## the pivot holds still - the heel at the strike, the ball rolling off - so the smallest of the
## heel's, the ankle's and the toe's moves.
func _worst_slide(rec: Dictionary) -> float:
	var worst := 0.0
	for i in 2:
		var p: Array = rec.pos[i]
		var t: Array = rec.toe[i]
		var h: Array = rec.heel[i]
		var pl: Array = rec.planted[i]
		for k in range(3, p.size()):
			if pl[k] and pl[k - 1] and pl[k - 2] and pl[k - 3]:
				var d := minf(minf((p[k] as Vector3).distance_to(p[k - 1]), (t[k] as Vector3).distance_to(t[k - 1])),
						(h[k] as Vector3).distance_to(h[k - 1]))
				worst = maxf(worst, d)
	return worst * 1000.0


func test_cycles_come_from_the_reference_clips() -> void:
	load_playground()
	var c := _sinew(marker("spawn").global_position)
	await ticks(40)
	var r := c.ragdoll as SinewRagdoll
	var cycles := SinewGaitCycles.build(c.anim, r.parts)
	var clips := []
	for cy in cycles:
		clips.append("%s @ %.2f m/s" % [cy.clip, cy.speed])
	info("gait cycles: %s" % [clips])
	check(cycles.size() == 3, "walk, run and sprint cycles sampled (%d)" % cycles.size())
	check((cycles[0].samples as Array).size() == SinewGaitCycles.SAMPLES and (cycles[0].samples[0] as Array).size() == r.parts.size(), "24 phases x every part")
	check(r._gait_on and r.gait_w > 0.99, "standing: the gait has the body")
	var st: Dictionary = r.world.physics.call("character_gait_state", r._id)
	check(not bool(st.stepping), "and stands still")


func test_walking_feet_stay_planted() -> void:
	load_playground()
	var c := _sinew(marker("spawn").global_position + Vector3(0, 0, -4))
	await ticks(30)
	bot(c).set_steps([{"ticks": 200, "move": Vector2(0, 1)}])
	await ticks(20)
	var rec := await _track_feet(c, 150)
	var slide := _worst_slide(rec)
	var lag := 0.0
	for i in 2:
		var last: Vector3 = rec.pos[i][-1]
		lag = maxf(lag, Vector2(last.x - c.state.pos.x, last.z - c.state.pos.z).length())
	info("walking %.2f m/s: planted foot moves at most %.1f mm a frame, feet within %.2f m of the body" % [Vector2(c.state.vel.x, c.state.vel.z).length(), slide, lag])
	check(slide < 8.0, "planted feet stay put (%.1f mm/frame)" % slide)
	var planted_frames := 0
	for i in 2:
		for v in rec.planted[i]:
			planted_frames += 1 if v else 0
	check(planted_frames > 100, "feet planted most of the time (%d of %d foot-frames)" % [planted_frames, 2 * (rec.pos[0] as Array).size()])
	# What shows IS the gait: the drawn feet on the gait's ankles (within a tick's motion).
	check(float(rec.off) < 0.04, "the drawn feet are the gait's (%.3f m off at worst)" % float(rec.off))
	check(lag < 0.9, "the feet keep up (%.2f m)" % lag)


func test_sprinting_feet_stay_planted() -> void:
	load_playground()
	var c := _sinew(marker("spawn").global_position + Vector3(3, 0, -4))
	await ticks(30)
	bot(c).set_steps([{"ticks": 200, "move": Vector2(0, 1), "buttons": InputFrame.B_SPRINT}])
	await ticks(40)
	var rec := await _track_feet(c, 90)
	var slide := _worst_slide(rec)
	info("sprinting %.2f m/s: planted foot moves at most %.1f mm a frame" % [Vector2(c.state.vel.x, c.state.vel.z).length(), slide])
	check(slide < 15.0, "planted feet stay put at a sprint (%.1f mm/frame)" % slide)


func test_stairs_put_each_foot_on_a_step() -> void:
	load_playground()
	var c := _sinew(Vector3(30.0, 0.05, -17.0))
	await ticks(30)
	c.teleport(Vector3(30.0, 0.05, -17.0), 0.0)
	await ticks(10)
	var r := c.ragdoll as SinewRagdoll
	bot(c).set_steps([{"ticks": 200, "yaw": 0.0, "move": Vector2(0, 1)}])
	var planted := 0
	var y0 := c.state.pos.y
	var worst := 0.0
	var ankle_h := -1.0
	for k in 180:
		await ticks(1)
		var st: Dictionary = r.world.physics.call("character_gait_state", r._id)
		for side in ["l", "r"]:
			if bool(st["planted_" + side]):
				var a: Vector3 = st["plant_" + side]
				var g: Dictionary = r.world.physics.call("ground_below", a + Vector3.UP * 0.3, 1.0)
				if bool(g.hit):
					var h := a.y - (g.point as Vector3).y
					if ankle_h < 0.0:
						ankle_h = h
					worst = maxf(worst, absf(h - ankle_h))
					planted += 1
	info("stairs: climbed %.2f m" % (c.state.pos.y - y0))
	check(c.state.pos.y - y0 > 0.8, "it walks up the stairs (%.2f m)" % (c.state.pos.y - y0))
	check(planted > 50, "on its feet the whole way")
	check(worst < 0.03, "every planted foot on a step: ankle height over the ground under it varies %.1f cm" % (worst * 100.0))


func test_gait_off_plays_the_clips() -> void:
	load_playground()
	var c := _sinew(marker("spawn").global_position + Vector3(-3, 0, -4), false)
	await ticks(30)
	var r := c.ragdoll as SinewRagdoll
	check(not r._gait_on and r.gait_w == 0.0, "gait off: the clips' own cycles")

