extends UltraTour
## Review tour (round E): rifle / pistol magazine swaps (old one dropped, new from the hip),
## the shotgun loaded shouldered, the gun-butt hook from the right, the machete's free arm at
## rest, the bat grip, prone with a machete held at the side.
##   godot --path . --resolution 1280x720 -- --tour=round_e_review --out=C:/Dev/verify/ultra/review/round_e_review

var _cam: Camera3D
const SLOW := 0.35


func _slow(on: bool) -> void:
	Engine.time_scale = SLOW if on else 1.0


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/round_e_review")
	var F := InputFrame
	var P := F.B_CRAWL | F.B_CROUCH
	steps = [
		{"teleport": "speed_start", "t": 0.6, "yaw": 0, "pitch": -4, "view_tp": true, "slot": 0},
		{"call": _give, "t": 0.3},
		{"call": _side_on, "t": 0.3, "slot": 0},
	]
	for g in [[2, "rifle", 12, 0.22], [1, "pistol", 10, 0.2], [3, "shotgun", 10, 0.3]]:
		steps.append({"t": 1.4, "slot": g[0], "shot": "%s_hip" % g[1]})
		steps.append({"call": _empty, "t": 0.05, "slot": g[0], "tap": F.B_RELOAD})
		for k in int(g[2]):
			steps.append({"t": g[3], "slot": g[0], "shot": "%s_reload_%02d" % [g[1], k]})
		steps.append({"t": 1.2, "slot": g[0]})
	# The gun-butt hook (slow motion).
	steps.append({"t": 1.6, "slot": 2})
	steps.append({"call": _slow.bind(true), "t": 0.01, "slot": 2})
	steps.append({"t": 0.02 / SLOW, "slot": 2, "tap": F.B_MELEE})
	for k in 8:
		steps.append({"t": 0.06 / SLOW, "slot": 2, "shot": "butt_%d" % k})
	steps.append({"call": _slow.bind(false), "t": 0.8, "slot": 2})
	# Machete: idle and walking with the free arm down; one strike.
	steps.append({"t": 1.4, "slot": 5, "shot": "machete_idle"})
	steps.append({"t": 1.2, "slot": 5, "move": Vector2(0, 1), "shot": "machete_walk"})
	steps.append({"t": 0.6, "slot": 5})
	steps.append({"t": 0.05, "slot": 5, "tap": F.B_PRIMARY})
	steps.append({"t": 0.25, "slot": 5, "shot": "machete_strike"})
	steps.append({"t": 1.0, "slot": 5, "shot": "machete_after"})
	steps.append({"t": 1.4, "slot": 4, "shot": "bat_idle"})
	# Prone with the machete held at the side.
	steps.append({"t": 2.0, "slot": 5, "buttons": P, "shot": "prone_machete"})
	steps.append({"t": 1.0, "slot": 5, "buttons": P, "move": Vector2(0, 1), "shot": "prone_machete_crawl"})
	steps.append({"t": 0.05, "slot": 5, "buttons": P, "tap": F.B_PRIMARY})
	steps.append({"t": 0.5, "slot": 5, "buttons": P, "shot": "prone_machete_attack_pressed"})
	# Prone with the rifle: reload, shuffle left / right, roll.
	steps.append({"t": 1.8, "slot": 2, "buttons": P, "shot": "prone_rifle"})
	steps.append({"call": _empty, "t": 0.05, "slot": 2, "buttons": P, "tap": F.B_RELOAD})
	for k in 8:
		steps.append({"t": 0.3, "slot": 2, "buttons": P, "shot": "prone_reload_%d" % k})
	steps.append({"t": 1.0, "slot": 2, "buttons": P})
	for k in 4:
		steps.append({"t": 0.3, "slot": 2, "buttons": P, "move": Vector2(-1, 0), "shot": "prone_left_%d" % k})
	for k in 4:
		steps.append({"t": 0.3, "slot": 2, "buttons": P, "move": Vector2(1, 0), "shot": "prone_right_%d" % k})
	steps.append({"t": 0.5, "slot": 2, "buttons": P})
	steps.append({"t": 0.05, "slot": 2, "buttons": P, "tap": F.B_DODGE})
	for k in 6:
		steps.append({"t": 0.2, "slot": 2, "buttons": P, "shot": "prone_roll_%d" % k})
	steps.append({"t": 1.5, "slot": 0})


func _give() -> void:
	for it: Array in [[&"pistol", 1], [&"rifle", 1], [&"shotgun", 1], [&"ammo_556", 90], [&"ammo_9mm", 60], [&"ammo_12g", 30], [&"bat", 1], [&"machete", 1]]:
		if main.player.inventory.count_of(it[0]) == 0:
			UltraItems.give(main.player, it[0], it[1])


func _empty() -> void:
	main.player.state.mag = 2


func _side_on() -> void:
	_cam = Camera3D.new()
	main.add_child(_cam)
	_cam.fov = 40.0


func _process(delta: float) -> void:
	super(delta)
	if _cam:
		_cam.current = true
		var c: UltraCharacter = main.player
		var yaw := c.state.body_yaw
		var right := Vector3(cos(yaw), 0, -sin(yaw))
		var fwd := Vector3(-sin(yaw), 0, -cos(yaw))
		var p := c.visual_root.global_position + Vector3.UP * 1.05
		var dist := 2.4
		if c.state.stance == MotorState.Stance.CRAWL or c.anim._cur_loco in ["prone_down", "prone_up"]:
			p = c.visual_root.global_position + Vector3.UP * 0.3 + fwd * 0.4
			dist = 2.0
		# Left-front: the reloading hand and the hip pouch face the camera.
		_cam.global_position = p - right * dist * 0.8 + fwd * dist * 0.7 + Vector3.UP * 0.25
		_cam.look_at(p)
