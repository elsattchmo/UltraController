extends UltraTour
## Review tour: running / sprinting with nothing, the pistol and the rifle, in both views - the
## player's own view, then the body from the side and from the front (head sway, where the gun
## is carried).
##   godot --path . --resolution 1280x720 -- --tour=run_review --out=C:/Dev/verify/ultra/review/run_review

var _cam: Camera3D
var _side := 0           ## 0 = player camera, 1 = side, 2 = front


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/run_review")
	var F := InputFrame
	steps = [
		{"teleport": "speed_start", "t": 0.6, "yaw": 0, "pitch": -5, "view_tp": true, "slot": 0},
		{"call": _give, "t": 0.2},
	]
	for slot in [0, 1, 2]:
		var item: String = ["unarmed", "pistol", "rifle"][slot]
		for view_tp in [true, false]:
			var tag := "%s_%s" % [item, "tp" if view_tp else "fp"]
			steps.append({"teleport": "speed_start", "t": 1.2, "yaw": 0, "pitch": -5, "view_tp": view_tp, "slot": slot})
			steps.append({"t": 1.6, "slot": slot, "move": Vector2(0, 1), "buttons": F.B_SPRINT})
			for k in 3:
				steps.append({"call": _view.bind(0), "t": 0.12, "slot": slot, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "shot": "%s_view_%d" % [tag, k]})
			for k in 3:
				steps.append({"call": _view.bind(1), "t": 0.12, "slot": slot, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "shot": "%s_side_%d" % [tag, k]})
			for k in 3:
				steps.append({"call": _view.bind(2), "t": 0.12, "slot": slot, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "shot": "%s_front_%d" % [tag, k]})
			if view_tp:
				# Close behind the head, a strip through a stride (what the third-person view sees).
				for k in 8:
					steps.append({"call": _view.bind(3), "t": 0.045, "slot": slot, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "shot": "%s_back_%d" % [tag, k]})
			steps.append({"call": _view.bind(0), "t": 0.1, "slot": slot})


func _give() -> void:
	for it: Array in [[&"pistol", 1], [&"rifle", 1], [&"ammo_9mm", 60], [&"ammo_556", 90]]:
		if main.player.inventory.count_of(it[0]) == 0:
			UltraItems.give(main.player, it[0], it[1])


func _view(which: int) -> void:
	_side = which
	if which == 0:
		if _cam:
			_cam.current = false
		for n in main.find_children("*", "UltraCameraRig", true, false):
			(n as UltraCameraRig).camera.current = true
		return
	if _cam == null:
		_cam = Camera3D.new()
		main.add_child(_cam)
		_cam.fov = 40.0
	_cam.current = true
	_follow()


func _process(delta: float) -> void:
	super(delta)
	if _side != 0:
		_follow()


func _follow() -> void:
	var c: UltraCharacter = main.player
	var yaw := c.state.body_yaw
	var right := Vector3(cos(yaw), 0, -sin(yaw))
	var fwd := Vector3(-sin(yaw), 0, -cos(yaw))
	var p := c.visual_root.global_position + Vector3.UP * 1.2
	if _side == 3:
		# Behind, level, steady (follows the body's root only).
		_cam.global_position = p - fwd * 2.2 + Vector3.UP * 0.25
		_cam.look_at(p + fwd * 2.0 + Vector3.UP * 0.25)
		return
	_cam.global_position = p + (right * 3.5 if _side == 1 else fwd * 3.5) + Vector3.UP * 0.2
	_cam.look_at(p)
