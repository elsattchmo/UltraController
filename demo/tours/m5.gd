extends UltraTour
## M5 review tour: grab, carry, throw, team lift with the helper, seesaw.


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/m5")
	var F := InputFrame
	steps = [
		{"teleport": "sandbox", "t": 0.8, "pitch": -20, "yaw": 0},
		{"call": func() -> void: _face("Crate5kg"), "t": 0.4},
		{"t": 0.05, "target": "Crate5kg", "tap": F.B_GRAB},
		{"t": 1.0, "pitch": -10, "shot": "01_fp_hold_crate"},
		{"t": 1.2, "move": Vector2(0, 0.6), "pitch": -5, "shot": "02_fp_walk_holding"},
		{"t": 0.7, "buttons": F.B_THROW, "pitch": 0.25, "shot": "03_fp_charge"},
		{"t": 0.35, "pitch": 0.25, "shot": "04_fp_thrown"},
		{"teleport": "sandbox", "t": 0.5, "view_tp": true},
		{"call": func() -> void: _face("PlateCrateB"), "t": 0.4},
		{"t": 0.05, "target": "Crate20kg", "tap": F.B_GRAB},
		{"call": func() -> void: _face("Crate20kg"), "t": 0.1},
		{"t": 0.05, "target": "Crate20kg", "tap": F.B_GRAB},
		{"t": 1.0, "pitch": -12, "shot": "05_tp_carry_20kg"},
		{"t": 0.05, "tap": F.B_DROP},
		{"teleport": "team_beam", "t": 0.6, "view_tp": true, "pitch": -15},
		{"call": func() -> void: _team_setup(), "t": 0.5},
		{"t": 0.05, "target": "TeamBeam", "tap": F.B_GRAB},
		{"t": 2.5, "pitch": -15, "shot": "06_team_lift_alone"},
		{"call": func() -> void: main.toggle_companion(), "t": 5.0, "shot": "07_team_lift_with_helper"},
		{"t": 2.0, "move": Vector2(0, 0.6), "shot": "08_team_carry_walk"},
	]


func _node(n: String) -> Node3D:
	return main.map.find_child(n, true, false) as Node3D


func _face(n: String) -> void:
	var t := _node(n)
	var p: Vector3 = main.player.state.pos
	var d := Vector3(t.global_position.x, 0, t.global_position.z) - Vector3(p.x, 0, p.z)
	var yaw := atan2(-d.x, -d.z)
	main.player.teleport(t.global_position - d.normalized() * 1.2 + Vector3(0, 0.06 - t.global_position.y, 0), yaw)
	_bot.live_yaw = yaw


func _team_setup() -> void:
	var beam := _node("TeamBeam")
	var g := UltraGrab.grip_points(beam)[0].global_position
	main.player.teleport(Vector3(g.x - 0.55, 0.06, g.z), -PI * 0.5)
	_bot.live_yaw = -PI * 0.5


func _drive(tick: int, src: BotInputSource) -> InputFrame:
	var f := super._drive(tick, src)
	if _i < steps.size() and steps[_i].has("target"):
		var o := _node(String(steps[_i]["target"]))
		if o:
			var no := o.find_child("NetObject", false, false) as NetObject
			f.target_id = no.net_id if no else 0
	return f
