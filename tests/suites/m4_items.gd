extends UltraTestSuite
## Items, inventory, pistol, world interaction and puzzles (in an OFFLINE session, so the
## same server-side code paths run as in multiplayer).

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


func _run(steps: Array) -> void:
	var b := c.input_source as BotInputSource
	b.set_steps(steps)
	var n := 0
	for s: Dictionary in steps:
		n += int(s.get("ticks", 1))
	await ticks(n + 1)


func _goto(m: String) -> void:
	var mk := marker(m)
	c.teleport(mk.global_position, mk.global_rotation.y)
	await ticks(3)


func test_pistol_fire_reload_holster() -> void:
	UltraItems.give(c, &"pistol")
	UltraItems.give(c, &"ammo_9mm", 30)
	await _run([{"ticks": 40, "slot": 1}])
	check(c.state.action == UltraActionLayer.Action.READY and c.held_def() and c.held_def().id == &"pistol", "pistol drawn and ready")
	check(c.state.mag == 12, "full magazine (%d)" % c.state.mag)
	var shots := []
	for i in 12:
		shots.append({"ticks": 2, "slot": 1, "tap": InputFrame.B_PRIMARY})
		shots.append({"ticks": 10, "slot": 1})
	await _run(shots)
	check(c.state.mag == 0, "12 shots empty the magazine (%d left)" % c.state.mag)
	await _run([{"ticks": 2, "slot": 1, "tap": InputFrame.B_PRIMARY}, {"ticks": 4, "slot": 1}])
	check(c.state.action == UltraActionLayer.Action.RELOADING, "dry fire starts an automatic reload")
	await _run([{"ticks": 140, "slot": 1}])
	check(c.state.mag == 12 and c.inventory.count_of(&"ammo_9mm") == 18, "reload: mag 12, reserve 30 -> %d" % c.inventory.count_of(&"ammo_9mm"))
	await _run([{"ticks": 40, "slot": 0}])
	check(c.state.held_uid == 0, "holstered")
	var slot := c.inventory.find_uid(c.inventory.get_slot(0).uid)
	check(int(c.inventory.get_slot(slot).data.get("mag", -1)) == 12, "magazine count stored on the item when holstered")


func test_reload_interrupted_gains_nothing() -> void:
	UltraItems.give(c, &"pistol")
	UltraItems.give(c, &"ammo_9mm", 30)
	await _run([{"ticks": 40, "slot": 1}, {"ticks": 2, "slot": 1, "tap": InputFrame.B_PRIMARY}, {"ticks": 12, "slot": 1}])
	# Knocked down before the magazine goes in: nothing gained.
	await _run([{"ticks": 2, "slot": 1, "tap": InputFrame.B_RELOAD}, {"ticks": 20, "slot": 1}])
	c.knock_down(Vector3(0, 0, 3.0))
	await _run([{"ticks": 60, "slot": 1}])
	# (Going down stows the gun: its magazine count is stored on the item.)
	var it: ItemInstance = null
	for k in c.inventory.size():
		var cand := c.inventory.get_slot(k)
		if cand and cand.def_id == &"pistol":
			it = cand
	var mag := c.state.mag if c.state.held_uid != 0 else (int(it.data.get("mag", -1)) if it else -1)
	check(mag == 11 and c.inventory.count_of(&"ammo_9mm") == 30, "a knock-down interrupts the reload before the mag goes in (mag %d)" % mag)


## Sprinting while reloading: the reload carries on (at a jog) - it used to be cancelled a tick
## after it started when the sprint toggle was on.
func test_reload_keeps_going_when_sprinting() -> void:
	UltraItems.give(c, &"pistol")
	UltraItems.give(c, &"ammo_9mm", 30)
	await _run([{"ticks": 40, "slot": 1}, {"ticks": 2, "slot": 1, "tap": InputFrame.B_PRIMARY}, {"ticks": 12, "slot": 1}])
	(c.input_source as BotInputSource).set_steps([{"ticks": 2, "slot": 1, "tap": InputFrame.B_RELOAD, "move": Vector2(0, 1), "buttons": InputFrame.B_SPRINT}, {"ticks": 200, "slot": 1, "move": Vector2(0, 1), "buttons": InputFrame.B_SPRINT}])
	var top := 0.0
	var reloading_ticks := 0
	for k in 202:
		await ticks(1)
		if c.state.action == UltraActionLayer.Action.RELOADING:
			reloading_ticks += 1
			top = maxf(top, Vector2(c.state.vel.x, c.state.vel.z).length())
	info("reloading for %d ticks while holding sprint, top speed %.2f m/s, mag %d" % [reloading_ticks, top, c.state.mag])
	check(c.state.mag == 12, "the reload finished while running")
	check(top <= c.profile.jog_speed + 0.1, "held to a jog while reloading")


