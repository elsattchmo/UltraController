extends "res://demo/tours/tour_base.gd"
## Marksman V4b filmed close up: an empty reload on the carbine and the pistol (the magazine swap, then the left hand
## racks the charging handle / slide), and freelook (the head turned off the aim, the gun still on it).
##   godot --path . --fixed-fps 60 --resolution 1280x720 -- --tour=marksman_gunfeel_review --controller=marksman --out=<dir>

var _c: UltraCharacter
var _cam: Camera3D
var _slots := {}
var _view_off := Vector3(1.2, 1.5, -1.2)
var _look_y := 1.35


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/marksman_gunfeel_review")
	steps = [{"teleport": "spawn", "t": 0.6, "yaw": 0, "pitch": 0, "view_tp": true, "slot": 0},
			{"call": _setup, "t": 1.0}]
	for item in ["rifle", "pistol"]:
		steps.append({"call": _arm.bind(item), "t": 600.0, "until": _ticks.bind(100), "yaw": 0, "pitch": -5})
		steps.append({"call": _empty, "t": 600.0, "until": _ticks.bind(3), "yaw": 0, "pitch": -5, "buttons": InputFrame.B_RELOAD})
		# (Ticks along the reload, real time: the magazine out, in, the rack reached, pulled, let go, back on the grip.)
		var at := [24, 78, 112, 134, 142, 160] if item == "rifle" else [24, 70, 92, 112, 120, 135]
		for k in at.size():
			steps.append({"t": 600.0, "until": _ticks.bind(int(at[k])), "yaw": 0, "pitch": -5, "shot": "%s_empty_%d" % [item, k]})
		steps.append({"t": 600.0, "until": _ticks.bind(260), "yaw": 0, "pitch": -5})
	# Arms against the body: the pistol held at the hip and in ADS, from above and from the side.
	if "--arms" in OS.get_cmdline_user_args():
		steps = [{"teleport": "spawn", "t": 0.6, "yaw": 0, "pitch": 0, "view_tp": true, "slot": 0}, {"call": _setup, "t": 1.0}]
		for item in ["pistol", "rifle"]:
			for ads: int in [0, InputFrame.B_SECONDARY]:
				steps.append({"call": _arm.bind(item), "t": 600.0, "until": _ticks.bind(100), "yaw": 0, "pitch": 0, "buttons": ads})
				for v: Array in [["top", Vector3(0.12, 2.3, -0.6), 1.2], ["side", Vector3(1.1, 1.45, 0.0), 1.3], ["front", Vector3(0.0, 1.5, -1.1), 1.35]]:
					steps.append({"call": _cam_at.bind(v[1], v[2]), "t": 600.0, "until": _ticks.bind(8), "yaw": 0, "pitch": 0, "buttons": ads,
							"shot": "arms_%s_%s_%s" % [item, "ads" if ads else "hip", v[0]]})
		return
	# Two-handed aims off the body (the user: "we currently clip through our body heavily when turning right and there is
	# some clipping when aiming up and a little down"): held right / left, turning right, up / down - from outside (the
	# camera turns with the body: front-left, above, front-right) and in first person.
	if "--aims" in OS.get_cmdline_user_args():
		steps = [{"teleport": "spawn", "t": 0.6, "yaw": 0, "pitch": 0, "view_tp": true, "slot": 0}, {"call": _setup, "t": 1.0}]
		var item := "shotgun" if "--shotgun" in OS.get_cmdline_user_args() else "rifle"
		var aims := [["ahead", 0.0, 0.0, 0.0], ["right45", -45.0, 0.0, 0.0], ["left45", 45.0, 0.0, 0.0], ["turnright", 0.0, 0.0, -150.0],
				["turnright_fast", 0.0, 0.0, -300.0], ["up60", 0.0, 60.0, 0.0], ["down60", 0.0, -60.0, 0.0]]
		for a: Array in aims:
			for v: Array in [["fl", Vector3(-0.9, 1.6, -1.6), 1.3], ["top", Vector3(0.0, 2.6, -0.5), 1.2], ["fr", Vector3(1.1, 1.5, -1.4), 1.3], ["fp", Vector3.ZERO, 0.0]]:
				var st := {"t": 600.0, "until": _ticks.bind(70 if float(a[3]) == 0.0 else 40), "yaw": a[1], "pitch": a[2], "view_tp": v[0] != "fp"}
				steps.append({"call": _aim_reset.bind(item), "t": 600.0, "until": _ticks.bind(80), "yaw": 0, "pitch": 0, "view_tp": v[0] != "fp"})
				if float(a[3]) != 0.0:
					st.erase("yaw")
					st["yaw_rate"] = a[3]
				st["call"] = _body_cam.bind(v[1], v[2], v[0] == "fp")
				steps.append(st)
				var shot := st.duplicate()
				shot.erase("call")
				shot["until"] = _ticks.bind(4)
				shot["shot"] = "aim_%s_%s" % [a[0], v[0]]
				steps.append(shot)
		return
	# Hits with the rifle up (V5): the body flinches, the gun is knocked off its line, the support hand knocked off.
	steps.append({"call": _arm.bind("rifle"), "t": 600.0, "until": _ticks.bind(100), "yaw": 0, "pitch": 0})
	for h: Array in [["torso", UltraLimbs.Region.TORSO, 25.0], ["gun_arm", UltraLimbs.Region.FOREARM_R, 25.0], ["support_arm", UltraLimbs.Region.FOREARM_L, 60.0]]:
		steps.append({"call": _hit.bind(h[1], h[2]), "t": 600.0, "until": _ticks.bind(6), "yaw": 0, "pitch": 0, "shot": "hit_%s" % h[0]})
		steps.append({"t": 600.0, "until": _ticks.bind(70), "yaw": 0, "pitch": 0})
	steps.append({"call": _arm.bind("rifle"), "t": 600.0, "until": _ticks.bind(80), "yaw": 0, "pitch": 0})
	steps.append({"call": _freelook.bind(true), "t": 600.0, "until": _ticks.bind(50), "yaw": 0, "pitch": 0, "shot": "freelook_left"})
	steps.append({"call": _freelook.bind(false), "t": 600.0, "until": _ticks.bind(50), "yaw": 0, "pitch": 0, "shot": "freelook_back"})


