extends UltraTestSuite
## Traversal: ledge matrix, vault, ladder, shimmy, rope. Bots act like a player would: jump
## when the obstacle is close, stop pushing once they're up.

const Id := MotorState.Id
var seen := {}
var trace: Array[String] = []


func before_each() -> void:
	load_playground()
	await ticks(2)


func _overlaps(c: UltraCharacter) -> bool:
	var q := PhysicsShapeQueryParameters3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = c.profile.radius - 0.03
	cap.height = c.state.height - 0.1
	q.shape = cap
	q.transform = Transform3D(Basis(), c.state.pos + Vector3.UP * (c.state.height * 0.5 + 0.03))
	q.collision_mask = UltraLayers.WORLD_STATIC
	q.exclude = [c.get_rid()]
	return not c.get_world_3d().direct_space_state.intersect_shape(q, 1).is_empty()


## Drive the bot with `fn(tick, c) -> InputFrame` until `done(c)` or `limit` ticks.
func drive(c: UltraCharacter, limit: int, fn: Callable, done: Callable) -> int:
	seen.clear()
	trace.clear()
	var b := c.input_source as BotInputSource
	var k := [0]
	var last := [-1]
	b.driver = func(t: int, _src: BotInputSource) -> InputFrame:
		var f: InputFrame = fn.call(k[0], c)
		return f
	for i in limit:
		await ticks(1)
		k[0] = i
		seen[c.state.state] = true
		if c.state.state != last[0]:
			trace.append("%d:%s" % [i, Id.keys()[c.state.state]])
			last[0] = c.state.state
		if done.call(c):
			b.driver = Callable()
			return i
	b.driver = Callable()
	return limit


static func frame(move: Vector2, buttons := 0, yaw := 0.0, pitch := 0.0) -> InputFrame:
	var f := InputFrame.new()
	f.move = move
	f.buttons = buttons
	f.yaw = yaw
	f.pitch = pitch
	return f


func test_ledge_matrix() -> void:
	var results := []
	for h: int in [50, 100, 150, 200, 250]:
		var c := spawn("ledge_%d" % h, "res://addons/ultra_controller/profiles/fps.tres", false)
		await ticks(3)
		var top: float = h / 100.0
		var jumped := [false]
		await drive(c, 400, func(_k: int, ch: UltraCharacter) -> InputFrame:
			var close := ch.state.pos.z < -27.3
			var b := 0
			if close:
				b = InputFrame.B_JUMP
			return frame(Vector2(0, 1) if not (ch.state.is_grounded() and ch.state.pos.y > top - 0.2) else Vector2.ZERO, b),
			func(ch: UltraCharacter) -> bool: return ch.state.is_grounded() and ch.state.pos.y > top - 0.15 and ch.state.state in [Id.IDLE, Id.MOVE])
		await ticks(20)
		var on_top: bool = absf(c.state.pos.y - top) < 0.1 and c.state.pos.z < -28.0 and c.state.is_grounded()
		var how := "mantle" if seen.has(Id.MANTLE) else ("ledge" if seen.has(Id.LEDGE_HANG) else ("climb" if seen.has(Id.LEDGE_CLIMB) else "none"))
		results.append("%.1fm:%s%s" % [top, how, "/top" if on_top else "/(y %.2f z %.2f)" % [c.state.pos.y, c.state.pos.z]])
		check(on_top, "%.1f m wall: ends on top" % top)
		check(not _overlaps(c), "%.1f m wall: capsule not inside geometry" % top)
		if h <= 100:
			check(seen.has(Id.MANTLE), "%.1f m: mantles" % top)
		elif top < UltraTraversal.HANG_DROP:
			# Lower than a hanging body: hanging would put the feet in the floor - climb straight up.
			check(not seen.has(Id.LEDGE_HANG) and seen.has(Id.LEDGE_CLIMB), "%.1f m: climbs straight up, no hang (%s)" % [top, " ".join(trace)])
		else:
			check(seen.has(Id.LEDGE_HANG) and seen.has(Id.LEDGE_CLIMB), "%.1f m: grabs the ledge and climbs up (%s)" % [top, " ".join(trace)])
		c.queue_free()
		chars.erase(c)
		await ticks(2)
	info(" ".join(results))


