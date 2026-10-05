extends UltraTestSuite
## Motor: inertia, jump, stairs, slopes, stances, slide, roll, landing, friction, determinism.
## Characters are spawned without bodies (pure simulation) unless a test needs animation.

const FWD := Vector2(0, 1)


func before_each() -> void:
	load_playground()
	await ticks(2)


func test_accel_and_stop() -> void:
	var c := spawn("speed_start", "res://addons/ultra_controller/profiles/fps.tres", false)
	await ticks(5)
	var t90 := -1
	for i in 240:
		await hold(c, 1, FWD, InputFrame.B_SPRINT, 0.0)
		if t90 < 0 and hspeed(c) >= c.profile.sprint_speed * 0.9:
			t90 = i
	info("reached 90%% sprint after %.2fs, top %.2f m/s" % [t90 / 60.0, hspeed(c)])
	check(t90 > 20 and t90 < 150, "sprint build-up is weighty but responsive (%.2fs)" % (t90 / 60.0))
	near(hspeed(c), c.profile.sprint_speed, 0.15, "top sprint speed")
	var p0 := c.state.pos
	var n := 0
	while hspeed(c) > 0.05 and n < 300:
		await hold(c, 1, Vector2.ZERO, 0, 0.0)
		n += 1
	var stop := Vector2(c.state.pos.x - p0.x, c.state.pos.z - p0.z).length()
	info("stop distance %.2f m in %.2fs" % [stop, n / 60.0])
	check(stop > 0.6 and stop < 3.5, "stopping carries momentum (%.2f m)" % stop)


func test_jump_height() -> void:
	var c := spawn("speed_start", "res://addons/ultra_controller/profiles/fps.tres", false)
	await ticks(10)
	var y0 := c.state.pos.y
	var top := y0
	bot(c).set_steps([{"ticks": 45, "buttons": InputFrame.B_JUMP}, {"ticks": 45}])
	for i in 90:
		await ticks(1)
		top = maxf(top, c.state.pos.y)
	near(top - y0, c.profile.jump_height, 0.08, "full jump height")
	check(c.state.is_grounded(), "landed again")
	# Tap: shorter hop (variable height).
	var c2 := spawn("speed_start", "res://addons/ultra_controller/profiles/fps.tres", false)
	c2.teleport(c.state.pos + Vector3(3, 0, 0))
	await ticks(5)
	y0 = c2.state.pos.y
	top = y0
	bot(c2).set_steps([{"ticks": 2, "buttons": InputFrame.B_JUMP}, {"ticks": 60}])
	for i in 62:
		await ticks(1)
		top = maxf(top, c2.state.pos.y)
	check(top - y0 < c.profile.jump_height * 0.75, "tap jump is lower (%.2f m)" % (top - y0))


func _climb(marker_name: String, top_marker: String, seconds: float) -> bool:
	var c := spawn(marker_name, "res://addons/ultra_controller/profiles/fps.tres", false)
	await ticks(3)
	var target := marker(top_marker).global_position.y
	for i in int(seconds * 60):
		await hold(c, 1, Vector2(0, 0.7), 0, 0.0)
		if c.state.pos.y >= target - 0.08:
			return true
	info("%s stalled at y=%.2f (top %.2f)" % [marker_name, c.state.pos.y, target])
	return false


func test_stairs() -> void:
	for r in [15, 20, 30]:
		check(await _climb("stairs_%d" % r, "stairs_%d_top" % r, 8.0), "climbs %d cm risers" % r)
	check(not await _climb("stairs_45", "stairs_45_top", 4.0), "45 cm risers block walking")


func test_slopes() -> void:
	for a in [10, 20, 30, 40]:
		check(await _climb("ramp_%d" % a, "ramp_%d_top" % a, 16.0), "walks up %d° ramp" % a)
	check(not await _climb("ramp_50", "ramp_50_top", 5.0), "50° ramp is too steep")


func test_crouch_and_crawl_clearance() -> void:
	var c := spawn("crouch_gap", "res://addons/ultra_controller/profiles/fps.tres", false)
	await ticks(3)
	await hold(c, 180, FWD, 0, 0.0)
	check(c.state.pos.z > -56.4, "standing can't enter the 1.25 m gap (z=%.2f)" % c.state.pos.z)
	await hold(c, 240, FWD, InputFrame.B_CROUCH, 0.0)
	check(c.state.pos.z < -59.0, "crouched gets into the gap (z=%.2f)" % c.state.pos.z)
	await hold(c, 30, Vector2.ZERO, 0, 0.0)
	check(c.state.stance == MotorState.Stance.CROUCH, "can't stand up under the roof")
	var k := spawn("crawl_tunnel", "res://addons/ultra_controller/profiles/fps.tres", false)
	await ticks(3)
	await hold(k, 120, FWD, InputFrame.B_CROUCH, 0.0)
	check(k.state.pos.z > -56.4, "crouching can't enter the 0.75 m tunnel")
	await hold(k, 500, FWD, InputFrame.B_CROUCH | InputFrame.B_CRAWL, 0.0)
	check(k.state.pos.z < -59.0, "crawling gets through the tunnel (z=%.2f)" % k.state.pos.z)