func test_hitscan_drops_target() -> void:
	UltraItems.give(c, &"pistol")
	UltraItems.give(c, &"ammo_9mm", 12)
	await _goto("range")
	var target: Node = map.find_child("Target3", true, false)       # lane 0, 8 m
	check(target != null, "target exists")
	if target == null:
		return
	var to := (target as Node3D).global_position + Vector3.UP * 1.2 - (c.state.pos + Vector3.UP * (c.state.height - 0.16))
	var yaw := atan2(-to.x, -to.z)
	var pitch := atan2(to.y, Vector2(to.x, to.z).length())
	await _run([{"ticks": 40, "slot": 1, "yaw": yaw, "pitch": pitch, "buttons": InputFrame.B_SECONDARY}, {"ticks": 2, "slot": 1, "yaw": yaw, "pitch": pitch, "buttons": InputFrame.B_SECONDARY, "tap": InputFrame.B_PRIMARY}, {"ticks": 6, "slot": 1}])
	check(bool(target.get("down")) and int(target.get("hits")) == 1, "aimed shot knocks the 8 m target down (down=%s hits=%s)" % [target.get("down"), target.get("hits")])


func test_pickup_drop_roundtrip_and_weight() -> void:
	await _goto("range")
	var gun := map.find_child("ShootingRange", true, false).find_children("*", "WorldItem", true, false)
	var pistol: WorldItem = null
	for g: WorldItem in gun:
		if g.item_id == &"pistol":
			pistol = g
	check(pistol != null, "a pistol lies on the bench")
	if pistol == null:
		return
	var oid := (pistol.find_child("NetObject", false, false) as NetObject).net_id
	c.teleport(pistol.global_position + Vector3(0, -1.05, -1.0), 0.0)
	await ticks(3)
	await _run([{"ticks": 2, "target": oid, "tap": InputFrame.B_INTERACT}, {"ticks": 5}])
	check(c.inventory.count_of(&"pistol") == 1, "interact picks the pistol up")
	check(not is_instance_valid(pistol) or pistol.is_queued_for_deletion(), "world item removed")
	c.inventory.get_slot(c.inventory.find_uid(c.inventory.get_slot(0).uid)).data["mag"] = 5
	var before := map.get_parent().find_children("*", "WorldItem", true, false).size()
	UltraNet.request_inventory(c.net_id, "drop", [0])
	await ticks(5)
	var dropped: WorldItem = null
	for w: WorldItem in find_children("*", "WorldItem", true, false):
		if w.item_id == &"pistol" and w.get_parent() == self:
			dropped = w
	check(c.inventory.count_of(&"pistol") == 0 and dropped != null, "dropped back into the world")
	check(dropped != null and int(dropped.item_data.get("mag", -1)) == 5, "dropped pistol keeps its 5 rounds")
	# Weight: 30 kg budget.
	c.inventory.capacity_kg = 1.0
	var left := UltraItems.give(c, &"ammo_9mm", 200)
	check(left > 0 and c.inventory.total_mass() <= 1.0001, "too heavy: %d refused, carrying %.2f kg" % [left, c.inventory.total_mass()])
	var _b := before


func test_locked_vault_and_key() -> void:
	var door := map.find_child("VaultDoor", true, false) as UltraDoor
	var oid := (door.find_child("NetObject", false, false) as NetObject).net_id
	await _goto("vault_door")
	await _run([{"ticks": 2, "target": oid, "tap": InputFrame.B_INTERACT}, {"ticks": 4}])
	check(door.locked and not door.is_open, "no key: still locked")
	UltraItems.give(c, &"key_blue")
	await _run([{"ticks": 2, "target": oid, "tap": InputFrame.B_INTERACT}, {"ticks": 4}])
	check(door.locked, "wrong key refused")
	UltraItems.give(c, &"key_red")
	await _run([{"ticks": 2, "target": oid, "tap": InputFrame.B_INTERACT}, {"ticks": 40}])
	check(not door.locked and door.is_open, "red key unlocks and opens the vault")


