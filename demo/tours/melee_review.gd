extends UltraTour
## Review tour: melee and knockouts - the pistol whip and the carbine's stock strike (first
## person, then side on knocking a dummy out), the bat's three-swing combo (a knockout) and the
## machete taking an arm off, being knocked out yourself (blackout, coming round groggy), and
## the breakables: crates shot and clubbed apart, bottles, the window.
##   godot --path . --resolution 1280x720 -- --tour=melee_review --out=C:/Dev/verify/ultra/review/melee_review

var _cam: Camera3D
var _dummy: UltraCharacter


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/melee_review")
	var F := InputFrame
	steps = [
		{"teleport": "speed_start", "t": 0.6, "yaw": 0, "pitch": -4, "view_tp": false, "slot": 0},
		{"call": _give, "t": 0.3},
		{"call": _place_dummy, "t": 1.4, "slot": 1, "shot": "fp_pistol"},
	]
	_strike("fp_whip", 1, 9, 0.05)
	steps.append({"t": 1.2, "slot": 2, "shot": "fp_rifle"})
	_strike("fp_butt", 2, 11, 0.05)
	# Third person, side on: the stock to a fresh dummy's head.
	steps.append({"call": _side_on, "t": 1.4, "slot": 2, "view_tp": true, "shot": "side_rifle"})
	steps.append({"call": _place_dummy, "t": 0.6, "slot": 2})
	_strike("side_butt", 2, 11, 0.05)
	steps.append({"t": 1.5, "slot": 2, "shot": "side_ko"})
	# The bat: idle, then the combo (A, B, C), in slow motion.
	steps.append({"call": _place_dummy, "t": 1.6, "slot": 4, "shot": "side_bat"})
	_combo("bat", 4, &"bat")
	steps.append({"t": 1.5, "slot": 4, "shot": "bat_after"})
	# The machete on a dummy with weakened arms.
	steps.append({"call": _place_weak_dummy, "t": 1.6, "slot": 5, "shot": "side_machete"})
	_combo("machete", 5, &"machete")
	steps.append({"t": 1.5, "slot": 5, "shot": "machete_after"})
	# Knocked out yourself (first person): out, black, coming round.
	steps.append({"call": _back_to_fp, "t": 1.0, "slot": 0, "view_tp": false})
	steps.append({"call": _knock_me_out, "t": 0.15, "shot": "ko_0"})
	for k in 5:
		steps.append({"t": 0.3, "shot": "ko_%d" % (k + 1)})
	steps.append({"t": 20.0, "until": _awake, "after": 0.1, "shot": "wake_0"})
	for k in 6:
		steps.append({"t": 0.35, "shot": "wake_%d" % (k + 1)})
	steps.append({"t": 3.0})
	# Breakables.
	steps.append({"teleport": "breakables", "t": 1.0, "yaw": 180, "pitch": -10, "slot": 1, "view_tp": true})
	steps.append({"call": _look_at.bind("WoodCrate0_1"), "t": 1.2, "slot": 1, "buttons": F.B_SECONDARY, "shot": "crates"})
	for k in 3:
		steps.append({"t": 0.05, "slot": 1, "buttons": F.B_SECONDARY | F.B_PRIMARY})
		steps.append({"t": 0.3, "slot": 1, "buttons": F.B_SECONDARY, "shot": "crate_shot_%d" % k})
	for k in 4:
		steps.append({"t": 0.12, "slot": 1, "shot": "crate_debris_%d" % k})
	steps.append({"call": _look_at.bind("Bottle1"), "t": 1.0, "slot": 1, "buttons": F.B_SECONDARY})
	steps.append({"t": 0.05, "slot": 1, "buttons": F.B_SECONDARY | F.B_PRIMARY})
	for k in 3:
		steps.append({"t": 0.1, "slot": 1, "buttons": F.B_SECONDARY, "shot": "bottle_%d" % k})
	steps.append({"call": _look_at.bind("WindowPane"), "t": 1.0, "slot": 1, "buttons": F.B_SECONDARY})
	steps.append({"t": 0.05, "slot": 1, "buttons": F.B_SECONDARY | F.B_PRIMARY})
	for k in 4:
		steps.append({"t": 0.1, "slot": 1, "buttons": F.B_SECONDARY, "shot": "window_%d" % k})
	steps.append({"t": 2.0, "slot": 1})


## Filmed in slow motion (the frame grabs stall a real-time capture).
const SLOW := 0.2


func _slow(on: bool) -> void:
	Engine.time_scale = SLOW if on else 1.0


