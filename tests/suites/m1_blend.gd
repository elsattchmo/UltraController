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
	var gentle := ["walk start", "walk stop", "sprint start", "walk fwd", "reverse to back", "strafe right", "flip to left", "turn left 100", "turn right 100", "draw rifle", "rifle walk", "holster", "lower", "reload"]
	for r: Array in res.rows:
		var p: Array = r[1]
		var core := maxf(maxf(p[0], p[1]), p[2])
		if String(r[0]).contains("jump"):
			continue
		var lim := 60.0 if gentle.has(r[0]) else 120.0
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
