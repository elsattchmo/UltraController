extends UltraTour
## Review tour: everyday moves frame by frame in third person - a standing jump, a running
## jump, a dodge roll and drops from 2 m and 4 m (landing animation, no sinking into the floor).
##   godot --path . --resolution 1280x720 -- --tour=moves_review --out=C:/Dev/verify/ultra/review/moves_review


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/moves_review")
	var F := InputFrame
	steps = [
		{"teleport": "speed_start", "t": 1.0, "yaw": 0, "pitch": -10, "view_tp": true, "slot": 0},
		{"t": 0.12, "tap": F.B_JUMP, "shot": "01_jump_takeoff"},
		{"t": 0.2, "shot": "02_jump_up"},
		{"t": 0.2, "shot": "03_jump_top"},
		{"t": 0.2, "shot": "04_jump_down"},
		{"t": 0.08, "shot": "05_jump_land"},
		{"t": 0.12, "shot": "06_jump_land_b"},
		{"t": 0.6},
		{"t": 0.8, "move": Vector2(0, 1), "buttons": F.B_SPRINT},
		{"t": 0.12, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "tap": F.B_JUMP, "shot": "07_run_jump_takeoff"},
		{"t": 0.25, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "shot": "08_run_jump_air"},
		{"t": 0.25, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "shot": "09_run_jump_down"},
		{"t": 0.12, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "shot": "10_run_jump_land"},
		{"t": 0.8},
		{"t": 0.6, "move": Vector2(0, 1)},
		{"t": 0.12, "move": Vector2(0, 1), "tap": F.B_DODGE, "shot": "11_roll_a"},
		{"t": 0.15, "move": Vector2(0, 1), "shot": "12_roll_b"},
		{"t": 0.15, "move": Vector2(0, 1), "shot": "13_roll_c"},
		{"t": 0.15, "move": Vector2(0, 1), "shot": "14_roll_d"},
		{"t": 0.2, "move": Vector2(0, 1), "shot": "15_roll_e"},
		{"t": 1.0},
		{"teleport": "drop_2", "t": 1.0, "yaw": 0, "pitch": -15},
		{"t": 0.6, "move": Vector2(0, 1), "shot": "16_drop2_off"},
		{"t": 0.2, "move": Vector2(0, 1), "shot": "17_drop2_land"},
		{"t": 0.15, "move": Vector2(0, 1), "shot": "18_drop2_land_b"},
		{"teleport": "drop_4", "t": 1.0, "yaw": 0, "pitch": -15},
		{"t": 0.75, "move": Vector2(0, 1), "shot": "19_drop4_air"},
		{"t": 0.2, "move": Vector2(0, 1), "shot": "20_drop4_land"},
		{"t": 0.2, "move": Vector2(0, 1), "shot": "21_drop4_land_b"},
	]
