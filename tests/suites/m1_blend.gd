extends UltraTestSuite
## Animation flow: a course through the everyday transitions (start / stop, sprint, reversing,
## strafing, direction sweeps, crouch, jumps, turning on the spot, the rifle: equip, walk, aim,
## fire, reload, sprint, holster). Each frame the head, chest, hips, hands and feet are taken
## in the body's own frame; a "pop" is a jump in acceleration - the second difference of
## position well above what the same point does in steady motion.

const POINTS := ["Head", "UpperChest", "Hips", "LeftHand", "RightHand", "LeftFoot", "RightFoot"]
## Core points (head, chest, hips) must never pop; hands and feet move fast in normal gaits.
const CORE := 3


func before_each() -> void:
	load_playground()
	await ticks(2)


## Steps: [label, ticks, move, buttons, yaw_deg, slot, tap]
func _course() -> Array:
	var F := InputFrame
	var fwd := Vector2(0, 1)
	return [
		["idle", 60, Vector2.ZERO, 0, 0.0, 0, 0],
		["walk start", 45, fwd, 0, 0.0, 0, 0],
		["walk", 45, fwd, 0, 0.0, 0, 0],
		["walk stop", 60, Vector2.ZERO, 0, 0.0, 0, 0],
		["sprint start", 60, fwd, F.B_SPRINT, 0.0, 0, 0],
		["sprint", 30, fwd, F.B_SPRINT, 0.0, 0, 0],
		["sprint stop", 70, Vector2.ZERO, 0, 0.0, 0, 0],
		["walk fwd", 50, fwd, 0, 0.0, 0, 0],
		["reverse to back", 60, -fwd, 0, 0.0, 0, 0],
		["strafe right", 50, Vector2(1, 0), 0, 0.0, 0, 0],
		["flip to left", 60, Vector2(-1, 0), 0, 0.0, 0, 0],
		["diag fl", 25, Vector2(-0.7, 0.7), 0, 0.0, 0, 0],
		["fwd", 25, fwd, 0, 0.0, 0, 0],
		["diag fr", 25, Vector2(0.7, 0.7), 0, 0.0, 0, 0],
		["right", 25, Vector2(1, 0), 0, 0.0, 0, 0],
		["diag br", 25, Vector2(0.7, -0.7), 0, 0.0, 0, 0],
		["stop 2", 60, Vector2.ZERO, 0, 0.0, 0, 0],
		["crouch down", 60, Vector2.ZERO, F.B_CROUCH, 0.0, 0, 0],
		["crouch walk", 60, fwd, F.B_CROUCH, 0.0, 0, 0],
		["stand up walking", 60, fwd, 0, 0.0, 0, 0],
		["stop 3", 60, Vector2.ZERO, 0, 0.0, 0, 0],
		["jump standing", 90, Vector2.ZERO, 0, 0.0, 0, F.B_JUMP],
		["run up", 50, fwd, F.B_SPRINT, 0.0, 0, 0],
		["running jump", 90, fwd, F.B_SPRINT, 0.0, 0, F.B_JUMP],
		["stop 4", 60, Vector2.ZERO, 0, 0.0, 0, 0],
		["turn left 100", 90, Vector2.ZERO, 0, 100.0, 0, 0],
		["turn right 100", 90, Vector2.ZERO, 0, 0.0, 0, 0],
		["draw rifle", 90, Vector2.ZERO, 0, 0.0, 2, 0],
		["rifle walk", 60, fwd, 0, 0.0, 2, 0],
		["rifle stop", 60, Vector2.ZERO, 0, 0.0, 2, 0],
		["aim", 45, Vector2.ZERO, F.B_SECONDARY, 0.0, 2, 0],
		["fire", 30, Vector2.ZERO, F.B_SECONDARY | F.B_PRIMARY, 0.0, 2, 0],
		["lower", 45, Vector2.ZERO, 0, 0.0, 2, 0],
		["reload", 160, Vector2.ZERO, 0, 0.0, 2, F.B_RELOAD],
		["rifle sprint", 60, fwd, F.B_SPRINT, 0.0, 2, 0],
		["rifle sprint stop", 70, Vector2.ZERO, 0, 0.0, 2, 0],
		["rifle turn", 90, Vector2.ZERO, 0, 90.0, 2, 0],
		["holster", 90, Vector2.ZERO, 0, 90.0, 0, 0],
	]