func test_vault() -> void:
	var c := spawn("parkour_start", "res://addons/ultra_controller/profiles/fps.tres", false)
	await ticks(3)
	var t0 := [-1]
	var n := await drive(c, 240, func(k: int, ch: UltraCharacter) -> InputFrame:
		var b := InputFrame.B_SPRINT
		if ch.state.pos.z < -14.4 and t0[0] < 0:
			b |= InputFrame.B_JUMP
			t0[0] = k
		return frame(Vector2(0, 1), b),
		func(ch: UltraCharacter) -> bool: return ch.state.pos.z < -17.0 and ch.state.is_grounded())
	info("vault: %s, crossed %.2fs after the jump" % [" ".join(trace), (n - t0[0]) / 60.0])
	check(seen.has(Id.VAULT), "sprint + jump at a 1 m box vaults")
	check((n - t0[0]) / 60.0 < 1.2, "crosses the box in under 1.2 s")
	check(Vector2(c.state.vel.x, c.state.vel.z).length() > 3.0, "keeps running after the vault")


func test_ladder_up_and_out() -> void:
	var c := spawn("parkour_ladder", "res://addons/ultra_controller/profiles/fps.tres", false)
	await ticks(3)
	await drive(c, 600, func(_k: int, _ch: UltraCharacter) -> InputFrame: return frame(Vector2(0, 1)),
		func(ch: UltraCharacter) -> bool: return ch.state.pos.y > 5.9 and ch.state.is_grounded() and ch.state.state in [Id.IDLE, Id.MOVE])
	await ticks(10)
	info("ladder: %s" % " ".join(trace))
	check(seen.has(Id.LADDER), "walking into the ladder climbs it")
	check(absf(c.state.pos.y - 6.0) < 0.1 and c.state.is_grounded(), "climbed out on top of the 6 m tower")


func test_shimmy_and_climb() -> void:
	var c := spawn("parkour_shimmy", "res://addons/ultra_controller/profiles/fps.tres", false)
	await ticks(3)
	await drive(c, 120, func(_k: int, ch: UltraCharacter) -> InputFrame:
		return frame(Vector2(0, 1), InputFrame.B_JUMP if ch.state.pos.z < -44.8 + -0.1 else 0),
		func(ch: UltraCharacter) -> bool: return ch.state.state == Id.LEDGE_HANG and ch.state.state_time > 0.4)
	check(c.state.state == Id.LEDGE_HANG, "hanging under the overhang (%s)" % " ".join(trace))
	await drive(c, 40, func(_k: int, _ch: UltraCharacter) -> InputFrame: return frame(Vector2(0, 1)), func(_ch: UltraCharacter) -> bool: return false)
	check(c.state.state == Id.LEDGE_HANG, "can't climb up here (no room)")
	var x0 := c.state.pos.x
	await drive(c, 600, func(_k: int, _ch: UltraCharacter) -> InputFrame: return frame(Vector2(1, 0)),
		func(ch: UltraCharacter) -> bool: return ch.state.trav_s > 0.5)
	info("shimmied %.2f m to a climbable spot" % (c.state.pos.x - x0))
	check(c.state.pos.x - x0 > 3.5 and c.state.state == Id.LEDGE_HANG, "shimmied right along the ledge")
	await drive(c, 150, func(_k: int, _ch: UltraCharacter) -> InputFrame: return frame(Vector2(0, 1)),
		func(ch: UltraCharacter) -> bool: return ch.state.is_grounded() and ch.state.state in [Id.IDLE, Id.MOVE])
	check(absf(c.state.pos.y - 2.2) < 0.1 and c.state.is_grounded(), "climbed up where the overhang ends (y %.2f; %s)" % [c.state.pos.y, " ".join(trace)])


