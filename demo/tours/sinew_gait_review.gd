extends "res://demo/tours/sinew_review.gd"
## Review tour for Sinew's procedural walk (S6c), filmed side on: standing, walking, a stop, jogging,
## sprinting, turning on the spot, walking up the stairs. Frames in slow motion where the feet matter.
##   godot --path . --resolution 1280x720 -- --tour=sinew_gait_review --controller=sinew --out=<dir>


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/sinew_gait_review")
	_from = Vector3(3.2, 1.0, 0.0)
	steps = [
		{"teleport": "speed_start", "t": 0.6, "yaw": 0, "pitch": -4, "view_tp": true, "slot": 0},
		{"call": _setup, "t": 2.0, "shot": "stand"},
		{"t": 1.5, "move": Vector2(0, 0.5), "yaw": 0},
		{"call": _slow.bind(true), "t": 0.0, "move": Vector2(0, 0.5), "yaw": 0},
	]
	for k in 6:
		steps.append({"t": 0.08, "move": Vector2(0, 0.5), "yaw": 0, "shot": "walk_%d" % k})
	steps += [
		{"call": _slow.bind(false), "t": 1.5, "move": Vector2.ZERO, "yaw": 0, "shot": "stopped"},
		{"t": 1.5, "move": Vector2(0, 1), "yaw": 0},
		{"call": _slow.bind(true), "t": 0.0, "move": Vector2(0, 1), "yaw": 0},
	]
	for k in 6:
		steps.append({"t": 0.06, "move": Vector2(0, 1), "yaw": 0, "shot": "fast_walk_%d" % k})
	steps += [
		{"call": _slow.bind(false), "t": 1.5, "move": Vector2(0, 1), "buttons": InputFrame.B_SPRINT, "yaw": 0},
		{"call": _slow.bind(true), "t": 0.0, "move": Vector2(0, 1), "buttons": InputFrame.B_SPRINT, "yaw": 0},
	]
	for k in 6:
		steps.append({"t": 0.05, "move": Vector2(0, 1), "buttons": InputFrame.B_SPRINT, "yaw": 0, "shot": "sprint_%d" % k})
	steps += [
		{"call": _slow.bind(false), "t": 2.0, "move": Vector2.ZERO, "yaw": 0, "shot": "sprint_stop"},
		{"t": 0.25, "yaw": 30, "shot": "turn_0"},
		{"t": 0.25, "yaw": 60, "shot": "turn_1"},
		{"t": 0.25, "yaw": 90, "shot": "turn_2"},
		{"t": 1.2, "yaw": 90, "shot": "turned"},
	]
