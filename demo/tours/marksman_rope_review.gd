extends UltraTour
## Marksman on the swing rope (MarksmanRopePass): hands on the rope, legs pumping the swing - side on, a frame at the
## front, the middle and the back of a swing, then letting go.
##   godot --path . --fixed-fps 60 --resolution 1280x720 -- --tour=marksman_rope_review --controller=marksman --mm --out=<dir>
## (Generous limits: steps end on the rope's state, not the clock - under a slow renderer the run-up took longer.)

const Id := MotorState.Id


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/marksman_rope_review")
	var F := InputFrame
	steps = [
		{"teleport": "parkour_rope", "t": 0.5, "yaw": 0, "pitch": 0, "view_tp": true},
		{"t": 30.0, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "jump_near_z": -55.4, "until": func() -> bool: return _st().state == Id.ROPE, "after": 0.2},
		{"t": 6.0, "pump": true},
		{"t": 0.05, "pump": true, "yaw": 90, "pitch": 5},
		{"t": 8.0, "pump": true, "until": func() -> bool: return _st().vel.z < -2.5, "after": 0.0, "shot": "01_swing_forward_fast"},
		{"t": 8.0, "pump": true, "until": func() -> bool: return absf(_st().vel.z) < 0.4 and _front(), "after": 0.0, "shot": "02_front_of_swing"},
		{"t": 8.0, "pump": true, "until": func() -> bool: return _st().vel.z > 2.5, "after": 0.0, "shot": "03_swing_back_fast"},
		{"t": 8.0, "pump": true, "until": func() -> bool: return absf(_st().vel.z) < 0.4 and not _front(), "after": 0.0, "shot": "04_back_of_swing"},
		{"t": 0.1, "tap": F.B_JUMP},
		{"t": 0.25, "shot": "05_letting_go"},
		{"t": 1.0, "shot": "06_after"},
	]


func _st() -> MotorState:
	return main.player.state


## Out in front of the rope's anchor (the swing's front: -Z of it).
func _front() -> bool:
	var r := UltraRope.find(_st().trav_id)
	return r != null and _st().pos.z < r.anchor().z


func _drive(tick: int, src: BotInputSource) -> InputFrame:
	var f := super._drive(tick, src)
	if _i < 0 or _i >= steps.size():
		return f
	var s: Dictionary = steps[_i]
	if s.has("jump_near_z") and _st().pos.z < float(s["jump_near_z"]) and _st().is_grounded():
		f.buttons |= InputFrame.B_JUMP
	if s.get("pump", false):
		f.move = Vector2(0, 1.0 if _st().vel.z < 0.0 else -1.0)
		f.pitch = 0.0
	return f
