extends UltraTour
## M6 review tour: mantle, ledge hang + climb-up, vault, ladder, shimmy, rope swing.

const Id := MotorState.Id


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/m6")
	var F := InputFrame
	var hop := func(marker: String, tp: bool, buttons := 0) -> Array:
		return [
			{"teleport": marker, "t": 0.6, "yaw": 0, "pitch": -10 if tp else -25, "view_tp": tp},
			{"t": 3.0, "move": Vector2(0, 1), "buttons": buttons, "until": func() -> bool: return _st().pos.z < -27.3},
			{"t": 0.05, "move": Vector2(0, 1), "buttons": buttons, "tap": F.B_JUMP},
		]
	steps = []
	# 1 m wall: mantle, third and first person
	steps += hop.call("ledge_100", true)
	steps += [{"t": 2.0, "move": Vector2(0, 1), "until": func() -> bool: return _st().state == Id.MANTLE, "after": 0.25, "shot": "01_tp_mantle"}]
	steps += hop.call("ledge_100", false)
	steps += [{"t": 2.0, "move": Vector2(0, 1), "until": func() -> bool: return _st().state == Id.MANTLE, "after": 0.2, "shot": "02_fp_mantle"}]
	# 2 m wall: grab, hang, climb up
	steps += hop.call("ledge_200", true)
	steps += [
		{"t": 2.0, "until": func() -> bool: return _st().state == Id.LEDGE_HANG, "after": 0.6, "pitch": 15, "shot": "03_tp_ledge_hang"},
		{"t": 2.0, "move": Vector2(0, 1), "until": func() -> bool: return _st().state == Id.LEDGE_CLIMB, "after": 0.35, "shot": "04_tp_ledge_climb"},
	]
	steps += hop.call("ledge_200", false)
	steps += [
		{"t": 2.0, "until": func() -> bool: return _st().state == Id.LEDGE_HANG, "after": 0.6, "pitch": 30, "shot": "05_fp_ledge_hang"},
		{"t": 2.0, "move": Vector2(0, 1), "until": func() -> bool: return _st().state == Id.LEDGE_CLIMB, "after": 0.4, "pitch": 0, "shot": "06_fp_ledge_climb"},
	]
	# vault the box on the parkour run
	steps += [
		{"teleport": "parkour_start", "t": 0.6, "yaw": 0, "pitch": -8, "view_tp": true},
		{"t": 4.0, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "until": func() -> bool: return _st().pos.z < -14.4},
		{"t": 0.05, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "tap": F.B_JUMP},
		{"t": 1.0, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "until": func() -> bool: return _st().state == Id.VAULT, "after": 0.18, "shot": "07_tp_vault"},
		# ladder
		{"teleport": "parkour_ladder", "t": 0.6, "yaw": 0, "pitch": 5},
		{"t": 6.0, "move": Vector2(0, 1), "until": func() -> bool: return _st().state == Id.LADDER and _st().pos.y > 2.0, "shot": "08_tp_ladder"},
		{"t": 0.6, "view_tp": false, "pitch": 40, "move": Vector2(0, 1), "shot": "09_fp_ladder_look_up"},
		{"t": 6.0, "move": Vector2(0, 1), "until": func() -> bool: return _st().state == Id.LEDGE_CLIMB, "after": 0.3, "pitch": 0, "shot": "10_fp_ladder_top_out"},
		# rope swing off the tower
		{"teleport": "parkour_rope", "t": 0.6, "yaw": 0, "pitch": -5, "view_tp": true},
		{"t": 3.0, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "until": func() -> bool: return _st().pos.z < -55.4},
		{"t": 0.05, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "tap": F.B_JUMP},
		{"t": 2.0, "move": Vector2(0, 1), "until": func() -> bool: return _st().state == Id.ROPE, "after": 0.5, "shot": "11_tp_rope_catch"},
		{"t": 1.0, "move": Vector2(0, 1), "shot": "12_tp_rope_swing"},
		{"t": 0.8, "view_tp": false, "pitch": 50, "move": Vector2(0, -1), "shot": "13_fp_rope_look_up"},
	]


func _st() -> MotorState:
	return main.player.state
