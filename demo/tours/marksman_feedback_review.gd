extends "res://demo/tours/tour_base.gd"
## The user's round of Marksman notes filmed: leaning right / left with the rifle (the gun goes over with the body), backing
## on a diagonal with the pistol and unarmed (motion matching: a walking clip, no shuffle), getting down to prone and up.
##   godot --path . --fixed-fps 60 --resolution 1280x720 -- --tour=marksman_feedback_review --controller=marksman --mm --out=<dir>

var _c: UltraCharacter
var _cam: Camera3D
var _slots := {}
var _off := Vector3(0, 1.5, 2.2)          ## camera offset in the body's frame (facing -Z)
var _look_y := 1.3
var _tick0 := 0


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/marksman_feedback_review")
	steps = [{"teleport": "spawn", "t": 0.6, "yaw": 0, "pitch": 0, "view_tp": true, "slot": 0}, {"call": _setup, "t": 1.0}]
	# Weapon strikes (--strike): the rifle's stock driven in, the pistol whipped - from the side and in first person, frames
	# through the blow (the sim's hit lands at 0.45 / 0.36 s).
	if "--strike" in OS.get_cmdline_user_args():
		for item in ["rifle", "pistol"]:
			for v: Array in [["side", Vector3(3.4, 1.4, -1.2)], ["fp", Vector3.ZERO]]:
				steps.append({"call": _arm.bind(item, v[1], v[0] == "fp"), "t": 600.0, "until": _ticks.bind(80), "yaw": 0, "pitch": 0, "view_tp": v[0] != "fp"})
				steps.append({"t": 600.0, "until": _ticks.bind(83), "yaw": 0, "pitch": 0, "view_tp": v[0] != "fp", "buttons": InputFrame.B_MELEE})
				for k in 6:
					steps.append({"t": 600.0, "until": _ticks.bind(86 + k * 8), "yaw": 0, "pitch": 0, "view_tp": v[0] != "fp",
							"shot": "strike_%s_%s_%d" % [item, v[0], k]})
				steps.append({"t": 600.0, "until": _ticks.bind(200), "yaw": 0, "pitch": 0, "view_tp": v[0] != "fp"})
		return
	# Drawing and putting away (--draw): pistol from the hip holster, rifle and bat off the back - from the right-front.
	if "--draw" in OS.get_cmdline_user_args():
		for item in ["pistol", "rifle", "bat"]:
			steps.append({"call": _arm.bind("", Vector3(2.2, 1.3, -1.6), false), "t": 600.0, "until": _ticks.bind(60), "yaw": 0, "pitch": 0, "view_tp": true})
			steps.append({"call": _pick.bind(item), "t": 600.0, "until": _ticks.bind(61), "yaw": 0, "pitch": 0, "view_tp": true})
			for k in 10:
				steps.append({"t": 600.0, "until": _ticks.bind(62 + k * 4), "yaw": 0, "pitch": 0, "view_tp": true,
						"shot": "draw_%s_%d" % [item, k]})
			steps.append({"t": 600.0, "until": _ticks.bind(140), "yaw": 0, "pitch": 0, "view_tp": true})
			for k in 8:
				steps.append({"t": 600.0, "until": _ticks.bind(142 + k * 4), "yaw": 0, "pitch": 0, "view_tp": true, "slot": 0,
						"shot": "away_%s_%d" % [item, k]})
			steps.append({"t": 600.0, "until": _ticks.bind(200), "yaw": 0, "pitch": 0, "view_tp": true, "slot": 0})
		return
	# Lean with the rifle: from behind and in first person.
	for lean: Array in [["right", InputFrame.B_LEAN_R], ["left", InputFrame.B_LEAN_L]]:
		for v: Array in [["back", Vector3(0, 1.6, 2.0)], ["fp", Vector3.ZERO]]:
			steps.append({"call": _arm.bind("rifle", v[1], v[0] == "fp"), "t": 600.0, "until": _ticks.bind(80), "yaw": 0, "pitch": 0, "view_tp": v[0] != "fp"})
			steps.append({"t": 600.0, "until": _ticks.bind(150), "yaw": 0, "pitch": 0, "buttons": lean[1], "view_tp": v[0] != "fp"})
			steps.append({"t": 600.0, "until": _ticks.bind(154), "yaw": 0, "pitch": 0, "buttons": lean[1], "view_tp": v[0] != "fp",
					"shot": "lean_%s_%s" % [lean[0], v[0]]})
	# Backing on a diagonal (pistol, unarmed): three frames through a stride, from the side.
	for item in ["pistol", ""]:
		for d: Array in [["back_left", Vector2(-0.707, -0.707)], ["back_right", Vector2(0.707, -0.707)]]:
			steps.append({"call": _arm.bind(item, Vector3(2.4, 1.3, 0.0), false), "t": 600.0, "until": _ticks.bind(70), "yaw": 0, "pitch": 0, "view_tp": true})
			for k in 3:
				steps.append({"t": 600.0, "until": _ticks.bind(110 + k * 12), "yaw": 0, "pitch": 0, "move": d[1], "view_tp": true,
						"shot": "%s_%s_%d" % [item if item != "" else "unarmed", d[0], k]})
	# Down to prone and back up (rifle), from the side.
	steps.append({"call": _arm.bind("rifle", Vector3(2.6, 1.0, 0.3), false), "t": 600.0, "until": _ticks.bind(70), "yaw": 0, "pitch": 0, "view_tp": true})
	for k in 4:
		steps.append({"t": 600.0, "until": _ticks.bind(72 + k * 12), "yaw": 0, "pitch": 0, "view_tp": true,
				"buttons": InputFrame.B_CRAWL | InputFrame.B_CROUCH, "shot": "prone_down_%d" % k})
	steps.append({"t": 600.0, "until": _ticks.bind(200), "yaw": 0, "pitch": 0, "view_tp": true, "buttons": InputFrame.B_CRAWL | InputFrame.B_CROUCH})
	for k in 4:
		steps.append({"t": 600.0, "until": _ticks.bind(202 + k * 12), "yaw": 0, "pitch": 0, "view_tp": true, "shot": "prone_up_%d" % k})


func _ticks(n: int) -> bool:
	return Engine.get_physics_frames() - _tick0 >= n


func _setup() -> void:
	_c = main.player
	for n in get_tree().root.find_children("*", "CanvasLayer", true, false):
		(n as CanvasLayer).visible = false
	_cam = Camera3D.new()
	main.add_child(_cam)
	_cam.fov = 45.0
	_cam.current = true
	for item: StringName in [&"rifle", &"pistol", &"bat"]:
		UltraItems.give(_c, item)
	for i in _c.inventory.size():
		var it := _c.inventory.get_slot(i)
		if it:
			_slots[String(it.def_id)] = i + 1


func _pick(item: String) -> void:
	_slot = int(_slots.get(item, 0))


func _arm(item: String, off: Vector3, fp: bool) -> void:
	_slot = int(_slots.get(item, 0))
	_c.teleport(main.map.call("marker", "spawn").global_position + Vector3(-16, 0, -3), 0.0)
	_off = off
	_cam.current = not fp
	_tick0 = Engine.get_physics_frames()


func _process(delta: float) -> void:
	super._process(delta)
	if _cam == null or _c == null or _c.visual_root == null:
		return
	var root := _c.visual_root.global_position
	var b := Basis(Vector3.UP, _c.state.body_yaw)
	_cam.global_position = root + b * _off
	_cam.look_at(root + Vector3.UP * _look_y, Vector3.UP)
