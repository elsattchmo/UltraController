extends UltraTour
## Review tour: the rope (taut above the hands while swinging, the tail hanging free, knocked by
## a walker), the gun stowed on the hip while climbing, and the first-person get-up view.

const Id := MotorState.Id


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/rope_review")
	var F := InputFrame
	steps = [
		# Swing rope: catch it and pump, side-ish view.
		{"call": func() -> void: _close(true), "teleport": "parkour_rope", "t": 0.5, "yaw": 0, "pitch": 0, "view_tp": true},
		{"t": 4.0, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "jump_near_z": -55.4, "until": func() -> bool: return _st().state == Id.ROPE, "after": 0.4},
		{"t": 3.0, "pump": true},
		{"t": 0.05, "pump": true, "yaw": 40, "pitch": 10},
		{"t": 2.0, "pump": true, "until": func() -> bool: return _st().vel.z < -3.0, "after": 0.0, "shot": "01_tp_swing_forward"},
		{"t": 2.0, "pump": true, "until": func() -> bool: return _st().vel.z > 3.0, "after": 0.0, "shot": "02_tp_swing_back"},
		{"t": 0.5, "view_tp": false, "yaw": 0, "pitch": 70, "shot": "03_fp_rope_up"},
		{"t": 0.4, "pitch": -60, "shot": "04_fp_rope_tail_down"},
		{"t": 0.1, "tap": F.B_JUMP},
		{"t": 0.6, "view_tp": true, "yaw": 180, "pitch": 5, "shot": "05_tp_rope_after_letting_go"},
		# Ladder with the pistol drawn: it goes on the hip.
		{"teleport": "parkour_ladder", "t": 1.0, "yaw": 0, "pitch": 0, "view_tp": true, "slot": 1},
		{"t": 4.0, "move": Vector2(0, 1), "slot": 1, "until": func() -> bool: return _st().state == Id.LADDER, "after": 0.8},
		{"t": 0.4, "move": Vector2(0, 1), "slot": 1, "yaw": 50, "pitch": 0, "shot": "06_tp_ladder_gun_on_hip"},
		{"t": 0.1, "slot": 1, "tap": F.B_JUMP},
		{"t": 2.0, "slot": 0},
		# First-person get-up off the face.
		{"call": func() -> void: _close(false), "teleport": "speed_start", "t": 0.6, "yaw": 180, "pitch": 0, "view_tp": false},
		{"call": func() -> void: main.player.knock_down(Vector3(0, 2.0, 6.0)), "t": 4.0,
			"until": func() -> bool: return _st().state == Id.GET_UP, "after": 0.2, "shot": "07_fp_getup_a"},
		{"t": 0.5, "shot": "08_fp_getup_b"},
		{"t": 0.5, "shot": "09_fp_getup_c"},
		{"t": 0.5, "shot": "10_fp_getup_d"},
		{"t": 0.6, "shot": "11_fp_getup_e"},
		{"t": 1.0, "shot": "12_fp_up"},
	]


func _st() -> MotorState:
	return main.player.state


func _close(on: bool) -> void:
	var rig := get_tree().root.find_children("*", "UltraCameraRig", true, false)[0] as UltraCameraRig
	var cp := rig.cam_profile
	if not has_meta("tp0"):
		set_meta("tp0", cp.tp_distance)
	cp.tp_distance = 3.2 if on else float(get_meta("tp0"))


func _drive(tick: int, src: BotInputSource) -> InputFrame:
	var f := super._drive(tick, src)
	if _i < 0 or _i >= steps.size():
		return f
	var s: Dictionary = steps[_i]
	if s.has("jump_near_z") and _st().pos.z < float(s["jump_near_z"]) and _st().is_grounded():
		f.buttons |= InputFrame.B_JUMP
	if s.get("pump", false):
		f.move = Vector2(0, 1.0 if _st().vel.z < 0.0 else -1.0)
		f.pitch = 0.0
	return f