## Runs the course; returns [label, peak accel per point (m/s^2), frame] rows and the steady
## baselines (median accel per point over the whole run).
func _run_course() -> Dictionary:
	var c := spawn("speed_start", "res://addons/ultra_controller/profiles/fps.tres", true)
	await ticks(3)
	UltraItems.give(c, &"pistol")
	UltraItems.give(c, &"rifle")
	UltraItems.give(c, &"ammo_556", 90)
	await ticks(2)
	var sk := c.skeleton
	var bones := []
	for n: String in POINTS:
		bones.append(sk.find_bone(n))
	var steps := []
	var labels := []
	for st: Array in _course():
		var d := {"ticks": st[1], "move": st[2], "buttons": st[3], "yaw": deg_to_rad(st[4]), "slot": st[5], "tap": st[6]}
		# Aim changes are swept over 0.25 s (a quick flick of the mouse), not snapped in a frame.
		var prev_yaw: float = steps[steps.size() - 1]["yaw"] if not steps.is_empty() else 0.0
		var dy := angle_difference(prev_yaw, deg_to_rad(st[4]))
		if absf(dy) > 0.01:
			for k in 15:
				steps.append({"ticks": 1, "move": st[2], "buttons": st[3], "yaw": prev_yaw + dy * (k + 1) / 15.0, "slot": st[5], "tap": st[6] if k == 0 else 0})
			d["ticks"] = int(st[1]) - 15
			d["tap"] = 0
		steps.append(d)
		for i in int(st[1]):
			labels.append(st[0])
	bot(c).live_yaw = 0.0
	bot(c).set_steps(steps)
	var frames := []
	for i in labels.size():
		await sk.skeleton_updated
		var inv := c.visual_root.global_transform.affine_inverse()
		var ps := []
		for b: int in bones:
			ps.append(inv * (sk.global_transform * sk.get_bone_global_pose(b).origin))
		frames.append(ps)
		if OS.get_environment("BLEND_WHY2") == labels[i] and frames.size() >= 3:
			var yawof := func(bn: String) -> String:
				var g := sk.get_bone_global_pose(sk.find_bone(bn))
				return "%s/%.0f" % [g.origin.snappedf(0.01), rad_to_deg(atan2(g.basis.z.x, g.basis.z.z))]
			var md := c.anim.modifier
			print("WHY3 %d aim_p %.3f aim_y %.3f lean_p %.3f lean_r %.3f wa %.3f hunch %.3f pelvis %s ihy %.2f sway %s" % [i, md.aim_pitch, md.aim_yaw, md.lean_pitch, md.lean_roll, md.weapon_aim, md.hunch, md.pelvis_offset.snappedf(0.001), md.item_hips_yaw, str(c.state.sway)])
			print("WHY2 %d hips %s spine %s chest %s uchest %s neck %s head %s" % [i, yawof.call("Hips"), yawof.call("Spine"), yawof.call("Chest"), yawof.call("UpperChest"), yawof.call("Neck"), yawof.call("Head")])
		if OS.get_environment("BLEND_WHY") == labels[i] and frames.size() >= 3:
			var acc := ((frames[i][0] as Vector3) - 2.0 * (frames[i - 1][0] as Vector3) + (frames[i - 2][0] as Vector3)).length() * 3600.0
			print("WHY %d acc %.0f state %s loco %s inert %d | wp %.2f fb %s pose %.2f item %.2f stance %.2f blade %.1f | snap %s bp %s bpb %s warp %.2f| head %s" % [i, acc, MotorState.Id.keys()[c.state.state], c.anim._cur_loco, c.anim.inertial.jumps, c.anim.weapon_pose.weight, c.anim.weapon_pose.from_body, c.anim._pose_w, c.anim._item_w, c.anim._stance_w, c.anim.weapon_pose.last_blade, str(c.anim._snap), str(c.anim.tree.get(UltraAnimDriver.LOCO + "ground/move/blend_position")), str(c.anim.tree.get(UltraAnimDriver.LOCO + "ground/move_b/blend_position")), c.anim._warp, (ps[0] as Vector3).snappedf(0.001)])
	c.queue_free()
	chars.erase(c)
	# Acceleration (second difference) per point per frame.
	var acc := []
	for i in range(1, frames.size() - 1):
		var row := []
		for k in POINTS.size():
			var a: Vector3 = (frames[i + 1][k] as Vector3) - 2.0 * (frames[i][k] as Vector3) + (frames[i - 1][k] as Vector3)
			row.append(a.length() * 3600.0)
		acc.append(row)
	var med := []
	for k in POINTS.size():
		var col: Array[float] = []
		for row: Array in acc:
			col.append(row[k])
		col.sort()
		med.append(col[col.size() / 2])
	var rows := []
	var cur := ""
	for i in acc.size():
		var lab: String = labels[i + 1]
		if lab != cur:
			rows.append([lab, [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], [0, 0, 0, 0, 0, 0, 0]])
			cur = lab
		var r: Array = rows[rows.size() - 1]
		for k in POINTS.size():
			if acc[i][k] > r[1][k]:
				r[1][k] = acc[i][k]
				r[2][k] = i
	return {"rows": rows, "median": med}


