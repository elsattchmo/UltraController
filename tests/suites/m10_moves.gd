extends UltraTestSuite
## Round 10: prone with a gun (aim, fire, reload lying down; directional crawl), dropping what's
## in hand, the run carried over a mantle, climbing clips that stop when you stop, sprinting on
## an angle, and climbing down (drop to hang, vault down, ladders / walls from the top).

const Id := MotorState.Id

var c: UltraCharacter


func before_each() -> void:
	load_playground()
	UltraNet.world_root = self
	UltraNet.spawn_transform = func(_p: NetPlayer) -> Transform3D: return marker("speed_start").global_transform
	UltraNet.character_factory = func(_p: NetPlayer) -> UltraCharacter:
		var ch := UltraCharacter.new()
		ch.profile = (load("res://addons/ultra_controller/profiles/fps.tres") as MovementProfile).duplicate(true)
		ch.body_profile = load("res://assets/characters/mannequin/mannequin_body_profile.tres")
		return ch
	UltraNet.local_input_factory = func(_i: int) -> InputSource: return BotInputSource.new()
	UltraNet.start_offline(1)
	c = UltraNet.local_players[0].character
	(c.input_source as BotInputSource).body = c
	await ticks(3)


func after_each() -> void:
	UltraNet.stop()
	UltraNet.character_factory = Callable()
	UltraNet.local_input_factory = Callable()
	UltraNet.spawn_transform = Callable()
	await super.after_each()


func _bot() -> BotInputSource:
	return c.input_source as BotInputSource


func _slot(item: StringName) -> int:
	for k in c.inventory.size():
		var it := c.inventory.get_slot(k)
		if it and it.def_id == item:
			return k + 1
	return 0


func _place(m: String) -> void:
	var mk := marker(m)
	c.teleport(mk.global_position, mk.global_rotation.y)
	await ticks(3)


## Prone with the rifle: it stays in hand; lying still it fires and reloads; crawling it can't
## fire (the arms pull you along); the prone clips play (directional, turning); a bat is put away.
func test_prone_rifle() -> void:
	UltraItems.give(c, &"rifle")
	UltraItems.give(c, &"ammo_556", 60)
	UltraItems.give(c, &"bat")
	var sl := _slot(&"rifle")
	_bot().set_steps([{"ticks": 60, "slot": sl, "yaw": 0.0}, {"ticks": 90, "slot": sl, "yaw": 0.0, "buttons": InputFrame.B_CRAWL | InputFrame.B_CROUCH}])
	await ticks(150)
	check(c.state.state == Id.CRAWL, "prone (%s)" % Id.keys()[c.state.state])
	check(c.state.held_uid != 0 and c.state.action == UltraActionLayer.Action.READY, "the rifle stays up lying down")
	check(c.anim.prone_armed(), "the prone set plays")
	var mag0 := c.state.mag
	_bot().set_steps([{"ticks": 2, "slot": sl, "yaw": 0.0, "buttons": InputFrame.B_CRAWL | InputFrame.B_CROUCH | InputFrame.B_PRIMARY}, {"ticks": 30, "slot": sl, "yaw": 0.0, "buttons": InputFrame.B_CRAWL | InputFrame.B_CROUCH}])
	await ticks(32)
	check(c.state.mag < mag0, "fires lying down (mag %d -> %d)" % [mag0, c.state.mag])
	_bot().set_steps([{"ticks": 2, "slot": sl, "yaw": 0.0, "buttons": InputFrame.B_CRAWL | InputFrame.B_CROUCH | InputFrame.B_RELOAD}, {"ticks": 30, "slot": sl, "yaw": 0.0, "buttons": InputFrame.B_CRAWL | InputFrame.B_CROUCH}])
	await ticks(10)
	check(c.state.action == UltraActionLayer.Action.RELOADING, "reloads lying down")
	await ticks(300)
	# Crawling forward: the trigger does nothing.
	_bot().set_steps([{"ticks": 30, "slot": sl, "yaw": 0.0, "move": Vector2(0, 1), "buttons": InputFrame.B_CRAWL | InputFrame.B_CROUCH},
		{"ticks": 120, "slot": sl, "yaw": 0.0, "move": Vector2(0, 1), "buttons": InputFrame.B_CRAWL | InputFrame.B_CROUCH | InputFrame.B_PRIMARY}])
	await ticks(30)
	var mag1 := c.state.mag
	# (Only while actually moving: crawl into something and stop, and the gun fires again.)
	var crawl_v := 0.0
	var fired_moving := false
	for k in 40:
		await ticks(1)
		var v := Vector2(c.state.vel.x, c.state.vel.z).length()
		crawl_v = maxf(crawl_v, v)
		if v > 0.3 and c.state.mag != mag1:
			fired_moving = true
	check(crawl_v > 0.3 and not fired_moving, "crawls (%.2f m/s) without firing" % crawl_v)
	await ticks(50)
	# Sideways: the roll; turning in place: the turn clip.
	_bot().set_steps([{"ticks": 60, "slot": sl, "yaw": 0.0, "move": Vector2(1, 0), "buttons": InputFrame.B_CRAWL | InputFrame.B_CROUCH}])
	await ticks(50)
	var dir: Vector2 = c.anim._prone_dir
	check(dir.x > 0.6, "moving right rolls right (%s)" % dir)
	_bot().set_steps([{"ticks": 60, "slot": sl, "yaw": 1.2, "buttons": InputFrame.B_CRAWL | InputFrame.B_CROUCH}])
	await ticks(20)
	check(c.anim._prone_turn > 0.5, "pivoting plays the turn clip (%.2f)" % c.anim._prone_turn)
	# A bat stays in hand lying down, and strikes lying still (only the arms swing).
	_bot().set_steps([{"ticks": 120, "slot": _slot(&"bat"), "buttons": InputFrame.B_CRAWL | InputFrame.B_CROUCH}])
	await ticks(120)
	check(c.state.held_uid != 0 and c.inventory.get_slot(c.inventory.find_uid(c.state.held_uid)).def_id == &"bat", "a bat stays in hand prone")
	var seq := c.state.melee_seq
	_bot().set_steps([{"ticks": 2, "slot": _slot(&"bat"), "buttons": InputFrame.B_CRAWL | InputFrame.B_CROUCH, "tap": InputFrame.B_PRIMARY}, {"ticks": 60, "slot": _slot(&"bat"), "buttons": InputFrame.B_CRAWL | InputFrame.B_CROUCH}])
	var arms := 0.0
	for k in 40:
		await ticks(1)
		arms = maxf(arms, float(c.anim.tree.get("parameters/swing_arms/blend_amount")))
	check(c.state.melee_seq != seq and arms > 0.5, "strikes lying down, arms only (%.2f)" % arms)


