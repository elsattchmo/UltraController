extends UltraTour
## M7 review tour: wading, swimming (TP / FP), diving and the underwater look, the board,
## the tunnel and grotto, floating props, the river and the flooded cistern.

const Id := MotorState.Id


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/m7")
	var F := InputFrame
	steps = [
		# Shallow end -> deep end.
		{"teleport": "pool", "t": 0.6, "yaw": 180, "pitch": -12, "view_tp": true},
		{"t": 3.0, "move": Vector2(0, 1), "until": func() -> bool: return _st().pos.z > 72.0 and _st().is_grounded(), "after": 0.3, "shot": "01_tp_wading"},
		{"t": 6.0, "move": Vector2(0, 1), "until": func() -> bool: return _st().state == Id.SWIM, "after": 1.2, "shot": "02_tp_swim"},
		{"t": 1.0, "move": Vector2(0, 1), "view_tp": false, "pitch": -8, "shot": "03_fp_swim"},
		{"t": 1.0, "pitch": -45, "shot": "04_fp_swim_look_down"},
		# Dive.
		{"t": 1.6, "move": Vector2(0, 1), "pitch": -50, "view_tp": true},
		{"t": 0.8, "move": Vector2(0, 0.6), "pitch": -10, "shot": "05_tp_dive"},
		{"t": 1.0, "move": Vector2(0, 0.6), "view_tp": false, "pitch": 0, "shot": "06_fp_underwater"},
		{"t": 1.2, "pitch": 70, "shot": "07_fp_underwater_look_up"},
		# Off the 5 m board.
		{"teleport": "dive_tower", "t": 0.6, "yaw": 0, "pitch": -10, "view_tp": true},
		{"t": 2.0, "move": Vector2(0, 1), "until": func() -> bool: return _st().state == Id.FALL and _st().pos.y < 3.0, "shot": "08_tp_off_the_board"},
		{"t": 2.0, "until": func() -> bool: return _st().state == Id.SWIM, "after": 0.15, "shot": "09_tp_splashdown"},
		# Tunnel to the grotto.
		{"teleport": "tunnel", "t": 0.3, "yaw": -90, "pitch": 0, "view_tp": false},
		{"t": 0.1, "tap": F.B_CROUCH},
		{"t": 1.8, "move": Vector2(0, 1), "shot": "10_fp_tunnel"},
		{"teleport": "grotto", "t": 2.5, "yaw": -60, "pitch": -5, "view_tp": false, "shot": "11_fp_grotto_key"},
		{"t": 0.1, "view_tp": true, "yaw": -120, "pitch": -20},
		{"t": 1.0, "shot": "12_tp_grotto"},
		# Floats from the deck.
		{"teleport": "pool_deep_side", "t": 1.0, "yaw": -90, "pitch": -25, "view_tp": false, "shot": "13_fp_floating_props"},
		# River.
		{"teleport": "river", "t": 0.4, "yaw": 180, "pitch": -15, "view_tp": true},
		{"t": 3.0, "move": Vector2(0, 0.7), "until": func() -> bool: return _st().state == Id.SWIM, "after": 2.0, "shot": "14_tp_river_drift"},
		# Cistern: open the valve, wait for the flood.
		{"teleport": "cistern", "t": 0.5, "yaw": -90, "pitch": -25, "view_tp": true, "shot": "15_tp_cistern_dry"},
		{"call": func() -> void: (main.map.find_child("CisternWater", true, false) as UltraWater).set_on(true), "t": 9.0, "shot": "16_tp_cistern_flooded"},
	]


func _st() -> MotorState:
	return main.player.state
