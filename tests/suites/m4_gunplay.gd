extends UltraTestSuite
## Gunplay: free aim (the gun's own direction - inertia, sway, recoil - in MotorState), shots
## along the gun, firing on the move, the two-handed rifle (auto fire, reload, ADS, slung on
## the back) and the HUD's gun dot. OFFLINE session, so the server code paths run.

var c: UltraCharacter
const DT := 1.0 / 60.0


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


func _run(steps: Array) -> void:
	_bot().set_steps(steps)
	var n := 0
	for s: Dictionary in steps:
		n += int(s.get("ticks", 1))
	await ticks(n + 1)


func _draw(item: StringName, extra := {}) -> void:
	UltraItems.give(c, item)
	var def := ItemDB.get_def(item)
	if def and def.stat("ammo", "") != "":
		UltraItems.give(c, StringName(def.stat("ammo", "")), 60)
	await _run([{"ticks": 60, "slot": c.inventory.find_uid(_uid_of(item)) + 1, "yaw": 0.0, "pitch": 0.0}.merged(extra)])


func _uid_of(item: StringName) -> int:
	for i in c.inventory.size():
		var it := c.inventory.get_slot(i)
		if it and it.def_id == item:
			return it.uid
	return 0


func _slot(item: StringName) -> int:
	return c.inventory.find_uid(_uid_of(item)) + 1


func _aim_dir(i: InputFrame) -> Vector3:
	return UltraActionLayer.gun_dir(i.yaw, i.pitch, Vector2.ZERO)


## Turning drags the gun behind the view (opposite way to the turn), within the free-aim zone,
## and it swings back onto the aim once the turn stops.
func test_turning_lags_the_gun() -> void:
	await _draw(&"pistol")
	var def := ItemDB.get_def(&"pistol")
	check(c.state.action == UltraActionLayer.Action.READY, "pistol ready")
	check(c.state.sway.length() < deg_to_rad(0.5), "standing still the gun is on the aim (%.2f deg)" % rad_to_deg(c.state.sway.length()))
	var sl := _slot(&"pistol")
	await _run([{"ticks": 20, "slot": sl, "yaw_rate": deg_to_rad(120.0)}])
	var lag := rad_to_deg(c.state.sway.x)
	info("turning left at 120 deg/s: gun %.2f deg behind (zone %.1f)" % [lag, def.free_aim_deg])
	check(lag < -1.5, "a left turn leaves the gun to the right of the aim (%.2f deg)" % lag)
	check(lag > -def.free_aim_deg - 0.5, "but no further than the free-aim zone")
	await _run([{"ticks": 60, "slot": sl}])
	check(absf(rad_to_deg(c.state.sway.x)) < 0.4, "a second after the turn the gun is back on the aim (%.2f deg)" % rad_to_deg(c.state.sway.x))
	# The heavier rifle lags more for the same turn.
	await _draw(&"rifle")
	var sr := _slot(&"rifle")
	await _run([{"ticks": 60, "slot": sr}])
	await _run([{"ticks": 8, "slot": sr, "yaw_rate": deg_to_rad(60.0)}])
	var rlag := rad_to_deg(c.state.sway.x)
	await _run([{"ticks": 60, "slot": sr, "yaw_rate": 0.0}])
	await _run([{"ticks": 60, "slot": sl}])
	await _run([{"ticks": 8, "slot": sl, "yaw_rate": deg_to_rad(60.0)}])
	var plag := rad_to_deg(c.state.sway.x)
	info("8 ticks into a 60 deg/s turn: rifle %.2f deg, pistol %.2f deg" % [rlag, plag])
	check(rlag < plag - 0.2, "the rifle has more inertia than the pistol")


