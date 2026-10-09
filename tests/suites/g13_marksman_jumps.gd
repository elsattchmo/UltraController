extends UltraTestSuite
## Marksman's jumps, landings, ledges and water after the user's round ("move away from the current jump animation ...
## different landing animations based off height and momentum ... land and stumble in the direction of momentum ... we
## aren't really grabbing the edge when hanging ... two directional inputs at the same time still do a shimmy and it's
## broken ... swimming underwater ... we just float around ... the fall into water where we go ragdoll for a moment").

const Id := MotorState.Id
const FPS := "res://addons/ultra_controller/profiles/fps.tres"
const SPEED_MAX := 25.0


func _marksman(at: Vector3, yaw := 0.0) -> MarksmanCharacter:
	var c := MarksmanCharacter.new()
	c.motion_matching = true
	c.profile = (load(FPS) as MovementProfile).duplicate(true)
	c.body_profile = CharacterModels.body_profile("mannequin")
	c.build_visuals = true
	var b := BotInputSource.new()
	b.name = "InputSource"
	c.add_child(b)
	c.input_source = b
	c.position = at
	c.rotation.y = yaw
	add_child(c)
	b.body = c
	chars.append(c)
	return c


static func frame(move: Vector2, buttons := 0, yaw := 0.0, pitch := 0.0) -> InputFrame:
	var f := InputFrame.new()
	f.move = move
	f.buttons = buttons
	f.yaw = yaw
	f.pitch = pitch
	return f


## Drive `c` with fn(tick, c) for `n` ticks: the loco nodes and states seen, the fastest shown bone (m/s).
func _course(c: MarksmanCharacter, n: int, fn: Callable) -> Dictionary:
	var out := {"nodes": [], "states": [], "fast": 0.0, "fast_bone": ""}
	var sk := c.skeleton
	var last := {}
	var probe := func() -> void:
		for b in sk.get_bone_count():
			var bn := sk.get_bone_name(b)
			if bn.contains("leaf") or bn == "Root":
				continue
			var p := sk.global_transform * sk.get_bone_global_pose(b).origin
			if last.has(b):
				var v: float = p.distance_to(last[b]) * 60.0
				if v > 25.0 and OS.get_environment("CATCH_DBG") != "":
					print("FAST f%d %s %.1f m/s" % [Engine.get_process_frames(), bn, v])
				if v > float(out.fast):
					out.fast = v
					out.fast_bone = bn
			last[b] = p
	await ticks(4)
	sk.skeleton_updated.connect(probe)
	var src := c.input_source as BotInputSource
	var k := [0]
	src.driver = func(_t: int, _s: BotInputSource) -> InputFrame: return fn.call(k[0], c)
	for i in n:
		await ticks(1)
		k[0] = i
		var nd: String = c.anim._cur_loco
		if out.nodes.is_empty() or out.nodes[-1] != nd:
			out.nodes.append(nd)
		var stn: String = Id.keys()[c.state.state]
		if out.states.is_empty() or out.states[-1] != stn:
			out.states.append(stn)
	sk.skeleton_updated.disconnect(probe)
	src.driver = Callable()
	return out


func _done(c: MarksmanCharacter) -> void:
	chars.erase(c)
	c.queue_free()
	await ticks(3)


func _line(name: String, r: Dictionary) -> void:
	info("%-22s nodes %s | states %s | fastest %s %.1f m/s" % [name, " ".join(r.nodes), " ".join(r.states), r.fast_bone, r.fast])


## A standing jump is the standing hop (both knees up), a walking one the running jump, a sprinting one the leap - each
## its own node, landing on its own clip; nothing flails.
func test_each_jump_its_clip() -> void:
	load_playground()
	var bad := []
	for spec: Array in [["standing", Vector2.ZERO, 0, "hop"], ["walking", Vector2(0, 1), 0, "jump_run"],
			["sprinting", Vector2(0, 1), InputFrame.B_SPRINT, "air_run"]]:
		var c := _marksman(Vector3(30, 0.05, -60))
		await ticks(30)
		var r: Dictionary = await _course(c, 150, func(k: int, _ch: MarksmanCharacter) -> InputFrame:
			return frame(spec[1], int(spec[2]) | (InputFrame.B_JUMP if k == 40 else 0)))
		_line(spec[0] + " jump", r)
		if not String(spec[3]) in r.nodes:
			bad.append("%s jump: no %s (%s)" % [spec[0], spec[3], " ".join(r.nodes)])
		if "air" in r.nodes:
			bad.append("%s jump: the old air clip showed" % spec[0])
		if float(r.fast) > SPEED_MAX:
			bad.append("%s jump: %s at %.1f m/s" % [spec[0], r.fast_bone, r.fast])
		await _done(c)
	check(bad.is_empty(), "each jump plays its own clip, smoothly (%s)" % "; ".join(bad))