func test_transitions_flow() -> void:
	var res: Dictionary = await _run_course()
	var med: Array = res.median
	var lines := ["accel peaks m/s^2 (head chest hips | hands | feet); steady medians %s" % [str(med.map(func(v: float) -> String: return "%.0f" % v))]]
	var worst := 0.0
	var worst_lab := ""
	for r: Array in res.rows:
		var p: Array = r[1]
		var core := maxf(maxf(p[0], p[1]), p[2])
		if core > worst and not String(r[0]).contains("jump"):
			worst = core
			worst_lab = r[0]
		lines.append("%-18s %5.0f %5.0f %5.0f | %5.0f %5.0f | %5.0f %5.0f%s" % [r[0], p[0], p[1], p[2], p[3], p[4], p[5], p[6], "   <-- core pop" if core > 60.0 else ""])
	info("\n  ".join(lines))
	info("worst core (head/chest/hips) peak outside jumps: %.0f m/s^2 at '%s'" % [worst, worst_lab])
	# (Before the blending pass: 250-760 m/s^2 at every start, stop, flip and rifle change.)
	var gentle := ["walk start", "walk stop", "walk fwd", "reverse to back", "strafe right", "flip to left", "turn left 100", "turn right 100", "draw rifle", "rifle walk", "holster", "lower", "reload"]
	for r: Array in res.rows:
		var p: Array = r[1]
		var core := maxf(maxf(p[0], p[1]), p[2])
		if String(r[0]).contains("jump"):
			continue
		var lim := 60.0 if gentle.has(r[0]) else 200.0
		check(core < lim, "%s: head / chest / hips flow (peak %.0f m/s^2, limit %.0f)" % [r[0], core, lim])


## Sprinting whips the head round in the clip; the stabiliser takes most of that out.
func test_head_steady_when_sprinting() -> void:
	var c := spawn("speed_start", "res://addons/ultra_controller/profiles/fps.tres", true)
	await ticks(3)
	await hold(c, 60, Vector2(0, 1), InputFrame.B_SPRINT, 0.0)
	var sk := c.skeleton
	var head := sk.find_bone("Head")
	var ref := sk.get_bone_global_rest(head).basis.inverse() * Vector3(0, 0, 1)
	var ys: Array[float] = []
	bot(c).set_steps([{"ticks": 120, "move": Vector2(0, 1), "buttons": InputFrame.B_SPRINT, "yaw": 0.0}])
	for i in 120:
		await sk.skeleton_updated
		var f := c.visual_root.global_basis.inverse() * (sk.global_basis * sk.get_bone_global_pose(head).basis) * ref
		ys.append(atan2(f.x, f.z))
	var lo := 999.0
	var hi := -999.0
	for y in ys.slice(30):
		var r := rad_to_deg(angle_difference(ys[30], y))
		lo = minf(lo, r)
		hi = maxf(hi, r)
	info("sprinting: head yaw swing %.1f deg" % (hi - lo))
	check(hi - lo < 25.0, "the head stays steady while sprinting (%.0f deg swing)" % (hi - lo))
	c.queue_free()
	chars.erase(c)