## Same inputs -> same gun offsets, and a rollback + replay (what the client does on every
## correction) lands on exactly the same bits.
func test_free_aim_is_deterministic() -> void:
	await _draw(&"rifle")
	var sl := _slot(&"rifle")
	var steps := [
		{"ticks": 15, "slot": sl, "yaw_rate": 2.5, "move": Vector2(0, 1)},
		{"ticks": 20, "slot": sl, "yaw_rate": -1.5, "pitch": 0.2, "move": Vector2(0.7, 0.7), "buttons": InputFrame.B_SPRINT},
		{"ticks": 10, "slot": sl, "buttons": InputFrame.B_PRIMARY},
		{"ticks": 10, "slot": sl, "buttons": InputFrame.B_SECONDARY | InputFrame.B_PRIMARY, "yaw_rate": 0.8},
		{"ticks": 10, "slot": sl, "buttons": InputFrame.B_JUMP, "move": Vector2(0, 1)},
	]
	# Record every frame the character simulates, and the state just before the first one.
	var inner := BotInputSource.new()
	inner.want_slot = sl
	inner.set_steps(steps)
	var inputs: Array[InputFrame] = []
	var trace: Array[Vector2] = []
	var start_box: Array[MotorState] = []
	_bot().driver = func(tick: int, _src: BotInputSource) -> InputFrame:
		if start_box.is_empty():
			start_box.append(c.state.copy())
		elif not inputs.is_empty():
			trace.append(c.state.sway)
		var f := inner.sample(tick)
		inputs.append(f.copy())
		return f
	var n := 0
	for s: Dictionary in steps:
		n += int(s.get("ticks", 1))
	await ticks(n)
	var end := c.state.copy()
	_bot().driver = Callable()
	inner.free()
	var start := start_box[0]
	var moved := 0.0
	for v in trace:
		moved = maxf(moved, v.length())
	info("%d ticks, largest gun offset %.2f deg, shots %d" % [inputs.size(), rad_to_deg(moved), end.fire_seq - start.fire_seq])
	check(moved > deg_to_rad(1.0), "the gun really moved about")
	# The offsets survive the snapshot codec exactly (what a client gets from the server).
	var q := end.copy().quantize()
	check(q.sway == end.sway and q.sway_v == end.sway_v and q.sway_phase == end.sway_phase and q.aim_prev_yaw == end.aim_prev_yaw, "sway fields are already quantized")
	# Roll back to the start and replay the recorded inputs (no presentation events), the way
	# a client re-predicts after a correction.
	c.state.copy_from(start)
	var replayed := 0
	for f in inputs:
		c.simulate(f, DT, true)
		replayed += 1
	var d := (c.state.sway - end.sway).length() + (c.state.sway_v - end.sway_v).length()
	info("replayed %d ticks: sway diff %.6f, pos diff %.4f" % [replayed, d, c.state.pos.distance_to(end.pos)])
	check(d == 0.0 and c.state.sway_phase == end.sway_phase, "replay gives exactly the same gun offsets")


## A shot goes along the GUN: fire mid-turn and the round lands where the dot is (the gun,
## lagging the turn), not at the crosshair.
func test_shot_goes_where_the_gun_points() -> void:
	await _draw(&"pistol")
	var sl := _slot(&"pistol")
	var shots: Array[Dictionary] = []
	# (In the event, state.aim_prev_* already holds this tick's aim and state.sway the offset
	# the shot used; the recoil only changed the spring's velocity.)
	c.item_event.connect(func(kind: StringName, d: Dictionary) -> void:
		if kind == &"fire":
			var f := InputFrame.new()
			f.yaw = c.state.aim_prev_yaw
			f.pitch = c.state.aim_prev_pitch
			shots.append({"dir": d.dir, "sway": c.state.sway, "input": f}))
	# The shot is resolved after this tick's free-aim step: record the gun direction then.
	await _run([{"ticks": 14, "slot": sl, "yaw_rate": deg_to_rad(150.0)}, {"ticks": 2, "slot": sl, "yaw_rate": deg_to_rad(150.0), "tap": InputFrame.B_PRIMARY}, {"ticks": 4, "slot": sl}])
	check(shots.size() == 1, "one shot")
	if shots.is_empty():
		return
	var s: Dictionary = shots[0]
	var i: InputFrame = s.input
	var to_aim := rad_to_deg((s.dir as Vector3).angle_to(_aim_dir(i)))
	var gun := UltraActionLayer.gun_dir(i.yaw, i.pitch, s.sway)
	var to_gun := rad_to_deg((s.dir as Vector3).angle_to(gun))
	var spread := float(ItemDB.get_def(&"pistol").stat("spread_deg", 0.8))
	info("shot vs gun %.2f deg, vs aim %.2f deg (gun offset %.2f deg, spread %.2f)" % [to_gun, to_aim, rad_to_deg((s.sway as Vector2).length()), spread])
	check(to_gun <= spread + 0.01, "the shot leaves along the gun (within the spread)")
	check(to_aim > to_gun + 1.0, "and not along the view while the gun lags")


