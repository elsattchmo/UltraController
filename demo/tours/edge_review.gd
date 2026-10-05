extends UltraTour
## Review tour: losing balance on a ledge's lip (teeter, topple), the limp with a hurt leg,
## shimmying both ways, a climbing rope swinging, carrying in third person.

const Id := MotorState.Id
const R := UltraLimbs.Region


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/edge_review")
	var F := InputFrame
	steps = [
		# Perched on the 1 m block's lip, seen from the side.
		{"call": func() -> void: _close(true), "teleport": "ledge_100", "t": 0.5, "yaw": 0, "pitch": -10, "view_tp": true},
		{"call": func() -> void: main.player.teleport(Vector3(65.17, 1.02, -30.0), 0.0), "t": 0.35, "yaw": 0, "shot": "01_tp_teeter_a"},
		{"t": 0.25, "shot": "02_tp_teeter_b"},
		{"t": 0.3, "shot": "03_tp_topple"},
		{"t": 0.5, "shot": "04_tp_fallen"},
		{"t": 3.5},
		# A hurt left leg: the limp, side view.
		{"teleport": "speed_start", "t": 0.5, "yaw": 0, "pitch": -10, "view_tp": true,
			"call": func() -> void: _hurt(R.THIGH_L, 30.0)},
		{"t": 1.2, "move": Vector2(0, 1), "yaw": 0},
		{"t": 0.4, "move": Vector2(0, 1), "yaw": 70, "shot": "05_tp_limp_a"},
		{"t": 0.35, "move": Vector2(0, 1), "shot": "06_tp_limp_b"},
		{"t": 0.35, "move": Vector2(0, 1), "shot": "07_tp_limp_c"},
		{"t": 0.35, "move": Vector2(0, 1), "shot": "08_tp_limp_d"},
		{"call": func() -> void: main.player.respawn(main.player.global_transform), "t": 0.3},
		# Shimmy both ways.
		{"teleport": "parkour_shimmy", "t": 0.4, "yaw": 0, "pitch": 0, "view_tp": true},
		{"t": 3.0, "move": Vector2(0, 1), "jump_near_z": -44.9, "until": func() -> bool: return _st().state == Id.LEDGE_HANG, "after": 1.0},
		{"t": 0.45, "yaw": 15, "pitch": 15, "move": Vector2(1, 0), "shot": "09_tp_shimmy_right_a"},
		{"t": 0.3, "move": Vector2(1, 0), "shot": "10_tp_shimmy_right_b"},
		{"t": 0.45, "move": Vector2(-1, 0), "shot": "11_tp_shimmy_left_a"},
		{"t": 0.3, "move": Vector2(-1, 0), "shot": "12_tp_shimmy_left_b"},
		{"t": 0.1, "tap": F.B_CROUCH},
		{"t": 1.0},
	]


func _st() -> MotorState:
	return main.player.state


func _hurt(region: int, amount: float) -> void:
	var d := UltraCombat.DamageInfo.new()
	d.amount = amount
	d.region = region
	d.kind = &"bullet"
	d.point = main.player.state.pos + Vector3.UP
	main.player.apply_damage(d)


func _close(on: bool) -> void:
	var rig := get_tree().root.find_children("*", "UltraCameraRig", true, false)[0] as UltraCameraRig
	var cp := rig.cam_profile
	if not has_meta("tp0"):
		set_meta("tp0", cp.tp_distance)
	cp.tp_distance = 2.2 if on else float(get_meta("tp0"))


func _drive(tick: int, src: BotInputSource) -> InputFrame:
	var f := super._drive(tick, src)
	if _i < 0 or _i >= steps.size():
		return f
	var s: Dictionary = steps[_i]
	if s.has("jump_near_z") and _st().pos.z < float(s["jump_near_z"]) and _st().is_grounded():
		f.buttons |= InputFrame.B_JUMP
	return f
