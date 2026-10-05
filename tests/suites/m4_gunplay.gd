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
	# Shouldered: the stock at the right shoulder, the chest bladed (not side-on), both hands on
	# the gun, the cheek down toward the sights.
	var sk := c.skeleton
	var g := func(n: String) -> Vector3: return sk.global_transform * sk.get_bone_global_pose(sk.find_bone(n)).origin
	var stock := gun.global_transform * UltraPoseSampler.marker(gun, "M_Stock").origin
	var ra: Vector3 = g.call("RightUpperArm")
	var la: Vector3 = g.call("LeftUpperArm")
	var chest_fwd := Vector3.UP.cross(ra - la).normalized()
	var blade := rad_to_deg(Vector2(want.x, want.z).angle_to(Vector2(chest_fwd.x, chest_fwd.z)))
	var head: Vector3 = g.call("Head")
	var rear := gun.global_transform * UltraPoseSampler.marker(gun, "M_RearSight").origin
	var errs: Array = c.anim.hand_ik.last_error
	info("TP shouldered: stock %.3f m from the right shoulder joint, chest %.0f deg off the gun, head %.3f m above the sight line, IK err L %.3f R %.3f" % [stock.distance_to(ra), blade, head.y - rear.y, errs[0], errs[1]])
	check(stock.distance_to(ra) < 0.13, "stock at the shoulder")
	check(absf(blade) > 15.0 and absf(blade) < 55.0, "bladed stance, not square or side-on (%.0f deg)" % blade)
	check(errs[0] < 0.02 and errs[1] < 0.02, "hands on the gun")



## Holding the rifle (low ready and aiming), standing and walking: the body stands in the
## rifle's own bladed stance - legs and torso agree - so it doesn't lean over to one side.
func test_rifle_stance_upright() -> void:
	UltraItems.give(c, &"rifle")
	var sl := _slot(&"rifle")
	_bot().view_tp = true
	var sk := c.skeleton
	var res := []
	for spec: Array in [["low ready", 0, Vector2.ZERO], ["aiming", InputFrame.B_SECONDARY, Vector2.ZERO], ["aiming, walking", InputFrame.B_SECONDARY, Vector2(0, 1)]]:
		_bot().set_steps([{"ticks": 1000, "slot": sl, "pitch": 0.0, "buttons": spec[1], "move": spec[2]}])
		await ticks(90)
		var out := [0.0, 0.0]
		var grab := func() -> void:
			var l := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("LeftUpperLeg")).origin
			var r := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("RightUpperLeg")).origin
			var right := Vector3(r.x - l.x, 0, r.z - l.z).normalized()
			var hips := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("Hips")).origin
			var head := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("Head")).origin
			var d := head - hips
			out[0] = maxf(out[0], absf(rad_to_deg(atan2(d.dot(right), d.y))))
			out[1] = c.anim.modifier.item_hips_yaw
		sk.skeleton_updated.connect(grab)
		for i in 30:
			await get_tree().process_frame
		sk.skeleton_updated.disconnect(grab)
		res.append("%s: lean %.0f deg" % [spec[0], out[0]])
		check(out[0] < 14.0, "%s: no big sideways lean (%.0f deg)" % [spec[0], out[0]])
	info("rifle stance: " + ", ".join(res) + "; stance weight %.2f" % c.anim._stance_w)