var _tick0 := 0


func _ticks(n: int) -> bool:
	return Engine.get_physics_frames() - _tick0 >= n


func _setup() -> void:
	_c = main.player
	for n in get_tree().root.find_children("*", "CanvasLayer", true, false):
		(n as CanvasLayer).visible = false
	_cam = Camera3D.new()
	main.add_child(_cam)
	_cam.fov = 40.0
	_cam.current = true
	for item: StringName in [&"rifle", &"pistol", &"ammo_556", &"ammo_9mm"]:
		UltraItems.give(_c, item)
	for i in _c.inventory.size():
		var it := _c.inventory.get_slot(i)
		if it:
			_slots[String(it.def_id)] = i + 1
	_c.teleport(main.map.call("marker", "spawn").global_position + Vector3(-16, 0, -3), 0.0)


func _arm(item: String) -> void:
	_slot = int(_slots.get(item, 0))
	_tick0 = Engine.get_physics_frames()


func _hit(region: int, amount: float) -> void:
	_c.state.hp = 100.0
	var d := UltraCombat.DamageInfo.new()
	d.amount = amount
	d.region = region
	d.kind = &"bullet"
	d.dir = Vector3(1, 0, 0.3).normalized()
	d.point = _c.state.pos + Vector3.UP * 1.3
	_c.apply_damage(d)
	_c.state.hp = 100.0
	_view_off = Vector3(1.4, 1.5, -1.6)
	_look_y = 1.3
	_tick0 = Engine.get_physics_frames()


func _cam_at(off: Vector3, look_y: float) -> void:
	_view_off = off
	_look_y = look_y
	_tick0 = Engine.get_physics_frames()


var _follow_body := false


func _aim_reset(item: String) -> void:
	if not _slots.has(item):
		UltraItems.give(_c, StringName(item))
		UltraItems.give(_c, &"ammo_12g")
		for i in _c.inventory.size():
			var it := _c.inventory.get_slot(i)
			if it:
				_slots[String(it.def_id)] = i + 1
	_slot = int(_slots.get(item, 0))
	_cam.current = true
	_follow_body = false
	_view_off = Vector3(-0.9, 1.6, -1.6)
	_look_y = 1.3
	_tick0 = Engine.get_physics_frames()


func _body_cam(off: Vector3, look_y: float, fp: bool) -> void:
	_view_off = off
	_look_y = look_y
	_follow_body = true
	_cam.current = not fp
	_tick0 = Engine.get_physics_frames()


func _empty() -> void:
	_c.state.mag = 0
	_tick0 = Engine.get_physics_frames()


func _freelook(on: bool) -> void:
	var fl := MarksmanFreelook.new(_c, null) if not (_c is MarksmanCharacter and (_c as MarksmanCharacter).eye) else (_c as MarksmanCharacter).eye.freelook
	if fl and on:
		fl.offset = Vector2(1.0, 0.15)
		fl.force = true
	elif fl:
		fl.force = false
	_view_off = Vector3(0.2, 1.65, -1.6)
	_look_y = 1.55
	_tick0 = Engine.get_physics_frames()


func _process(delta: float) -> void:
	super._process(delta)
	if _cam == null or _c == null or _c.visual_root == null:
		return
	var root := _c.visual_root.global_position
	if _follow_body:
		# (Turned with the body: the offsets are for a body facing -Z.)
		var b := Basis(Vector3.UP, _c.state.body_yaw)
		_cam.global_position = root + b * _view_off
		_cam.look_at(root + Vector3.UP * _look_y + b * Vector3(0, 0, -0.35), Vector3.UP)
		return
	_cam.global_position = root + _view_off
	_cam.look_at(root + Vector3.UP * _look_y + Vector3(0, 0, -0.35), Vector3.UP)
