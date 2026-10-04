extends UltraTestSuite
## Water: wading slows you, deep water floats you at the swim line, dive / surface, breath and
## drowning, climbing out over the pool edge, buoyant props, the river current, the valve.

const Id := MotorState.Id
const FPS := "res://addons/ultra_controller/profiles/fps.tres"
var seen := {}
var trace: Array[String] = []


func before_each() -> void:
	load_playground()
	await ticks(2)


## Drive the bot with `fn(k, c) -> InputFrame` until `done(c)` or `limit` ticks. Returns ticks used.
func drive(c: UltraCharacter, limit: int, fn: Callable, done := Callable()) -> int:
	seen.clear()
	trace.clear()
	var b := c.input_source as BotInputSource
	var k := [0]
	var last := [-1]
	b.driver = func(_t: int, _src: BotInputSource) -> InputFrame: return fn.call(k[0], c)
	for i in limit:
		await ticks(1)
		k[0] = i
		seen[c.state.state] = true
		if c.state.state != last[0]:
			trace.append("%d:%s" % [i, Id.keys()[c.state.state]])
			last[0] = c.state.state
		if done.is_valid() and done.call(c):
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


func water(n: String) -> UltraWater:
	return map.find_child(n, true, false) as UltraWater


func surface(c: UltraCharacter, w: UltraWater) -> float:
	return w.surface_y(c.platform_tick)


func test_wade_then_swim() -> void:
	var c := spawn("pool", FPS, false)
	await ticks(3)
	var dry := [0.0]
	var wet := [0.0]
	await drive(c, 600, func(_k: int, ch: UltraCharacter) -> InputFrame:
		var z := ch.state.pos.z
		if z > 66.0 and z < 67.6:
			dry[0] = maxf(dry[0], hspeed(ch))
		if z > 71.0 and z < 75.0 and ch.state.is_grounded():
			wet[0] = maxf(wet[0], hspeed(ch))
		return frame(Vector2(0, 1), 0, PI),
		func(ch: UltraCharacter) -> bool: return ch.state.state == Id.SWIM)
	info("dry %.2f m/s, waist-deep %.2f m/s; %s" % [dry[0], wet[0], " ".join(trace)])
	check(wet[0] > 0.3 and wet[0] < dry[0] * 0.75, "wading in 1 m of water is slower than on the deck")
	check(c.state.state == Id.SWIM, "walking into the deep end starts swimming")
	# Float still for a bit: the feet settle on the swim line.
	await drive(c, 150, func(_k: int, _ch: UltraCharacter) -> InputFrame: return frame(Vector2.ZERO, 0, PI))
	var w := water("PoolWater")
	var want := surface(c, w) - c.profile.float_depth
	near(c.state.pos.y, want, 0.05, "floating at the swim line (head out of the water)")
	check(c.state.breath >= c.profile.breath_time - 0.01, "breathing at the surface")


func test_dive_surface_breath() -> void:
	var c := spawn("pool_deep_side", FPS, false)
	await ticks(3)
	var yaw := -PI * 0.5                     # facing +X, into the deep end
	await drive(c, 300, func(_k: int, _ch: UltraCharacter) -> InputFrame: return frame(Vector2(0, 1), 0, yaw),
		func(ch: UltraCharacter) -> bool: return ch.state.state == Id.SWIM)
	check(c.state.state == Id.SWIM, "fell in and swims")
	await drive(c, 120, func(_k: int, _ch: UltraCharacter) -> InputFrame: return frame(Vector2.ZERO, 0, yaw))
	# Dive: look down and swim.
	var w := water("PoolWater")
	var low := [INF]
	await drive(c, 150, func(_k: int, ch: UltraCharacter) -> InputFrame:
		low[0] = minf(low[0], ch.state.pos.y)
		return frame(Vector2(0, 1), 0, yaw, -0.9))
	info("dive: %s, deepest feet %.2f (surface %.2f), breath %.1f s" % [" ".join(trace), low[0], surface(c, w), c.state.breath])
	check(seen.has(Id.DIVE), "looking down while swimming dives")
	check(low[0] < surface(c, w) - 2.5, "got well under water")
	check(c.state.breath < c.profile.breath_time - 1.5, "holding breath under water")
	var held := c.state.breath
	# Let go: drift up and surface.
	await drive(c, 600, func(_k: int, _ch: UltraCharacter) -> InputFrame: return frame(Vector2.ZERO, InputFrame.B_JUMP, yaw),
		func(ch: UltraCharacter) -> bool: return ch.state.state == Id.SWIM and ch.state.state_time > 1.0)
	check(c.state.state == Id.SWIM, "surfaced (%s)" % " ".join(trace))
	check(c.state.breath > held + 1.0, "air refills at the surface")
	check(absf(c.state.height - c.profile.stand_height) < 0.05, "capsule back to full height at the surface")