## Dropping the gun in hand: it leaves the hand at once and falls at the feet, a physics body.
func test_drop_held_weapon() -> void:
	UltraItems.give(c, &"rifle")
	var sl := _slot(&"rifle")
	_bot().set_steps([{"ticks": 100000, "slot": sl, "yaw": 0.0}])
	await ticks(80)
	check(c.state.held_uid != 0, "rifle in hand")
	(_bot()).want_slot = 0
	UltraNet.request_inventory(c.net_id, "drop", [sl - 1])
	await ticks(2)
	check(c.state.held_uid == 0 and c.inventory.count_of(&"rifle") == 0, "gone from the hand and the inventory")
	var found: RigidBody3D = null
	for n in get_tree().get_nodes_in_group(&"ultra_interactable"):
		var b := n.get_parent() as RigidBody3D
		if b and str(b.get("item_id")) == "rifle":
			found = b
	check(found != null, "a rifle in the world")
	if found == null:
		return
	var y0 := found.global_position.y
	await ticks(90)
	var d := Vector2(found.global_position.x - c.state.pos.x, found.global_position.z - c.state.pos.z).length()
	info("dropped rifle: from y %.2f to %.2f, %.2f m from the feet" % [y0, found.global_position.y, d])
	check(found.global_position.y < y0 - 0.4 and found.global_position.y < c.state.pos.y + 0.3, "it falls to the ground")
	check(d < 1.0, "at the feet (%.2f m)" % d)