## First person with the rifle (hip, aiming, looking down): the gun is placed from the camera,
## so the body comes to it - stock in the shoulder pocket, hands on the gun, the left arm
## reaching forward under the gun (not across the eye), the torso not folded over.
func test_fp_rifle_shouldered() -> void:
	UltraItems.give(c, &"rifle")
	var rig := UltraCameraRig.new()
	add_child(rig)
	rig.attach(c)
	var sl := _slot(&"rifle")
	var sk := c.skeleton
	var res := []
	for spec: Array in [["hip", 0, 0.0], ["ADS", InputFrame.B_SECONDARY, 0.0], ["ADS down 40", InputFrame.B_SECONDARY, -0.7], ["hip down 60", 0, -1.05], ["ADS up 40", InputFrame.B_SECONDARY, 0.7]]:
		_bot().set_steps([{"ticks": 1000, "slot": sl, "buttons": spec[1], "pitch": spec[2]}])
		await ticks(100)
		await sk.skeleton_updated
		var wp := c.anim.weapon_pose
		var cam := rig.camera.global_transform
		var g := func(n: String) -> Vector3: return sk.global_transform * sk.get_bone_global_pose(sk.find_bone(n)).origin
		var ua: Vector3 = g.call("LeftUpperArm")
		var la: Vector3 = g.call("LeftLowerArm")
		var lh: Vector3 = g.call("LeftHand")
		var arm_d := minf(Geometry3D.get_closest_point_to_segment(cam.origin, ua, la).distance_to(cam.origin), Geometry3D.get_closest_point_to_segment(cam.origin, la, lh).distance_to(cam.origin))
		# How high the left elbow comes into the view: angle above (+) / below (-) the view ray.
		var el: Vector3 = la - cam.origin
		var el_up := rad_to_deg(asin(clampf(el.normalized().dot(cam.basis.y), -1.0, 1.0)))
		var hips: Vector3 = g.call("Hips")
		var neck: Vector3 = g.call("Neck")
		var bend := rad_to_deg((neck - hips).angle_to(Vector3.UP))
		var errs: Array = c.anim.hand_ik.last_error
		res.append("%s: gap %.3f m, left arm %.2f m from the eye (elbow %+.0f deg), torso bend %.0f deg, IK err L %.3f R %.3f, active %s" % [spec[0], wp.last_gap, arm_d, el_up, bend, errs[0], errs[1], wp.shouldered])
		check(wp.shouldered and wp.last_gap < 0.06, "%s: stock in the shoulder (%.3f m)" % [spec[0], wp.last_gap])
		check(arm_d > 0.14, "%s: left arm clear of the eye (%.2f m)" % [spec[0], arm_d])
		check(errs[0] < 0.02 and errs[1] < 0.02, "%s: hands on the gun" % spec[0])
		check(bend < 40.0, "%s: torso not folded over (%.0f deg)" % [spec[0], bend])
	info("\n  ".join(res))
	rig.queue_free()


## Third person with a gun up the body faces where it points: swinging the view round turns
## the feet (turn in place) instead of twisting the gun round behind the back.
func test_tp_gun_up_faces_the_aim() -> void:
	UltraItems.give(c, &"rifle")
	var sl := _slot(&"rifle")
	_bot().view_tp = true
	_bot().set_steps([{"ticks": 90, "slot": sl, "yaw": 0.0, "pitch": 0.0}])
	await ticks(90)
	_bot().live_yaw = deg_to_rad(150.0)
	_bot().set_steps([{"ticks": 150, "slot": sl, "yaw": deg_to_rad(150.0), "pitch": 0.0}])
	await ticks(150)
	var off := rad_to_deg(absf(angle_difference(c.state.body_yaw, deg_to_rad(150.0))))
	info("TP rifle up, view swung 150 deg: body %.1f deg off the aim, action %d" % [off, c.state.action])
	check(off < 10.0, "the body came round with the gun (%.1f deg off)" % off)


## Looking down at the ground close by (and at ADS): the dot stays on the crosshair - shots
## start where the camera is (InputFrame.aim_from), so there's no parallax at short range.
func test_gun_dot_close_range() -> void:
	UltraItems.give(c, &"rifle")
	var rig := UltraCameraRig.new()
	add_child(rig)
	rig.attach(c)
	rig.camera.current = true
	var hud := UltraHUD.new()
	hud.character = c
	add_child(hud)
	var sl := _slot(&"rifle")
	var res := []
	for spec: Array in [["looking down 60", 0, -1.05], ["ADS down 45", InputFrame.B_SECONDARY, -0.8], ["level", 0, 0.0]]:
		await _run([{"ticks": 90, "slot": sl, "pitch": spec[2], "yaw": 0.0, "buttons": spec[1]}])
		await get_tree().process_frame
		var cam := rig.camera
		var fwd := -cam.global_basis.z
		var off := rad_to_deg(cam.project_ray_normal(hud.dot_pos).angle_to(fwd))
		var gun := rad_to_deg(c.state.sway.length())
		res.append("%s: dot %.2f deg off the crosshair (gun sway %.2f)" % [spec[0], off, gun])
		check(hud.dot_visible and off < gun + 0.6, "%s: the dot sits on the crosshair (%.2f deg)" % [spec[0], off])
	info(", ".join(res))
	hud.queue_free()
	rig.queue_free()


