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


## Walking about on a platform keeps riding it (it used to register only while standing still:
## a moving rider left no floor contact, wasn't carried, and the platform slid away under it).
func test_walk_on_moving_platform() -> void:
	var c := spawn("platform_rotate", "res://addons/ultra_controller/profiles/fps.tres", false)
	await ticks(5)
	bot(c).set_steps([{"ticks": 1000, "move": Vector2(0, 0.3), "yaw": 0.0}])
	var off := 0
	for i in 150:
		await ticks(1)
		if c.state.platform_id == 0:
			off += 1
	info("walking on the rotating platform: %d of 150 ticks not riding it" % off)
	check(off < 5, "a walking rider is carried (%d ticks off)" % off)
	c.queue_free()
	chars.erase(c)


## Climbing onto a moving platform: the mantle's path rides the platform and ends on it.
func test_climb_onto_moving_platform() -> void:
	var c := spawn("speed_start", "res://addons/ultra_controller/profiles/fps.tres", false)
	await ticks(3)
	var plat: TickPlatform = null
	for tp: TickPlatform in TickPlatform.all:
		if tp.name == "Linear":
			plat = tp
	for i in 600:
		await ticks(1)
		if (plat.pose_at(TickPlatform.current_tick).origin - plat.pose_at(TickPlatform.current_tick - 1).origin).length() > 0.03:
			break
	c.teleport(Vector3(plat.global_position.x + 2.7, 0.0, plat.global_position.z), PI * 0.5)
	bot(c).set_steps([{"ticks": 30, "move": FWD, "yaw": PI * 0.5, "buttons": InputFrame.B_JUMP}, {"ticks": 150, "yaw": PI * 0.5}])
	var mantled := false
	for i in 180:
		await ticks(1)
		mantled = mantled or c.state.state == MotorState.Id.MANTLE
	var lp := plat.global_transform.affine_inverse() * c.state.pos
	info("climbed onto the moving platform: local %s, riding %d" % [lp.snappedf(0.01), c.state.platform_id])
	check(mantled and c.state.platform_id == plat.platform_id and c.state.is_grounded(), "mantled onto the platform and rides it")
	check(absf(lp.x) < 2.0 and absf(lp.z) < 2.0, "standing on top, not left behind")
	c.queue_free()
	chars.erase(c)


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


## Balance on edges (the 1 m ledge block, top x 61..65 at z -32..-28): perched on the lip with
## nothing under the middle you teeter and topple off; walking off on purpose just falls;
## stepping back recovers.
func _perch(c: UltraCharacter, yaw: float) -> void:
	c.teleport(Vector3(65.17, 1.02, -30.0), yaw)
	await ticks(1)


func test_edge_balance() -> void:
	var c := spawn("ledge_100", "res://addons/ultra_controller/profiles/fps.tres", false)
	await ticks(3)
	# 1. Standing still on the lip.
	await _perch(c, 0.0)
	var states := {}
	var toppled_at := -1
	bot(c).set_steps([{"ticks": 240, "yaw": 0.0}])
	for k in 240:
		await ticks(1)
		states[MotorState.Id.keys()[c.state.state]] = true
		if toppled_at < 0 and c.state.state == MotorState.Id.RAGDOLL:
			toppled_at = k
	info("perched still: %s; toppled after %.2f s, ends at y %.2f" % [states.keys(), toppled_at / 60.0, c.state.pos.y])
	check(toppled_at > 20 and toppled_at < 90, "standing on the lip, you lose your balance (%.2f s)" % (toppled_at / 60.0))
	check(c.state.pos.y < 0.3, "and end up on the ground below")
	await hold(c, 300, Vector2.ZERO, 0, 0.0)
	# 2. Walking off on purpose: a normal fall, no ragdoll.
	c.teleport(Vector3(63.0, 1.02, -30.0), -PI * 0.5)        # facing +X
	await ticks(5)
	states.clear()
	bot(c).set_steps([{"ticks": 150, "move": Vector2(0, 1), "yaw": -PI * 0.5}])
	for k in 150:
		await ticks(1)
		states[MotorState.Id.keys()[c.state.state]] = true
	info("walk off: %s, pos %s hp %.0f legs %s" % [states.keys(), c.state.pos, c.state.hp, c.state.limb_hp])
	check(not states.has("RAGDOLL") and states.has("FALL"), "walking off the edge just drops you down (no stumble)")
	# 3. Perched, then stepping back onto the block: recovers.
	await _perch(c, 0.0)
	states.clear()
	bot(c).set_steps([{"ticks": 10, "yaw": 0.0}, {"ticks": 60, "move": Vector2(-1, 0), "yaw": 0.0}])
	for k in 70:
		await ticks(1)
		states[MotorState.Id.keys()[c.state.state]] = true
	info("step back: %s, pos %s" % [states.keys(), c.state.pos])
	check(not states.has("RAGDOLL") and c.state.pos.y > 0.9 and c.state.pos.x < 65.0, "stepping back from the edge keeps you on top")


