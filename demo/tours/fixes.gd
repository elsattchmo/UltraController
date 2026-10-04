extends UltraTour
## Review tour for play-test fixes: hands on the pistol (FP / TP close), the reload, carrying,
## rope climbing, floating props + splash, a leg cut off, a big fall.

const Id := MotorState.Id
const R := UltraLimbs.Region


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/fixes")
	var F := InputFrame
	steps = [
		{"teleport": "range", "t": 0.5, "yaw": 180, "pitch": -5, "view_tp": false, "slot": 1},
		{"t": 1.2, "slot": 1, "shot": "01_fp_pistol_hip"},
		{"t": 0.8, "slot": 1, "buttons": F.B_SECONDARY, "shot": "02_fp_pistol_ads"},
		{"call": func() -> void: main.player.state.mag = 2, "t": 0.05, "slot": 1},
		{"t": 0.05, "slot": 1, "tap": F.B_RELOAD},
		{"t": 0.45, "slot": 1, "shot": "03_fp_reload_a"},
		{"t": 0.45, "slot": 1, "shot": "04_fp_reload_b"},
		{"t": 0.45, "slot": 1, "shot": "05_fp_reload_c"},
		{"t": 1.0, "slot": 1},
		{"call": func() -> void: _close(true), "t": 0.6, "slot": 1, "view_tp": true, "yaw": 135, "pitch": -12, "shot": "06_tp_close_pistol"},
		{"t": 0.8, "slot": 1, "yaw": 220, "pitch": -12, "shot": "07_tp_close_pistol_left_side"},
		{"call": func() -> void: main.player.state.mag = 2, "t": 0.05, "slot": 1},
		{"t": 0.05, "slot": 1, "tap": F.B_RELOAD},
		{"t": 0.45, "slot": 1, "shot": "08_tp_reload_a"},
		{"t": 0.45, "slot": 1, "shot": "09_tp_reload_b"},
		{"t": 0.45, "slot": 1, "shot": "10_tp_reload_c"},
		{"t": 1.0, "slot": 0},
		# Carrying a crate.
		{"call": func() -> void:
			_close(false)
			_face("Crate5kg"), "t": 0.4, "view_tp": false, "slot": 0},
		{"t": 0.05, "target": "Crate5kg", "tap": F.B_GRAB},
		{"t": 1.0, "pitch": -15, "shot": "11_fp_hold_crate"},
		{"call": func() -> void: _close(true), "t": 0.8, "view_tp": true, "yaw": 160, "pitch": -10, "shot": "12_tp_hold_crate"},
		{"t": 0.05, "tap": F.B_DROP},
		# Rope climb.
		{"call": func() -> void:
			_close(false)
			var r := main.map.find_child("ClimbRope6", true, false) as UltraRope
			main.player.teleport(r.anchor() + Vector3.DOWN * 4.6, 0.0)
			main.player.state.state = Id.FALL, "t": 0.4, "view_tp": true, "yaw": 30, "pitch": 5},
		{"t": 0.7, "move": Vector2(0, 1), "shot": "13_tp_rope_climb_a"},
		{"t": 0.3, "move": Vector2(0, 1), "shot": "14_tp_rope_climb_b"},
		{"t": 0.6, "move": Vector2(0, 1), "view_tp": false, "pitch": 55, "shot": "15_fp_rope_climb"},
		# Floating props and a dive splash.
		{"teleport": "pool_deep_side", "t": 1.2, "yaw": -90, "pitch": -18, "view_tp": true, "shot": "16_tp_floating_props"},
		{"teleport": "dive_tower", "t": 0.5, "yaw": 0, "pitch": -25, "view_tp": true},
		{"t": 4.0, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "until": func() -> bool: return _st().state == Id.SWIM, "after": 0.1, "shot": "17_tp_splash"},
		{"t": 0.35, "shot": "18_tp_splash_ring"},
		# Leg cut off: straight to the crawl.
		{"teleport": "booth", "t": 0.6, "yaw": 180, "pitch": -12, "view_tp": true, "move": Vector2.ZERO},
		{"call": func() -> void: _booth(5), "t": 1.2, "shot": "19_tp_leg_cut_down"},
		{"t": 1.2, "shot": "20_tp_leg_cut_getting_up"},
		{"t": 1.5, "shot": "21_tp_leg_cut_crawl"},
		{"call": func() -> void: _booth(7), "t": 0.3},
		# A big fall: ragdoll and back up.
		{"teleport": "dive_tower", "t": 0.4, "yaw": 180, "pitch": -20, "view_tp": true},
		{"call": func() -> void: main.player.teleport(Vector3(36, 13, 3), PI), "t": 0.1},
		{"t": 3.0, "until": func() -> bool: return _st().state == Id.RAGDOLL, "after": 0.4, "shot": "22_tp_big_fall_ragdoll"},
		{"t": 1.6, "shot": "23_tp_big_fall_getting_up"},
		{"t": 1.4, "shot": "24_tp_big_fall_up"},
	]


func _st() -> MotorState:
	return main.player.state


func _rig() -> UltraCameraRig:
	return get_tree().root.find_children("*", "UltraCameraRig", true, false)[0] as UltraCameraRig


func _close(on: bool) -> void:
	var cp := _rig().cam_profile
	if not has_meta("tp0"):
		set_meta("tp0", cp.tp_distance)
	cp.tp_distance = 1.3 if on else float(get_meta("tp0"))


func _face(n: String) -> void:
	var t := main.map.find_child(n, true, false) as Node3D
	var p: Vector3 = t.global_position + Vector3(0, 0, 1.2)
	main.player.teleport(Vector3(p.x, 0.06, p.z), 0.0)
	_bot.live_yaw = 0.0


func _booth(i: int) -> void:
	var p: Node = main.map.find_child("Booth", true, false)
	if p:
		p.call("_act", i)


func _drive(tick: int, src: BotInputSource) -> InputFrame:
	var f := super._drive(tick, src)
	if _i < steps.size() and steps[_i].has("target"):
		var o: Node = main.map.find_child(String(steps[_i]["target"]), true, false)
		if o:
			var no := o.find_child("NetObject", false, false) as NetObject
			f.target_id = no.net_id if no else 0
	return f