func test_lever_sequence() -> void:
	var door := map.find_child("LeverDoor", true, false) as UltraDoor
	var lv := [map.find_child("Lever1", true, false), map.find_child("Lever2", true, false), map.find_child("Lever3", true, false)]
	await _goto("levers")
	(lv[0] as UltraSwitch).interact(c)    # wrong: I first
	await ticks(2)
	check(not door.is_open, "wrong order keeps it shut")
	check(not (lv[0] as UltraSwitch).on, "a wrong lever resets the sequence")
	for i in [1, 2, 0]:                   # II, III, I
		(lv[i] as UltraSwitch).interact(c)
		await ticks(2)
	check(door.is_open and not door.locked, "II, III, I opens the store room")


func test_pressure_plate_and_button() -> void:
	var door := map.find_child("PlateDoor", true, false) as UltraDoor
	var plate := map.find_child("Plate", true, false) as UltraPressurePlate
	var crate := map.find_child("PlateCrateB", true, false) as RigidBody3D
	crate.global_position = plate.global_position + Vector3(0, 0.6, 0)
	crate.linear_velocity = Vector3.ZERO
	await ticks(60)
	check(plate.active and door.is_open, "45 kg on the plate opens the door (load %.0f)" % plate.load_kg)
	crate.global_position += Vector3(4, 0.3, 0)
	await ticks(60)
	check(not plate.active and not door.is_open, "lifting it closes the door again")
	var bdoor := map.find_child("ButtonDoor", true, false) as UltraDoor
	(map.find_child("DoorButton", true, false) as UltraSwitch).interact(c)
	await ticks(10)
	check(bdoor.is_open, "button opens its door")
	await ticks(330)
	check(not bdoor.is_open, "and it closes by itself after 5 s")


func test_ads_aligns_sights() -> void:
	UltraItems.give(c, &"pistol")
	var rig := UltraCameraRig.new()
	add_child(rig)
	rig.attach(c)
	(c.input_source as BotInputSource).set_steps([{"ticks": 40, "slot": 1, "pitch": 0.0}, {"ticks": 400, "slot": 1, "buttons": InputFrame.B_SECONDARY, "pitch": 0.0}])
	await ticks(110)
	await c.skeleton.skeleton_updated
	var eq := c.get_node("Equipment") as UltraEquipmentVisual
	var gun := eq.held_node
	var rear := gun.global_transform * UltraPoseSampler.marker(gun, "M_RearSight").origin
	var front := gun.global_transform * UltraPoseSampler.marker(gun, "M_FrontSight").origin
	var cam := rig.camera.global_transform
	var view := -cam.basis.z
	var a_rear := rad_to_deg(view.angle_to(rear - cam.origin))
	var a_front := rad_to_deg(view.angle_to(front - cam.origin))
	info("ADS: rear sight %.2f°, front sight %.2f° off the view ray (ads %.2f)" % [a_rear, a_front, eq.ads])
	var hb := c.skeleton.find_bone("RightHand")
	var bone_w := c.skeleton.global_transform * c.skeleton.get_bone_global_pose(hb)
	var sk := c.skeleton
	var sh := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("RightUpperArm")).origin
	var el := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("RightLowerArm")).origin
	var goal: Transform3D = (c.anim.hand_ik.goals[1] as HandIKModifier.Goal).target
	info("shoulder->goal %.3f m, arm %.3f + %.3f; goal rel cam %s" % [sh.distance_to(goal.origin), sh.distance_to(el), el.distance_to(bone_w.origin), cam.affine_inverse() * goal.origin])
	info("hand IK error %.4f m; attachment vs bone %.4f m; gun vs bone*grip %.4f m" % [c.anim.hand_ik.last_error[1], eq.hand_attach.global_position.distance_to(bone_w.origin), gun.global_position.distance_to((bone_w * eq.held_def.grip_offset).origin)])
	check(a_rear < 0.5 and a_front < 0.5, "sights on the view ray")
	rig.queue_free()