func test_rope_swing() -> void:
	var c := spawn("parkour_rope", "res://addons/ultra_controller/profiles/fps.tres", false)
	await ticks(3)
	await drive(c, 200, func(_k: int, ch: UltraCharacter) -> InputFrame:
		return frame(Vector2(0, 1), InputFrame.B_SPRINT | (InputFrame.B_JUMP if ch.state.pos.z < -55.4 and ch.state.is_grounded() else 0)),
		func(ch: UltraCharacter) -> bool: return ch.state.state == Id.ROPE or ch.state.pos.y < 2.0)
	info("rope: %s" % " ".join(trace))
	check(c.state.state == Id.ROPE, "jumped and caught the rope")
	if c.state.state != Id.ROPE:
		return
	var max_swing := [0.0]
	await drive(c, 300, func(k: int, ch: UltraCharacter) -> InputFrame:
		max_swing[0] = maxf(max_swing[0], absf(ch.state.pos.z - (-60.0)))
		# pump in time with the swing
		return frame(Vector2(0, 1.0 if ch.state.vel.z < 0.0 else -1.0)),
		func(_ch: UltraCharacter) -> bool: return false)
	info("swing amplitude %.2f m" % max_swing[0])
	check(max_swing[0] > 1.5, "pumping builds a swing")
	var L := c.state.trav_s + 1.95
	check(max_swing[0] < L * sin(deg_to_rad(75.0)), "swing stays below ~75 degrees (%.2f m of %.2f m)" % [max_swing[0], L])
	var r := UltraRope.find(c.state.trav_id)
	if r:
		check(absf(c.state.pos.distance_to(r.anchor()) - (c.state.trav_s + 1.95)) < 0.02, "rope length holds under load")
	await drive(c, 20, func(_k: int, _ch: UltraCharacter) -> InputFrame: return frame(Vector2.ZERO, InputFrame.B_JUMP), func(_ch: UltraCharacter) -> bool: return false)
	check(c.state.state != Id.ROPE, "jump lets go (%s)" % Id.keys()[c.state.state])


## Swing ropes climb too: look up + forward goes up the rope, look down + forward slides down.
func test_swing_rope_climb() -> void:
	var c := spawn("parkour_rope", "res://addons/ultra_controller/profiles/fps.tres", false)
	await ticks(3)
	await drive(c, 200, func(_k: int, ch: UltraCharacter) -> InputFrame:
		return frame(Vector2(0, 1), InputFrame.B_SPRINT | (InputFrame.B_JUMP if ch.state.pos.z < -55.4 and ch.state.is_grounded() else 0)),
		func(ch: UltraCharacter) -> bool: return ch.state.state == Id.ROPE or ch.state.pos.y < 2.0)
	check(c.state.state == Id.ROPE, "caught the swing rope")
	if c.state.state != Id.ROPE:
		return
	var s0 := c.state.trav_s
	await drive(c, 60, func(_k: int, _ch: UltraCharacter) -> InputFrame: return frame(Vector2(0, 1), 0, 0.0, 0.8), func(_ch: UltraCharacter) -> bool: return false)
	var s1 := c.state.trav_s
	await drive(c, 60, func(_k: int, _ch: UltraCharacter) -> InputFrame: return frame(Vector2(0, 1), 0, 0.0, -0.8), func(_ch: UltraCharacter) -> bool: return false)
	var s2 := c.state.trav_s
	info("grip along the rope: %.2f -> up %.2f -> down %.2f" % [s0, s1, s2])
	check(s1 < s0 - 0.5, "looking up + forward climbs the swing rope")
	check(s2 > s1 + 0.5, "looking down + forward slides back down")
	check(c.state.state == Id.ROPE, "still on the rope")