## Walking off the landing tower: 2 m lands in the squat, 6 m in the hard landing (down on a hand) - both after the
## falling loop; sprinting off 2 m the body stumbles on along its way (Sinew's catching steps) and stays up.
func test_landings_by_height_and_momentum() -> void:
	load_playground()
	var bad := []
	# (From MarksmanRagdoll.land_stagger_speed the balancer has the legs - it may go down: the simulation's, gm 4 m jump.)
	for spec: Array in [["2 m walking", 58.0, 2.0, 0, "land"], ["4 m walking", 64.0, 4.0, 0, "land_hard"], ["6 m walking", 70.0, 6.0, 0, "land_hard"]]:
		var c := _marksman(Vector3(spec[1], spec[2] + 0.05, -48.5), PI)
		await ticks(30)
		var r: Dictionary = await _course(c, 200, func(_k: int, _ch: MarksmanCharacter) -> InputFrame:
			return frame(Vector2(0, 1), int(spec[3]), PI))
		_line(spec[0], r)
		for want: String in ["fall", spec[4]]:
			if not want in r.nodes:
				bad.append("%s: no %s (%s)" % [spec[0], want, " ".join(r.nodes)])
		if "RAGDOLL" in r.states and float(spec[2]) < 5.0:
			bad.append("%s: went down" % spec[0])
		await _done(c)
	# Jogging off 2 m: a stumble on, on its feet; sprinting off it: it runs on.
	for spec: Array in [["jogging", true], ["sprinting", false]]:
		var c2 := _marksman(Vector3(58, 2.05, -49.6), PI)
		if spec[1]:
			c2.profile.default_gait = MovementProfile.Gait.JOG
		await ticks(30)
		var z0 := c2.state.pos.z
		var r2: Dictionary = await _course(c2, 200, func(_k: int, ch: MarksmanCharacter) -> InputFrame:
			return frame(Vector2(0, 1), InputFrame.B_SPRINT if not spec[1] and ch.state.pos.z < -45.8 else 0, PI))
		_line("2 m " + spec[0], r2)
		info("stumbles %d, ended %s %.1f m on" % [c2.landed_stumbles, Id.keys()[c2.state.state], c2.state.pos.z - z0])
		if spec[1] and c2.landed_stumbles < 1:
			bad.append("%s off 2 m: no stumble" % spec[0])
		if c2.state.state in [Id.RAGDOLL, Id.GET_UP, Id.DEAD] or "RAGDOLL" in r2.states:
			bad.append("%s off 2 m: it didn't stay up" % spec[0])
		await _done(c2)
	check(bad.is_empty(), "landings by height and momentum (%s)" % "; ".join(bad))


