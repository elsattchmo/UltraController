extends UltraTour
## Review tour: the shotgun - held and aimed (both views), the pump racked after a shot, the
## shell-at-a-time reload, and a point-blank blast on a dummy (knock-back, a limb off).
##   godot --path . --resolution 1280x720 -- --tour=shotgun_review --out=C:/Dev/verify/ultra/review/shotgun_review

var _cam: Camera3D
var _side := false
var _dummy: UltraCharacter


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/shotgun_review")
	var F := InputFrame
	steps = [
		{"teleport": "speed_start", "t": 0.6, "yaw": 0, "pitch": -4, "view_tp": false, "slot": 0},
		{"call": _give, "t": 0.3},
		{"t": 1.4, "slot": 3, "shot": "fp_hip"},
		{"t": 0.8, "slot": 3, "buttons": F.B_SECONDARY, "shot": "fp_ads"},
		{"t": 0.05, "slot": 3, "buttons": F.B_SECONDARY | F.B_PRIMARY},
	]
	for k in 8:
		steps.append({"t": 0.07, "slot": 3, "buttons": F.B_SECONDARY, "shot": "fp_pump_%d" % k})
	steps.append({"t": 0.6, "slot": 3})
	steps.append({"call": _empty, "t": 0.05, "slot": 3, "tap": F.B_RELOAD})
	for k in 10:
		steps.append({"t": 0.12, "slot": 3, "shot": "fp_reload_%d" % k})
	steps.append({"t": 2.5, "slot": 3})
	# Third person, side on.
	steps.append({"t": 1.0, "slot": 3, "view_tp": true, "shot": "tp_hip"})
	steps.append({"call": _side_on, "t": 0.5, "slot": 3, "buttons": F.B_SECONDARY, "shot": "side_aim"})
	steps.append({"t": 0.05, "slot": 3, "buttons": F.B_SECONDARY | F.B_PRIMARY})
	for k in 8:
		steps.append({"t": 0.07, "slot": 3, "buttons": F.B_SECONDARY, "shot": "side_pump_%d" % k})
	steps.append({"t": 0.5, "slot": 3})
	steps.append({"call": _empty, "t": 0.05, "slot": 3, "tap": F.B_RELOAD})
	for k in 10:
		steps.append({"t": 0.12, "slot": 3, "shot": "side_reload_%d" % k})
	steps.append({"t": 2.5, "slot": 3})
	# A dummy 3 m ahead: blast it.
	steps.append({"call": _place_dummy, "t": 0.6, "slot": 3, "buttons": F.B_SECONDARY})
	steps.append({"call": _aim_at_dummy, "t": 1.5, "slot": 3, "buttons": F.B_SECONDARY})
	steps.append({"t": 0.05, "slot": 3, "buttons": F.B_SECONDARY | F.B_PRIMARY, "shot": "blast_0"})
	for k in 8:
		steps.append({"t": 0.1, "slot": 3, "shot": "blast_%d" % (k + 1)})


func _give() -> void:
	for it: Array in [[&"pistol", 1], [&"rifle", 1], [&"shotgun", 1], [&"ammo_12g", 30]]:
		if main.player.inventory.count_of(it[0]) == 0:
			UltraItems.give(main.player, it[0], it[1])


func _empty() -> void:
	main.player.state.mag = 2


func _side_on() -> void:
	_cam = Camera3D.new()
	main.add_child(_cam)
	_cam.fov = 40.0
	_cam.current = true
	_side = true


func _place_dummy() -> void:
	var c: UltraCharacter = main.player
	var fwd := Vector3(-sin(c.state.body_yaw), 0, -cos(c.state.body_yaw))
	var p := UltraNet.spawn_bot("Dummy", Transform3D(Basis(Vector3.UP, c.state.body_yaw + PI), c.state.pos + fwd * 3.0))
	(p.character.input_source as BotInputSource).set_steps([{"ticks": 100000}])
	_dummy = p.character


## Keep the crosshair (the camera's centre - third person, over the shoulder) on its chest.
var _track := false


func _aim_at_dummy() -> void:
	_track = true


func _track_dummy() -> void:
	var rig: UltraCameraRig = main.find_children("*", "UltraCameraRig", true, false)[0]
	var to := _dummy.state.pos + Vector3.UP * 1.25 - rig.global_position
	_bot.live_yaw = atan2(-to.x, -to.z)
	_bot.live_pitch = asin(to.normalized().y)


func _process(delta: float) -> void:
	super(delta)
	if _track and _dummy and _dummy.state.state == MotorState.Id.IDLE:
		_track_dummy()
	if _side and _cam:
		var c: UltraCharacter = main.player
		var yaw := c.state.body_yaw
		var right := Vector3(cos(yaw), 0, -sin(yaw))
		var fwd := Vector3(-sin(yaw), 0, -cos(yaw))
		var p := c.visual_root.global_position + Vector3.UP * 1.0 + fwd * (4.0 if _dummy else 0.4)
		_cam.global_position = p + right * (11.0 if _dummy else 2.6) + Vector3.UP * 0.2
		_cam.look_at(p)
