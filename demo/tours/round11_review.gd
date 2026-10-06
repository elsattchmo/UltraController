extends UltraTour
## Review tour (round 11): third person holds guns like first person (hip, ADS, reload, the
## gun-butt), the machete's free-hand guard and the bat in both hands, getting down to / up from
## prone, a pistol and a machete lying down, and stepping off the cliff into a hang.
##   godot --path . --resolution 1280x720 -- --tour=round11_review --out=C:/Dev/verify/ultra/review/round11_review

var _cam: Camera3D
const SLOW := 0.35


func _slow(on: bool) -> void:
	Engine.time_scale = SLOW if on else 1.0


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/round11_review")
	var F := InputFrame
	var P := F.B_CRAWL | F.B_CROUCH
	steps = [
		{"teleport": "speed_start", "t": 0.6, "yaw": 0, "pitch": -4, "view_tp": true, "slot": 0},
		{"call": _give, "t": 0.3},
		{"call": _side_on, "t": 0.3, "slot": 0},
		# Guns in third person: rifle hip / ADS / reload / gun-butt, pistol hip / ADS.
		{"t": 1.4, "slot": 2, "shot": "rifle_hip"},
		{"t": 0.8, "slot": 2, "buttons": F.B_SECONDARY, "shot": "rifle_ads"},
		{"call": _empty, "t": 0.05, "slot": 2, "tap": F.B_RELOAD},
	]
	for k in 10:
		steps.append({"t": 0.22, "slot": 2, "shot": "rifle_reload_%d" % k})
	steps.append({"t": 1.0, "slot": 2})
	steps.append({"call": _slow.bind(true), "t": 0.01, "slot": 2})
	steps.append({"t": 0.02 / SLOW, "slot": 2, "tap": F.B_MELEE})
	for k in 6:
		steps.append({"t": 0.07 / SLOW, "slot": 2, "shot": "rifle_butt_%d" % k})
	steps.append({"call": _slow.bind(false), "t": 0.8, "slot": 2})
	steps.append({"t": 1.2, "slot": 1, "shot": "pistol_hip"})
	steps.append({"t": 0.8, "slot": 1, "buttons": F.B_SECONDARY, "shot": "pistol_ads"})
	steps.append({"t": 0.6, "slot": 1})
	steps.append({"call": _slow.bind(true), "t": 0.01, "slot": 1})
	steps.append({"t": 0.02 / SLOW, "slot": 1, "tap": F.B_MELEE})
	for k in 6:
		steps.append({"t": 0.06 / SLOW, "slot": 1, "shot": "pistol_butt_%d" % k})
	steps.append({"call": _slow.bind(false), "t": 0.8, "slot": 1})
	# Machete: guard and counter-swing through a combo; the bat in both hands.
	steps.append({"t": 1.2, "slot": 5, "shot": "machete_idle"})
	steps.append({"call": _slow.bind(true), "t": 0.01, "slot": 5})
	for k in 18:
		var st := {"t": 0.06 / SLOW, "slot": 5, "shot": "machete_%02d" % k}
		if k < 12:
			st["tap"] = F.B_PRIMARY
		steps.append(st)
	steps.append({"call": _slow.bind(false), "t": 1.0, "slot": 5})
	steps.append({"t": 1.2, "slot": 4, "shot": "bat_idle"})
	steps.append({"call": _slow.bind(true), "t": 0.01, "slot": 4})
	for k in 10:
		var st2 := {"t": 0.08 / SLOW, "slot": 4, "shot": "bat_%02d" % k}
		if k < 6:
			st2["tap"] = F.B_PRIMARY
		steps.append(st2)
	steps.append({"call": _slow.bind(false), "t": 1.0, "slot": 4})
	# Prone with the rifle: down, lying, back up.
	steps.append({"t": 0.6, "slot": 2})
	for k in 6:
		steps.append({"t": 0.15, "slot": 2, "buttons": P, "shot": "prone_down_%d" % k})
	steps.append({"t": 0.8, "slot": 2, "buttons": P, "shot": "prone_rifle"})
	for k in 6:
		steps.append({"t": 0.15, "slot": 2, "shot": "prone_up_%d" % k})
	# Pistol and machete lying down (a machete strike).
	steps.append({"t": 1.6, "slot": 1, "buttons": P, "shot": "prone_pistol"})
	steps.append({"t": 0.05, "slot": 1, "buttons": P | F.B_PRIMARY})
	steps.append({"t": 0.1, "slot": 1, "buttons": P, "shot": "prone_pistol_fire"})
	steps.append({"t": 1.4, "slot": 5, "buttons": P, "shot": "prone_machete"})
	steps.append({"t": 0.05, "slot": 5, "buttons": P, "tap": F.B_PRIMARY})
	for k in 5:
		steps.append({"t": 0.1, "slot": 5, "buttons": P, "shot": "prone_machete_%d" % k})
	steps.append({"t": 1.5, "slot": 0})
	# Off the cliff into a hang.
	steps.append({"call": _to.bind(Vector3(128.5, 8.05, -24.8), PI), "t": 0.8, "slot": 0, "yaw": 180})
	steps.append({"call": _slow.bind(true), "t": 0.01, "slot": 0})
	for k in 14:
		steps.append({"t": 0.11 / SLOW, "slot": 0, "move": Vector2(0, 1), "shot": "drop_%02d" % k})
	steps.append({"call": _slow.bind(false), "t": 0.5, "slot": 0})


func _give() -> void:
	for it: Array in [[&"pistol", 1], [&"rifle", 1], [&"ammo_556", 90], [&"bat", 1], [&"machete", 1]]:
		if main.player.inventory.count_of(it[0]) == 0:
			UltraItems.give(main.player, it[0], it[1])


func _empty() -> void:
	main.player.state.mag = 2


func _to(p: Vector3, yaw: float) -> void:
	main.player.teleport(p, yaw)


func _side_on() -> void:
	_cam = Camera3D.new()
	main.add_child(_cam)
	_cam.fov = 45.0


func _process(delta: float) -> void:
	super(delta)
	if _cam:
		_cam.current = true
		var c: UltraCharacter = main.player
		var yaw := c.state.body_yaw
		var right := Vector3(cos(yaw), 0, -sin(yaw))
		var fwd := Vector3(-sin(yaw), 0, -cos(yaw))
		var p := c.visual_root.global_position + Vector3.UP * 1.0
		var dist := 3.0
		if c.state.state == MotorState.Id.CRAWL or c.anim._cur_loco in ["prone_down", "prone_up"]:
			p = c.visual_root.global_position + Vector3.UP * 0.35 + fwd * 0.4
		if c.state.state in [MotorState.Id.LEDGE_CLIMB, MotorState.Id.LEDGE_HANG]:
			p += Vector3.UP * (0.8 + c.camera_lift())
			dist = 4.0
		_cam.global_position = p + right * dist + fwd * 0.6 + Vector3.UP * 0.3
		_cam.look_at(p)
