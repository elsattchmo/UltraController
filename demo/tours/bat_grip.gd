extends UltraTour
## Probe: the two-handed club grip at rest and through a swing - where each hand's
## thumb points along the handle and how far the fingertips are from the handle axis.
##   godot --path . -- --tour=bat_grip --out=C:/Dev/verify/ultra/review/bat_grip

var _cam: Camera3D


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/bat_grip")
	steps = [
		{"teleport": "speed_start", "t": 0.6, "yaw": 0, "pitch": -4, "view_tp": true, "slot": 0},
		{"call": _give, "t": 0.3},
		{"call": _setup, "t": 0.1},
	]
	steps.append({"t": 1.5, "slot": 4, "shot": "idle"})
	steps.append({"call": _measure.bind(0), "t": 0.05, "slot": 4})
	steps.append({"call": _slow.bind(true), "t": 0.01, "slot": 4})
	for k in 8:
		var st := {"t": 0.08 / 0.35, "slot": 4, "shot": "swing_%d" % k, "call": _measure.bind(k + 1)}
		if k == 0:
			st["tap"] = InputFrame.B_PRIMARY
		steps.append(st)
	steps.append({"call": _slow.bind(false), "t": 0.5, "slot": 4})


func _give() -> void:
	if main.player.inventory.count_of(&"bat") == 0:
		UltraItems.give(main.player, &"bat", 1)


func _setup() -> void:
	_cam = Camera3D.new()
	main.add_child(_cam)
	_cam.fov = 30.0
	main.player.skeleton.skeleton_updated.connect(_on_skel)


func _slow(on: bool) -> void:
	Engine.time_scale = 0.35 if on else 1.0


var _pending := -1


func _measure(v: int) -> void:
	_pending = v


func _on_skel() -> void:
	if _pending < 0:
		return
	var v := _pending
	_pending = -1
	var c: UltraCharacter = main.player
	var sk := c.skeleton
	var eq := c.get_node("Equipment") as UltraEquipmentVisual
	var g := (eq.held_node as Node3D).global_transform
	var tip := UltraPoseSampler.marker(eq.held_node, "M_Tip")
	var axis := (g * tip.origin - g.origin).normalized()
	var out := "BAT v%d" % v
	for side in ["Right", "Left"]:
		var hand := (sk.global_transform * sk.get_bone_global_pose(sk.find_bone(side + "Hand"))).origin
		var th := (sk.global_transform * sk.get_bone_global_pose(sk.find_bone(side + "ThumbDistal"))).origin
		var tdir := (th - hand).normalized()
		var dmax := 0.0
		for f in ["IndexDistal", "MiddleDistal", "RingDistal", "LittleDistal"]:
			var q := (sk.global_transform * sk.get_bone_global_pose(sk.find_bone(side + f))).origin - g.origin
			dmax = maxf(dmax, (q - axis * q.dot(axis)).length())
		var kq := (sk.global_transform * sk.get_bone_global_pose(sk.find_bone(side + "MiddleProximal"))).origin - g.origin
		out += "  knuckle %.3f" % (kq - axis * kq.dot(axis)).length()
		var hq := hand - g.origin
		out += "  %s thumb.axis %.2f tips<=%.3f wrist_off %.3f along %.3f" % [side, tdir.dot(axis), dmax, (hq - axis * hq.dot(axis)).length(), hq.dot(axis)]
	var goal: HandIKModifier.Goal = c.anim.hand_ik.goals[HandIKModifier.Hand.LEFT]
	var lh := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("LeftHand"))
	out += "  err %.3f  goal_w %.2f  to_goal %.3f" % [c.anim.hand_ik.last_error[HandIKModifier.Hand.LEFT], goal.weight, lh.origin.distance_to(goal.target.origin)]
	print(out)


func _process(delta: float) -> void:
	super(delta)
	if _cam:
		_cam.current = true
		var c: UltraCharacter = main.player
		var sk := c.skeleton
		var lh := (sk.global_transform * sk.get_bone_global_pose(sk.find_bone("LeftHand"))).origin
		var yaw := c.state.body_yaw
		var fwd := Vector3(-sin(yaw), 0, -cos(yaw))
		var right := Vector3(cos(yaw), 0, -sin(yaw))
		_cam.global_position = lh + fwd * 0.55 - right * 0.55 + Vector3.UP * 0.35
		_cam.look_at(lh)