## Sprinting (unarmed, pistol, rifle): how far the head and chest swing side to side and how
## much the head rolls, in the body's own frame.
func test_sprint_sway() -> void:
	var res := []
	for spec: Array in [["unarmed", &""], ["pistol", &"pistol"], ["rifle", &"rifle"]]:
		var c := spawn("speed_start", "res://addons/ultra_controller/profiles/fps.tres", true)
		await ticks(3)
		var slot := 0
		if spec[1] != &"":
			UltraItems.give(c, spec[1])
			slot = c.inventory.find_uid(c.inventory.get_slot(0).uid) + 1
		await hold(c, 40, Vector2.ZERO, 0, 0.0)
		bot(c).set_steps([{"ticks": 90, "move": Vector2(0, 1), "buttons": InputFrame.B_SPRINT, "yaw": 0.0, "slot": slot}])
		await ticks(50)
		var sk := c.skeleton
		var hx := []
		var cx := []
		var roll := []
		var yaws := []
		for i in 40:
			await sk.skeleton_updated
			var inv := c.visual_root.global_transform.affine_inverse()
			var h := inv * (sk.global_transform * sk.get_bone_global_pose(sk.find_bone("Head")).origin)
			var ch := inv * (sk.global_transform * sk.get_bone_global_pose(sk.find_bone("UpperChest")).origin)
			var hb := c.visual_root.global_basis.inverse() * (sk.global_basis * sk.get_bone_global_pose(sk.find_bone("Head")).basis)
			hx.append(h.x)
			cx.append(ch.x)
			var up := hb.orthonormalized() * (sk.get_bone_global_rest(sk.find_bone("Head")).basis.inverse() * Vector3.UP)
			roll.append(rad_to_deg(atan2(up.x, up.y)))
			var fw := hb.orthonormalized() * (sk.get_bone_global_rest(sk.find_bone("Head")).basis.inverse() * Vector3.BACK)
			yaws.append(rad_to_deg(atan2(fw.x, fw.z)))
		var rng := func(a: Array) -> float: return a.max() - a.min()
		var mean := func(a: Array) -> float:
			var t := 0.0
			for v: float in a:
				t += v
			return t / a.size()
		res.append("%s: head side %.3f m, chest side %.3f m, head roll %.1f deg (mean %.1f), head yaw %.1f deg (mean %.1f), blends %d" % [spec[0], rng.call(hx), rng.call(cx), rng.call(roll), mean.call(roll), rng.call(yaws), mean.call(yaws), c.anim.inertial.jumps])
		# (Before: pistol 0.33 m / 42 deg, unarmed 0.12 m / 16 deg.)
		check(rng.call(hx) < 0.12 and rng.call(roll) < 12.0, "%s: the head doesn't swing about at a sprint (%.2f m, %.0f deg)" % [spec[0], rng.call(hx), rng.call(roll)])
		c.queue_free()
		chars.erase(c)
		await ticks(2)
	info("\n  ".join(res))