## Ladder: hands and feet land on the rungs while climbing.
func test_ladder_limbs_on_rungs() -> void:
	var c := spawn("parkour_ladder")
	await ticks(3)
	var sk := c.skeleton
	var ik := c.anim.hand_ik
	var bones: Array[int] = []
	for h in 4:
		bones.append(ik.hand_bone(h))
	var near := [0, 0]          # [frames sampled, limb-frames within 4 cm of a rung]
	var sample := func() -> void:
		if c.state.state != Id.LADDER or c.state.state_time < 0.5:
			return
		var lad := UltraLadder.find(c.state.trav_id)
		near[0] += 1
		for h in 4:
			var p := sk.global_transform * sk.get_bone_global_pose(bones[h]).origin
			var o: Vector2 = UltraTraversalVisual.RUNG_FOOT if h >= 2 else UltraTraversalVisual.RUNG_HAND
			var y := (p - lad.global_position).y - o.x
			var k := clampf(roundf((y - UltraLadder.FIRST_RUNG) / UltraLadder.RUNG_SPACING), 0.0, lad.rung_count() - 1.0)
			var rung := lad.global_position + Vector3.UP * (UltraLadder.FIRST_RUNG + k * UltraLadder.RUNG_SPACING)
			var off := (p - rung) - lad.normal() * o.y - Vector3.UP * o.x
			off -= lad.normal().cross(Vector3.UP).normalized() * off.dot(lad.normal().cross(Vector3.UP).normalized())
			if off.length() < 0.04:
				near[1] += 1
	sk.skeleton_updated.connect(sample)
	await drive(c, 400, func(_k: int, _ch: UltraCharacter) -> InputFrame: return frame(Vector2(0, 1)),
		func(ch: UltraCharacter) -> bool: return ch.state.pos.y > 3.5)
	sk.skeleton_updated.disconnect(sample)
	var per := float(near[1]) / maxf(near[0], 1.0)
	info("ladder: %d frames, %.2f limbs on a rung per frame" % [near[0], per])
	check(near[0] > 30 and per >= 1.5, "at least two limbs are on rungs on average")


## Every rope swings and climbs; climbing down to the ground puts you on your feet (never
## through the floor). ClimbRope6: anchor 7 m up, 6.5 m long - its end is near the ground.
func test_all_ropes_swing_climb_and_land() -> void:
	var c := spawn("parkour_rope", "res://addons/ultra_controller/profiles/fps.tres", false)
	await ticks(3)
	var rope: UltraRope = map.find_child("ClimbRope6", true, false)
	c.teleport(rope.anchor() + Vector3.DOWN * 4.6, 0.0)
	c.state.state = Id.FALL
	await drive(c, 60, func(_k: int, _ch: UltraCharacter) -> InputFrame: return frame(Vector2.ZERO), func(ch: UltraCharacter) -> bool: return ch.state.state == Id.ROPE)
	check(c.state.state == Id.ROPE, "caught the climbing rope")
	if c.state.state != Id.ROPE:
		return
	var amp := [0.0]
	var a := rope.anchor()
	await drive(c, 240, func(_k: int, ch: UltraCharacter) -> InputFrame:
		amp[0] = maxf(amp[0], absf(ch.state.pos.z - a.z))
		return frame(Vector2(0, 1.0 if ch.state.vel.z < 0.0 else -1.0)), func(_ch: UltraCharacter) -> bool: return false)
	info("climb rope swing amplitude %.2f m" % amp[0])
	check(amp[0] > 1.0, "the climbing rope swings too")
	# Let it settle, climb up a bit, then climb all the way down.
	await drive(c, 240, func(_k: int, _ch: UltraCharacter) -> InputFrame: return frame(Vector2.ZERO), func(_ch: UltraCharacter) -> bool: return false)
	var s0 := c.state.trav_s
	await drive(c, 60, func(_k: int, _ch: UltraCharacter) -> InputFrame: return frame(Vector2(0, 1), 0, 0.0, 0.8), func(_ch: UltraCharacter) -> bool: return false)
	check(c.state.trav_s < s0 - 0.5, "looking up + forward climbs it (%.2f -> %.2f)" % [s0, c.state.trav_s])
	var lowest := [INF]
	var n := await drive(c, 600, func(_k: int, ch: UltraCharacter) -> InputFrame:
		lowest[0] = minf(lowest[0], ch.state.pos.y)
		return frame(Vector2(0, 1), 0, 0.0, -0.8),
		func(ch: UltraCharacter) -> bool: return ch.state.state != Id.ROPE)
	await ticks(20)
	info("climbed down: %s; lowest feet y %.2f; now %s at y %.2f" % [" ".join(trace), lowest[0], Id.keys()[c.state.state], c.state.pos.y])
	check(c.state.state in [Id.IDLE, Id.MOVE, Id.LAND] and c.state.is_grounded(), "climbing down to the ground puts you on your feet")
	check(lowest[0] > -0.05 and c.state.pos.y > -0.05, "never below the floor")


