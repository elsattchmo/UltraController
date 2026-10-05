extends UltraTour
## Review tour: the pool rope swing (run off the deck, catch the rope, swing out, let go into
## the deep end) and a drop off the 5 m board - hitting the water hard knocks you limp for a
## moment before you come round swimming. Filmed from the pool's south-west corner.
##   godot --path . --resolution 1280x720 -- --tour=water_review --out=C:/Dev/verify/ultra/review/water_review

var _cam: Camera3D


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/water_review")
	var F := InputFrame
	steps = [
		{"teleport": "pool_swing", "t": 1.0, "yaw": -90, "pitch": -5, "view_tp": true, "slot": 0},
		{"call": func() -> void: _fixed(Vector3(37, 4.5, 70), Vector3(44, 3.0, 83)), "t": 0.2},
		{"t": 0.82, "yaw": -90, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "shot": "01_run_up"},
		{"t": 0.25, "yaw": -90, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "tap": F.B_JUMP, "shot": "02_leap"},
		{"t": 0.35, "yaw": -90, "move": Vector2(0, 1), "shot": "03_catch"},
		{"t": 0.4, "yaw": -90, "move": Vector2(0, 1), "shot": "04_swing_out"},
		{"t": 0.35, "yaw": -90, "move": Vector2(0, 1), "shot": "05_swing_far"},
		{"t": 0.2, "yaw": -90, "tap": F.B_JUMP, "shot": "06_let_go"},
		{"t": 0.3, "yaw": -90, "shot": "07_flying"},
		{"t": 0.25, "yaw": -90, "shot": "08_splash"},
		{"t": 0.4, "yaw": -90, "shot": "09_limp"},
		{"t": 1.4, "yaw": -90, "shot": "10_swimming"},
		{"teleport": "dive_tower", "t": 0.6, "yaw": 0},
		{"call": func() -> void: _fixed(Vector3(57, 3.5, 84), Vector3(49, 2.0, 88)), "t": 0.2},
		{"t": 3.55, "yaw": 0, "move": Vector2(0, 1), "shot": "11_board_off"},
		{"t": 0.35, "yaw": 0, "shot": "12_falling"},
		{"t": 0.3, "yaw": 0, "shot": "13_impact"},
		{"t": 0.5, "yaw": 0, "shot": "14_limp"},
		{"t": 1.2, "yaw": 0, "shot": "15_come_round"},
	]


func _fixed(at: Vector3, look: Vector3) -> void:
	if _cam == null:
		_cam = Camera3D.new()
		main.add_child(_cam)
		_cam.fov = 62.0
	_cam.global_position = at
	_cam.look_at(look)
	_cam.current = true