## Jumping at the 2.5 m wall: the brace catch plays, the palms on the top of the lip (MarksmanLedgePass), then up.
func test_ledge_catch_hands_on_the_lip() -> void:
	load_playground()
	var a := marker("ledge_250")
	var c := _marksman(a.global_position, a.global_rotation.y)
	await ticks(20)
	var lip := [INF, INF]            # worst hand height off the lip's top, worst hand distance out from the face (m)
	var worst := [0.0]
	var sk := c.skeleton
	var swing := [0.0, 0.0]          # the catch: the shown hips' and feet's furthest from the animation (m)
	var tear := [0.0, ""]            # the widest a shown joint opened (m: a child off where its parent puts it)
	var probe := func() -> void:
		var lp := c.ragdoll as MarksmanRagdoll
		if lp.catching() and lp.modifier.anim_pose.size() == lp.parts.size():
			for i in lp.parts.size():
				var n := String(lp.parts[i].name)
				var pp: int = lp.parts[i].parent
				if pp >= 0:
					var ap: Transform3D = lp.modifier.anim_pose[pp]
					var ai: Transform3D = lp.modifier.anim_pose[i]
					var want := sk.get_bone_global_pose(lp.parts[pp].bone) * (ap.affine_inverse() * ai).origin
					var gap := sk.get_bone_global_pose(lp.parts[i].bone).origin.distance_to(want)
					if gap > float(tear[0]):
						tear[0] = gap
						tear[1] = n
				if i == 0 or n.ends_with("Foot"):
					var d := sk.get_bone_global_pose(lp.parts[i].bone).origin.distance_to(lp.modifier.anim_pose[i].origin)
					swing[0 if i == 0 else 1] = maxf(swing[0 if i == 0 else 1], d)
		if c.state.state != Id.LEDGE_HANG or lp.ledge_pass.weight < 0.99:
			return
		for h in ["LeftHand", "RightHand"]:
			var p := sk.global_transform * sk.get_bone_global_pose(sk.find_bone(h)).origin
			worst[0] = maxf(worst[0], absf(p.y - c.state.trav_point.y - 0.035 - 0.03))
			if OS.get_environment("CATCH_DBG") != "":
				print("f%d %s %s lip %.2f catching %s w %.2f blend %.2f pend %d hips %s" % [Engine.get_process_frames(), h, p.snappedf(0.01), c.state.trav_point.y,
						lp.catching(), lp._catch_w, lp.modifier.blend, lp._catch_pending, (sk.global_transform * sk.get_bone_global_pose(0).origin).snappedf(0.01)])
	sk.skeleton_updated.connect(probe)
	var r: Dictionary = await _course(c, 260, func(k: int, ch: MarksmanCharacter) -> InputFrame:
		var hanging := ch.state.state == Id.LEDGE_HANG
		return frame(Vector2.ZERO if hanging and ch.state.state_time < 1.0 else Vector2(0, 1),
				InputFrame.B_JUMP if ch.state.pos.z < -27.3 and ch.state.is_grounded() else 0))
	sk.skeleton_updated.disconnect(probe)
	_line("2.5 m wall", r)
	info("hands off the lip's top by up to %.1f cm while hanging" % (worst[0] * 100.0))
	info("catch: %d physical, hips swung up to %.1f cm, feet %.1f cm off the clip, widest joint %s %.1f cm" % [
			(c.ragdoll as MarksmanRagdoll).caught_swinging, swing[0] * 100.0, swing[1] * 100.0, tear[1], float(tear[0]) * 100.0])
	check((c.ragdoll as MarksmanRagdoll).caught_swinging == 1 and swing[1] > 0.05, "the body swings under the hands at the catch")
	check(float(tear[0]) < 0.03, "the body holds together through the catch (%s %.1f cm off its parent)" % [tear[1], float(tear[0]) * 100.0])
	check("catch" in r.nodes and "climb_up" in r.nodes, "the brace catch, then the climb (%s)" % " ".join(r.nodes))
	check(worst[0] < 0.06, "the hands hold the lip (%.1f cm)" % (worst[0] * 100.0))
	check(float(r.fast) < SPEED_MAX, "nothing flails (%s %.1f m/s)" % [r.fast_bone, r.fast])
	await _done(c)


## Hanging under the overhang with the stick forward + right: a full-speed shimmy, no climb attempt (the motor read both).
func test_diagonal_stick_shimmies() -> void:
	load_playground()
	var a := marker("parkour_shimmy")
	var c := _marksman(a.global_position, a.global_rotation.y)
	await ticks(20)
	var x0 := [INF]
	var t := [0]
	var r: Dictionary = await _course(c, 360, func(_k: int, ch: MarksmanCharacter) -> InputFrame:
		if ch.state.state == Id.LEDGE_HANG and ch.state.state_time > 0.4:
			if x0[0] == INF:
				x0[0] = ch.state.pos.x
			t[0] += 1
			return frame(Vector2(0.707, 0.707))
		return frame(Vector2(0, 1), InputFrame.B_JUMP if ch.state.pos.z < -44.9 and ch.state.is_grounded() else 0))
	_line("diagonal shimmy", r)
	var moved: float = c.state.pos.x - float(x0[0]) if x0[0] != INF else 0.0
	var speed := moved / maxf(float(t[0]) / 60.0, 0.01)
	info("moved %.2f m right in %.1f s (%.2f m/s), the shimmy blend at %.2f" % [moved, t[0] / 60.0, speed, c.anim._hang_dir])
	check(c.state.state == Id.LEDGE_HANG or "LEDGE_CLIMB" in r.states, "still on the ledge")
	check(speed > 0.42, "a full-speed shimmy (%.2f m/s, the motor's 0.5)" % speed)
	check(absf(c.anim._hang_dir) > 0.95 or "LEDGE_CLIMB" in r.states, "the shimmy clip, not half the still hang (%.2f)" % c.anim._hang_dir)
	await _done(c)


