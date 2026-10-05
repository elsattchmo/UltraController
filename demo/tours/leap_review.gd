extends UltraTour
## Review tour: a running leap off the 6 m elevator tower (a fall longer than the leap clip:
## the arms keep moving), filmed side on.
##   godot --path . --resolution 1280x720 -- --tour=leap_review --out=C:/Dev/verify/ultra/review/leap_review

var _cam: Camera3D
var _jumped := false


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/leap_review")
	var F := InputFrame
	steps = [
		{"call": _place, "t": 1.0, "yaw": 0, "pitch": -5, "view_tp": true, "slot": 0},
		{"call": _side, "t": 3.0, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "until": _at_edge},
		{"t": 0.12, "move": Vector2(0, 1), "buttons": F.B_SPRINT | F.B_JUMP},
	]
	for k in 16:
		steps.append({"t": 0.08, "move": Vector2(0, 1), "shot": "leap_%02d" % k})


func _place() -> void:
	main.player.teleport(Vector3(-40, 6.25, -83.0), 0.0)


func _at_edge() -> bool:
	return main.player.state.pos.z < -87.6


func _side() -> void:
	_cam = Camera3D.new()
	main.add_child(_cam)
	_cam.fov = 50.0
	_cam.current = true


func _process(delta: float) -> void:
	super(delta)
	if _cam:
		var p: Vector3 = main.player.visual_root.global_position + Vector3.UP * 1.0
		_cam.global_position = p + Vector3(5.0, 0.5, 0.0)
		_cam.look_at(p)
