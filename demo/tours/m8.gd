extends UltraTour
## M8 review tour: the dummy yard, shooting a leg, a limping walker, a dangling arm, cut-off
## limbs with caps and gibs, knock-down ragdoll and get-up, and first person with a crippled
## arm and with the pistol in the off hand.

const R := UltraLimbs.Region
const Id := MotorState.Id


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/m8")
	var F := InputFrame
	steps = [
		{"teleport": "dummies", "t": 2.0, "yaw": 180, "pitch": -8, "view_tp": true, "shot": "01_tp_dummy_yard"},
		# Shoot Dummy B's left thigh from first person (pistol from the kit).
		{"t": 1.0, "view_tp": false, "slot": 1, "yaw": 180 - 0.7, "pitch": -5.7},
		{"t": 0.6, "slot": 1, "buttons": F.B_SECONDARY, "yaw": 180 - 0.7, "pitch": -5.7, "shot": "02_fp_ads_on_leg"},
		{"t": 0.05, "slot": 1, "buttons": F.B_SECONDARY, "tap": F.B_PRIMARY},
		{"t": 0.4, "slot": 1, "buttons": F.B_SECONDARY},
		{"t": 0.05, "slot": 1, "buttons": F.B_SECONDARY, "tap": F.B_PRIMARY},
		{"t": 0.8, "slot": 1, "buttons": F.B_SECONDARY, "shot": "03_fp_leg_crippled"},
		# A limping walker (hurt left leg) seen from the side.
		{"call": func() -> void: _hurt("Walker", R.THIGH_L, 40), "t": 0.1, "slot": 0},
		{"call": func() -> void: _place(Vector3(28.5, 0.1, 40.5), 90.0), "t": 2.5, "view_tp": true, "pitch": -6, "yaw": 90, "shot": "04_tp_walker_limps"},
		{"t": 0.45, "shot": "05_tp_walker_limps_b"},
		# Booth: cripple the left arm, cut off the right arm, cut off the left leg, knock down.
		{"teleport": "booth", "t": 0.6, "yaw": 180, "pitch": -10, "view_tp": true},
		{"call": func() -> void: _booth(2), "t": 1.2, "shot": "06_tp_booth_arm_dangles"},
		{"call": func() -> void: _booth(4), "t": 0.5, "shot": "07_tp_booth_arm_cut"},
		{"t": 1.5, "pitch": -25, "shot": "08_tp_stump_and_gib"},
		{"call": func() -> void: _booth(5), "t": 0.35, "pitch": -15, "shot": "09_tp_leg_cut_falls"},
		{"t": 2.4, "shot": "10_tp_down_ragdoll"},
		{"t": 2.0, "shot": "11_tp_crawls_after"},
		{"call": func() -> void: _booth(7), "t": 1.0},
		{"call": func() -> void: _place(Vector3(19.5, 0.1, 47.2), 90.0), "t": 0.8, "yaw": 90, "pitch": -12},
		{"call": func() -> void: _booth(6), "t": 0.35, "shot": "12_tp_knockdown"},
		{"t": 0.7, "shot": "13_tp_falling"},
		{"t": 0.9, "shot": "13b_tp_down"},
		{"t": 0.6, "shot": "14_tp_getting_up"},
		{"t": 1.2, "shot": "14b_tp_up_again"},
		# First person: crippled left arm hangs; then right arm out, pistol in the left hand.
		{"teleport": "dummies", "t": 0.4, "yaw": 180, "view_tp": false, "pitch": -45, "slot": 0},
		{"call": func() -> void: main.player.state.limb_hp[R.ARM_L] = 0, "t": 1.5, "yaw": 196, "pitch": -74, "shot": "15_fp_arm_dangles"},
		{"t": 1.2, "view_tp": true, "yaw": 120, "pitch": -12, "move": Vector2(0, 0.5), "shot": "15b_tp_arm_dangles_walking"},
		{"t": 0.3, "view_tp": false, "yaw": 180},
		{"call": func() -> void:
			main.player.state.limb_hp[R.ARM_L] = 100
			main.player.state.limb_hp[R.FOREARM_R] = 0, "t": 1.4, "slot": 1, "pitch": -4, "shot": "16_fp_left_handed_hip"},
		{"t": 0.8, "slot": 1, "buttons": F.B_SECONDARY, "pitch": -4, "shot": "17_fp_left_handed_ads"},
		{"t": 0.6, "slot": 1, "view_tp": true, "pitch": -10, "yaw": 150, "shot": "18_tp_left_handed"},
	]


func _post(n: String) -> Node:
	return main.map.find_child(n, true, false)


func _dummy(n: String) -> UltraCharacter:
	var p := _post(n)
	return UltraNet.world.character(int(p.get("bot_id"))) if p else null


func _hurt(n: String, region: int, pct: int) -> void:
	var c := _dummy(n)
	if c:
		c.state.limb_hp[region] = pct


func _booth(i: int) -> void:
	var p := _post("Booth")
	if p:
		p.call("_act", i)


func _place(at: Vector3, yaw_deg: float) -> void:
	main.player.teleport(at, deg_to_rad(yaw_deg))
	_bot.live_yaw = deg_to_rad(yaw_deg)
