extends UltraTour
## Review tour: one- and two-handed melee settled - idle, walking, a strike, blocking.
##   godot --path . --resolution 1280x720 -- --tour=melee_check --out=C:/Dev/verify/ultra/review/melee_check

var _cam: Camera3D


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/melee_check")
	var F := InputFrame
	steps = [
		{"teleport": "speed_start", "t": 0.6, "yaw": 0, "pitch": -4, "view_tp": true, "slot": 0},
		{"call": _give, "t": 0.3},
		{"call": _side_on, "t": 0.3, "slot": 0},
	]
	for s: Array in [[5, "machete"], [4, "bat"]]:
		steps.append({"t": 2.5, "slot": s[0], "shot": s[1] + "_idle"})
		steps.append({"t": 1.2, "slot": s[0], "move": Vector2(0, 1), "shot": s[1] + "_walk"})
		steps.append({"t": 0.8, "slot": s[0]})
		steps.append({"t": 0.05, "slot": s[0], "tap": F.B_PRIMARY})
		steps.append({"t": 0.3, "slot": s[0], "shot": s[1] + "_strike"})
		steps.append({"t": 1.5, "slot": s[0], "shot": s[1] + "_after"})
		steps.append({"t": 1.0, "slot": s[0], "buttons": F.B_SECONDARY, "shot": s[1] + "_block"})
		steps.append({"t": 1.0, "slot": s[0], "shot": s[1] + "_release"})


func _give() -> void:
	for it: StringName in [&"bat", &"machete"]:
		if main.player.inventory.count_of(it) == 0:
			UltraItems.give(main.player, it, 1)


func _side_on() -> void:
	_cam = Camera3D.new()
	main.add_child(_cam)
	_cam.fov = 45.0


func _process(delta: float) -> void:
	super(delta)
	if _cam:
		_cam.current = true
		var c: UltraCharacter = main.player
		var yaw := c.state.body_yaw
		var right := Vector3(cos(yaw), 0, -sin(yaw))
		var fwd := Vector3(-sin(yaw), 0, -cos(yaw))
		var p := c.visual_root.global_position + Vector3.UP * 1.0
		_cam.global_position = p + right * 2.2 + fwd * 1.6 + Vector3.UP * 0.3
		_cam.look_at(p)