## Sprinting doesn't block the trigger: the shot simply goes where the lowered gun points.
func test_fire_while_sprinting() -> void:
	await _draw(&"pistol")
	var sl := _slot(&"pistol")
	var dirs: Array[Vector3] = []
	c.item_event.connect(func(kind: StringName, d: Dictionary) -> void:
		if kind == &"fire":
			dirs.append(d.dir))
	await _run([{"ticks": 50, "slot": sl, "move": Vector2(0, 1), "buttons": InputFrame.B_SPRINT}])
	var sprinting := c.state.has(MotorState.F_SPRINTING) and hspeed(c) > c.profile.jog_speed * 0.9
	check(sprinting, "sprinting (%.1f m/s)" % hspeed(c))
	var mag0 := c.state.mag
	var low := rad_to_deg(c.state.sway.y)
	await _run([{"ticks": 2, "slot": sl, "move": Vector2(0, 1), "buttons": InputFrame.B_SPRINT, "tap": InputFrame.B_PRIMARY}, {"ticks": 3, "slot": sl, "move": Vector2(0, 1), "buttons": InputFrame.B_SPRINT}])
	check(c.state.mag == mag0 - 1 and dirs.size() == 1, "fired while sprinting (mag %d -> %d)" % [mag0, c.state.mag])
	if dirs.size() == 1:
		var pitch := rad_to_deg(asin(dirs[0].y))
		info("sprinting: gun %.1f deg below the aim, shot pitch %.1f deg" % [low, pitch])
		check(low < -10.0 and pitch < -8.0, "the gun is carried low and the shot goes low")


