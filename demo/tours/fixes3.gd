extends UltraTour
## Review (first person): strafing looking down, knocked down / dying from the eye, and the
## poses that used to show the inside of the neck.

const Id := MotorState.Id


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/fixes3")
	var F := InputFrame
	steps = [
		{"teleport": "speed_start", "t": 0.6, "yaw": 0, "pitch": -60, "view_tp": false, "slot": 0},
		{"t": 1.2, "move": Vector2(1, 0), "pitch": -65},
		{"t": 0.15, "move": Vector2(1, 0), "pitch": -65, "shot": "01_fp_strafe_r_a"},
		{"t": 0.15, "move": Vector2(1, 0), "pitch": -65, "shot": "02_fp_strafe_r_b"},
		{"t": 0.15, "move": Vector2(1, 0), "pitch": -65, "shot": "03_fp_strafe_r_c"},
		{"t": 1.2, "move": Vector2(-0.7071, 0.7071), "pitch": -65},
		{"t": 0.2, "move": Vector2(-0.7071, 0.7071), "pitch": -65, "shot": "04_fp_diag_a"},
		{"t": 0.2, "move": Vector2(-0.7071, 0.7071), "pitch": -65, "shot": "05_fp_diag_b"},
		# Knocked down, first person.
		{"t": 0.5, "pitch": -5},
		{"call": func() -> void: main.player.knock_down(Vector3(0, 2.0, -6.0)), "t": 0.3, "shot": "06_fp_knocked"},
		{"t": 0.5, "shot": "07_fp_falling"},
		{"t": 1.0, "shot": "08_fp_lying"},
		{"t": 4.0, "until": func() -> bool: return main.player.state.state == Id.GET_UP, "after": 0.8, "shot": "09_fp_getting_up"},
		{"t": 0.3, "shot": "09b_fp_getting_up"},
		{"t": 1.0, "shot": "10_fp_getting_up_b"},
		{"t": 1.5, "shot": "11_fp_up"},
		# Dying, first person.
		{"call": func() -> void: _kill(), "t": 0.4, "shot": "12_fp_dying"},
		{"t": 1.2, "shot": "13_fp_dead"},
		{"t": 1.5, "shot": "14_fp_dead_b"},
		{"call": func() -> void: main.player.respawn(main.map.call("marker", "speed_start").global_transform), "t": 1.0, "pitch": 0},
		# Neck checks: crouch, crawl, sprint, swim, ledge hang, ladder - all looking down.
		{"t": 1.0, "buttons": F.B_CROUCH, "pitch": -85, "shot": "15_fp_crouch_down"},
		{"t": 1.0, "move": Vector2(0, 1), "buttons": F.B_CROUCH | F.B_CRAWL, "pitch": -80, "shot": "16_fp_crawl_down"},
		{"t": 1.0, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "pitch": -85, "shot": "17_fp_sprint_down"},
		{"teleport": "ledge_200", "t": 0.5, "yaw": 0, "pitch": 0},
		{"t": 3.0, "move": Vector2(0, 1), "until": func() -> bool: return main.player.state.pos.z < -27.3},
		{"t": 0.05, "move": Vector2(0, 1), "tap": F.B_JUMP},
		{"t": 2.0, "until": func() -> bool: return main.player.state.state == Id.LEDGE_HANG, "after": 0.6, "pitch": -80, "shot": "18_fp_hang_look_down"},
		{"teleport": "parkour_ladder", "t": 0.5, "yaw": 0, "pitch": 0},
		{"t": 4.0, "move": Vector2(0, 1), "until": func() -> bool: return main.player.state.state == Id.LADDER and main.player.state.pos.y > 2.0, "pitch": -80, "shot": "19_fp_ladder_look_down"},
		{"teleport": "pool_deep_side", "t": 0.4, "yaw": -90, "pitch": 0},
		{"t": 4.0, "move": Vector2(0, 1), "until": func() -> bool: return main.player.state.state == Id.SWIM, "after": 1.0, "pitch": -80, "shot": "20_fp_swim_look_down"},
	]


func _kill() -> void:
	var d := UltraCombat.DamageInfo.new()
	d.amount = 500.0
	d.region = UltraLimbs.Region.TORSO
	d.dir = Vector3(0, 0, 1)
	d.point = main.player.state.pos + Vector3.UP
	main.player.apply_damage(d)