## The climbable wall (accent coloured, 6 m): walk into it to start climbing, hold forward to
## climb, and you climb out on top.
func test_climbable_wall() -> void:
	var c := spawn("climb_wall", "res://addons/ultra_controller/profiles/fps.tres", false)
	await ticks(3)
	await drive(c, 900, func(_k: int, _ch: UltraCharacter) -> InputFrame: return frame(Vector2(0, 1)),
		func(ch: UltraCharacter) -> bool: return ch.state.pos.y > 5.9 and ch.state.is_grounded() and ch.state.state in [Id.IDLE, Id.MOVE])
	info("climb wall: %s; y %.2f" % [" ".join(trace), c.state.pos.y])
	check(seen.has(Id.WALL_CLIMB), "walking into the climbable wall climbs it (no jump needed)")
	check(c.state.pos.y > 5.9 and c.state.is_grounded(), "climbed out on top")


## Two-handed moves stow the gun: it's put away for the ladder and drawn again on top.
func test_gun_stowed_while_climbing() -> void:
	var c := spawn("parkour_ladder", "res://addons/ultra_controller/profiles/fps.tres", false)
	await ticks(3)
	UltraItems.give(c, &"pistol")
	var with_slot := func(move: Vector2) -> InputFrame:
		var f := frame(move)
		f.want_slot = 1
		return f
	await drive(c, 40, func(_k: int, _ch: UltraCharacter) -> InputFrame: return with_slot.call(Vector2.ZERO), func(_ch: UltraCharacter) -> bool: return false)
	check(c.state.equipped != 0, "pistol drawn")
	var drawn_on_ladder := [0, 0]
	await drive(c, 600, func(_k: int, ch: UltraCharacter) -> InputFrame:
		if ch.state.state == Id.LADDER:
			drawn_on_ladder[0] += 1
			if ch.state.held_uid != 0:
				drawn_on_ladder[1] += 1
		return with_slot.call(Vector2(0, 1)),
		func(ch: UltraCharacter) -> bool: return ch.state.pos.y > 5.9 and ch.state.is_grounded() and ch.state.state in [Id.IDLE, Id.MOVE])
	info("ladder ticks %d, with the gun in hand %d" % drawn_on_ladder)
	check(drawn_on_ladder[0] > 30 and drawn_on_ladder[1] == 0, "the gun is stowed the whole climb")
	await drive(c, 90, func(_k: int, _ch: UltraCharacter) -> InputFrame: return with_slot.call(Vector2.ZERO), func(ch: UltraCharacter) -> bool: return ch.state.action == UltraActionLayer.Action.READY)
	check(c.state.equipped != 0 and c.state.action == UltraActionLayer.Action.READY, "and drawn again at the top")


