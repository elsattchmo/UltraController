extends "res://demo/tours/tour_base.gd"
## Marksman turning on the spot with each kit (unarmed, pistol, machete, bat, rifle): a slow quarter turn left, a half
## turn right, filmed from a fixed camera in front and above. Frames every 4 ticks (physics ticks: frame grabs are slow).
##   godot --path . --fixed-fps 60 --resolution 1280x720 -- --tour=marksman_turn_review --controller=marksman --mm
##       [--kits=pistol,bat] [--log: hips / knee height, loco node, turn weight per 4 ticks] --out=<dir>

var _cam: Camera3D
var _tick0 := 0
var _slots := {}
var _c: UltraCharacter
const AT := Vector3(-16, 0, -3)


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/marksman_turn_review")
	steps = [{"teleport": "spawn", "t": 0.6, "yaw": 0, "pitch": 0, "view_tp": true, "slot": 0}, {"call": _setup, "t": 1.0}]
	var kits := ["unarmed", "pistol", "machete", "bat", "rifle"]
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--kits="):
			kits = a.trim_prefix("--kits=").split(",")
	for kit: String in kits:
		steps.append({"call": _arm.bind(kit), "t": 600.0, "until": _ticks.bind(90), "yaw": 0, "pitch": 0, "view_tp": true})
		# A quarter turn left over a second (yaw_rate deg/s), then still.
		for k in 22:
			steps.append({"t": 600.0, "until": _ticks.bind(90 + (k + 1) * 4), "yaw_rate": 90.0 if k < 15 else 0.0, "pitch": 0,
					"view_tp": true, "shot": "%s_q_%02d" % [kit, k]})
		# A half turn right over half a second.
		steps.append({"call": _mark, "t": 0.0})
		for k in 22:
			steps.append({"t": 600.0, "until": _ticks.bind((k + 1) * 4), "yaw_rate": -360.0 if k < 8 else 0.0, "pitch": 0,
					"view_tp": true, "shot": "%s_h_%02d" % [kit, k]})


func _ticks(n: int) -> bool:
	return Engine.get_physics_frames() - _tick0 >= n


func _mark() -> void:
	_tick0 = Engine.get_physics_frames()


func _arm(kit: String) -> void:
	_c.teleport(main.map.call("marker", "spawn").global_position + AT, 0.0)
	_bot.live_yaw = 0.0
	_slot = int(_slots.get(kit, 0))
	_mark()


func _setup() -> void:
	_c = main.player
	for n in get_tree().root.find_children("*", "CanvasLayer", true, false):
		(n as CanvasLayer).visible = false
	_cam = Camera3D.new()
	main.add_child(_cam)
	_cam.fov = 40.0
	_cam.current = true
	for item: StringName in [&"pistol", &"machete", &"bat", &"rifle"]:
		if _c.inventory.count_of(item) == 0:
			UltraItems.give(_c, item)
	for i in _c.inventory.size():
		var it := _c.inventory.get_slot(i)
		if it and not _slots.has(String(it.def_id)):
			_slots[String(it.def_id)] = i + 1


func _process(delta: float) -> void:
	super._process(delta)
	if _cam == null:
		return
	if OS.get_cmdline_user_args().has("--log") and _c and Engine.get_physics_frames() % 4 == 0:
		var sk := _c.skeleton
		var drv := _c.anim as MarksmanAnimDriver
		var hips := (sk.global_transform * sk.get_bone_global_pose(sk.find_bone("Hips")).origin).y - _c.state.pos.y
		var lk := (sk.global_transform * sk.get_bone_global_pose(sk.find_bone("LeftLowerLeg")).origin).y - _c.state.pos.y
		print("LOG f%d hips %.2f knee %.2f state %s yaw %.2f body %.2f loco %s turn_w %.2f key %s clip %s gait_w %.2f blend %.2f" % [Engine.get_physics_frames(),
				hips, lk, MotorState.Id.keys()[_c.state.state], _bot.live_yaw, _c.state.body_yaw, drv._cur_loco, drv.turn_w, drv._mk_turn_key,
				String(drv.mm.db.clips[drv.mm.clip].name).get_file() if drv.mm and drv.mm.clip >= 0 else "-",
				(_c.ragdoll as SinewRagdoll).gait_w, (_c.ragdoll as SinewRagdoll).modifier.blend])
	var at: Vector3 = main.map.call("marker", "spawn").global_position + AT + Vector3(0, 0.9, 0)
	_cam.global_position = at + Vector3(0.0, 2.2, -3.2)
	_cam.look_at(at, Vector3.UP)
