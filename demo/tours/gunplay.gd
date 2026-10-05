extends UltraTour
## Gunplay review tour: free aim (the crosshair is where you look, the dot is where the gun
## points) with the pistol - idle, turning, sprinting, aiming down sights - then the rifle in
## first and third person: idle, ADS, automatic fire, reload, sprint, slung on the back.
##   godot --path . --resolution 1280x720 -- --tour=gunplay --out=C:/Dev/verify/ultra/review/gunplay


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/gunplay")
	var F := InputFrame
	steps = [
		{"teleport": "range", "t": 0.6, "yaw": 180, "pitch": -2, "slot": 0},
		{"t": 1.4, "slot": 1, "shot": "01_fp_pistol_idle"},
		# Turning: the gun trails the view, the dot lags behind the crosshair.
		{"t": 0.3, "yaw_rate": 140, "shot": "02_fp_pistol_turning"},
		{"t": 0.12, "shot": "02b_fp_pistol_turn_stopped"},
		{"t": 0.8, "yaw": 0},
		# Sprinting: gun carried low, the dot drops and bobs; it still fires where it points.
		{"t": 1.0, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "shot": "03_fp_pistol_sprint"},
		{"t": 0.25, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "shot": "03b_fp_pistol_sprint_b"},
		{"t": 0.05, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "tap": F.B_PRIMARY, "shot": "03c_fp_pistol_sprint_fire"},
		{"t": 1.0, "teleport": "range", "yaw": 180, "pitch": -2},
		# Aim down sights: dot and sights converge.
		{"t": 1.0, "buttons": F.B_SECONDARY, "shot": "04_fp_pistol_ads"},
		{"t": 0.25, "buttons": F.B_SECONDARY, "yaw_rate": 60, "shot": "05_fp_pistol_ads_turning"},
		{"t": 0.6, "buttons": F.B_SECONDARY},
		{"t": 0.05, "buttons": F.B_SECONDARY, "tap": F.B_PRIMARY, "shot": "06_fp_pistol_ads_fire"},
		{"t": 0.6},
		{"t": 1.0, "view_tp": true, "pitch": -4, "shot": "07_tp_pistol_idle"},
		{"t": 0.3, "yaw_rate": 120, "shot": "08_tp_pistol_turning"},
		{"t": 0.8, "view_tp": false},
		# Rifle (slot 2).
		{"call": _give_rifle, "t": 0.2},
		{"t": 1.6, "slot": 2, "yaw": 180, "pitch": -2, "shot": "10_fp_rifle_idle"},
		{"t": 0.3, "yaw_rate": 140, "shot": "11_fp_rifle_turning"},
		{"t": 0.8},
		{"t": 1.0, "buttons": F.B_SECONDARY, "shot": "12_fp_rifle_ads"},
		{"t": 0.45, "buttons": F.B_SECONDARY | F.B_PRIMARY, "shot": "13_fp_rifle_ads_auto_fire"},
		{"t": 0.6},
		{"t": 0.45, "buttons": F.B_PRIMARY, "shot": "14_fp_rifle_hip_auto_fire"},
		{"t": 0.6},
		# The first-person body from outside (it comes to the camera-placed gun).
		{"call": func() -> void: _side_cam(1.0), "t": 0.6, "shot": "14b_fp_body_side_hip"},
		{"t": 0.8, "buttons": F.B_SECONDARY, "shot": "14c_fp_body_side_ads"},
		{"call": func() -> void: _cam_at(1.5, 1.9), "t": 0.6, "buttons": F.B_SECONDARY, "shot": "14d_fp_body_front_ads"},
		{"t": 0.8, "shot": "14e_fp_body_front_hip"},
		{"t": 0.8, "buttons": F.B_SECONDARY, "pitch": -40, "shot": "14f_fp_body_front_ads_down"},
		{"call": func() -> void: _cam_at(-1.6, 1.6), "t": 0.6, "buttons": F.B_SECONDARY, "pitch": -2, "shot": "14g_fp_body_left_front_ads"},
		{"call": _main_cam, "t": 0.6},
		{"t": 0.8, "buttons": F.B_SECONDARY, "pitch": -40, "shot": "14h_fp_rifle_ads_down"},
		{"t": 0.8, "pitch": -2},
		{"t": 0.8, "tap": F.B_RELOAD, "shot": "15_fp_rifle_reload"},
		{"t": 2.2, "yaw": 0},
		{"t": 1.0, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "shot": "16_fp_rifle_sprint"},
		{"t": 1.0, "teleport": "range", "yaw": 180, "pitch": -2},
		{"t": 1.0, "view_tp": true, "pitch": -4, "shot": "17_tp_rifle_idle"},
		{"t": 1.0, "buttons": F.B_SECONDARY, "shot": "18_tp_rifle_ads"},
		{"t": 0.4, "buttons": F.B_SECONDARY | F.B_PRIMARY, "shot": "19_tp_rifle_fire"},
		{"t": 0.6},
		# Side views (a spare camera beside the player).
		{"call": func() -> void: _side_cam(1.0), "t": 0.6, "shot": "19b_side_rifle_low_ready"},
		{"t": 0.8, "buttons": F.B_SECONDARY, "shot": "19c_side_rifle_aim"},
		{"call": func() -> void: _side_cam(-1.0), "t": 0.6, "buttons": F.B_SECONDARY, "shot": "19d_side_rifle_aim_left"},
		{"t": 0.9, "tap": F.B_RELOAD, "shot": "19e_side_rifle_reload"},
		{"call": _main_cam, "t": 1.8},
		{"t": 0.9, "tap": F.B_RELOAD, "shot": "20_tp_rifle_reload"},
		{"t": 2.0, "yaw": 0},
		{"t": 1.2, "move": Vector2(0, 1), "shot": "21_tp_rifle_jog"},
		{"t": 1.0, "teleport": "range", "yaw": 180, "pitch": -4},
		# Pistol drawn, rifle slung on the back.
		{"t": 1.4, "slot": 1, "yaw": 180, "pitch": -12, "shot": "22_tp_rifle_slung_back"},
		{"t": 1.0, "slot": 0, "yaw": 210, "pitch": -12, "shot": "23_tp_both_stowed"},
	]


