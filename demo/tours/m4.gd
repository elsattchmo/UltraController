extends UltraTour
## M4 review tour: pistol drawn, aim down sights, fire, reload, holster (FP + TP).


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/m4")
	var F := InputFrame
	steps = [
		{"teleport": "speed_start", "t": 1.0, "pitch": 0, "slot": 0},
		{"t": 1.2, "slot": 1, "shot": "01_fp_pistol_drawn"},
		{"t": 0.8, "buttons": F.B_SECONDARY, "shot": "02_fp_ads"},
		{"t": 0.04, "buttons": F.B_SECONDARY | F.B_PRIMARY, "shot": "03_fp_ads_fire"},
		{"t": 0.5, "buttons": F.B_SECONDARY},
		{"t": 0.04, "buttons": F.B_PRIMARY, "shot": "04_fp_hip_fire"},
		{"t": 0.6},
		{"t": 1.0, "buttons": F.B_RELOAD, "shot": "05_fp_reload"},
		{"t": 1.6},
		{"t": 0.8, "pitch": -65, "shot": "06_fp_look_down_pistol"},
		{"t": 0.8, "view_tp": true, "pitch": -8},
		{"t": 0.6, "shot": "07_tp_pistol"},
		{"t": 0.05, "buttons": F.B_PRIMARY, "shot": "08_tp_fire"},
		{"t": 0.8, "buttons": F.B_SECONDARY, "shot": "09_tp_aim"},
		{"t": 1.0, "slot": 0, "shot": "10_tp_holstered"},
		{"t": 0.8, "yaw": 90, "pitch": -10, "shot": "10b_tp_holster_side"},
		{"t": 0.3, "yaw": 0},
		{"t": 1.4, "move": Vector2(0, 1), "slot": 1, "shot": "11_tp_jog_pistol"},
		{"teleport": "range", "view_tp": false, "t": 1.0, "slot": 1, "pitch": -3},
		{"t": 0.6, "buttons": F.B_SECONDARY, "shot": "12_range_ads"},
		{"t": 0.05, "buttons": F.B_SECONDARY | F.B_PRIMARY},
		{"t": 0.5, "buttons": F.B_SECONDARY, "shot": "13_range_target_down"},
		{"teleport": "range", "t": 0.6, "slot": 0, "yaw": 180, "pitch": -35, "shot": "14_pickup_prompt"},
		{"teleport": "key_tower", "view_tp": true, "t": 1.0, "pitch": -12, "shot": "15_key_tower"},
		{"teleport": "vault_door", "view_tp": false, "t": 1.0, "pitch": -5, "shot": "16_vault_locked_prompt"},
		{"call": func() -> void: UltraItems.give(main.player, &"key_red"), "t": 0.6, "shot": "17_vault_with_key"},
		{"call": func() -> void: _interact_vault(), "t": 1.5, "shot": "18_vault_open"},
		{"teleport": "puzzles", "view_tp": true, "t": 1.0, "yaw": 160, "pitch": -15, "shot": "19_puzzle_yard"},
		{"teleport": "levers", "view_tp": false, "t": 1.0, "yaw": 180, "pitch": -10, "shot": "20_levers"},
	]


func _interact_vault() -> void:
	var door := main.map.find_child("VaultDoor", true, false) as UltraDoor
	if door:
		door.interact(main.player)
