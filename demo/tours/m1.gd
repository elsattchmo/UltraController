extends UltraTour
## M1 review tour: full-body first person, locomotion gaits, third person, crouch/crawl, jump.


func _build() -> void:
	var F := InputFrame
	steps = [
		{"teleport": "speed_start", "t": 1.2, "pitch": -5},
		{"t": 0.6, "pitch": -72, "shot": "01_fp_look_down_idle"},
		{"t": 1.4, "move": Vector2(0, 0.5), "pitch": -55, "shot": "02_fp_look_down_walk"},
		{"t": 1.6, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "pitch": -8, "shot": "03_fp_sprint"},
		{"t": 1.2, "move": Vector2.ZERO, "pitch": -40, "shot": "04_fp_stop"},
		{"teleport": "speed_start", "t": 0.8, "view_tp": true, "pitch": -12},
		{"t": 0.6, "shot": "05_tp_idle"},
		{"t": 1.3, "move": Vector2(0, 0.4), "shot": "06_tp_walk"},
		{"t": 1.3, "move": Vector2(0, 1), "shot": "07_tp_jog"},
		{"t": 1.6, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "shot": "08_tp_sprint"},
		{"t": 0.25, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "tap": F.B_JUMP, "shot": "09_tp_jump"},
		{"t": 1.5, "move": Vector2(0, 0)},
		{"t": 1.2, "move": Vector2(1, 0), "shot": "10_tp_strafe_right"},
		{"t": 1.2, "move": Vector2(0, -1), "shot": "11_tp_backpedal"},
		{"t": 1.6, "move": Vector2(0, 1), "buttons": F.B_SPRINT},
		{"t": 0.35, "move": Vector2(0, 1), "buttons": F.B_SPRINT | F.B_CROUCH, "shot": "11b_tp_slide"},
		{"t": 1.0, "buttons": F.B_CROUCH, "shot": "12_tp_crouch_idle"},
		{"t": 1.4, "move": Vector2(0, 1), "buttons": F.B_CROUCH, "shot": "13_tp_crouch_walk"},
		{"t": 1.4, "move": Vector2(0, 1), "buttons": F.B_CROUCH | F.B_CRAWL, "shot": "14_tp_crawl"},
		{"teleport": "stairs_20", "t": 0.6, "pitch": -15},
		{"t": 2.4, "move": Vector2(0, 0.6), "shot": "15_tp_stairs"},
		{"teleport": "drop_6", "t": 0.5, "view_tp": false, "pitch": -20},
		{"t": 0.9, "move": Vector2(0, 1), "shot": "16_fp_drop_edge"},
		{"t": 1.6, "move": Vector2.ZERO, "shot": "17_fp_after_land"},
		{"teleport": "gallery", "view_tp": true, "t": 1.5, "pitch": -10, "shot": "18_gallery"},
	]
