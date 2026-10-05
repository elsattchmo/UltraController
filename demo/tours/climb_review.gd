extends UltraTour
## Review tour for the second play-test round: hands gripping the ledge (hang + shimmy),
## hands and feet on ladder rungs, rope swing legs + climbing a swing rope, first-person
## strafing, the face-down get-up and the slide.

const Id := MotorState.Id


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/climb_review")
	var F := InputFrame
	steps = [
		# Ledge hang and shimmy.
		{"call": func() -> void: _close(true), "teleport": "parkour_shimmy", "t": 0.4, "yaw": 0, "pitch": 0, "view_tp": true},
		{"t": 3.0, "move": Vector2(0, 1), "jump_near_z": -44.9, "until": func() -> bool: return _st().state == Id.LEDGE_HANG, "after": 1.2},
		{"t": 0.6, "yaw": 25, "pitch": 15, "shot": "01_tp_hang_hands_behind_left"},
		{"t": 0.6, "yaw": -25, "pitch": 15, "shot": "02_tp_hang_hands_behind_right"},
		{"t": 0.6, "yaw": 70, "pitch": 5, "shot": "03_tp_hang_side"},
		{"t": 0.5, "yaw": 20, "pitch": 10, "move": Vector2(1, 0), "shot": "04_tp_shimmy_a"},
		{"t": 0.35, "move": Vector2(1, 0), "shot": "05_tp_shimmy_b"},
		{"t": 0.35, "move": Vector2(1, 0), "shot": "06_tp_shimmy_c"},
		{"t": 0.6, "view_tp": false, "yaw": 0, "pitch": 40, "shot": "07_fp_hang_hands"},
		{"t": 0.1, "tap": F.B_CROUCH},
		# Ladder.
		{"teleport": "parkour_ladder", "t": 0.4, "yaw": 0, "pitch": 0, "view_tp": true},
		{"t": 4.0, "move": Vector2(0, 1), "until": func() -> bool: return _st().state == Id.LADDER, "after": 1.0},
		{"t": 0.3, "move": Vector2(0, 1), "yaw": 60, "pitch": -5, "shot": "08_tp_ladder_side_a"},
		{"t": 0.25, "move": Vector2(0, 1), "shot": "09_tp_ladder_side_b"},
		{"t": 0.25, "move": Vector2(0, 1), "shot": "10_tp_ladder_side_c"},
		{"t": 0.5, "yaw": 0, "pitch": 15, "shot": "11_tp_ladder_behind_still"},
		{"t": 0.5, "view_tp": false, "yaw": 0, "pitch": 40, "shot": "12_fp_ladder_hands"},
		{"t": 0.1, "tap": F.B_JUMP},
		# Rope: swing, then climb by looking up.
		{"teleport": "parkour_rope", "t": 0.5, "yaw": 0, "pitch": 0, "view_tp": true},
		{"t": 4.0, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "jump_near_z": -55.4, "until": func() -> bool: return _st().state == Id.ROPE, "after": 0.3},
		{"t": 4.0, "pump": true, "yaw": 90, "pitch": 0},
		{"t": 3.0, "pump": true, "until": func() -> bool: return _st().vel.z < -2.5, "after": 0.0, "shot": "13_tp_swing_forward"},
		{"t": 3.0, "pump": true, "until": func() -> bool: return _st().vel.z > 2.5, "after": 0.0, "shot": "14_tp_swing_back"},
		{"t": 2.0, "until": func() -> bool: return absf(_st().vel.z) < 0.4, "shot": "15_tp_swing_top"},
		{"t": 0.8, "move": Vector2(0, 1), "yaw": 30, "pitch": 50, "shot": "16_tp_swing_rope_climb"},
		{"t": 0.6, "view_tp": false, "move": Vector2(0, 1), "yaw": 0, "pitch": 50, "shot": "17_fp_swing_rope_climb"},
		{"t": 0.1, "tap": F.B_JUMP},
		# First-person strafing, looking down at the legs.
		{"call": func() -> void: _close(false), "teleport": "speed_start", "t": 0.8, "yaw": 180, "pitch": -55, "view_tp": false},
		{"t": 0.35, "move": Vector2(1, 0), "shot": "18_fp_strafe_r_a"},
		{"t": 0.12, "move": Vector2(1, 0), "shot": "19_fp_strafe_r_b"},
		{"t": 0.12, "move": Vector2(1, 0), "shot": "20_fp_strafe_r_c"},
		{"t": 0.35, "move": Vector2(-1, 0), "shot": "21_fp_strafe_l_a"},
		{"t": 0.12, "move": Vector2(-1, 0), "shot": "22_fp_strafe_l_b"},
		{"call": func() -> void: _close(true), "t": 0.5, "move": Vector2(1, 0), "view_tp": true, "yaw": 0, "pitch": -10, "shot": "23_tp_strafe_r"},
		{"t": 0.6, "move": Vector2(-1, 0), "shot": "24_tp_strafe_l"},
		# Knocked onto the face, then up again (watch the head).
		{"teleport": "speed_start", "t": 0.6, "yaw": 180, "pitch": -15, "view_tp": true},
		{"call": func() -> void: main.player.knock_down(Vector3(0, 2.0, 6.0)), "t": 3.0,
			"until": func() -> bool: return _st().state == Id.GET_UP, "after": 0.3, "shot": "25_tp_getup_front_a"},
		{"t": 0.7, "yaw": 60, "shot": "26_tp_getup_front_b"},
		{"t": 0.7, "shot": "27_tp_getup_front_c"},
		{"t": 0.7, "shot": "28_tp_getup_front_d"},
		{"t": 1.5},
		# Slide.
		{"teleport": "speed_start", "t": 0.4, "yaw": 0, "pitch": -10, "view_tp": true},
		{"t": 1.5, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "yaw": 60},
		{"t": 2.0, "move": Vector2(0, 1), "buttons": F.B_SPRINT | F.B_CROUCH, "until": func() -> bool: return _st().state == Id.SLIDE, "after": 0.15, "shot": "29_tp_slide_a"},
		{"t": 0.25, "move": Vector2(0, 1), "buttons": F.B_SPRINT | F.B_CROUCH, "shot": "30_tp_slide_b"},
		{"t": 0.25, "move": Vector2(0, 1), "buttons": F.B_SPRINT | F.B_CROUCH, "shot": "31_tp_slide_c"},
		{"t": 0.25, "move": Vector2(0, 1), "buttons": F.B_SPRINT | F.B_CROUCH, "shot": "32_tp_slide_d"},
	]


func _st() -> MotorState:
	return main.player.state


func _close(on: bool) -> void:
	var rig := get_tree().root.find_children("*", "UltraCameraRig", true, false)[0] as UltraCameraRig
	var cp := rig.cam_profile
	if not has_meta("tp0"):
		set_meta("tp0", cp.tp_distance)
	cp.tp_distance = 1.6 if on else float(get_meta("tp0"))


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
