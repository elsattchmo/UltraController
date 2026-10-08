extends "res://demo/tours/tour_base.gd"
## Marksman on a ledge, filmed from a fixed camera off the wall's right: the jump up to the shimmy ledge (the catch),
## hanging still, shimmying right on a DIAGONAL stick (forward + right: the user's broken case) and left, then climbing
## up. Frames every 6 ticks through each part.
##   godot --path . --fixed-fps 60 --resolution 1280x720 -- --tour=marksman_ledge_review --controller=marksman --mm --out=<dir>

var _cam: Camera3D
var _tick0 := 0


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/marksman_ledge_review")
	steps = [{"teleport": "spawn", "t": 0.6, "yaw": 0, "pitch": 0, "view_tp": true, "slot": 0}, {"call": _setup, "t": 1.0},
			{"teleport": "parkour_shimmy", "call": _mark, "t": 600.0, "until": _ticks.bind(30), "yaw": 0, "pitch": 0, "view_tp": true}]
	# Up to the ledge: forward, jump when close; frames through the catch.
	steps.append({"t": 600.0, "until": _hanging, "yaw": 0, "pitch": 0, "move": Vector2(0, 1), "jump_near": true, "view_tp": true})
	steps.append({"call": _mark, "t": 0.0})
	for k in 8:
		steps.append({"t": 600.0, "until": _ticks.bind(4 + k * 6), "yaw": 0, "pitch": 10, "view_tp": true, "shot": "catch_%d" % k})
	for k in 8:
		steps.append({"t": 600.0, "until": _ticks.bind(60 + k * 8), "yaw": 0, "pitch": 10, "view_tp": true, "move": Vector2(0.707, 0.707),
				"shot": "diag_right_%d" % k})
	for k in 6:
		steps.append({"t": 600.0, "until": _ticks.bind(140 + k * 8), "yaw": 0, "pitch": 10, "view_tp": true, "move": Vector2(-1, 0),
				"shot": "left_%d" % k})
	# The open 2.5 m wall: run at it, jump, catch, climb up.
	steps.append({"teleport": "ledge_250", "call": _mark, "t": 600.0, "until": _ticks.bind(30), "yaw": 0, "pitch": 0, "view_tp": true})
	steps.append({"t": 600.0, "until": _hanging, "yaw": 0, "pitch": 0, "move": Vector2(0, 1), "jump_near": true, "view_tp": true})
	steps.append({"call": _mark, "t": 0.0})
	for k in 6:
		steps.append({"t": 600.0, "until": _ticks.bind(4 + k * 6), "yaw": 0, "pitch": 10, "view_tp": true, "shot": "wall_catch_%d" % k})
	steps.append({"t": 600.0, "until": _ticks.bind(50), "yaw": 0, "pitch": 10, "view_tp": true})
	for k in 8:
		steps.append({"t": 600.0, "until": _ticks.bind(54 + k * 6), "yaw": 0, "pitch": 10, "view_tp": true, "move": Vector2(0, 1),
				"shot": "climb_%d" % k})


func _ticks(n: int) -> bool:
	return Engine.get_physics_frames() - _tick0 >= n


func _mark() -> void:
	_tick0 = Engine.get_physics_frames()


func _hanging() -> bool:
	return main.player.state.state == MotorState.Id.LEDGE_HANG


func _setup() -> void:
	for n in get_tree().root.find_children("*", "CanvasLayer", true, false):
		(n as CanvasLayer).visible = false
	_cam = Camera3D.new()
	main.add_child(_cam)
	_cam.fov = 50.0
	_cam.current = true


func _drive(tick: int, src: BotInputSource) -> InputFrame:
	var f := super._drive(tick, src)
	var s: Dictionary = steps[_i] if _i >= 0 and _i < steps.size() else {}
	var st: MotorState = main.player.state
	var near := -44.0 if st.pos.z < -40.0 else -27.3
	if s.get("jump_near", false) and st.is_grounded() and st.pos.z < near:
		f.buttons |= InputFrame.B_JUMP
	return f


func _process(delta: float) -> void:
	super._process(delta)
	if _cam == null:
		return
	# (Close, off the body's right and a little behind - the wall is to the north, -Z.)
	var at: Vector3 = main.player.state.pos + Vector3(0, 1.6, 0)
	_cam.global_position = at + Vector3(2.0, 0.5, 1.8)
	_cam.look_at(at, Vector3.UP)
