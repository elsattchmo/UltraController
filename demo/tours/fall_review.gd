extends UltraTour
## Review tour: sprinting off a 9 m drop (goes limp at the edge, falls loose with its momentum,
## hits the ground and tumbles on) and off a 4 m drop (lands on its feet and runs on - no
## roll). A fixed camera off to the side films a strip of frames.
##   godot --path . --resolution 1280x720 -- --tour=fall_review --out=C:/Dev/verify/ultra/review/fall_review

var _cam: Camera3D


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/fall_review")
	var F := InputFrame
	steps = [
		{"teleport": "drop_9", "t": 1.0, "yaw": 0, "pitch": -20, "view_tp": true, "slot": 0},
		{"t": 0.3},
		{"t": 0.6, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "shot": "01_run_up"},
		{"t": 0.25, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "shot": "02_edge"},
		{"t": 0.25, "shot": "03_limp_falling"},
		{"t": 0.25, "shot": "04_falling"},
		{"t": 0.25, "shot": "05_falling_late"},
		{"t": 0.2, "shot": "06_impact"},
		{"t": 0.25, "shot": "07_tumble"},
		{"t": 0.3, "shot": "08_tumble_b"},
		{"t": 0.6, "shot": "09_down"},
		{"t": 3.0, "shot": "10_up"},
		{"teleport": "drop_4", "t": 1.0, "yaw": 0},
		{"t": 0.3},
		{"t": 0.7, "move": Vector2(0, 1), "buttons": F.B_SPRINT},
		{"t": 0.2, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "shot": "11_4m_air"},
		{"t": 0.2, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "shot": "12_4m_land"},
		{"t": 0.25, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "shot": "13_4m_run_on"},
	]


## A camera fixed in the world to the player's right, wide enough for the whole drop.
func _side_cam() -> void:
	if _cam == null:
		_cam = Camera3D.new()
		main.add_child(_cam)
	var c: UltraCharacter = main.player
	var yaw := c.state.body_yaw
	var right := Vector3(cos(yaw), 0, -sin(yaw))
	var fwd := Vector3(-sin(yaw), 0, -cos(yaw))
	var p := c.global_position
	var look := p + fwd * 11.0 + Vector3.DOWN * 5.0
	_cam.global_position = look + right * 17.0 + Vector3.UP * 2.0
	_cam.look_at(look)
	_cam.fov = 70.0
	_cam.current = true