func test_slide_and_roll() -> void:
	var c := spawn("speed_start", "res://addons/ultra_controller/profiles/fps.tres", false)
	await ticks(3)
	await hold(c, 120, FWD, InputFrame.B_SPRINT, 0.0)
	var entered := false
	bot(c).set_steps([{"ticks": 40, "move": FWD, "buttons": InputFrame.B_SPRINT | InputFrame.B_CROUCH}])
	for i in 40:
		await ticks(1)
		entered = entered or c.state.state == MotorState.Id.SLIDE
	check(entered, "sprint + crouch slides")
	await hold(c, 90, Vector2.ZERO, 0, 0.0)
	var p0 := c.state.pos
	bot(c).set_steps([{"ticks": 2, "buttons": InputFrame.B_DODGE}, {"ticks": 150}])
	var rolled := false
	for i in 152:
		await ticks(1)
		rolled = rolled or c.state.state == MotorState.Id.ROOT_MOTION
	check(rolled, "dodge with no input rolls")
	var d := Vector2(c.state.pos.x - p0.x, c.state.pos.z - p0.z).length()
	near(d, 4.99, 0.35, "roll covers its root-motion distance")


func test_hard_landing() -> void:
	var c := spawn("drop_9", "res://addons/ultra_controller/profiles/fps.tres", false)
	await ticks(3)
	var hard := false
	var impact := [0.0]          # lambdas capture by value: use a container
	c.landed.connect(func(v: float) -> void: impact[0] = maxf(impact[0], v))
	bot(c).set_steps([{"ticks": 60, "move": FWD, "buttons": InputFrame.B_SPRINT}, {"ticks": 400}])
	var up := false
	for i in 460:
		await ticks(1)
		hard = hard or c.state.state == MotorState.Id.RAGDOLL
		up = hard and c.state.state == MotorState.Id.IDLE
	info("impact %.1f m/s" % impact[0])
	check(impact[0] > 11.0, "landing impact reported")
	check(hard, "9 m drop: the legs give way (ragdoll)")
	check(up, "and the character gets back up")


func test_ice_is_slippery() -> void:
	var g := spawn("speed_start", "res://addons/ultra_controller/profiles/fps.tres", false)
	var ice := spawn("ice", "res://addons/ultra_controller/profiles/fps.tres", false)
	await ticks(3)
	var stops := []
	for c in [g, ice]:
		await hold(c, 90, FWD, 0, 0.0)
		var p0: Vector3 = c.state.pos
		await hold(c, 240, Vector2.ZERO, 0, 0.0)
		stops.append(Vector2(c.state.pos.x - p0.x, c.state.pos.z - p0.z).length())
	info("stop: ground %.2f m, ice %.2f m" % stops)
	check(stops[1] > stops[0] * 3.0, "ice stops much later than ground")


func _course() -> Array:
	return [
		{"ticks": 40, "move": FWD},
		{"ticks": 30, "move": Vector2(0.7, 0.7), "yaw_rate": 1.5, "buttons": InputFrame.B_SPRINT},
		{"ticks": 2, "move": FWD, "tap": InputFrame.B_JUMP},
		{"ticks": 60, "move": FWD},
		{"ticks": 30, "move": Vector2(-1, 0), "buttons": InputFrame.B_CROUCH},
		{"ticks": 50, "move": Vector2(0, -1)},
		{"ticks": 20},
	]


func test_determinism() -> void:
	var finals := []
	for run in 2:
		var c := spawn("speed_start", "res://addons/ultra_controller/profiles/fps.tres", false)
		c.self_simulate = false
		await ticks(2)
		var b := bot(c)
		b.set_steps(_course())
		var t := 0
		while not b.is_done():
			c.simulate(b.sample(t), 1.0 / 60.0)
			t += 1
		finals.append(c.state.copy())
		c.queue_free()
		chars.erase(c)
		await ticks(2)
	var a: MotorState = finals[0]
	var b2: MotorState = finals[1]
	info("final %s / %s" % [a.pos, b2.pos])
	check(a.pos.distance_to(b2.pos) < 1e-4 and a.state == b2.state, "same inputs -> same result")


func test_moving_platforms() -> void:
	for spec in [["platform_linear", 300], ["platform_rotate", 300], ["platform_elevator", 420]]:
		var c := spawn(spec[0], "res://addons/ultra_controller/profiles/fps.tres", false)
		await ticks(3)
		var plat := TickPlatform.find(c.state.platform_id)
		var rode := false
		var max_y := -INF
		for i in int(spec[1]):
			await ticks(1)
			rode = rode or c.state.platform_id != 0
			max_y = maxf(max_y, c.state.pos.y)
		check(rode, "%s: standing on the platform registers it" % spec[0])
		check(c.state.platform_id != 0 and c.state.is_grounded(), "%s: still riding after %d ticks (on %d)" % [spec[0], spec[1], c.state.platform_id])
		if spec[0] == "platform_elevator":
			check(max_y > 4.0, "elevator lifted the rider (max y %.2f)" % max_y)
		c.queue_free()
		chars.erase(c)
		await ticks(2)


## After a roll's travel is done, input takes over at once (the clip's tail no longer locks
## the player out), and the player moves where they steer.
func test_roll_hands_back_control() -> void:
	var c := spawn("speed_start", "res://addons/ultra_controller/profiles/fps.tres", false)
	await ticks(10)
	bot(c).set_steps([{"ticks": 2, "move": FWD, "buttons": InputFrame.B_DODGE}, {"ticks": 200, "move": Vector2(1, 0)}])
	var left_at := -1
	var rolled := false
	for i in 200:
		await ticks(1)
		rolled = rolled or c.state.state == MotorState.Id.ROOT_MOTION
		if rolled and left_at < 0 and c.state.state != MotorState.Id.ROOT_MOTION:
			left_at = i
	var v := Vector2(c.state.vel.x, c.state.vel.z)
	info("roll handed back control after %.2f s; then moving %.2f m/s" % [left_at / 60.0, v.length()])
	check(rolled and left_at > 0 and left_at < 110, "control returns within ~1.8 s of the roll")
	check(v.length() > 0.8 and c.state.state == MotorState.Id.MOVE, "and the player moves on the stick")
