extends "res://demo/tours/tour_base.gd"
## Marksman's jumps and landings, from the side: a standing hop, a walking jump, a sprinting leap, then walking off the
## landing tower's 2 / 4 / 6 m blocks (the falling loop, a squat, the hard landing). Frames every 5 ticks.
##   godot --path . --fixed-fps 60 --resolution 1280x720 -- --tour=marksman_jump_review --controller=marksman --mm --out=<dir>

var _cam: Camera3D
var _tick0 := 0
var _sprint := false
const JUMP_AT := 30


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/marksman_jump_review")
	steps = [{"teleport": "spawn", "t": 0.6, "yaw": 0, "pitch": 0, "view_tp": true, "slot": 0}, {"call": _setup, "t": 1.0}]
	# On the flat east of the spawn, facing north (-Z).
	for spec: Array in [["hop", Vector2.ZERO, false], ["walk_jump", Vector2(0, 1), false], ["sprint_jump", Vector2(0, 1), true]]:
		steps.append({"call": _put.bind(Vector3(30, 0.05, -60), 0.0), "t": 600.0, "until": _ticks.bind(20), "yaw": 0, "pitch": 0, "view_tp": true})
		steps.append({"t": 600.0, "until": _ticks.bind(JUMP_AT), "yaw": 0, "pitch": 0, "view_tp": true, "move": spec[1],
				"buttons": InputFrame.B_SPRINT if spec[2] else 0})
		steps.append({"t": 600.0, "until": _ticks.bind(JUMP_AT + 1), "yaw": 0, "pitch": 0, "view_tp": true, "move": spec[1],
				"buttons": (InputFrame.B_SPRINT if spec[2] else 0) | InputFrame.B_JUMP})
		for k in 14:
			steps.append({"t": 600.0, "until": _ticks.bind(JUMP_AT + 3 + k * 5), "yaw": 0, "pitch": 0, "view_tp": true, "move": spec[1],
					"buttons": InputFrame.B_SPRINT if spec[2] else 0, "shot": "%s_%02d" % [spec[0], k]})
	# Off the landing tower's blocks (x 58 / 64 / 70, top 2 / 4 / 6 m, z -50 .. -46): walking south off the edge.
	for spec: Array in [["drop2", 58.0, 2.0], ["drop4", 64.0, 4.0], ["drop6", 70.0, 6.0]]:
		steps.append({"call": _put.bind(Vector3(spec[1], spec[2] + 0.05, -48.5), 180.0), "t": 600.0, "until": _ticks.bind(20), "yaw": 180,
				"pitch": 0, "view_tp": true})
		steps.append({"t": 600.0, "until": _falling, "yaw": 180, "pitch": 0, "view_tp": true, "move": Vector2(0, 1)})
		steps.append({"call": _mark, "t": 0.0})
		for k in 16:
			steps.append({"t": 600.0, "until": _ticks.bind(3 + k * 5), "yaw": 180, "pitch": 0, "view_tp": true, "shot": "%s_%02d" % [spec[0], k]})


func _ticks(n: int) -> bool:
	return Engine.get_physics_frames() - _tick0 >= n


func _mark() -> void:
	_tick0 = Engine.get_physics_frames()


func _falling() -> bool:
	return main.player.state.state == MotorState.Id.FALL


func _put(p: Vector3, yaw_deg: float) -> void:
	main.player.teleport(p, deg_to_rad(yaw_deg))
	_mark()


func _setup() -> void:
	for n in get_tree().root.find_children("*", "CanvasLayer", true, false):
		(n as CanvasLayer).visible = false
	_cam = Camera3D.new()
	main.add_child(_cam)
	_cam.fov = 50.0
	_cam.current = true


func _process(delta: float) -> void:
	super._process(delta)
	if _cam == null:
		return
	var c: UltraCharacter = main.player
	var at := c.visual_root.global_position + Vector3.UP * 1.0
	var b := Basis(Vector3.UP, c.state.body_yaw)
	_cam.global_position = at + b * Vector3(4.5, 0.4, 0.0)
	_cam.look_at(at, Vector3.UP)