## Diving and letting go of the stick: the diver hovers (it drifted up to the surface at 0.4 m/s); a plunge off the
## tower floats limp at the surface (Sinew's body had no buoyancy) and swims.
func test_water() -> void:
	load_playground()
	var c := _marksman(Vector3(49, -1.0, 89), PI)
	await ticks(40)
	await _course(c, 60, func(k: int, _ch: MarksmanCharacter) -> InputFrame:
		return frame(Vector2(0, 1) if k > 4 else Vector2.ZERO, InputFrame.B_CROUCH if k < 3 else 0, PI, -0.5))
	var dove := c.state.state == Id.DIVE
	var y0 := c.state.pos.y
	await _course(c, 120, func(_k: int, _ch: MarksmanCharacter) -> InputFrame: return frame(Vector2.ZERO, 0, PI))
	info("diving: %s, still for 2 s: rose %.2f m" % [dove, c.state.pos.y - y0])
	check(dove and c.state.state == Id.DIVE and c.state.pos.y - y0 < 0.3, "still under water it hovers (rose %.2f m)" % (c.state.pos.y - y0))
	await _done(c)
	var d := marker("dive_tower")
	var p := _marksman(d.global_position, 0.0)
	await ticks(30)
	var hips_low := [INF]
	var sk := p.skeleton
	var probe := func() -> void:
		if p.state.state == Id.RAGDOLL and p.state.state_time > 0.6:
			hips_low[0] = minf(hips_low[0], (sk.global_transform * sk.get_bone_global_pose(sk.find_bone("Hips")).origin).y)
	sk.skeleton_updated.connect(probe)
	var r: Dictionary = await _course(p, 420, func(_k: int, ch: MarksmanCharacter) -> InputFrame:
		return frame(Vector2(0, 1) if ch.state.is_grounded() else Vector2.ZERO, 0, 0.0))
	sk.skeleton_updated.disconnect(probe)
	_line("plunge", r)
	info("limp in the water: hips at %.2f m at the lowest (surface -0.3)" % hips_low[0])
	check("RAGDOLL" in r.states and "SWIM" in r.states, "knocked limp in the water, then swimming (%s)" % " ".join(r.states))
	check(hips_low[0] > -1.6, "the limp body floats (hips down to %.2f m; the pool is 4 m deep)" % hips_low[0])
	await _done(p)


## Jumping at something low hops up onto it (the standing hop over the motor's mantle); at a 1 m wall, the hands-on
## climb - not one run-up-and-knee clip for everything (the user: "a mantle type thing everywhere").
func test_low_mantle_hops_up() -> void:
	load_playground()
	var bad := []
	for spec: Array in [[50, "hop_up"], [100, "climb_up"]]:
		var a := marker("ledge_%d" % spec[0])
		var c := _marksman(a.global_position, a.global_rotation.y)
		await ticks(20)
		var top := float(spec[0]) / 100.0
		var r: Dictionary = await _course(c, 240, func(_k: int, ch: MarksmanCharacter) -> InputFrame:
			var up := ch.state.is_grounded() and ch.state.pos.y > top - 0.2
			return frame(Vector2.ZERO if up else Vector2(0, 1), InputFrame.B_JUMP if ch.state.pos.z < -27.3 and ch.state.is_grounded() and not up else 0))
		_line("%.1f m mantle" % top, r)
		if not String(spec[1]) in r.nodes or not "MANTLE" in r.states:
			bad.append("%.1f m: no %s (%s / %s)" % [top, spec[1], " ".join(r.nodes), " ".join(r.states)])
		if float(r.fast) > SPEED_MAX:
			bad.append("%.1f m: %s at %.1f m/s" % [top, r.fast_bone, r.fast])
		if c.state.pos.y < top - 0.15:
			bad.append("%.1f m: not on top (y %.2f)" % [top, c.state.pos.y])
		await _done(c)
	check(bad.is_empty(), "low tops are hopped onto, 1 m is climbed (%s)" % "; ".join(bad))