## The drawn rope reacts to the world: taut above a climber's hands, pushed aside by people
## walking into it (and swinging after), lying on the ground without sinking into it, knocked
## by a flying prop, and still swinging after you let go.
func test_rope_reacts_to_the_world() -> void:
	# A test rope over the speed lane: anchor 3 m up, 5 m long (2 m of it lies on the ground).
	var r := UltraRope.new()
	r.length = 5.0
	add_child(r)
	r.global_position = Vector3(-24, 3.0, -40)
	await ticks(300)
	var lowest := INF
	var on_ground := 0
	for k in 60:
		var p := r.point_at(r.length * k / 59.0)
		lowest = minf(lowest, p.y)
		if p.y < 0.13:
			on_ground += 1
	info("rope on the ground: lowest point y %.3f, %d of 60 samples lying on it" % [lowest, on_ground])
	check(lowest > -0.01 and on_ground > 10, "the long end lies on the ground, not through it")
	check(r.is_still(), "and the rope comes to rest")
	# Walk through it.
	var c := spawn("parkour_rope", "res://addons/ultra_controller/profiles/fps.tres", true)
	await ticks(3)
	c.teleport(Vector3(-24, 0.1, -38), 0.0)
	var before := r.point_at(2.0)
	var pushed := [0.0]
	await drive(c, 120, func(_k: int, _ch: UltraCharacter) -> InputFrame:
		pushed[0] = maxf(pushed[0], r.point_at(2.0).distance_to(before))
		return frame(Vector2(0, 1)), func(_ch: UltraCharacter) -> bool: return false)
	info("walking through it pushed the rope %.2f m (walker went %s -> %s; %s)" % [pushed[0], Vector3(-24, 0.1, -38), c.state.pos, " ".join(trace)])
	check(pushed[0] > 0.2, "walking into the rope pushes it aside")
	await drive(c, 20, func(_k: int, _ch: UltraCharacter) -> InputFrame: return frame(Vector2.ZERO), func(_ch: UltraCharacter) -> bool: return false)
	check(not r.is_still(), "and it's still swinging just after")
	c.teleport(Vector3(-24, 0.1, -60), 0.0)
	await ticks(600)
	check(r.is_still(), "then it settles again")
	# A prop flying into it.
	var rb := RigidBody3D.new()
	rb.mass = 3.0
	rb.collision_layer = UltraLayers.WORLD_DYNAMIC
	rb.collision_mask = UltraLayers.WORLD_STATIC
	rb.gravity_scale = 0.0
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3.ONE * 0.3
	cs.shape = bs
	rb.add_child(cs)
	add_child(rb)
	rb.global_position = Vector3(-27, 1.8, -40)
	rb.linear_velocity = Vector3(8, 0, 0)
	before = r.point_at(1.2)
	var knocked := 0.0
	for i in 40:
		await ticks(1)
		knocked = maxf(knocked, r.point_at(1.2).distance_to(before))
	info("a 3 kg box at 8 m/s knocked the rope %.2f m" % knocked)
	check(knocked > 0.15, "a flying prop knocks the rope about")
	rb.queue_free()
	r.queue_free()


## Held, the rope is taut and straight from the anchor to the hands; let go, it keeps swinging.
func test_rope_taut_when_held() -> void:
	var c := spawn("parkour_rope", "res://addons/ultra_controller/profiles/fps.tres", true)
	await ticks(3)
	await drive(c, 200, func(_k: int, ch: UltraCharacter) -> InputFrame:
		return frame(Vector2(0, 1), InputFrame.B_SPRINT | (InputFrame.B_JUMP if ch.state.pos.z < -55.4 and ch.state.is_grounded() else 0)),
		func(ch: UltraCharacter) -> bool: return ch.state.state == Id.ROPE or ch.state.pos.y < 2.0)
	check(c.state.state == Id.ROPE, "caught the rope")
	if c.state.state != Id.ROPE:
		return
	var rope := UltraRope.find(c.state.trav_id)
	var worst := [0.0]
	await drive(c, 180, func(_k: int, ch: UltraCharacter) -> InputFrame:
		var a := rope.anchor()
		var h := UltraTraversalVisual.rope_grip(ch)
		for k in 10:
			var p := rope.point_at(ch.state.trav_s * 0.9 * k / 10.0)
			var q := Geometry3D.get_closest_point_to_segment(p, a, h)
			worst[0] = maxf(worst[0], p.distance_to(q))
		return frame(Vector2(0, 1.0 if ch.state.vel.z < 0.0 else -1.0)), func(_ch: UltraCharacter) -> bool: return false)
	info("held rope: worst bend between anchor and hands %.3f m" % worst[0])
	check(worst[0] < 0.03, "taut and straight above the hands")
	await drive(c, 10, func(_k: int, _ch: UltraCharacter) -> InputFrame: return frame(Vector2.ZERO, InputFrame.B_JUMP), func(ch: UltraCharacter) -> bool: return ch.state.state != Id.ROPE)
	var p0 := rope.point_at(rope.length)
	await ticks(20)
	info("let go: rope end moved %.2f m in 0.33 s" % rope.point_at(rope.length).distance_to(p0))
	check(rope.point_at(rope.length).distance_to(p0) > 0.3, "let go, the rope swings on")