func test_climb_out_of_pool() -> void:
	var c := spawn("pool_deep_side", FPS, false)
	await ticks(3)
	await drive(c, 300, func(_k: int, _ch: UltraCharacter) -> InputFrame: return frame(Vector2(0, 1), 0, -PI * 0.5),
		func(ch: UltraCharacter) -> bool: return ch.state.state == Id.SWIM)
	await drive(c, 90, func(_k: int, _ch: UltraCharacter) -> InputFrame: return frame(Vector2(0, 1), 0, -PI * 0.5))
	# Turn round and swim back to the edge, hopping at it.
	await drive(c, 600, func(k: int, ch: UltraCharacter) -> InputFrame:
		var hop := ch.state.state == Id.SWIM and k % 20 < 2
		return frame(Vector2(0, 1) if ch.state.state != Id.MOVE else Vector2.ZERO, InputFrame.B_JUMP if hop else 0, PI * 0.5),
		func(ch: UltraCharacter) -> bool: return ch.state.is_grounded() and ch.state.pos.y > -0.05 and ch.state.state in [Id.IDLE, Id.MOVE])
	info("climb out: %s" % " ".join(trace))
	check(seen.has(Id.MANTLE), "mantles out of the water")
	check(absf(c.state.pos.y) < 0.06 and c.state.pos.x < 42.0, "standing on the deck")


func test_buoyancy() -> void:
	await ticks(420)
	var w := water("PoolWater")
	var s := w.surface_y(0)
	var wood := map.find_child("WoodCrate", true, false) as RigidBody3D
	var metal := map.find_child("MetalCrate", true, false) as RigidBody3D
	var ball := map.find_child("BeachBall", true, false) as RigidBody3D
	info("wood %.2f, metal %.2f, ball %.2f (surface %.2f)" % [wood.global_position.y, metal.global_position.y, ball.global_position.y, s])
	# 30 kg in 0.51 m3: floats with ~6 % under, so its centre rides ~0.35 m above the surface.
	check(absf(wood.global_position.y - (s + 0.35)) < 0.12 and wood.linear_velocity.length() < 0.3, "wooden crate floats high and has settled")
	check(metal.global_position.y < s - 3.5, "metal crate sinks to the bottom")
	check(ball.global_position.y > s - 0.2, "beach ball rides high")


func test_river_current() -> void:
	var c := spawn("river", FPS, false)
	await ticks(3)
	await drive(c, 240, func(_k: int, _ch: UltraCharacter) -> InputFrame: return frame(Vector2(0, 0.6), 0, PI),
		func(ch: UltraCharacter) -> bool: return ch.state.state == Id.SWIM)
	check(c.state.state == Id.SWIM, "swimming in the river")
	var z0 := c.state.pos.z
	await drive(c, 180, func(_k: int, _ch: UltraCharacter) -> InputFrame: return frame(Vector2.ZERO, 0, PI))
	var dz := c.state.pos.z - z0
	info("drifted %.2f m in 3 s" % dz)
	check(dz > 3.0, "the current carries an idle swimmer downstream")


