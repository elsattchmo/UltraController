extends "res://demo/tours/sinew_review.gd"
## Review tour for 8-way movement and direction changes on Sinew's gait: facing fixed, the stick goes
## forward, right, back, left, the diagonals, then sharp reversals. Filmed from a high three-quarter view.
##   godot --path . --resolution 1280x720 -- --tour=sinew_8way_review --controller=sinew --out=<dir>


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/sinew_8way_review")
	_from = Vector3(2.6, 2.4, 2.6)
	steps = [
		{"teleport": "speed_start", "t": 0.6, "yaw": 0, "pitch": -4, "view_tp": true, "slot": 0},
		{"call": _setup, "t": 2.0, "shot": "stand"},
	]
	var dirs := [["fwd", Vector2(0, 1)], ["right", Vector2(1, 0)], ["back", Vector2(0, -1)], ["left", Vector2(-1, 0)],
			["fwd_right", Vector2(0.7, 0.7)], ["back_left", Vector2(-0.7, -0.7)]]
	for d in dirs:
		steps.append({"t": 0.8, "move": d[1], "yaw": 0})
		for k in 3:
			steps.append({"t": 0.12, "move": d[1], "yaw": 0, "shot": "%s_%d" % [d[0], k]})
	# Reversals: forward, then straight back; right, then straight left.
	steps += [
		{"t": 1.0, "move": Vector2(0, 1), "yaw": 0},
		{"t": 0.1, "move": Vector2(0, -1), "yaw": 0, "shot": "rev_fb_0"},
		{"t": 0.1, "move": Vector2(0, -1), "yaw": 0, "shot": "rev_fb_1"},
		{"t": 0.1, "move": Vector2(0, -1), "yaw": 0, "shot": "rev_fb_2"},
		{"t": 0.8, "move": Vector2(1, 0), "yaw": 0},
		{"t": 0.1, "move": Vector2(-1, 0), "yaw": 0, "shot": "rev_lr_0"},
		{"t": 0.1, "move": Vector2(-1, 0), "yaw": 0, "shot": "rev_lr_1"},
		{"t": 0.1, "move": Vector2(-1, 0), "yaw": 0, "shot": "rev_lr_2"},
		{"t": 1.0, "move": Vector2.ZERO, "yaw": 0, "shot": "settled"},
	]
