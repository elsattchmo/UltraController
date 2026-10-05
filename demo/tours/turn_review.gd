extends UltraTour
## Review tour: turning on the spot - standing, crouched, and with the rifle up in third person
## (the body now follows a raised gun) - filmed by a fixed camera, a strip of frames per turn.
##   godot --path . --resolution 1280x720 -- --tour=turn_review --out=C:/Dev/verify/ultra/review/turn_review

var _cam: Camera3D


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/turn_review")
	var F := InputFrame
	steps = [
		{"teleport": "speed_start", "t": 1.0, "yaw": 0, "pitch": -5, "view_tp": false, "slot": 0},
		{"call": _fixed_cam, "t": 0.6},
		# Standing, 90 deg left then back right.
		{"t": 0.12, "yaw": 90, "shot": "01_stand_l_a"},
		{"t": 0.18, "yaw": 90, "shot": "02_stand_l_b"},
		{"t": 0.18, "yaw": 90, "shot": "03_stand_l_c"},
		{"t": 0.18, "yaw": 90, "shot": "04_stand_l_d"},
		{"t": 0.6, "yaw": 90, "shot": "05_stand_l_end"},
		{"t": 0.15, "yaw": 0, "shot": "06_stand_r_a"},
		{"t": 0.2, "yaw": 0, "shot": "07_stand_r_b"},
		{"t": 0.2, "yaw": 0, "shot": "08_stand_r_c"},
		{"t": 0.8, "yaw": 0, "shot": "09_stand_r_end"},
		# Crouched.
		{"t": 1.0, "yaw": 0, "buttons": F.B_CROUCH},
		{"t": 0.15, "yaw": 90, "buttons": F.B_CROUCH, "shot": "10_crouch_l_a"},
		{"t": 0.2, "yaw": 90, "buttons": F.B_CROUCH, "shot": "11_crouch_l_b"},
		{"t": 0.2, "yaw": 90, "buttons": F.B_CROUCH, "shot": "12_crouch_l_c"},
		{"t": 0.8, "yaw": 90, "buttons": F.B_CROUCH, "shot": "13_crouch_l_end"},
		{"t": 1.0, "yaw": 0},
		# Rifle up, third person: the body comes round with the gun.
		{"call": _give_rifle, "t": 0.2},
		{"t": 1.6, "slot": 2, "yaw": 0, "view_tp": true},
		{"call": _fixed_cam, "t": 0.3},
		{"t": 0.15, "yaw": 90, "shot": "14_rifle_l_a"},
		{"t": 0.2, "yaw": 90, "shot": "15_rifle_l_b"},
		{"t": 0.2, "yaw": 90, "shot": "16_rifle_l_c"},
		{"t": 0.8, "yaw": 90, "shot": "17_rifle_l_end"},
		{"t": 1.0, "yaw": 200, "shot": "18_rifle_round_behind"},
	]


## A camera fixed in the world, ahead and to the right of the player, looking at the body.
func _fixed_cam() -> void:
	if _cam == null:
		_cam = Camera3D.new()
		main.add_child(_cam)
	var c: UltraCharacter = main.player
	var p := c.global_position
	_cam.global_position = p + Vector3(1.6, 1.4, -2.4)
	_cam.look_at(p + Vector3(0, 0.9, 0))
	_cam.fov = 55.0
	_cam.current = true


func _give_rifle() -> void:
	if UltraNet.is_server() and ItemDB.get_def(&"rifle"):
		if main.player.inventory.count_of(&"rifle") == 0:
			UltraItems.give(main.player, &"rifle", 1)
