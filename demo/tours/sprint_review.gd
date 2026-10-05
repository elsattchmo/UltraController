extends UltraTour
## Review tour: the sprint cycle side on (a camera kept beside the runner), a strip of frames
## through one stride.
##   godot --path . --resolution 1280x720 -- --tour=sprint_review --out=C:/Dev/verify/ultra/review/sprint_review

var _cam: Camera3D


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/sprint_review")
	var F := InputFrame
	steps = [
		{"teleport": "speed_start", "t": 1.0, "yaw": 0, "pitch": -5, "view_tp": true, "slot": 0},
		{"t": 1.6, "move": Vector2(0, 1), "buttons": F.B_SPRINT},
	]
	for k in 8:
		steps.append({"call": _beside, "t": 0.06, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "shot": "%02d_sprint" % k})


func _beside() -> void:
	if _cam == null:
		_cam = Camera3D.new()
		main.add_child(_cam)
		_cam.fov = 45.0
	var c: UltraCharacter = main.player
	var yaw := c.state.body_yaw
	var right := Vector3(cos(yaw), 0, -sin(yaw))
	var fwd := Vector3(-sin(yaw), 0, -cos(yaw))
	var p := c.global_position + Vector3.UP * 0.95 + fwd * 0.45
	_cam.global_position = p + right * 4.5
	_cam.look_at(p)
	_cam.current = true
