extends UltraTour
## Review tour: the support (left) hand on long guns - close-ups and numbers. Rifle and shotgun,
## first- and third-person mode, filmed from outside: idle, walking, strafing, looking around,
## aiming, crouched. Each segment prints how the hand moves on the gun (`slide` = range of the
## hand in the gun's frame, `jit` = frame-to-frame jerk, mm) and how deep the fingers sink into
## the gun's parts (`pen`, mm, worst finger joint).
##   godot --path . --resolution 1280x720 -- --tour=grip_review --out=C:/Dev/verify/ultra/review/grip_review

var _cam: Camera3D
var _seg := ""
var _rows := {}
var _prev := []
var _parts := []           ## [AABB in gun space]
var _worst_name := ""


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/grip_review")
	var F := InputFrame
	steps = [
		{"teleport": "speed_start", "t": 0.6, "yaw": 0, "pitch": -4, "view_tp": false, "slot": 0},
		{"call": _give, "t": 0.3},
		{"call": _side_on, "t": 0.3, "slot": 0},
	]
	var quick: bool = main.args.has("quick")          # (--quick: rifle, third person only)
	for slot in ([2] if quick else [2, 3]):
		for view in (["tp"] if quick else ["fp", "tp"]):
			var tp: bool = view == "tp"
			var tag := "%s_%s" % ["rifle" if slot == 2 else "shotgun", view]
			steps.append({"teleport": "speed_start", "t": 1.6, "yaw": 0, "pitch": -4, "view_tp": tp, "slot": slot, "call": _mark.bind(""), "shot": tag + "_a_idle"})
			steps.append({"t": 1.2, "slot": slot, "call": _mark.bind(tag + " idle"), "shot": tag + "_a_idle2"})
			steps.append({"t": 1.4, "slot": slot, "move": Vector2(0, 1), "call": _mark.bind(tag + " walk"), "shot": tag + "_b_walk"})
			steps.append({"t": 1.4, "slot": slot, "move": Vector2(1, 0), "call": _mark.bind(tag + " strafe"), "shot": tag + "_c_strafe"})
			steps.append({"t": 1.4, "slot": slot, "yaw_rate": 60.0, "call": _mark.bind(tag + " look"), "shot": tag + "_d_look"})
			steps.append({"t": 1.0, "slot": slot, "pitch": 30, "call": _mark.bind(tag + " look up"), "shot": tag + "_e_up"})
			steps.append({"t": 1.0, "slot": slot, "pitch": -40, "call": _mark.bind(tag + " look down"), "shot": tag + "_f_down"})
			steps.append({"t": 1.2, "slot": slot, "pitch": -4, "buttons": F.B_SECONDARY, "call": _mark.bind(tag + " ads"), "shot": tag + "_g_ads"})
			steps.append({"t": 1.4, "slot": slot, "move": Vector2(0, 1), "buttons": F.B_SECONDARY, "call": _mark.bind(tag + " ads walk"), "shot": tag + "_h_adswalk"})
			steps.append({"t": 0.05, "slot": slot, "tap": F.B_CROUCH, "call": _mark.bind("")})
			steps.append({"t": 1.4, "slot": slot, "move": Vector2(0, 1), "call": _mark.bind(tag + " crouch walk"), "shot": tag + "_i_crouch"})
			steps.append({"t": 0.05, "slot": slot, "tap": F.B_CROUCH, "call": _mark.bind("")})
			steps.append({"t": 0.6, "slot": slot, "call": _report})


func _give() -> void:
	for it: Array in [[&"rifle", 1], [&"shotgun", 1], [&"ammo_556", 90], [&"ammo_12g", 30]]:
		if main.player.inventory.count_of(it[0]) == 0:
			UltraItems.give(main.player, it[0], it[1])


func _side_on() -> void:
	_cam = Camera3D.new()
	main.add_child(_cam)
	_cam.fov = 30.0
	main.player.skeleton.skeleton_updated.connect(_sample)


func _mark(label: String) -> void:
	_seg = label
	_prev = []
	_parts = []


