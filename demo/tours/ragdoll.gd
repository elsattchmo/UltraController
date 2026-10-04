extends UltraTour
## Review: active ragdoll falls (forward / backward / big drop) and the matching get-ups.

const Id := MotorState.Id


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/ragdoll")
	steps = []
	for cfg: Array in [["fwd", Vector3(0, 2.0, -6.0)], ["back", Vector3(0, 2.0, 6.0)]]:
		steps.append({"teleport": "speed_start", "t": 0.8, "yaw": 0, "pitch": -12, "view_tp": true, "slot": 0})
		steps.append({"call": func() -> void: _close(), "t": 0.6, "yaw": -70})
		steps.append({"call": func() -> void: main.player.knock_down(cfg[1]), "t": 0.2, "shot": "%s_1_hit" % cfg[0]})
		steps.append({"t": 0.25, "shot": "%s_2_falling" % cfg[0]})
		steps.append({"t": 0.35, "shot": "%s_3_impact" % cfg[0]})
		steps.append({"t": 4.0, "until": func() -> bool: return main.player.state.state == Id.GET_UP, "shot": "%s_4_lying" % cfg[0]})
		for k in 4:
			steps.append({"t": 0.38, "shot": "%s_5_getup_%d" % [cfg[0], k]})
		steps.append({"t": 0.6, "shot": "%s_6_up" % cfg[0]})


func _close() -> void:
	var rig := get_tree().root.find_children("*", "UltraCameraRig", true, false)[0] as UltraCameraRig
	rig.cam_profile.tp_distance = 3.6
