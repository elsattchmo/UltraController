extends "res://demo/tours/tour_base.gd"
## Marksman in the water, from the side: swimming at the surface, treading water, diving and swimming under, still under
## water, and a plunge off the diving tower (knocked limp in the water, then swimming).
##   godot --path . --fixed-fps 60 --resolution 1280x720 -- --tour=marksman_swim_review --controller=marksman --mm --out=<dir>

var _c: UltraCharacter
var _cam: Camera3D
var _off := Vector3(4.0, 0.6, 0.0)          ## camera offset in the body's frame (facing -Z): its right side
var _tick0 := 0


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/marksman_swim_review")
	steps = [{"teleport": "spawn", "t": 0.6, "yaw": 0, "pitch": 0, "view_tp": true, "slot": 0}, {"call": _setup, "t": 1.0}]
	# In the deep end, facing south (the pool runs z 68..92; deep end north).
	steps.append({"call": _put.bind(Vector3(49, -1.0, 89), 180.0), "t": 600.0, "until": _ticks.bind(60), "yaw": 180, "pitch": 0, "view_tp": true})
	for k in 6:
		steps.append({"t": 600.0, "until": _ticks.bind(70 + k * 10), "yaw": 180, "pitch": 0, "move": Vector2(0, 1), "view_tp": true, "shot": "swim_%d" % k})
	for k in 3:
		steps.append({"t": 600.0, "until": _ticks.bind(140 + k * 15), "yaw": 180, "pitch": 0, "view_tp": true, "shot": "tread_%d" % k})
	steps.append({"t": 600.0, "until": _ticks.bind(185), "yaw": 180, "pitch": 0, "view_tp": true, "tap": InputFrame.B_CROUCH})
	for k in 6:
		steps.append({"t": 600.0, "until": _ticks.bind(195 + k * 12), "yaw": 180, "pitch": -25, "move": Vector2(0, 1), "view_tp": true, "shot": "dive_%d" % k})
	for k in 4:
		steps.append({"t": 600.0, "until": _ticks.bind(280 + k * 15), "yaw": 180, "pitch": 0, "view_tp": true, "shot": "under_still_%d" % k})
	# Off the tower's board: falls ~5 m into the deep end.
	steps.append({"call": _put_marker.bind("dive_tower", 0.0), "t": 600.0, "until": _ticks.bind(40), "yaw": 0, "pitch": 0, "view_tp": true})
	steps.append({"t": 600.0, "until": _falling, "yaw": 0, "pitch": 0, "move": Vector2(0, 1), "view_tp": true})
	steps.append({"call": _mark, "t": 0.0})
	for k in 14:
		steps.append({"t": 600.0, "until": _ticks.bind(6 + k * 8), "yaw": 0, "pitch": 0, "view_tp": true, "shot": "plunge_%02d" % k})


func _falling() -> bool:
	return main.player.state.state == MotorState.Id.FALL


func _mark() -> void:
	_tick0 = Engine.get_physics_frames()


func _ticks(n: int) -> bool:
	return Engine.get_physics_frames() - _tick0 >= n


func _setup() -> void:
	_c = main.player
	for n in get_tree().root.find_children("*", "CanvasLayer", true, false):
		(n as CanvasLayer).visible = false
	_cam = Camera3D.new()
	main.add_child(_cam)
	_cam.fov = 50.0
	_cam.current = true


func _put(p: Vector3, yaw_deg: float) -> void:
	_c.teleport(p, deg_to_rad(yaw_deg))
	_tick0 = Engine.get_physics_frames()


func _put_marker(m: String, yaw_deg: float) -> void:
	_put(main.map.call("marker", m).global_position, yaw_deg)


func _process(delta: float) -> void:
	super._process(delta)
	if _cam == null or _c == null or _c.visual_root == null:
		return
	var root := _c.visual_root.global_position
	var b := Basis(Vector3.UP, _c.state.body_yaw)
	_cam.global_position = root + b * _off + Vector3.UP * 0.4
	_cam.look_at(root + Vector3.UP * 0.4, Vector3.UP)
