extends UltraTour
## Review: neck cap (crouch / run looking down), gun motion while running, hands on held props.

const Id := MotorState.Id


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/fixes2")
	var F := InputFrame
	steps = [
		{"teleport": "speed_start", "t": 0.6, "yaw": 0, "pitch": -60, "view_tp": false, "slot": 0},
		{"t": 1.0, "buttons": F.B_CROUCH, "pitch": -60, "shot": "01_fp_crouch_look_down"},
		{"t": 1.0, "buttons": F.B_CROUCH, "pitch": -80, "shot": "02_fp_crouch_look_down_far"},
		{"t": 1.0, "move": Vector2(0, 1), "buttons": F.B_CROUCH, "pitch": -70, "shot": "03_fp_crouch_walk_down"},
		{"t": 1.2, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "pitch": -65, "shot": "04_fp_sprint_look_down"},
		{"t": 0.13, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "pitch": -75, "shot": "05_fp_sprint_look_down_b"},
		# Gun while moving.
		{"teleport": "speed_start", "t": 1.0, "yaw": 0, "pitch": -3, "slot": 1},
		{"t": 1.0, "move": Vector2(0, 1), "slot": 1, "shot": "06_fp_gun_walk_a"},
		{"t": 0.3, "move": Vector2(0, 1), "slot": 1, "shot": "07_fp_gun_walk_b"},
		{"t": 1.0, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "slot": 1, "shot": "08_fp_gun_sprint"},
		{"t": 0.17, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "slot": 1, "shot": "09_fp_gun_sprint_b"},
		{"t": 0.6, "move": Vector2(0, 1), "slot": 1, "yaw_rate": 120, "shot": "10_fp_gun_turning"},
		{"t": 0.6, "slot": 0},
		# Holding props.
		{"call": func() -> void: _face("Crate5kg"), "t": 0.4, "view_tp": false},
		{"t": 0.15, "target": "Crate5kg", "tap": F.B_GRAB},
		{"t": 1.0, "pitch": -15, "shot": "11_fp_hold_5kg"},
		{"t": 0.8, "pitch": -60, "shot": "12_fp_hold_5kg_look_down"},
		{"call": func() -> void: _close(true), "t": 0.8, "view_tp": true, "yaw": 140, "pitch": -12, "shot": "13_tp_hold_5kg"},
		{"t": 0.05, "tap": F.B_DROP},
		{"call": func() -> void:
			_close(false)
			_face("Crate20kg"), "t": 0.4, "view_tp": false, "yaw": 0},
		{"t": 0.15, "target": "Crate20kg", "tap": F.B_GRAB},
		{"t": 1.0, "pitch": -25, "shot": "14_fp_carry_20kg"},
		{"call": func() -> void: _close(true), "t": 0.8, "view_tp": true, "yaw": 130, "pitch": -12, "shot": "15_tp_carry_20kg"},
		{"t": 0.6, "yaw": 230, "shot": "16_tp_carry_20kg_other_side"},
		{"t": 0.05, "tap": F.B_DROP},
		{"call": func() -> void: _close(false), "t": 0.2},
	]


func _rig() -> UltraCameraRig:
	return get_tree().root.find_children("*", "UltraCameraRig", true, false)[0] as UltraCameraRig


func _close(on: bool) -> void:
	var cp := _rig().cam_profile
	if not has_meta("tp0"):
		set_meta("tp0", cp.tp_distance)
	cp.tp_distance = 1.4 if on else float(get_meta("tp0"))


func _face(n: String) -> void:
	var t := main.map.find_child(n, true, false) as Node3D
	var p: Vector3 = t.global_position + Vector3(0, 0, 1.0)
	main.player.teleport(Vector3(p.x, 0.06, p.z), 0.0)
	_bot.live_yaw = 0.0


func _drive(tick: int, src: BotInputSource) -> InputFrame:
	var f := super._drive(tick, src)
	if _i < steps.size() and steps[_i].has("target"):
		var o: Node = main.map.find_child(String(steps[_i]["target"]), true, false)
		if o:
			var no := o.find_child("NetObject", false, false) as NetObject
			f.target_id = no.net_id if no else 0
	return f