## A drop you won't land on your feet: the body goes limp in the air (before touching down)
## and keeps its speed, tumbling on along the ground instead of stopping dead.
func test_fall_ragdolls_mid_air_and_tumbles_on() -> void:
	var c := spawn("drop_9", "res://addons/ultra_controller/profiles/fps.tres", false)
	await ticks(3)
	bot(c).set_steps([{"ticks": 60, "move": FWD, "buttons": InputFrame.B_SPRINT}, {"ticks": 400}])
	var limp_y := INF
	var touch := Vector3.INF
	var rest := Vector3.ZERO
	for i in 460:
		await ticks(1)
		if limp_y == INF and c.state.state == MotorState.Id.RAGDOLL:
			limp_y = c.state.pos.y
		if limp_y != INF and touch == Vector3.INF and c.state.is_grounded():
			touch = c.state.pos
		if c.state.state == MotorState.Id.GET_UP and rest == Vector3.ZERO:
			rest = c.state.pos
	var slide := Vector2(rest.x - touch.x, rest.z - touch.z).length() if touch != Vector3.INF else 0.0
	info("went limp at y %.2f (ground 0); tumbled %.2f m after touching down" % [limp_y, slide])
	check(limp_y > 6.0 and limp_y < 9.5, "goes limp early in the fall, as soon as the hard landing is certain (y %.2f)" % limp_y)
	check(slide > 1.0, "keeps its momentum along the ground (no dead stop)")


## A hard landing you can take while running: on your feet, no roll, and you keep moving.
func test_hard_landing_at_a_run_keeps_going() -> void:
	var c := spawn("drop_4", "res://addons/ultra_controller/profiles/fps.tres", false)
	await ticks(3)
	bot(c).set_steps([{"ticks": 300, "move": FWD, "buttons": InputFrame.B_SPRINT}])
	var states := {}
	var min_speed_after := INF
	var landed_at := -1
	for i in 300:
		await ticks(1)
		states[MotorState.Id.keys()[c.state.state]] = true
		if landed_at < 0 and c.state.is_grounded() and states.has("FALL"):
			landed_at = i
		if landed_at >= 0 and i > landed_at + 2 and i < landed_at + 60:
			min_speed_after = minf(min_speed_after, Vector2(c.state.vel.x, c.state.vel.z).length())
	info("4 m drop at a sprint: %s; slowest after landing %.2f m/s" % [states.keys(), min_speed_after])
	check(landed_at >= 0 and not states.has("ROOT_MOTION") and not states.has("RAGDOLL"), "lands on its feet - no roll, no fall over")
	check(min_speed_after > 1.0, "and keeps moving")


## Medium drops land on the feet; jumping across a gap from one block to a lower one (over a
## 9 m pit) lands on the block - neither is a ragdoll.
func test_no_ragdoll_for_medium_drops_and_gap_jumps() -> void:
	var c := spawn("drop_6", "res://addons/ultra_controller/profiles/fps.tres", false)
	await ticks(3)
	bot(c).set_steps([{"ticks": 200, "move": FWD, "buttons": InputFrame.B_SPRINT}])
	var states := {}
	for i in 200:
		await ticks(1)
		states[MotorState.Id.keys()[c.state.state]] = true
	info("6 m drop at a sprint: %s (impact %.1f m/s)" % [states.keys(), c.state.land_impact])
	check(not states.has("RAGDOLL") and states.has("FALL"), "6 m drop: lands on its feet")
	c.queue_free()
	chars.erase(c)
	# Gap jump: from the 9 m block across the 2 m gap onto the 6 m block.
	var j := spawn("drop_9", "res://addons/ultra_controller/profiles/fps.tres", false)
	await ticks(3)
	var west := deg_to_rad(90.0)
	bot(j).live_yaw = west
	bot(j).set_steps([{"ticks": 20, "yaw": west}, {"ticks": int(GAP_RUN_TICKS), "move": FWD, "buttons": InputFrame.B_SPRINT, "yaw": west},
		{"ticks": 2, "move": FWD, "buttons": InputFrame.B_SPRINT, "tap": InputFrame.B_JUMP, "yaw": west}, {"ticks": 60, "yaw": west}])
	states = {}
	for i in 140:
		await ticks(1)
		states[MotorState.Id.keys()[j.state.state]] = true
	info("gap jump 9 m -> 6 m block: %s, ended at y %.2f x %.2f" % [states.keys(), j.state.pos.y, j.state.pos.x])
	check(j.state.pos.y > 5.5 and not states.has("RAGDOLL"), "landed on the lower block, no ragdoll")
	j.queue_free()
	chars.erase(j)


const GAP_RUN_TICKS := 16
