extends UltraTestSuite
## IK: grounded feet on slopes/stairs, knee sanity, foot locking, hand reach, look-at.


func before_each() -> void:
	load_playground()
	await ticks(2)


func _sole_error(c: UltraCharacter) -> Array[float]:
	var sk := c.skeleton
	var out: Array[float] = []
	var space := c.get_world_3d().direct_space_state
	for side in ["Left", "Right"]:
		var b := sk.find_bone(side + "Foot")
		var rest_h := sk.get_bone_global_rest(b).origin.y
		var p := sk.global_transform * sk.get_bone_global_pose(b).origin
		var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 0.5, p + Vector3.DOWN * 1.5, UltraLayers.WORLD_STATIC, [c.get_rid()])
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			out.append(INF)
		else:
			out.append(p.y - rest_h - (hit.position as Vector3).y)
	return out


func _settle_on(pos: Vector3, yaw: float, ik_weight: float) -> UltraCharacter:
	var c := spawn("speed_start")
	c.teleport(pos, yaw)
	await ticks(90)
	c.anim.ik_scale = ik_weight
	await ticks(60)
	await c.skeleton.skeleton_updated
	return c


func test_feet_on_slope_and_stairs() -> void:
	# Sideways on the 20° ramp: one foot is ~7 cm higher than the other.
	var r := marker("ramp_20").global_position
	var run := 2.5 / tan(deg_to_rad(20.0))
	var on_ramp := Vector3(r.x, 1.4, -20.0 - run * 0.5)
	var c0 := await _settle_on(on_ramp, PI * 0.5, 0.0)
	var e0 := _sole_error(c0)
	c0.queue_free(); chars.erase(c0); await ticks(2)
	var c1 := await _settle_on(on_ramp, PI * 0.5, 1.0)
	var e1 := _sole_error(c1)
	info("ramp sole error without IK %s, with IK %s" % [e0, e1])
	check(maxf(absf(e1[0]), absf(e1[1])) < 0.035, "both feet within 3.5 cm of the slope with IK")
	check(maxf(absf(e0[0]), absf(e0[1])) > maxf(absf(e1[0]), absf(e1[1])) + 0.02, "IK clearly improves grounding")
	_knees_ok(c1)
	c1.queue_free(); chars.erase(c1); await ticks(2)
	# Sideways across two 20 cm steps.
	var st := marker("stairs_20").global_position
	var c2 := await _settle_on(Vector3(st.x, 1.0, -20.0 - 0.32 * 3 - 0.16), PI * 0.5, 1.0)
	var e2 := _sole_error(c2)
	info("stairs sole error with IK %s, pelvis drop %.2f" % [e2, c2.anim.foot_ik.pelvis_drop])
	check(maxf(absf(e2[0]), absf(e2[1])) < 0.05, "feet planted on the stair treads")
	_knees_ok(c2)


func _knees_ok(c: UltraCharacter) -> void:
	var sk := c.skeleton
	for side in ["Left", "Right"]:
		var a := sk.get_bone_global_pose(sk.find_bone(side + "UpperLeg")).origin
		var b := sk.get_bone_global_pose(sk.find_bone(side + "LowerLeg")).origin
		var f := sk.get_bone_global_pose(sk.find_bone(side + "Foot")).origin
		var ang := rad_to_deg((a - b).angle_to(f - b))
		check(ang > 90.0 and ang < 179.5, "%s knee angle sane (%.1f°)" % [side, ang])
		# Knee should bend forward (+Z in skeleton space), never backwards.
		var mid := (a + f) * 0.5
		check((b - mid).z > -0.02, "%s knee bends forward" % side)