## Swinging into a loose prop knocks it away (and you keep swinging).
func test_swing_knocks_props() -> void:
	var c := spawn("parkour_rope", "res://addons/ultra_controller/profiles/fps.tres", false)
	await ticks(3)
	await drive(c, 200, func(_k: int, ch: UltraCharacter) -> InputFrame:
		return frame(Vector2(0, 1), InputFrame.B_SPRINT | (InputFrame.B_JUMP if ch.state.pos.z < -55.4 and ch.state.is_grounded() else 0)),
		func(ch: UltraCharacter) -> bool: return ch.state.state == Id.ROPE or ch.state.pos.y < 2.0)
	if c.state.state != Id.ROPE:
		check(false, "caught the rope")
		return
	await drive(c, 240, func(_k: int, ch: UltraCharacter) -> InputFrame:
		return frame(Vector2(0, 1.0 if ch.state.vel.z < 0.0 else -1.0)), func(_ch: UltraCharacter) -> bool: return false)
	var rope := UltraRope.find(c.state.trav_id)
	var L := c.state.trav_s + 1.95
	var bottom := rope.anchor() + Vector3.DOWN * (L - 1.0)
	var rb := RigidBody3D.new()
	rb.mass = 5.0
	rb.gravity_scale = 0.0
	rb.collision_layer = UltraLayers.WORLD_DYNAMIC
	rb.collision_mask = UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC | UltraLayers.CHARACTER
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3.ONE * 0.4
	cs.shape = bs
	rb.add_child(cs)
	add_child(rb)
	rb.global_position = bottom
	var start := rb.global_position
	await drive(c, 150, func(_k: int, ch: UltraCharacter) -> InputFrame:
		return frame(Vector2(0, 1.0 if ch.state.vel.z < 0.0 else -1.0)), func(_ch: UltraCharacter) -> bool: return rb.global_position.distance_to(start) > 1.5)
	info("crate knocked %.2f m (speed %.1f m/s); still on the rope: %s" % [rb.global_position.distance_to(start), rb.linear_velocity.length(), c.state.state == Id.ROPE])
	check(rb.global_position.distance_to(start) > 1.0, "the swing knocks the crate away")
	check(c.state.state == Id.ROPE, "and you keep swinging")
	rb.queue_free()


## Looking up while on a ladder turns the head (and a little of the chest): the chest stays at
## the ladder and the hands stay on the rungs.
func test_ladder_look_up_keeps_hands_on() -> void:
	var c := spawn("parkour_ladder")
	await ticks(3)
	await drive(c, 400, func(_k: int, _ch: UltraCharacter) -> InputFrame: return frame(Vector2(0, 1)),
		func(ch: UltraCharacter) -> bool: return ch.state.state == Id.LADDER and ch.state.state_time > 1.0)
	var sk := c.skeleton
	var lad := UltraLadder.find(c.state.trav_id)
	var chest := sk.find_bone("Chest")
	var res := {}
	for pitch: float in [0.0, 1.2]:
		await drive(c, 60, func(_k: int, _ch: UltraCharacter) -> InputFrame: return frame(Vector2.ZERO, 0, 0.0, pitch), func(_ch: UltraCharacter) -> bool: return false)
		var out := [0.0, 0.0]
		var grab := func() -> void:
			var p := sk.global_transform * sk.get_bone_global_pose(chest).origin
			out[0] = (p - lad.global_position).dot(lad.normal())
			out[1] = maxf(c.anim.hand_ik.last_error[0], c.anim.hand_ik.last_error[1])
		sk.skeleton_updated.connect(grab)
		await get_tree().process_frame
		await get_tree().process_frame
		sk.skeleton_updated.disconnect(grab)
		res[pitch] = out.duplicate()
	info("chest out from the ladder: level %.2f m, looking up %.2f m; hand IK error %.3f / %.3f m" % [res[0.0][0], res[1.2][0], res[0.0][1], res[1.2][1]])
	check(absf(res[1.2][0] - res[0.0][0]) < 0.08, "looking up doesn't pull the chest off the ladder")
	check(res[1.2][1] < 0.03, "the hands stay on the rungs")