func test_rifle_auto_fire_reload_and_sling() -> void:
	await _draw(&"rifle")
	var def := ItemDB.get_def(&"rifle")
	check(def != null and def.two_handed and def.fire_mode == ItemDefinition.FireMode.AUTO, "rifle: two-handed, automatic")
	check(c.state.action == UltraActionLayer.Action.READY and c.held_def() == def, "rifle drawn and ready")
	check(c.state.mag == 30, "30-round magazine (%d)" % c.state.mag)
	var sl := _slot(&"rifle")
	var fired := [0]
	c.item_event.connect(func(kind: StringName, _d: Dictionary) -> void:
		if kind == &"fire":
			fired[0] += 1)
	# Hold the trigger for one second: ~650 rounds a minute.
	await _run([{"ticks": 60, "slot": sl, "buttons": InputFrame.B_PRIMARY}, {"ticks": 5, "slot": sl}])
	var want := int(ceil(1.0 / float(def.stat("fire_interval", 0.1))))
	info("1 s of automatic fire: %d shots (expected ~%d), mag %d" % [fired[0], want, c.state.mag])
	check(absi(fired[0] - want) <= 1 and c.state.mag == 30 - fired[0], "holding the trigger fires automatically at the rifle's rate")
	var reserve := c.inventory.count_of(&"ammo_556")
	await _run([{"ticks": 2, "slot": sl, "tap": InputFrame.B_RELOAD}, {"ticks": int(float(def.stat("reload_time", 2.6)) * 60.0) + 10, "slot": sl}])
	check(c.state.mag == 30 and c.state.action == UltraActionLayer.Action.READY, "reloaded to 30")
	check(c.inventory.count_of(&"ammo_556") == reserve - fired[0], "reserve paid for it (%d -> %d)" % [reserve, c.inventory.count_of(&"ammo_556")])
	# Put it away: slung on the back.
	await _run([{"ticks": 60, "slot": 0}])
	var eq := c.get_node("Equipment") as UltraEquipmentVisual
	await ticks(2)
	check(c.state.held_uid == 0, "holstered")
	check(eq.back_node != null and eq.back_node.get_parent() is BoneAttachment3D and (eq.back_node.get_parent() as BoneAttachment3D).bone_name == "UpperChest", "slung on the back")
	if eq.back_node:
		var local := c.visual_root.global_transform.affine_inverse() * eq.back_node.global_transform * Vector3(0, 0.03, -0.17)
		info("slung rifle centre in body space %s" % local)
		check(local.z > 0.05 and local.y > 0.9, "behind the shoulders (body faces -Z)")
	# The pistol drawn: rifle stays on the back, pistol leaves the hip.
	UltraItems.give(c, &"pistol")
	await _run([{"ticks": 40, "slot": _slot(&"pistol")}])
	await ticks(2)
	check(eq.back_node != null and eq.holster_node == null, "pistol in hand, rifle on the back")


## In first person aiming down sights, the rear and front sights line up on the view ray and
## on the gun's direction (the dot): checked for the pistol and the rifle.
func test_ads_sights_on_the_gun_ray() -> void:
	for item: StringName in [&"pistol", &"rifle"]:
		UltraItems.give(c, item)
	var rig := UltraCameraRig.new()
	add_child(rig)
	rig.attach(c)
	for item: StringName in [&"pistol", &"rifle"]:
		var sl := _slot(item)
		_bot().set_steps([{"ticks": 60, "slot": sl, "pitch": 0.0}, {"ticks": 400, "slot": sl, "buttons": InputFrame.B_SECONDARY, "pitch": 0.0}])
		await ticks(140)
		await c.skeleton.skeleton_updated
		var eq := c.get_node("Equipment") as UltraEquipmentVisual
		var gun := eq.held_node
		var rear := gun.global_transform * UltraPoseSampler.marker(gun, "M_RearSight").origin
		var front := gun.global_transform * UltraPoseSampler.marker(gun, "M_FrontSight").origin
		var cam := rig.camera.global_transform
		var view := -cam.basis.z
		var ray := eq.gun_ray()
		var gdir: Vector3 = ray.dir
		var a_rear := rad_to_deg(view.angle_to(rear - cam.origin))
		var a_front := rad_to_deg(view.angle_to(front - cam.origin))
		var line := (front - rear).normalized()
		var a_gun := rad_to_deg(line.angle_to(gdir))
		info("%s ADS: rear %.2f deg, front %.2f deg off the view ray; sight line vs gun %.2f deg; rear sight %.3f m from the eye (ads %.2f)" % [item, a_rear, a_front, a_gun, rear.distance_to(cam.origin), eq.ads])
		check(eq.held_def.id == item and eq.ads > 0.99, "%s up and aiming" % item)
		check(a_rear < 0.5 and a_front < 0.5, "%s: sights on the view ray" % item)
		check(a_gun < 0.3, "%s: the sight line is the gun's direction (the dot sits on the sights)" % item)
		if item == &"rifle":
			var lh := c.skeleton.global_transform * c.skeleton.get_bone_global_pose(c.skeleton.find_bone("LeftHand")).origin
			# The wrist (hand bone) in the gun's frame: under the handguard, along its length.
			var p := gun.global_transform.affine_inverse() * lh
			var bore := UltraPoseSampler.marker(gun, "M_Muzzle").origin.y
			var off_axis := Vector2(p.x, p.y - bore).length()
			info("rifle left wrist in the gun frame %s (%.3f m off the bore axis); left IK error %.4f" % [p.snappedf(0.001), off_axis, c.anim.hand_ik.last_error[0]])
			check(p.z < -0.12 and p.z > -0.5 and off_axis < 0.11 and c.anim.hand_ik.last_error[0] < 0.01, "left hand on the handguard")
	rig.queue_free()