func _skate(c: UltraCharacter, move: Vector2) -> float:
	await hold(c, 90, move, 0, 0.0)
	var sk := c.skeleton
	var feet := [sk.find_bone("LeftToes"), sk.find_bone("RightToes")]
	var track := []
	bot(c).set_steps([{"ticks": 150, "move": move, "yaw": 0.0}])
	for i in 150:
		await sk.skeleton_updated
		track.append([sk.global_transform * sk.get_bone_global_pose(feet[0]).origin, sk.global_transform * sk.get_bone_global_pose(feet[1]).origin])
	var miny := [INF, INF]
	for ps: Array in track:
		for f in 2:
			miny[f] = minf(miny[f], (ps[f] as Vector3).y)
	var v: Array[float] = []
	for i in range(11, track.size()):
		var lo := 0 if (track[i][0] as Vector3).y <= (track[i][1] as Vector3).y else 1
		var p: Vector3 = track[i][lo]
		if p.y > miny[lo] + 0.03:
			continue
		var q: Vector3 = track[i - 1][lo]
		v.append(Vector2(p.x - q.x, p.z - q.z).length() * 60.0)
	v.sort()
	return v[v.size() / 2] if not v.is_empty() else INF


func test_foot_lock_removes_backpedal_skate() -> void:
	var c := spawn("speed_start")
	await ticks(3)
	c.anim.foot_ik.lock_feet = false
	var without := await _skate(c, Vector2(0, -0.75))
	c.queue_free(); chars.erase(c); await ticks(2)
	var c2 := spawn("speed_start")
	await ticks(3)
	var with_lock := await _skate(c2, Vector2(0, -0.75))
	info("backpedal skate: no lock %.2f m/s, lock %.2f m/s" % [without, with_lock])
	check(with_lock < 0.2, "foot lock keeps the planted foot still (%.2f m/s)" % with_lock)
	# (The 8-way backpedal barely skates on its own now; the lock must never make it worse.)
	check(with_lock <= without + 0.03, "lock never makes it worse")


func test_hand_ik_reaches() -> void:
	var c := spawn("speed_start")
	await ticks(60)
	var sk := c.skeleton
	var chest := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("UpperChest")).origin
	var fwd := c.visual_root.global_basis * Vector3.FORWARD
	var right := c.visual_root.global_basis * Vector3.RIGHT
	var goal := chest + fwd * 0.4 + right * 0.15 + Vector3.DOWN * 0.1
	var hb := sk.find_bone("RightHand")
	var cur := sk.global_transform * sk.get_bone_global_pose(hb)
	c.anim.hand_ik.set_goal(HandIKModifier.Hand.RIGHT, Transform3D(cur.basis, goal), 1.0, false, 20.0)
	await ticks(30)
	await sk.skeleton_updated
	var got := sk.global_transform * sk.get_bone_global_pose(hb).origin
	info("hand error %.3f m" % got.distance_to(goal))
	check(got.distance_to(goal) < 0.02, "right hand reaches its target")
	c.anim.hand_ik.release(HandIKModifier.Hand.RIGHT, 50.0)
	await ticks(10)
	await sk.skeleton_updated
	var back := sk.global_transform * sk.get_bone_global_pose(hb).origin
	check(back.distance_to(goal) > 0.1, "released hand returns to the animation")


func test_look_at() -> void:
	var c := spawn("speed_start")
	await ticks(60)
	var sk := c.skeleton
	var head := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("Head")).origin
	var right := c.visual_root.global_basis * Vector3.RIGHT
	var fwd := c.visual_root.global_basis * Vector3.FORWARD
	var target := head + (fwd + right * 0.8).normalized() * 3.0 + Vector3.UP * 0.6
	c.anim.look.look_at_point(target, 1.0)
	c.anim.look.speed = 50.0
	await ticks(20)
	await sk.skeleton_updated
	var hb := sk.find_bone("Head")
	var pose := sk.get_bone_global_pose(hb)
	var rel := pose.basis.orthonormalized() * sk.get_bone_global_rest(hb).basis.orthonormalized().inverse()
	var face := (sk.global_basis.orthonormalized() * (rel * Vector3.BACK)).normalized()   # model faces +Z
	var want := (target - sk.global_transform * pose.origin).normalized()
	var err := rad_to_deg(face.angle_to(want))
	info("look error %.1f°" % err)
	check(err < 12.0, "head turns to the target (%.1f°)" % err)