## Sprinting at a waist-high wall: over it and running on (it used to stop dead on top).
func test_mantle_keeps_running() -> void:
	await _place("ledge_100")
	var seen := {}
	var after := []
	_bot().set_steps([{"ticks": 600, "yaw": 0.0, "move": Vector2(0, 1), "buttons": InputFrame.B_SPRINT}])
	for k in 240:
		if c.state.pos.z < -27.3 and c.state.is_grounded() and not seen.has(Id.MANTLE):
			_bot().set_steps([{"ticks": 2, "yaw": 0.0, "move": Vector2(0, 1), "buttons": InputFrame.B_SPRINT | InputFrame.B_JUMP}, {"ticks": 600, "yaw": 0.0, "move": Vector2(0, 1), "buttons": InputFrame.B_SPRINT}])
		await ticks(1)
		seen[c.state.state] = true
		if seen.has(Id.MANTLE) and c.state.state != Id.MANTLE:
			after.append(Vector2(c.state.vel.x, c.state.vel.z).length())
			if after.size() >= 6:
				break
	info("mantle at a sprint, speed after: %s" % [after])
	check(seen.has(Id.MANTLE), "mantles")
	check(after.size() > 0 and after[0] > 2.5, "carries on at a run (%s)" % [after])


## Climbing at a rope's end: the hands stop when the body stops.
func test_rope_end_stops_the_clip() -> void:
	await _place("climb_rope")
	var rope: UltraRope = null
	var best := INF
	for rp in UltraRope.all:
		var dd := (rp as UltraRope).anchor().distance_to(c.state.pos)
		if dd < best:
			best = dd
			rope = rp
	check(rope != null, "a rope")
	if rope == null:
		return
	# On the rope, climbing up past its top.
	c.teleport(rope.anchor() + Vector3.DOWN * (0.8 + 1.95), 0.0)
	c.state.trav_from = Vector3.ZERO
	c.state.state = Id.ROPE
	c.state.trav_id = rope.rope_id
	c.state.trav_s = 0.8
	_bot().set_steps([{"ticks": 240, "yaw": 0.0, "pitch": 0.9, "move": Vector2(0, 1)}])
	var climbing := 0.0
	for k in 240:
		await ticks(1)
		if k == 10:
			climbing = c.anim.climb_speed
	info("rope: climb speed while climbing %.2f, at the top %.2f (grip %.2f)" % [climbing, c.anim.climb_speed, c.state.trav_s])
	check(c.state.state == Id.ROPE, "still on the rope")
	check(climbing > 0.5, "climbing plays the climb")
	check(absf(c.anim.climb_speed) < 0.05, "at the top the climb stops")


## Walk the bot `move` (world yaw `yaw`) for up to `n` ticks; returns the states seen in order.
func _walk(move: Vector2, yaw: float, n: int, buttons := 0, until := Callable()) -> Array:
	var seen := []
	_bot().set_steps([{"ticks": n, "yaw": yaw, "move": move, "buttons": buttons}])
	for k in n:
		await ticks(1)
		if seen.is_empty() or seen[-1] != c.state.state:
			seen.append(c.state.state)
		if until.is_valid() and until.call():
			break
	return seen


func _names(ids: Array) -> String:
	return ",".join(ids.map(func(x: int) -> String: return Id.keys()[x]))


## Walking off the cliff top: lowered over the edge into a hang facing the wall; up climbs back
## onto the top; crouch while teetering on a lip also lowers you.
func test_walk_off_lowers_into_a_hang() -> void:
	c.teleport(Vector3(128.5, 8.05, -24.6), PI)          # cliff top, facing +Z (the edge at z -23.5)
	await ticks(5)
	var seen: Array = await _walk(Vector2(0, 1), PI, 240, 0, func() -> bool: return c.state.state == Id.LEDGE_HANG and c.state.state_time > 0.5)
	info("walk off the cliff: %s, at y %.2f (top 8.0), facing %.0f deg" % [_names(seen), c.state.pos.y, rad_to_deg(c.state.body_yaw)])
	check(seen.has(Id.LEDGE_CLIMB) and c.state.state == Id.LEDGE_HANG, "lowers into a hang (%s)" % _names(seen))
	check(absf(c.state.pos.y - (8.0 - UltraTraversal.HANG_DROP)) < 0.05, "hanging from the lip")
	check(absf(angle_difference(c.state.body_yaw, 0.0)) < 0.2, "facing the wall")
	seen = await _walk(Vector2(0, 1), 0.0, 120, 0, func() -> bool: return c.state.is_grounded() and c.state.pos.y > 7.9 and c.state.state in [Id.IDLE, Id.MOVE])
	check(c.state.pos.y > 7.9, "climbs back up (%s)" % _names(seen))
	# Crouch while teetering on the lip.
	_bot().set_steps([{"ticks": 100000, "yaw": PI}])
	c.teleport(Vector3(128.5, 8.05, -23.45), PI)
	await ticks(15)
	var teeter := c.state.teeter
	seen = await _walk(Vector2.ZERO, PI, 120, InputFrame.B_CROUCH, func() -> bool: return c.state.state == Id.LEDGE_HANG)
	info("teetering %.2f s, crouch: %s" % [teeter, _names(seen)])
	check(teeter > 0.0 and c.state.state == Id.LEDGE_HANG, "crouch on the lip lowers into a hang (%s)" % _names(seen))


