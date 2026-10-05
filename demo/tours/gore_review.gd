extends UltraTour
## Review tour: blood and gun smoke - rifle hits on a dummy (spatter on it and the ground
## behind), a limb off (the stump pumps blood, the dummy bleeds out lying in a spreading pool),
## muzzle smoke and barrel wisps, the shotgun's shell ejected as the pump is racked.
##   godot --path . --resolution 1280x720 -- --tour=gore_review --out=C:/Dev/verify/ultra/review/gore_review

var _cam: Camera3D
var _dummy: UltraCharacter
var _view := 0             ## 0 player, 1 wide side, 2 on the dummy, 3 at the muzzle, 4 at the ejection port
var _track := false


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/gore_review")
	var F := InputFrame
	steps = [
		{"teleport": "speed_start", "t": 0.8, "yaw": 0, "pitch": -2, "view_tp": true, "slot": 2},
		{"call": _place_dummy, "t": 1.4, "slot": 2, "buttons": F.B_SECONDARY},
		{"call": func() -> void: _set_view(1), "t": 0.05, "slot": 2, "buttons": F.B_SECONDARY | F.B_PRIMARY},
		{"t": 0.25, "slot": 2, "buttons": F.B_SECONDARY, "shot": "rifle_hit_0"},
		{"t": 0.25, "slot": 2, "buttons": F.B_SECONDARY, "shot": "rifle_hit_1"},
		{"t": 0.8, "slot": 2, "shot": "rifle_hit_2"},
		{"call": _cut_arm, "t": 0.15, "slot": 2, "shot": "cut_0"},
	]
	for k in 8:
		steps.append({"t": 0.35, "slot": 2, "shot": "bleed_%d" % k})
	steps.append({"call": _knock, "t": 1.0, "slot": 2})
	for k in 6:
		steps.append({"t": 0.7, "slot": 2, "shot": "pool_%d" % k})
	steps.append({"call": func() -> void: _set_view(2), "t": 0.2, "slot": 2, "shot": "body_close"})
	# Smoke and the shotgun's shell.
	steps.append({"call": func() -> void: _set_view(3), "t": 1.5, "slot": 3, "buttons": F.B_SECONDARY})
	steps.append({"t": 0.05, "slot": 3, "buttons": F.B_SECONDARY | F.B_PRIMARY})
	for k in 6:
		steps.append({"t": 0.15, "slot": 3, "buttons": F.B_SECONDARY, "shot": "smoke_%d" % k})
	steps.append({"call": func() -> void: _set_view(4), "t": 1.6, "slot": 3, "buttons": F.B_SECONDARY})
	steps.append({"t": 0.05, "slot": 3, "buttons": F.B_SECONDARY | F.B_PRIMARY})
	steps.append({"t": 0.45, "slot": 3, "buttons": F.B_SECONDARY})
	for k in 10:
		steps.append({"t": 0.04, "slot": 3, "buttons": F.B_SECONDARY, "shot": "eject_%d" % k})


func _place_dummy() -> void:
	var c: UltraCharacter = main.player
	var fwd := Vector3(-sin(c.state.body_yaw), 0, -cos(c.state.body_yaw))
	var p := UltraNet.spawn_bot("Dummy", Transform3D(Basis(Vector3.UP, c.state.body_yaw + PI), c.state.pos + fwd * 5.0))
	(p.character.input_source as BotInputSource).set_steps([{"ticks": 100000}])
	_dummy = p.character
	_track = true


func _cut_arm() -> void:
	_track = false
	var d := UltraCombat.DamageInfo.new()
	d.amount = 60.0
	d.region = UltraLimbs.Region.ARM_L
	d.kind = &"blade"
	d.dir = Vector3(-1, 0, 0)
	d.point = _dummy.state.pos + Vector3.UP * 1.35
	_dummy.apply_damage(d)


func _knock() -> void:
	_dummy.state.hp = minf(_dummy.state.hp, 12.0)      # (bleeds out lying there)
	_dummy.knock_down(Vector3(0, 0, -2.0))


func _set_view(v: int) -> void:
	_view = v
	if _cam == null:
		_cam = Camera3D.new()
		main.add_child(_cam)
	_cam.fov = 45.0 if v < 3 else 30.0
	_cam.current = true


func _process(delta: float) -> void:
	super(delta)
	var c: UltraCharacter = main.player
	if _track and _dummy:
		var rig: UltraCameraRig = main.find_children("*", "UltraCameraRig", true, false)[0]
		var to := _dummy.state.pos + Vector3.UP * 1.25 - rig.global_position
		_bot.live_yaw = atan2(-to.x, -to.z)
		_bot.live_pitch = asin(to.normalized().y)
	if _cam == null or _view == 0:
		return
	var yaw := c.state.body_yaw
	var right := Vector3(cos(yaw), 0, -sin(yaw))
	var fwd := Vector3(-sin(yaw), 0, -cos(yaw))
	var eq := c.get_node_or_null("Equipment") as UltraEquipmentVisual
	match _view:
		1:
			var p := c.visual_root.global_position + Vector3.UP * 0.8 + fwd * 3.5
			_cam.global_position = p + right * 6.5 + Vector3.UP * 1.2
			_cam.look_at(p)
		2:
			var p := _dummy.visual_root.global_position + Vector3.UP * 0.3
			_cam.global_position = p + right * 1.6 + Vector3.UP * 1.4 + fwd * 0.6
			_cam.look_at(p)
		3:
			if eq and eq.held_node:
				var m := eq.muzzle_transform().origin
				_cam.global_position = m + right * 1.4 + Vector3.UP * 0.25 - fwd * 0.4
				_cam.look_at(m + fwd * 0.3)
		4:
			if eq and eq.held_node:
				var e := eq.eject_transform().origin
				_cam.global_position = e + right * 0.9 + Vector3.UP * 0.35 + fwd * 0.3
				_cam.look_at(e + right * 0.25)
