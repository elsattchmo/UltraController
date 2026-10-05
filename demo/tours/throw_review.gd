extends UltraTour
## Review tour: picking up a 5 kg crate and throwing it - the two-handed push from the chest -
## in third person, a strip of frames through the throw.
##   godot --path . --resolution 1280x720 -- --tour=throw_review --out=C:/Dev/verify/ultra/review/throw_review


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/throw_review")
	var F := InputFrame
	steps = [
		{"teleport": "speed_start", "t": 0.6, "yaw": 0, "pitch": -10, "view_tp": true, "slot": 0},
		{"call": func() -> void: _face("Crate5kg"), "t": 0.4},
		{"t": 0.15, "target": "Crate5kg", "tap": F.B_GRAB},
		{"t": 1.0, "yaw": 140, "pitch": -12, "shot": "01_holding"},
		{"call": _beside, "t": 0.5, "yaw": 140, "pitch": -12, "buttons": F.B_THROW, "shot": "02_charging"},
		{"t": 0.05, "yaw": 140, "pitch": -12, "shot": "03_release"},
		{"t": 0.1, "yaw": 140, "pitch": -12, "shot": "04_push_a"},
		{"t": 0.1, "yaw": 140, "pitch": -12, "shot": "05_push_b"},
		{"t": 0.12, "yaw": 140, "pitch": -12, "shot": "06_push_c"},
		{"t": 0.15, "yaw": 140, "pitch": -12, "shot": "07_push_d"},
		{"t": 0.4, "yaw": 140, "pitch": -12, "shot": "08_after"},
	]


func _face(n: String) -> void:
	var t := main.map.find_child(n, true, false) as Node3D
	var p: Vector3 = t.global_position + Vector3(0, 0, 1.0)
	main.player.teleport(Vector3(p.x, 0.06, p.z), 0.0)
	_bot.live_yaw = 0.0


func _drive(tick: int, src: BotInputSource) -> InputFrame:
	var f := super._drive(tick, src)
	if _i < steps.size() and steps[_i].has("target"):
		var o: Node = main.map.find_child(String(steps[_i]["target"]), true, false)
		if o:
			var no := o.find_child("NetObject", false, false) as NetObject
			f.target_id = no.net_id if no else 0
	return f


var _cam: Camera3D


## A camera to the player's side, looking at the chest.
func _beside() -> void:
	if _cam == null:
		_cam = Camera3D.new()
		main.add_child(_cam)
		_cam.fov = 50.0
	var c: UltraCharacter = main.player
	var yaw := c.state.body_yaw
	var right := Vector3(cos(yaw), 0, -sin(yaw))
	var fwd := Vector3(-sin(yaw), 0, -cos(yaw))
	var p := c.global_position + Vector3.UP * 1.1 + fwd * 0.4
	_cam.global_position = p + right * 3.2
	_cam.look_at(p)
	_cam.current = true