## Off the tower running on (the user: "after falling and running sometimes Sinew stays active too long and you need to
## stand still to stop it"): once down on its feet with the stick held, the body is the animation's again soon - after a
## sprint off a block (braced landing) and after backing off one by accident (Sinew's stagger catches the fall).
func test_running_on_after_a_fall() -> void:
	load_playground()
	var bad := []
	# [name, block x, top, start z, facing, stick before the fall, buttons]
	for spec: Array in [["2 m sprint", 58.0, 2.0, -48.8, PI, Vector2(0, 1), InputFrame.B_SPRINT],
			["4 m sprint", 64.0, 4.0, -48.8, PI, Vector2(0, 1), InputFrame.B_SPRINT],
			["2 m backing off", 58.0, 2.0, -46.25, 0.0, Vector2(0, -1), 0]]:
		var c := _marksman(Vector3(spec[1], spec[2] + 0.05, spec[3]), spec[4])
		await ticks(30)
		var r := c.ragdoll as MarksmanRagdoll
		var landed := -1
		var sinew := [0, 0, 0]          # ticks after landing: staggering, stumbling on the gait, any upper part physical
		var last := -1
		var down := false
		for i in 300:
			# (Down, it runs off west along the open ground: south of the blocks a run met a wall in 1.7 s and stood.)
			var run := landed >= 0
			bot(c).set_steps([{"ticks": 100000, "move": Vector2(0, 1) if run else spec[5],
					"buttons": InputFrame.B_SPRINT if run else int(spec[6]), "yaw": PI * 0.5 if run else float(spec[4])}])
			await ticks(1)
			if c.state.state in [Id.RAGDOLL, Id.GET_UP, Id.DEAD]:
				down = true
			if landed < 0 and c.state.is_grounded() and i > 10 and c.state.pos.y < float(spec[2]) - 0.5:
				landed = i
			if landed < 0 or down:
				continue
			var up := 0.0
			for k in r.parts.size():
				if not r._walks(k):
					up = maxf(up, r.part_w[k])
			var any := false
			if r.staggering():
				sinew[0] += 1
				any = true
			if r.stumbling_gait():
				sinew[1] += 1
				any = true
			if up > 0.5:
				sinew[2] += 1
				any = true
			if any:
				last = i - landed
		info("%s: landed %s, went down %s; after landing: staggering %d, stumbling %d, upper physical %d ticks; Sinew last on %.2f s after; at %.1f m/s" % [
				spec[0], landed >= 0, down, sinew[0], sinew[1], sinew[2], last / 60.0, Vector2(c.state.vel.x, c.state.vel.z).length()])
		if landed < 0:
			bad.append("%s: never landed" % spec[0])
		elif not down and last > 75:
			bad.append("%s: Sinew on %.2f s after landing" % [spec[0], last / 60.0])
		chars.erase(c)
		c.queue_free()
		await ticks(3)
	check(bad.is_empty(), "running on after a fall, the animation has the body back within 1.25 s (%s)" % "; ".join(bad))


## A stagger the body has come through ends when the stick asks to go: standing, staggered (as a hard hit or a rough
## landing does), then sprint held - the animation has the legs back within a second and the body runs.
func test_stick_ends_a_stagger() -> void:
	load_playground()
	var c := _marksman(Vector3(30, 0.05, -60))
	await ticks(60)
	var r := c.ragdoll as MarksmanRagdoll
	r.start_stagger()
	check(r.staggering(), "staggered")
	var t := -1
	for i in 150:
		bot(c).set_steps([{"ticks": 100000, "move": Vector2(0, 1), "buttons": InputFrame.B_SPRINT, "yaw": 0.0}])
		await ticks(1)
		if not r.staggering() and t < 0:
			t = i
	info("stick held from the stagger's start: the animation had the legs back after %.2f s (by the stick %d), running at %.1f m/s, state %s" % [
			t / 60.0, r.stagger_ended_by_stick, Vector2(c.state.vel.x, c.state.vel.z).length(), Id.keys()[c.state.state]])
	check(t >= 0 and t < 60, "the stick ends the stagger within a second (%.2f s)" % (t / 60.0))
	check(Vector2(c.state.vel.x, c.state.vel.z).length() > 3.0, "and it runs on")
	chars.erase(c)
	c.queue_free()
	await ticks(3)
