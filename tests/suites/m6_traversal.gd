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
		var how := "mantle" if seen.has(Id.MANTLE) else ("ledge" if seen.has(Id.LEDGE_HANG) else "none")
		results.append("%.1fm:%s%s" % [top, how, "/top" if on_top else "/(y %.2f z %.2f)" % [c.state.pos.y, c.state.pos.z]])
		check(on_top, "%.1f m wall: ends on top" % top)
		check(not _overlaps(c), "%.1f m wall: capsule not inside geometry" % top)
		if h <= 100:
			check(seen.has(Id.MANTLE), "%.1f m: mantles" % top)
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
	check(c.state.state in [Id.FALL, Id.JUMP, Id.LAND, Id.IDLE, Id.MOVE], "jump lets go (%s)" % Id.keys()[c.state.state])
