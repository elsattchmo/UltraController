extends UltraTour
## Review tour: 8-way locomotion (walk forward / diagonal / sideways / back, sprint) seen from
## the side and front in third person, and looking down at the legs in first person.

const Id := MotorState.Id


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/walk8_review")
	var F := InputFrame
	steps = [
		{"call": func() -> void: _close(true), "teleport": "speed_start", "t": 0.6, "yaw": 180, "pitch": -8, "view_tp": true, "slot": 0},
		{"t": 1.2, "move": Vector2(0, 1), "yaw": 180},
		{"t": 0.05, "move": Vector2(0, 1), "yaw_rate": 0, "shot": "01_tp_walk_fwd_back_view"},
		{"t": 0.3, "move": Vector2(0, 1), "shot": "02_tp_walk_fwd_b"},
		{"t": 1.0, "move": Vector2(1, 1), "shot": "03_tp_walk_diag_fr"},
		{"t": 1.0, "move": Vector2(1, 0), "shot": "04_tp_walk_right"},
		{"t": 0.3, "move": Vector2(1, 0), "shot": "05_tp_walk_right_b"},
		{"t": 1.0, "move": Vector2(-1, 0), "shot": "06_tp_walk_left"},
		{"t": 1.0, "move": Vector2(0, -1), "shot": "07_tp_walk_back"},
		{"t": 1.0, "move": Vector2(-1, -1), "shot": "08_tp_walk_back_left"},
		{"t": 1.5, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "shot": "09_tp_sprint"},
		{"t": 0.6},
		{"call": func() -> void: _close(false), "t": 0.5, "view_tp": false, "pitch": -60},
		{"t": 0.8, "move": Vector2(0, 1), "shot": "10_fp_walk_fwd_legs"},
		{"t": 0.8, "move": Vector2(1, 0), "shot": "11_fp_walk_right_legs"},
		{"t": 0.25, "move": Vector2(1, 0), "shot": "12_fp_walk_right_legs_b"},
		{"t": 0.8, "move": Vector2(-1, 1), "shot": "13_fp_walk_diag_fl_legs"},
		{"t": 0.8, "move": Vector2(0, -1), "shot": "14_fp_walk_back_legs"},
	]


func _close(on: bool) -> void:
	var rig := get_tree().root.find_children("*", "UltraCameraRig", true, false)[0] as UltraCameraRig
	var cp := rig.cam_profile
	if not has_meta("tp0"):
		set_meta("tp0", cp.tp_distance)
	cp.tp_distance = 2.6 if on else float(get_meta("tp0"))
