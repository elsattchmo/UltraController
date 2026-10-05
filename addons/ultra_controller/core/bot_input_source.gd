class_name BotInputSource
extends InputSource
## Scripted input for tests, scenarios and companions. Drive it with a list of steps
## (`steps`), a Callable (`driver`), or by setting `goal` to walk toward a point.
##
## A step is a Dictionary: {"ticks": int, "move": Vector2, "yaw": float (abs, optional),
## "yaw_rate": float (rad/s, optional), "pitch": float, "buttons": int, "tap": int}
## "tap" bits are held for the first tick only (edge presses like jump).
## "to": Vector3 (+ "radius", default 1) walks there and ends the step on arrival ("ticks" is
## then the limit).

signal finished

var steps: Array = []
var driver: Callable
var goal: Variant = null           ## Vector3 to walk toward (simple follow bot)
var goal_radius := 1.5
var goal_sprint_distance := 6.0
var body: Node3D                   ## for goal seeking
var loop := false
var want_slot := 0

var _step := 0
var _step_tick := 0
var _done := false


## Net id of the nearest enabled Interactable within 3 m of the body (bots' "look at it").
func _nearest_interactable() -> int:
	if body == null:
		return 0
	var best := 0
	var bd := 3.0
	for n in body.get_tree().get_nodes_in_group(&"ultra_interactable"):
		var it := n as Interactable
		if it.enabled and it.target():
			var d := it.target().global_position.distance_to(body.global_position)
			if d < bd and it.net_id() != 0:
				bd = d
				best = it.net_id()
	return best


func is_done() -> bool:
	return _done


func set_steps(s: Array) -> void:
	steps = s
	_step = 0
	_step_tick = 0
	_done = false


func sample(tick: int) -> InputFrame:
	var f := InputFrame.new()
	f.tick = tick
	if driver.is_valid():
		var r: Variant = driver.call(tick, self)
		if r is InputFrame:
			(r as InputFrame).tick = tick
			(r as InputFrame).aim_from = aim_from
			live_yaw = r.yaw
			live_pitch = r.pitch
			return (r as InputFrame).quantize()
	if goal != null and body != null:
		var to: Vector3 = (goal as Vector3) - body.global_position
		to.y = 0.0
		var d := to.length()
		if d > goal_radius:
			live_yaw = atan2(-to.x, -to.z)
			f.move = Vector2(0, 1)
			if d > goal_sprint_distance:
				f.buttons |= InputFrame.B_SPRINT
	elif _step < steps.size():
		var s: Dictionary = steps[_step]
		if s.has("yaw"):
			live_yaw = float(s["yaw"])
		live_yaw += float(s.get("yaw_rate", 0.0)) / float(Engine.physics_ticks_per_second)
		if s.has("pitch"):
			live_pitch = float(s["pitch"])
		f.move = s.get("move", Vector2.ZERO)
		f.buttons = int(s.get("buttons", 0))
		if s.has("slot"):
			want_slot = int(s["slot"])
		f.target_id = int(s.get("target", 0))
		if f.target_id == -1:
			f.target_id = _nearest_interactable()
		if _step_tick == 0:
			f.buttons |= int(s.get("tap", 0))
		var arrived := false
		if s.has("to") and body != null:
			var to: Vector3 = (s["to"] as Vector3) - body.global_position
			to.y = 0.0
			arrived = to.length() <= float(s.get("radius", 1.0))
			if not arrived:
				f.move = Vector2(0, 1)
				if not s.has("yaw"):
					live_yaw = atan2(-to.x, -to.z)
		_step_tick += 1
		if _step_tick >= int(s.get("ticks", 1)) or arrived:
			_step += 1
			_step_tick = 0
			if _step >= steps.size():
				if loop:
					_step = 0
				else:
					_done = true
					finished.emit()
	if view_tp:
		f.buttons |= InputFrame.B_VIEW_TP
	f.yaw = live_yaw
	f.pitch = live_pitch
	f.want_slot = want_slot
	f.aim_from = aim_from
	return f.quantize()