## A strike (the melee button) filmed in `n` frames `dt` (game seconds) apart.
func _strike(name: String, slot: int, n: int, dt: float) -> void:
	steps.append({"call": _slow.bind(true), "t": 0.01, "slot": slot})
	steps.append({"t": 0.02 / SLOW, "slot": slot, "tap": InputFrame.B_MELEE})
	for k in n:
		steps.append({"t": dt / SLOW, "slot": slot, "shot": "%s_%d" % [name, k]})
	steps.append({"call": _slow.bind(false), "t": 0.8, "slot": slot})


## A weapon's three-swing combo, filmed every `dt` game seconds; the attack button is pressed
## on every frame until the third swing has started (presses late in a swing chain the next).
func _combo(name: String, slot: int, item: StringName, dt := 0.07) -> void:
	var def := ItemDB.get_def(item)
	var sw: Array = def.stat("melee", []) if def else []
	var t_ab := 0.0
	var total := 0.0
	for k in sw.size():
		total += float(sw[k].time)
		if k < 2:
			t_ab += float(sw[k].time)
	steps.append({"call": _slow.bind(true), "t": 0.01, "slot": slot})
	var n := int((total + 0.35) / dt)
	for j in n:
		var st := {"t": dt / SLOW, "slot": slot, "shot": "%s_%02d" % [name, j]}
		if j * dt < t_ab + 0.05:
			st["tap"] = InputFrame.B_PRIMARY
		steps.append(st)
	steps.append({"call": _slow.bind(false), "t": 0.5, "slot": slot})


func _give() -> void:
	for it: StringName in [&"pistol", &"rifle", &"shotgun", &"bat", &"machete"]:
		if main.player.inventory.count_of(it) == 0:
			UltraItems.give(main.player, it, 1)


## A fresh dummy 1.15 m ahead, facing us (the last one goes).
func _place_dummy() -> void:
	if _dummy and is_instance_valid(_dummy):
		UltraNet.despawn_bot(_dummy.net_id)
	var c: UltraCharacter = main.player
	var fwd := Vector3(-sin(c.state.body_yaw), 0, -cos(c.state.body_yaw))
	var p := UltraNet.spawn_bot("Dummy", Transform3D(Basis(Vector3.UP, c.state.body_yaw + PI), c.state.pos + fwd * 1.15))
	(p.character.input_source as BotInputSource).set_steps([{"ticks": 100000}])
	_dummy = p.character


func _place_weak_dummy() -> void:
	_place_dummy()
	for r in [UltraLimbs.Region.ARM_L, UltraLimbs.Region.ARM_R, UltraLimbs.Region.FOREARM_L, UltraLimbs.Region.FOREARM_R]:
		_dummy.state.limb_hp[r] = 10


func _side_on() -> void:
	_cam = Camera3D.new()
	main.add_child(_cam)
	_cam.fov = 40.0
	_cam.current = true


func _back_to_fp() -> void:
	if _cam:
		_cam.queue_free()
		_cam = null
	if _dummy and is_instance_valid(_dummy):
		UltraNet.despawn_bot(_dummy.net_id)
		_dummy = null


func _knock_me_out() -> void:
	var d := UltraCombat.DamageInfo.new()
	d.amount = 26.0
	d.region = UltraLimbs.Region.HEAD
	d.kind = &"blunt"
	d.dir = Vector3(-sin(main.player.state.body_yaw), 0, -cos(main.player.state.body_yaw)) * -1.0
	d.point = main.player.state.pos + Vector3.UP * 1.6
	main.player.apply_damage(d)


func _awake() -> bool:
	return not main.player.state.has(MotorState.F_UNCONSCIOUS)


func _look_at(n: String) -> void:
	var t := main.find_child(n, true, false) as Node3D
	if t == null:
		return
	var rig: UltraCameraRig = main.find_children("*", "UltraCameraRig", true, false)[0]
	var to := t.global_position - rig.global_position
	_bot.live_yaw = atan2(-to.x, -to.z)
	_bot.live_pitch = asin(to.normalized().y)


func _process(delta: float) -> void:
	super(delta)
	if _cam:
		_cam.current = true                 # (the rig takes the view back when it changes)
		var c: UltraCharacter = main.player
		var yaw := c.state.body_yaw
		var right := Vector3(cos(yaw), 0, -sin(yaw))
		var fwd := Vector3(-sin(yaw), 0, -cos(yaw))
		var p := c.visual_root.global_position + Vector3.UP * 1.1 + fwd * 0.6
		_cam.global_position = p + right * 3.6 + Vector3.UP * 0.2
		_cam.look_at(p)