## Climbing up onto a ledge and vaulting: the legs don't flash a run / sprint as the move hands
## back to the ground (the scripted move's own speed - several m/s - used to drive the gait).
func test_no_run_legs_after_climb() -> void:
	for spec: Array in [["ledge_100", InputFrame.B_SPRINT], ["ledge_200", 0], ["parkour_start", InputFrame.B_SPRINT]]:
		var c := spawn(spec[0], "res://addons/ultra_controller/profiles/fps.tres", true)
		await ticks(3)
		var Id := MotorState.Id
		var b := c.input_source as BotInputSource
		var phase := [0]          # 0 approach, 1 moving over, 2 after
		var after := [0]
		var worst := [0.0]
		var seen := {}
		b.driver = func(_t: int, _src: BotInputSource) -> InputFrame:
			var f := InputFrame.new()
			f.yaw = 0.0
			var climbing: bool = c.state.state in [Id.LEDGE_CLIMB, Id.VAULT, Id.MANTLE, Id.LEDGE_HANG]
			f.move = Vector2(0, 1) if phase[0] == 0 or c.state.state == Id.LEDGE_HANG else Vector2.ZERO
			f.buttons = int(spec[1])
			if phase[0] == 0 and (c.state.pos.z < -27.3 if spec[0].begins_with("ledge") else c.state.pos.z < -14.4):
				f.buttons |= InputFrame.B_JUMP
			return f
		for i in 400:
			await ticks(1)
			var st := c.state.state
			if st in [Id.LEDGE_CLIMB, Id.VAULT, Id.MANTLE, Id.LEDGE_HANG]:
				phase[0] = 1
				seen[Id.keys()[st]] = true
			elif phase[0] == 1:
				phase[0] = 2
			if phase[0] >= 1 and after[0] < 30:
				if phase[0] == 2:
					after[0] += 1
				# Gait shown with no stick input: the moving mix times the blend speed (the blend
				# position itself holds the last gait while the mix fades - that's fine).
				var bp: Vector2 = c.anim.tree.get(UltraAnimDriver.LOCO + "ground/move/blend_position")
				var mix: float = c.anim.tree.get(UltraAnimDriver.LOCO + "ground/mix/blend_amount")
				if phase[0] == 2:
					worst[0] = maxf(worst[0], bp.length() * mix)
			if phase[0] == 2 and after[0] >= 30:
				break
		b.driver = Callable()
		info("%s (%s): ground blend speed after the move %.2f m/s" % [spec[0], " ".join(seen.keys()), worst[0]])
		check(phase[0] == 2, "%s: got over (%s)" % [spec[0], seen.keys()])
		if spec[0] != "parkour_start":      # (a vault keeps the run's momentum: running legs are right)
			check(worst[0] < 1.0, "%s: no running legs as the climb ends (%.2f m/s)" % [spec[0], worst[0]])
		c.queue_free()
		chars.erase(c)
		await ticks(2)


## Hanging still on a ledge, the body is still (the braced idle's looping tail snapped it 2 cm
## every 0.55 s).
func test_hang_still() -> void:
	var Id := MotorState.Id
	var c := spawn("ledge_250", "res://addons/ultra_controller/profiles/fps.tres", true)
	await ticks(3)
	var b := c.input_source as BotInputSource
	b.driver = func(_t: int, _s: BotInputSource) -> InputFrame:
		var f := InputFrame.new()
		f.move = Vector2(0, 1) if c.state.state != Id.LEDGE_HANG else Vector2.ZERO
		if c.state.pos.z < -27.3 and c.state.state != Id.LEDGE_HANG:
			f.buttons = InputFrame.B_JUMP
		return f
	for i in 200:
		await ticks(1)
		if c.state.state == Id.LEDGE_HANG and c.state.state_time > 1.0:
			break
	var sk := c.skeleton
	var rec := []
	var cb := func() -> void:
		var vi := c.visual_root.global_transform.affine_inverse()
		var row := [c.visual_root.global_position, c.state.pos, c.tick]
		for n in ["Head", "LeftHand", "RightHand", "Hips", "LeftFoot"]:
			row.append(vi * (sk.global_transform * sk.get_bone_global_pose(sk.find_bone(n))).origin)
		rec.append(row)
	sk.skeleton_updated.connect(cb)
	await ticks(240)
	sk.skeleton_updated.disconnect(cb)
	var lines := []
	for i in range(1, rec.size()):
		var s := "%d" % rec[i][2]
		var any := false
		for k in range(3, 8):
			var d: Vector3 = (rec[i][k] as Vector3) - (rec[i - 1][k] as Vector3)
			any = any or d.length() > 0.002
			s += " | %s" % d.snappedf(0.001)
		if any:
			lines.append(s)
	info("hanging still: %d of %d frames moved a bone > 2 mm" % [lines.size(), rec.size()])
	check(lines.size() == 0, "the hanging body stays still (%s)" % "; ".join(lines.slice(0, 3)))
	c.queue_free()
	chars.erase(c)