## Running off a short drop hops down; a careful walk off it just steps down.
func test_run_off_short_drop_hops() -> void:
	c.teleport(Vector3(63.0, 1.05, -31.0), PI)          # the 1 m wall's top, edge at z -28
	await ticks(5)
	var up := [0.0]
	_bot().set_steps([{"ticks": 120, "yaw": PI, "move": Vector2(0, 1), "buttons": InputFrame.B_SPRINT}])
	for k in 120:
		await ticks(1)
		if not c.state.is_grounded():
			up[0] = maxf(up[0], c.state.vel.y)
		if c.state.pos.y < 0.2:
			break
	info("ran off a 1 m drop: up to %.2f m/s up" % up[0])
	check(up[0] > 1.5, "hops off the edge (%.2f m/s up)" % up[0])


## From a ladder's top (on the cliff): walking onto it climbs down; the climbable wall's top:
## walking off it climbs down the wall.
func test_down_ladder_and_wall_from_the_top() -> void:
	c.teleport(Vector3(132.0, 8.05, -24.6), PI)          # behind the CliffLadder's top
	await ticks(5)
	var seen: Array = await _walk(Vector2(0, 1), PI, 200, 0, func() -> bool: return c.state.state == Id.LADDER and c.state.state_time > 0.3)
	info("onto the ladder top: %s, rung height %.2f" % [_names(seen), c.state.trav_s])
	check(c.state.state == Id.LADDER, "climbs onto the ladder (%s)" % _names(seen))
	seen = await _walk(Vector2(0, -1), 0.0, 600, 0, func() -> bool: return c.state.is_grounded() and c.state.pos.y < 0.3)
	check(c.state.pos.y < 0.3, "and down it to the ground (%s)" % _names(seen))
	c.teleport(Vector3(137.0, 6.05, -26.0), PI)          # on top of the climbable wall
	await ticks(5)
	seen = await _walk(Vector2(0, 1), PI, 240, 0, func() -> bool: return c.state.state == Id.WALL_CLIMB and c.state.state_time > 0.3)
	info("off the climbable wall's top: %s" % _names(seen))
	check(c.state.state == Id.WALL_CLIMB, "climbs down onto the wall (%s)" % _names(seen))
	seen = await _walk(Vector2(0, -1), 0.0, 600, 0, func() -> bool: return c.state.is_grounded() and c.state.pos.y < 0.3)
	check(c.state.pos.y < 0.3, "and down the wall to the ground (%s)" % _names(seen))


## Getting up from prone: the prone-to-crouch clip plays, and you can't move meanwhile.
func test_prone_get_up() -> void:
	UltraItems.give(c, &"rifle")
	var sl := _slot(&"rifle")
	_bot().set_steps([{"ticks": 150, "slot": sl, "yaw": 0.0, "buttons": InputFrame.B_CRAWL | InputFrame.B_CROUCH}])
	await ticks(150)
	check(c.state.state == Id.CRAWL, "prone")
	_bot().set_steps([{"ticks": 200, "slot": sl, "yaw": 0.0, "move": Vector2(0, 1)}])
	var played := false
	var held := 0
	for k in 40:
		await ticks(1)
		played = played or c.anim._cur_loco == "prone_up"
		if c.motor.prone_transitioning(c.state) and Vector2(c.state.vel.x, c.state.vel.z).length() < 0.05:
			held += 1
	info("getting up: transition clip %s, held still %d ticks" % [played, held])
	check(played, "the get-up clip plays")
	check(held > 15, "no moving while getting up (%d ticks)" % held)


