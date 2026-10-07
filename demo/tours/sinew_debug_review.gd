extends "res://demo/tours/sinew_review.gd"
## Review tour for the Sinew debug view (K / --sinew-debug): standing powered (muscles coloured
## by effort), walking and sprinting (the legs show the gait's estimate), a hard hit -> stagger on physical legs with the COM,
## capture point and support polygon, the x-ray view, a blow it can't take -> knocked down.
##   godot --path . --resolution 1280x720 -- --tour=sinew_debug_review --controller=sinew --out=<dir>


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/sinew_debug_review")
	steps = [
		{"teleport": "speed_start", "t": 0.6, "yaw": 0, "pitch": -4, "view_tp": true, "slot": 0},
		{"call": _setup_debug, "t": 2.5, "shot": "overlay_stand"},
		# Walking / sprinting: the animated legs show the gait's estimate (standing leg loaded, swing light).
		{"t": 1.2, "move": Vector2(0, 1), "yaw": 0},
		{"t": 0.1, "move": Vector2(0, 1), "yaw": 0, "shot": "walk_0"},
		{"t": 0.12, "move": Vector2(0, 1), "yaw": 0, "shot": "walk_1"},
		{"t": 0.12, "move": Vector2(0, 1), "yaw": 0, "shot": "walk_2"},
		{"t": 1.6, "move": Vector2(0, 1), "yaw": 0, "buttons": InputFrame.B_SPRINT},
		{"t": 0.08, "move": Vector2(0, 1), "yaw": 0, "buttons": InputFrame.B_SPRINT, "shot": "sprint_0"},
		{"t": 0.08, "move": Vector2(0, 1), "yaw": 0, "buttons": InputFrame.B_SPRINT, "shot": "sprint_1"},
		{"t": 2.0, "move": Vector2.ZERO, "yaw": 0, "shot": "stopped"},
		{"call": _slow.bind(true), "t": 0.0},
		{"call": _hit_chest, "t": 0.08, "shot": "stagger_0"},
		{"t": 0.15, "shot": "stagger_1"},
		{"t": 0.15, "shot": "stagger_2"},
		{"t": 0.3, "shot": "stagger_3"},
		{"call": _slow.bind(false), "t": 2.0, "shot": "after_stagger"},
		{"call": _view.bind(SinewDebugDraw.View.XRAY), "t": 0.5, "shot": "xray_stand"},
		{"call": _slow.bind(true), "t": 0.0},
		{"call": _blow, "t": 0.1, "shot": "blow_0"},
		{"t": 0.15, "shot": "blow_1"},
		{"t": 0.2, "shot": "blow_2"},
		{"t": 0.3, "shot": "blow_3"},
		{"call": _slow.bind(false), "t": 1.5, "shot": "down"},
		{"call": _view.bind(SinewDebugDraw.View.OFF), "t": 0.3, "shot": "off"},
	]


func _setup_debug() -> void:
	_setup()
	SinewDebugDraw.view = SinewDebugDraw.View.OVERLAY


func _view(v: int) -> void:
	SinewDebugDraw.view = v


## A blow through the balance (250 N s on the chest): steps can't save it.
func _blow() -> void:
	var r := _c.ragdoll as SinewRagdoll
	r.start_stagger()
	var chest: int = r.world.physics.call("character_body", r._id, r._part("Chest"))
	r.world.physics.call("apply_impulse", chest, -_from.normalized() * 250.0, r.pose_now[r._part("Chest")].origin)