## The arms stay outside the torso (reloading the rifle brought the right forearm through the
## chest). Torso: an ellipse round the hips->neck line, in the chest's frame.
func test_arms_clear_the_body() -> void:
	UltraItems.give(c, &"rifle")
	UltraItems.give(c, &"ammo_556", 60)
	var sl := _slot(&"rifle")
	_bot().view_tp = true
	var sk := c.skeleton
	var res := []
	for spec: Array in [["idle", 0, 0], ["reload", InputFrame.B_RELOAD, 150], ["walk", 0, 0]]:
		var steps := [{"ticks": 80, "slot": sl, "move": Vector2(0, 1) if spec[0] == "walk" else Vector2.ZERO}]
		if spec[1] != 0:
			steps = [{"ticks": 60, "slot": sl}, {"ticks": 2, "slot": sl, "tap": InputFrame.B_PRIMARY}, {"ticks": 10, "slot": sl}, {"ticks": 2, "slot": sl, "tap": spec[1]}, {"ticks": 200, "slot": sl}]
		_bot().set_steps(steps)
		await ticks(76 if spec[1] != 0 else 60)
		if spec[1] != 0:
			check(c.state.action == UltraActionLayer.Action.RELOADING, "reloading")
		var worst := [INF, ""]
		for f in (150 if spec[1] != 0 else 40):
			await sk.skeleton_updated
			var q := _torso_q(sk)
			if float(q[0]) < float(worst[0]):
				worst = q
		res.append("%s: closest %.2f (%s) - 1 = on the surface" % [spec[0], worst[0], worst[1]])
		check(float(worst[0]) > 0.9, "%s: the arms stay outside the body (%.2f at %s)" % [spec[0], worst[0], worst[1]])
	info(", ".join(res))


## Smallest normalised ellipse distance of the elbows / forearms / hands to the torso.
func _torso_q(sk: Skeleton3D) -> Array:
	var g := func(n: String) -> Vector3: return sk.get_bone_global_pose(sk.find_bone(n)).origin
	var hips: Vector3 = g.call("Hips")
	var neck: Vector3 = g.call("Neck")
	var right: Vector3 = (g.call("RightUpperArm") as Vector3) - (g.call("LeftUpperArm") as Vector3)
	var axis := (neck - hips).normalized()
	right = (right - axis * right.dot(axis)).normalized()
	var fwd := axis.cross(right).normalized()
	var best := [INF, ""]
	for side in ["Left", "Right"]:
		var sh: Vector3 = g.call(side + "UpperArm")
		var e: Vector3 = g.call(side + "LowerArm")
		var h: Vector3 = g.call(side + "Hand")
		for pt: Array in [[sh.lerp(e, 0.55), side + " upper arm"], [e, side + " elbow"], [(e + h) * 0.5, side + " forearm"], [h, side + " hand"]]:
			var p: Vector3 = pt[0]
			var L := (neck - hips).length()
			var t := clampf((p - hips).dot(axis), 0.15, L)
			var d := p - (hips + axis * t)
			var kk := smoothstep(0.3, 0.8, t / L)
			var hw := lerpf(UltraArmClear.WAIST_HALF_WIDTH, UltraArmClear.TORSO_HALF_WIDTH, kk)
			var hd := lerpf(UltraArmClear.WAIST_HALF_DEPTH, UltraArmClear.TORSO_HALF_DEPTH, kk)
			var qv := pow(d.dot(right) / hw, 2.0) + pow(d.dot(fwd) / hd, 2.0)
			if sqrt(qv) < float(best[0]):
				best = [sqrt(qv), pt[1]]
	return best


