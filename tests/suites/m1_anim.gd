extends UltraTestSuite
## Animation quality: planted feet must not skate. Measures the world speed of whichever toe
## is on the ground while running at steady speed, for each gait and a diagonal.


func before_each() -> void:
	load_playground()
	await ticks(2)


func _toe_slide(move: Vector2, buttons: int, settle := 90, measure := 180, yaw := 0.0) -> Array:
	var c := spawn("speed_start", "res://addons/ultra_controller/profiles/fps.tres", true)
	await ticks(3)
	await hold(c, settle, move, buttons, yaw)
	var sk := c.skeleton
	var feet := [sk.find_bone("LeftToes"), sk.find_bone("RightToes")]
	var samples: Array[float] = []
	var signed: Array[float] = []
	var speeds: Array[float] = []
	bot(c).set_steps([{"ticks": measure, "move": move, "buttons": buttons, "yaw": yaw}])
	var track := []
	for i in measure:
		await sk.skeleton_updated
		var ps := []
		for f in 2:
			ps.append(sk.global_transform * sk.get_bone_global_pose(feet[f]).origin)
		track.append(ps)
		speeds.append(hspeed(c))
	# Supporting foot = the lower one, and only while it's actually on the ground (running
	# gaits have flight phases where neither foot supports).
	var miny := [INF, INF]
	for ps: Array in track:
		for f in 2:
			miny[f] = minf(miny[f], (ps[f] as Vector3).y)
	for i in range(11, track.size()):
		var ps: Array = track[i]
		var lo := 0 if (ps[0] as Vector3).y <= (ps[1] as Vector3).y else 1
		var p: Vector3 = ps[lo]
		if p.y > miny[lo] + 0.03:
			continue
		var q: Vector3 = track[i - 1][lo]
		samples.append(Vector2(p.x - q.x, p.z - q.z).length() * 60.0)
		var bv := Vector2(c.state.vel.x, c.state.vel.z).normalized()
		signed.append(Vector2(p.x - q.x, p.z - q.z).dot(bv) * 60.0)
	signed.sort()
	if not signed.is_empty():
		info("   signed toe velocity along travel: median %.2f" % signed[signed.size() / 2])
	samples.sort()
	speeds.sort()
	var med := samples[samples.size() / 2] if not samples.is_empty() else INF
	var p75 := samples[samples.size() * 3 / 4] if not samples.is_empty() else INF
	var spd := speeds[speeds.size() / 2]
	c.queue_free()
	chars.erase(c)
	await ticks(2)
	return [med, p75, spd]


func test_foot_slide_gaits() -> void:
	var cases := [
		["walk", Vector2(0, 0.3), 0],
		["brisk", Vector2(0, 0.55), 0],
		["walk_full", Vector2(0, 1), 0],
		["sprint", Vector2(0, 1), InputFrame.B_SPRINT],
		["diag_walk", Vector2(0.7071, 0.7071), 0],
		["back_slow", Vector2(0, -0.5), 0],
		["back_mid", Vector2(0, -0.75), 0],
		["back", Vector2(0, -1), 0],
		["strafe", Vector2(1, 0), 0],
		["strafe_l", Vector2(-1, 0), 0, PI],            # facing +Z, so it steps along the open lane
		["back_diag_r", Vector2(0.7071, -0.7071), 0],
		["back_diag_l", Vector2(-0.7071, -0.7071), 0],
	]
	for cs: Array in cases:
		var r: Array = await _toe_slide(cs[1], cs[2], 90, 180, float(cs[3]) if cs.size() > 3 else 0.0)
		info("%-8s speed %.2f m/s  planted toe median %.2f m/s  p75 %.2f" % [cs[0], r[2], r[0], r[1]])
		# (Walk_Backwards' feet drift sideways in the source clip; foot locking removes it.)
		var tol := maxf(0.3, r[2] * 0.12)
		check(r[0] < tol, "%s: planted foot doesn't skate (median %.2f at %.2f m/s)" % [cs[0], r[0], r[2]])
		if String(cs[0]).begins_with("strafe"):
			# Side-steps stay on the side-step clip (no walk / backpedal mixed in): no slips.
			check(r[1] < 0.2 and r[2] > 1.0, "%s: no slipping steps (p75 %.2f m/s)" % [cs[0], r[1]])