func _report() -> void:
	for k: String in _rows:
		var r: Dictionary = _rows[k]
		var n := maxi(int(r.n), 1)
		print("GRIP %-24s slide %5.1f  jit avg %5.2f max %5.2f  pen avg %5.1f max %5.1f  err %5.1f" % [k,
			(r.hi as Vector3 - r.lo as Vector3).length() * 1000.0, r.jit / n * 1000.0, r.jmax * 1000.0,
			r.pen / n * 1000.0, r.pmax * 1000.0, r.err / n * 1000.0])
	print("GRIP deepest: ", _worst_name)
	_rows.clear()


## Every part of the held gun as a box in the gun's frame.
func _gun_parts(gun: Node3D) -> Array:
	var out := []
	var inv := gun.global_transform.affine_inverse()
	for m in gun.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		if mi.mesh == null or not mi.is_visible_in_tree() or mi.name.begins_with("M_"):
			continue
		out.append((inv * mi.global_transform) * mi.get_aabb())
	return out


func _sample() -> void:
	var c: UltraCharacter = main.player
	var eq := c.get_node_or_null("Equipment") as UltraEquipmentVisual
	if _seg == "" or eq == null or eq.held_node == null:
		return
	var sk := c.skeleton
	var gun := (eq.held_node as Node3D).global_transform
	if _parts.is_empty():
		_parts = _gun_parts(eq.held_node)
	var inv := gun.affine_inverse()
	var lh := inv * (sk.global_transform * sk.get_bone_global_pose(sk.find_bone("LeftHand"))).origin
	var r: Dictionary = _rows.get(_seg, {"n": 0, "lo": lh, "hi": lh, "jit": 0.0, "jmax": 0.0, "pen": 0.0, "pmax": 0.0, "err": 0.0})
	r.n += 1
	r.lo = (r.lo as Vector3).min(lh)
	r.hi = (r.hi as Vector3).max(lh)
	_prev.append(lh)
	if _prev.size() > 3:
		_prev.pop_front()
	if _prev.size() == 3:
		var j := ((_prev[2] as Vector3) - (_prev[1] as Vector3) * 2.0 + (_prev[0] as Vector3)).length()
		r.jit += j
		r.jmax = maxf(r.jmax, j)
	# Deepest finger joint inside any part of the gun.
	var worst := 0.0
	for b in sk.get_bone_count():
		var n := sk.get_bone_name(b)
		if not n.begins_with("Left") or not (n.contains("Index") or n.contains("Middle") or n.contains("Ring") or n.contains("Little") or n.contains("Thumb")):
			continue
		var p := inv * (sk.global_transform * sk.get_bone_global_pose(b)).origin
		for a: AABB in _parts:
			if a.has_point(p):
				var d := minf(minf(minf(p.x - a.position.x, a.end.x - p.x), minf(p.y - a.position.y, a.end.y - p.y)), minf(p.z - a.position.z, a.end.z - p.z))
				if d > worst:
					worst = d
					_worst_name = "%s in %s" % [n, a]
	r.pen += worst
	r.pmax = maxf(r.pmax, worst)
	r.err += float(c.anim.hand_ik.last_error[HandIKModifier.Hand.LEFT])
	if main.args.has("trace") and _seg.ends_with(String(main.args["trace"])):
		print("TR %d lh %s slide %.4f err %.4f" % [Engine.get_process_frames(), lh, eq._left_slide, c.anim.hand_ik.last_error[HandIKModifier.Hand.LEFT]])
	_rows[_seg] = r


func _process(delta: float) -> void:
	super(delta)
	if _cam:
		_cam.current = true
		var c: UltraCharacter = main.player
		var sk := c.skeleton
		var lh := (sk.global_transform * sk.get_bone_global_pose(sk.find_bone("LeftHand"))).origin
		var yaw := c.state.body_yaw
		var right := Vector3(cos(yaw), 0, -sin(yaw))
		var fwd := Vector3(-sin(yaw), 0, -cos(yaw))
		# --cam=right / below: the far side of the handguard, or from under it.
		match String(main.args.get("cam", "left")):
			"right":
				_cam.global_position = lh + right * 0.9 + fwd * 0.45 + Vector3.UP * 0.2
			"below":
				_cam.global_position = lh - right * 0.25 + fwd * 0.3 + Vector3.DOWN * 0.7
			_:
				_cam.global_position = lh - right * 0.9 + fwd * 0.35 + Vector3.UP * 0.25
		_cam.look_at(lh + right * 0.05, fwd if String(main.args.get("cam", "")) == "below" else Vector3.UP)