## The HUD's gun dot: where the gun points, projected through the player's camera. Still: at
## the crosshair. Mid-turn: off to the side the gun lags to.
func test_hud_gun_dot() -> void:
	UltraItems.give(c, &"pistol")
	var rig := UltraCameraRig.new()
	add_child(rig)
	rig.attach(c)
	rig.camera.current = true
	var hud := UltraHUD.new()
	hud.character = c
	add_child(hud)
	var sl := _slot(&"pistol")
	await _run([{"ticks": 70, "slot": sl, "pitch": 0.0, "yaw": 0.0}])
	await get_tree().process_frame
	# (Read right after process_frame: the HUD and the camera both still hold last frame's
	# values, so they are measured against each other. Angles, not pixels: the headless window
	# can be any size.)
	var cam := rig.camera
	var fwd := -cam.global_basis.z
	var dot_ray := cam.project_ray_normal(hud.dot_pos)
	var still := rad_to_deg(dot_ray.angle_to(fwd))
	info("still: dot %.2f deg from the crosshair (visible %s, pane %s)" % [still, hud.dot_visible, get_viewport().get_visible_rect().size])
	check(hud.dot_visible and still < 0.4, "standing still the dot sits on the crosshair")
	_bot().set_steps([{"ticks": 1000, "slot": sl, "yaw_rate": deg_to_rad(120.0)}])
	await ticks(20)
	await get_tree().process_frame
	fwd = -cam.global_basis.z
	dot_ray = cam.project_ray_normal(hud.dot_pos)
	var off := rad_to_deg(dot_ray.angle_to(fwd))
	var side := dot_ray.dot(cam.global_basis.x)
	var gun := rad_to_deg(c.state.sway.length())
	info("turning left: dot %.2f deg from the crosshair, to the %s (gun offset %.2f deg)" % [off, "right" if side > 0.0 else "left", gun])
	check(side > 0.0 and off > 1.5, "turning left the dot trails to the right")
	check(absf(off - gun) < 1.0, "by the gun's offset (the dot is the projected gun ray)")
	hud.queue_free()
	rig.queue_free()


## Third person: the rifle in the hands (aiming clip, bladed stance) points where the gun dot
## does - the clip's own barrel offset is taken out and the free-aim offset added.
func test_tp_rifle_points_along_the_gun() -> void:
	UltraItems.give(c, &"rifle")
	var sl := _slot(&"rifle")
	_bot().view_tp = true
	_bot().set_steps([{"ticks": 1000, "slot": sl, "pitch": 0.0, "buttons": InputFrame.B_SECONDARY}])
	await ticks(100)
	await c.skeleton.skeleton_updated
	var eq := c.get_node("Equipment") as UltraEquipmentVisual
	var gun := eq.held_node
	var barrel := -gun.global_basis.z.normalized()
	var want: Vector3 = eq.gun_ray().dir
	var yaw_err := rad_to_deg(Vector2(want.x, want.z).angle_to(Vector2(barrel.x, barrel.z)))
	var pitch_err := rad_to_deg(asin(barrel.y) - asin(want.y))
	info("TP rifle aiming: barrel vs gun direction yaw %.1f deg, pitch %.1f deg" % [yaw_err, pitch_err])
	check(absf(yaw_err) < 6.0 and absf(pitch_err) < 6.0, "the rifle points along the gun direction")
