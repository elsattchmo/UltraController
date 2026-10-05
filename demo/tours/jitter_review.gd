extends UltraTour
## Diagnostic tour: records the camera and the held gun every rendered frame (real time, real
## frame rate) through first- and third-person gun use, and prints jerk statistics per phase
## (median / p95 / max of the per-frame second difference; "long" = frames over 25 ms, which
## show up as world-space spikes that aren't the controller's). JIT_PHASE="rifle FP aim turn"
## traces one phase frame by frame.
##   godot --path . --resolution 1280x720 -- --tour=jitter_review --out=C:/Dev/verify/ultra/review/jitter_review

var _rec := []
var _phase := ""
var _lines := []


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/jitter_review")
	var F := InputFrame
	steps = [
		{"teleport": "speed_start", "t": 0.6, "yaw": 0, "pitch": -5, "view_tp": false, "slot": 0},
		{"call": _give, "t": 0.2},
	]
	for gun in [1, 2]:
		for view_tp in [false, true]:
			var tag := "%s %s" % ["pistol" if gun == 1 else "rifle", "TP" if view_tp else "FP"]
			steps.append({"t": 1.2, "slot": gun, "view_tp": view_tp, "yaw": 0})
			for ph: Array in [["idle", Vector2.ZERO, 0, 0.0], ["walk", Vector2(0, 1), 0, 0.0], ["sprint", Vector2(0, 1), F.B_SPRINT, 0.0], ["aim", Vector2.ZERO, F.B_SECONDARY, 0.0], ["turn", Vector2.ZERO, 0, 90.0], ["aim turn", Vector2.ZERO, F.B_SECONDARY, 60.0], ["fire", Vector2.ZERO, F.B_SECONDARY | F.B_PRIMARY, 0.0]]:
				var label: String = "%s %s" % [tag, ph[0]]
				steps.append({"call": _starter(label), "t": 1.5, "slot": gun, "view_tp": view_tp, "move": ph[1], "buttons": ph[2], "yaw_rate": ph[3]})
			steps.append({"call": _starter(""), "t": 0.6, "slot": gun, "view_tp": view_tp})
	steps.append({"call": _report, "t": 0.2})


func _starter(label: String) -> Callable:
	return func() -> void: _start(label)


func _give() -> void:
	for it: Array in [[&"pistol", 1], [&"rifle", 1], [&"ammo_9mm", 60], [&"ammo_556", 90]]:
		if main.player.inventory.count_of(it[0]) == 0:
			UltraItems.give(main.player, it[0], it[1])


var _hooked := false


func _start(label: String) -> void:
	if not _hooked and main and main.player and main.player.anim:
		main.player.anim.skeleton.skeleton_updated.connect(_on_skel)
		_hooked = true
	print("PHASE ", label, " t=", Time.get_ticks_msec(), " fps ", Engine.get_frames_per_second())
	_flush()
	_phase = label
	_rec = []


## Sampled when the skeleton has its final pose for the frame (the camera was placed earlier in
## the same frame): exactly what gets rendered. (Sampling in _process mixed this frame's body
## placement with last frame's pose.)
func _on_skel() -> void:
	if _phase == "" or main == null or main.player == null:
		return
	var cam := get_viewport().get_camera_3d()
	var pl: UltraCharacter = main.player
	var eq := pl.get_node_or_null("Equipment") as UltraEquipmentVisual
	if cam == null or eq == null:
		return
	var sk := pl.anim.skeleton
	var g := Transform3D()
	if eq.held_node:
		var hb := sk.find_bone(&"RightHand" if eq.held_node.get_parent() == eq.hand_attach else &"LeftHand")
		g = sk.global_transform * sk.get_bone_global_pose(hb) * eq.held_node.transform
	var hand_l := pl.visual_root.global_transform.affine_inverse() * (sk.global_transform * sk.get_bone_global_pose(sk.find_bone(&"LeftHand"))).origin
	var head := pl.visual_root.global_transform.affine_inverse() * (sk.global_transform * sk.get_bone_global_pose(sk.find_bone(&"Head"))).origin
	_rec.append([cam.global_transform, g, Engine.get_frames_per_second(), pl.visual_root.global_transform, head, hand_l, get_process_delta_time()])
	if OS.get_environment("JIT_PHASE") == _phase:
		# Per-frame trace of one phase: gun in camera space, support hand in body space.
		var ci := cam.global_transform.affine_inverse()
		print("JF %d gun %s Lhand %s state %s tick %d dt %.1f ms" % [_rec.size(), (ci * g.origin).snappedf(0.001), hand_l.snappedf(0.001), MotorState.Id.keys()[pl.state.state], pl.tick, get_process_delta_time() * 1000.0])


func _flush() -> void:
	if _phase == "" or _rec.size() < 10:
		return
	var cj := []
	var gj := []
	var rj := []
	var bj := []
	var hj := []
	var lj := []
	for i in range(1, _rec.size() - 1):
		var a: Transform3D = _rec[i - 1][0]
		var b: Transform3D = _rec[i][0]
		var c: Transform3D = _rec[i + 1][0]
		cj.append(((c.origin - b.origin) - (b.origin - a.origin)).length() * 1000.0)
		var q0 := a.basis.get_rotation_quaternion()
		var q1 := b.basis.get_rotation_quaternion()
		var q2 := c.basis.get_rotation_quaternion()
		rj.append(rad_to_deg(((q2 * q1.inverse()) * (q1 * q0.inverse()).inverse()).get_angle()))
		var ga: Vector3 = a.affine_inverse() * (_rec[i - 1][1] as Transform3D).origin
		var gb: Vector3 = b.affine_inverse() * (_rec[i][1] as Transform3D).origin
		var gc: Vector3 = c.affine_inverse() * (_rec[i + 1][1] as Transform3D).origin
		gj.append(((gc - gb) - (gb - ga)).length() * 1000.0)
		var ra: Vector3 = _rec[i - 1][3].origin
		var rb: Vector3 = _rec[i][3].origin
		var rc: Vector3 = _rec[i + 1][3].origin
		bj.append(((rc - rb) - (rb - ra)).length() * 1000.0)
		for k in [4, 5]:
			var pa: Vector3 = _rec[i - 1][k]
			var pb: Vector3 = _rec[i][k]
			var pc: Vector3 = _rec[i + 1][k]
			(hj if k == 4 else lj).append(((pc - pb) - (pb - pa)).length() * 1000.0)
	var long := 0
	for r: Array in _rec:
		if float(r[6]) > 0.025:
			long += 1
	_lines.append("%-20s long %d fps %3d | cam mm %s | cam deg %s | gun/cam mm %s | body mm %s | head mm %s | L hand mm %s" % [_phase, long, int(_rec[_rec.size() / 2][2]), _stat(cj), _stat(rj), _stat(gj), _stat(bj), _stat(hj), _stat(lj)])


static func _stat(a: Array) -> String:
	var s := a.duplicate()
	s.sort()
	return "%4.1f/%5.1f/%6.1f" % [s[s.size() / 2], s[int(s.size() * 0.95)], s[s.size() - 1]]


func _report() -> void:
	_flush()
	_phase = ""
	print("JITTER\n" + "\n".join(_lines))
