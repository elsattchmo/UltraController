extends UltraTour
## Review tour: the same actions in first-person mode and third-person mode, filmed from the
## same outside camera - third person should be first person seen from outside (body, gun hold,
## gun movement). Rifle and pistol: idle, walking, aiming, firing, reloading, sprinting, a
## gun-butt.
##   godot --path . --resolution 1280x720 -- --tour=fp_tp_compare --out=C:/Dev/verify/ultra/review/fp_tp_compare

var _cam: Camera3D


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/fp_tp_compare")
	var F := InputFrame
	steps = [
		{"teleport": "speed_start", "t": 0.6, "yaw": 0, "pitch": -4, "view_tp": false, "slot": 0},
		{"call": _give, "t": 0.3},
		{"call": _side_on, "t": 0.3, "slot": 0},
	]
	for slot in [2, 1]:
		for view in ["fp", "tp"]:
			var tp: bool = view == "tp"
			var g: String = "rifle" if slot == 2 else "pistol"
			var tag := "%s_%s" % [g, view]
			steps.append({"teleport": "speed_start", "t": 1.4, "yaw": 0, "pitch": -4, "view_tp": tp, "slot": slot, "shot": tag + "_a_idle"})
			steps.append({"t": 0.9, "slot": slot, "move": Vector2(0, 1), "shot": tag + "_b_walk"})
			steps.append({"t": 0.8, "slot": slot, "buttons": F.B_SECONDARY, "shot": tag + "_c_ads"})
			steps.append({"t": 0.05, "slot": slot, "buttons": F.B_SECONDARY | F.B_PRIMARY})
			steps.append({"t": 0.05, "slot": slot, "buttons": F.B_SECONDARY, "shot": tag + "_d_fire"})
			steps.append({"t": 0.6, "slot": slot})
			steps.append({"call": _empty, "t": 0.05, "slot": slot, "tap": F.B_RELOAD})
			steps.append({"t": 0.6, "slot": slot, "shot": tag + "_e_reload1"})
			steps.append({"t": 0.6, "slot": slot, "shot": tag + "_f_reload2"})
			steps.append({"t": 2.0, "slot": slot})
			steps.append({"t": 1.2, "slot": slot, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "shot": tag + "_g_sprint"})
			steps.append({"t": 0.8, "slot": slot})
			steps.append({"t": 0.05, "slot": slot, "tap": F.B_MELEE})
			steps.append({"t": 0.25, "slot": slot, "shot": tag + "_h_butt"})
			steps.append({"t": 0.8, "slot": slot})


func _give() -> void:
	for it: Array in [[&"pistol", 1], [&"rifle", 1], [&"ammo_556", 90], [&"ammo_9mm", 60]]:
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
		var p := c.visual_root.global_position + Vector3.UP * 1.2 + fwd * 0.3
		_cam.global_position = p + right * 2.4 + fwd * 1.0 + Vector3.UP * 0.2
		_cam.look_at(p)