## Camera / gun stability, first person, each gun: sampled when the skeleton has its final pose
## (what gets rendered). The gun must stay put against the camera, and the support hand mustn't
## flick about on the body. Regressions: the hand stepped 2.5 cm along the handguard as the walk
## bobbed the shoulder; the body's glue to the mouse yaw switched on and off (2 deg) turning
## while aiming and firing.
func test_camera_and_gun_steady() -> void:
	UltraItems.give(c, &"pistol")
	UltraItems.give(c, &"rifle")
	UltraItems.give(c, &"ammo_9mm", 60)
	UltraItems.give(c, &"ammo_556", 90)
	var rig := UltraCameraRig.new()
	add_child(rig)
	rig.attach(c)
	rig.camera.current = true
	var eq := c.get_node("Equipment") as UltraEquipmentVisual
	var sk := c.skeleton
	var rh := sk.find_bone("RightHand")
	var lh := sk.find_bone("LeftHand")
	var rec := []
	var grab := func() -> void:
		var cam := rig.camera.global_transform
		var g := sk.global_transform * sk.get_bone_global_pose(rh) * (eq.held_node.transform if eq.held_node else Transform3D())
		var vi := c.visual_root.global_transform.affine_inverse()
		rec.append([cam.affine_inverse() * g.origin, vi * (sk.global_transform * sk.get_bone_global_pose(lh)).origin])
	sk.skeleton_updated.connect(grab)
	var res := []
	var worst := {}
	var F := InputFrame
	for gun: StringName in [&"pistol", &"rifle"]:
		var sl := _slot(gun)
		for spec: Array in [["walk", Vector2(0, 1), 0, 0.0], ["sprint", Vector2(0, 1), F.B_SPRINT, 0.0], ["aim", Vector2.ZERO, F.B_SECONDARY, 0.0], ["aim turn", Vector2.ZERO, F.B_SECONDARY, 60.0], ["fire", Vector2.ZERO, F.B_SECONDARY | F.B_PRIMARY, 0.0]]:
			var step := {"ticks": 1000, "slot": sl, "move": spec[1], "buttons": spec[2], "pitch": -0.1}
			if spec[3] != 0.0:
				step["yaw_rate"] = deg_to_rad(spec[3])
			else:
				step["yaw"] = 0.0
			_bot().set_steps([step])
			await ticks(100 if spec[0] == "walk" else 40)     # (a new gun comes up first)
			rec.clear()
			await ticks(90)
			var gj := 0.0
			var lj := 0.0
			for i in range(1, rec.size() - 1):
				for k in 2:
					var a: Vector3 = rec[i - 1][k]
					var b: Vector3 = rec[i][k]
					var d: Vector3 = rec[i + 1][k]
					var j := (d - 2.0 * b + a).length() * 1000.0
					if k == 0:
						gj = maxf(gj, j)
					else:
						lj = maxf(lj, j)
			var tag := "%s %s" % [gun, spec[0]]
			res.append("%s: gun vs camera %.1f mm, support hand %.1f mm" % [tag, gj, lj])
			worst[tag] = [gj, lj]
	sk.skeleton_updated.disconnect(grab)
	rig.queue_free()
	info("
  ".join(res))
	for tag: String in worst:
		# (Sprinting carries the gun low and swinging: the arms move with the run.)
		var lim := 40.0 if tag.ends_with("sprint") else 25.0
		check(float(worst[tag][0]) < lim, "%s: the gun jumps against the camera (%.1f mm)" % [tag, worst[tag][0]])
		check(float(worst[tag][1]) < lim, "%s: the support hand flicks (%.1f mm)" % [tag, worst[tag][1]])


## Every view and both holds: the barrel points along the gun direction (the dot), and at rest
## the gun direction is the view direction. (Third person the pistol's aim clip held the barrel
## ~20 deg left of the aim; EquipmentVisual._aim_fix trims it out.)
func test_gun_points_at_aim() -> void:
	UltraItems.give(c, &"pistol")
	UltraItems.give(c, &"rifle")
	var eq := c.get_node("Equipment") as UltraEquipmentVisual
	var rig := UltraCameraRig.new()
	add_child(rig)
	rig.attach(c)
	rig.camera.current = true
	var res := []
	for gun: StringName in [&"pistol", &"rifle"]:
		for tp in [false, true]:
			for ads in [false, true]:
				_bot().view_tp = tp
				_bot().set_steps([{"ticks": 1000, "slot": _slot(gun), "yaw": 0.3, "pitch": -0.05, "buttons": InputFrame.B_SECONDARY if ads else 0}])
				await ticks(120)
				await c.skeleton.skeleton_updated
				var sk := c.skeleton
				var g := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("RightHand")) * eq.held_node.transform
				var barrel := -g.basis.z.normalized()
				var want: Vector3 = eq.gun_ray().dir
				var view := -rig.camera.global_basis.z
				var yaw_err := rad_to_deg(Vector2(want.x, want.z).angle_to(Vector2(barrel.x, barrel.z)))
				var pitch_err := rad_to_deg(asin(barrel.y) - asin(want.y))
				var dot_err := rad_to_deg(Vector2(view.x, view.z).angle_to(Vector2(want.x, want.z)))
				var tag := "%s %s %s" % [gun, "TP" if tp else "FP", "ADS" if ads else "hip"]
				res.append("%s: barrel vs gun dir yaw %.1f pitch %.1f; gun dir vs view yaw %.2f" % [tag, yaw_err, pitch_err, dot_err])
				check(absf(yaw_err) < 2.0 and absf(pitch_err) < 2.0, "%s: the barrel points along the gun direction (yaw %.1f, pitch %.1f deg)" % [tag, yaw_err, pitch_err])
				check(absf(dot_err) < 0.5, "%s: at rest the gun direction is the view (%.2f deg)" % [tag, dot_err])
	rig.queue_free()
	info("\n  ".join(res))