func test_drowning() -> void:
	var c := spawn("pool_deep_side", FPS, false)
	c.profile.breath_time = 2.0
	await ticks(3)
	await drive(c, 300, func(_k: int, _ch: UltraCharacter) -> InputFrame: return frame(Vector2(0, 1), 0, -PI * 0.5),
		func(ch: UltraCharacter) -> bool: return ch.state.state == Id.SWIM)
	var hp0 := c.state.hp
	await drive(c, 300, func(_k: int, _ch: UltraCharacter) -> InputFrame: return frame(Vector2.ZERO, InputFrame.B_CROUCH, -PI * 0.5))
	info("breath %.2f, hp %.0f -> %.0f" % [c.state.breath, hp0, c.state.hp])
	check(c.state.breath <= 0.0, "air runs out when you stay under")
	check(c.state.hp < hp0 - 10.0, "drowning hurts")


func test_valve_floods_cistern() -> void:
	var c := spawn("cistern", FPS, false)
	await ticks(3)
	c.teleport(Vector3(80.5, -3.45, 72.0), 0.0)
	await ticks(20)
	var w := water("CisternWater")
	check(c.state.is_grounded() and c.state.state in [Id.IDLE, Id.MOVE, Id.LAND], "standing in the shallow pit")
	w.set_on(true)
	await ticks(int(w.raise_time * 60.0) + 90)
	var s := surface(c, w)
	info("cistern surface %.2f, player %s y %.2f" % [s, Id.keys()[c.state.state], c.state.pos.y])
	near(s, -0.3, 0.02, "the valve raised the water 2.7 m")
	check(c.state.state == Id.SWIM, "the rising water floated the player")
	near(c.state.pos.y, s - c.profile.float_depth, 0.08, "carried up to the swim line")
	# Swim to the pillar and climb on.
	await drive(c, 600, func(k: int, ch: UltraCharacter) -> InputFrame:
		var to := Vector3(84, 0, 70) - ch.state.pos
		var hop := ch.state.state == Id.SWIM and k % 20 < 2
		return frame(Vector2(0, 1), InputFrame.B_JUMP if hop else 0, atan2(-to.x, -to.z)),
		func(ch: UltraCharacter) -> bool: return ch.state.is_grounded() and ch.state.pos.y > -0.05)
	check(c.state.pos.y > -0.05 and absf(c.state.pos.x - 84.0) < 1.2, "swam to the pillar and climbed onto it (%s)" % " ".join(trace))


func test_tunnel_to_grotto() -> void:
	var c := spawn("tunnel", FPS, false)
	await ticks(3)
	var wps := [Vector3(66, -3.3, 86), Vector3(66, -3.3, 73.0), Vector3(65.5, -1.0, 70.5)]
	var wi := [0]
	var low_air := [INF]
	await drive(c, 1500, func(k: int, ch: UltraCharacter) -> InputFrame:
		low_air[0] = minf(low_air[0], ch.state.breath)
		var to: Vector3 = wps[wi[0]] - (ch.state.pos + Vector3.UP * 0.4)
		if Vector2(to.x, to.z).length() < 0.6 and wi[0] < wps.size() - 1:
			wi[0] += 1
		var flat := Vector2(to.x, to.z).length()
		var btn := InputFrame.B_CROUCH if k < 3 else 0
		return frame(Vector2(0, 1) if flat > 0.4 else Vector2.ZERO, btn, atan2(-to.x, -to.z), clampf(atan2(to.y, maxf(flat, 0.3)), -1.2, 1.2)),
		func(ch: UltraCharacter) -> bool: return wi[0] == wps.size() - 1 and ch.state.state == Id.SWIM)
	info("tunnel: %s, least air %.1f s" % [" ".join(trace), low_air[0]])
	check(c.state.state == Id.SWIM and c.state.pos.z < 74.0 and c.state.pos.x > 63.0, "swam the tunnel and surfaced in the grotto")
	check(low_air[0] > 0.0 and low_air[0] < c.profile.breath_time - 5.0, "a real breath-hold, but survivable")