## One-handed weapons lying down: the pistol fires; the machete stays in hand.
func test_prone_one_handed() -> void:
	UltraItems.give(c, &"pistol")
	UltraItems.give(c, &"machete")
	var sl := _slot(&"pistol")
	_bot().set_steps([{"ticks": 160, "slot": sl, "yaw": 0.0, "buttons": InputFrame.B_CRAWL | InputFrame.B_CROUCH}])
	await ticks(160)
	check(c.state.held_uid != 0 and c.anim.prone_armed(), "the pistol held prone")
	var m0 := c.state.mag
	_bot().set_steps([{"ticks": 2, "slot": sl, "yaw": 0.0, "buttons": InputFrame.B_CRAWL | InputFrame.B_CROUCH | InputFrame.B_PRIMARY}, {"ticks": 30, "slot": sl, "yaw": 0.0, "buttons": InputFrame.B_CRAWL | InputFrame.B_CROUCH}])
	await ticks(32)
	check(c.state.mag < m0, "fires the pistol lying down")
	var sk := c.skeleton
	await sk.skeleton_updated                 # (the final pose, after the hand IK)
	var gap := sk.get_bone_global_pose(sk.find_bone("LeftHand")).origin.distance_to(sk.get_bone_global_pose(sk.find_bone("RightHand")).origin)
	var eq := c.get_node("Equipment") as UltraEquipmentVisual
	info("prone pistol: hands %.2f apart, owns %s, fp_w %.2f, ready %s, action %d" % [gap, eq._owns, eq._fp_w, eq.ready_support(), c.state.action])
	check(gap < 0.2, "both hands on the pistol lying down (%.2f m apart)" % gap)
	_bot().set_steps([{"ticks": 120, "slot": _slot(&"machete"), "buttons": InputFrame.B_CRAWL | InputFrame.B_CROUCH}])
	await ticks(120)
	check(c.state.held_uid != 0 and c.inventory.get_slot(c.inventory.find_uid(c.state.held_uid)).def_id == &"machete", "the machete held prone")


## The free hand with melee weapons: a machete's guard swings against the strike; the bat's
## second hand rides the handle. With the right arm gone the weapon is in the left hand, the
## strike still plays (mirrored) and there's no guard.
func test_melee_free_hand_and_lost_arm() -> void:
	UltraItems.give(c, &"machete")
	UltraItems.give(c, &"bat")
	var eq := c.get_node("Equipment") as UltraEquipmentVisual
	_bot().set_steps([{"ticks": 80, "slot": _slot(&"machete"), "yaw": 0.0}, {"ticks": 2, "slot": _slot(&"machete"), "yaw": 0.0, "tap": InputFrame.B_PRIMARY}, {"ticks": 60, "slot": _slot(&"machete"), "yaw": 0.0}])
	await ticks(82)
	var guard := 0.0
	var counter := 0.0
	for k in 40:
		await ticks(1)
		guard = maxf(guard, eq._free_w)
		counter = maxf(counter, absf(eq._counter))
	info("machete: guard %.2f, counter-swing %.2f m" % [guard, counter])
	check(guard > 0.8 and counter > 0.02, "the free hand guards and swings against the strike")
	_bot().set_steps([{"ticks": 100, "slot": _slot(&"bat"), "yaw": 0.0}])
	await ticks(100)
	var sk := c.skeleton
	await sk.skeleton_updated
	var lh := (sk.get_bone_global_pose(sk.find_bone("LeftHand")).origin)
	var rh := (sk.get_bone_global_pose(sk.find_bone("RightHand")).origin)
	info("bat: hands %.2f m apart" % lh.distance_to(rh))
	check(lh.distance_to(rh) < 0.25, "both hands on the bat (%.2f m apart)" % lh.distance_to(rh))
	# The right arm gone: the weapon in the left hand.
	c.state.severed |= 1 << UltraLimbs.Region.ARM_R
	_bot().set_steps([{"ticks": 100, "slot": _slot(&"machete"), "yaw": 0.0}])
	await ticks(100)
	check(UltraInjury.weapon_hand(c.state) == -1 and c.state.held_uid != 0, "the machete in the left hand")
	var seq := c.state.melee_seq
	_bot().set_steps([{"ticks": 2, "slot": _slot(&"machete"), "yaw": 0.0, "tap": InputFrame.B_PRIMARY}, {"ticks": 60, "slot": _slot(&"machete"), "yaw": 0.0}])
	var sw := 0.0
	for k in 40:
		await ticks(1)
		sw = maxf(sw, c.anim.swing_w)
	check(c.state.melee_seq != seq and sw > 0.5 and c.anim.item_left, "still strikes, left-handed")
	check(eq._free_w < 0.05, "no guard with one arm (%.2f)" % eq._free_w)