## (UltraTour._drive adds "yaw_rate" to live_yaw after copying it into the frame, and the bot
## then resets live_yaw from the frame, so the turn never accumulates: send the turned aim.)
func _drive(tick: int, src: BotInputSource) -> InputFrame:
	var f := super(tick, src)
	f.yaw = _bot.live_yaw
	return f


var _cam: Camera3D


## A camera 2.3 m to the player's right (side = 1) or left (-1), level with the chest.
func _side_cam(side: float) -> void:
	if _cam == null:
		_cam = Camera3D.new()
		main.add_child(_cam)
	var c: UltraCharacter = main.player
	var yaw := c.state.body_yaw
	var right := Vector3(cos(yaw), 0, -sin(yaw))
	var fwd := Vector3(-sin(yaw), 0, -cos(yaw))
	var chest := c.global_position + Vector3.UP * 1.3
	_cam.global_position = chest + right * 2.3 * side + fwd * 0.4
	_cam.look_at(chest + fwd * 0.4)
	_cam.fov = 50.0
	_cam.current = true


## A camera `right_m` to the player's right and `fwd_m` ahead, looking back at the chest.
func _cam_at(right_m: float, fwd_m: float) -> void:
	_side_cam(1.0)
	var c: UltraCharacter = main.player
	var yaw := c.state.body_yaw
	var right := Vector3(cos(yaw), 0, -sin(yaw))
	var fwd := Vector3(-sin(yaw), 0, -cos(yaw))
	var chest := c.global_position + Vector3.UP * 1.35
	_cam.global_position = chest + right * right_m + fwd * fwd_m + Vector3.UP * 0.15
	_cam.look_at(chest + fwd * 0.2)


func _main_cam() -> void:
	if _cam:
		_cam.current = false
		_cam.queue_free()
		_cam = null
	var rig: Array[Node] = (main.get("locals") as Node).find_children("*", "UltraCameraRig", true, false)
	if not rig.is_empty():
		(rig[0] as UltraCameraRig).camera.current = true


func _give_rifle() -> void:
	if UltraNet.is_server() and ItemDB.get_def(&"rifle"):
		if main.player.inventory.count_of(&"rifle") == 0:
			UltraItems.give(main.player, &"rifle", 1)
