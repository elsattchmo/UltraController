extends UltraTour
## Review: backpedalling on the diagonals and strafing, first and third person.


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/backwalk")
	steps = []
	for cfg: Array in [["back_diag_r", Vector2(0.7071, -0.7071)], ["back_diag_l", Vector2(-0.7071, -0.7071)], ["back", Vector2(0, -1)], ["strafe_r", Vector2(1, 0)]]:
		steps.append({"teleport": "speed_end", "t": 0.5, "yaw": 180, "pitch": -55, "view_tp": false, "slot": 0})
		steps.append({"t": 1.2, "move": cfg[1]})
		for k in 3:
			steps.append({"t": 0.2, "move": cfg[1], "shot": "%s_fp_%d" % [cfg[0], k]})
		steps.append({"t": 0.4, "move": cfg[1], "view_tp": true, "pitch": -12, "yaw": 120})
		for k in 3:
			steps.append({"t": 0.22, "move": cfg[1], "shot": "%s_tp_%d" % [cfg[0], k]})
