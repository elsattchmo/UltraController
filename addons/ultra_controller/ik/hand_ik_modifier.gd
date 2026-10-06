class_name HandIKModifier
extends SkeletonModifier3D
## Puts hands on things: held-prop grips, ledges, ladder rungs, a weapon's support grip.
## Gameplay sets a WORLD-space target transform per hand plus a weight; weights move on a
## spring so hands reach and release smoothly. The elbow keeps its animated bend plane,
## nudged outward/down by `pole_hint`.

enum Hand { LEFT, RIGHT, LEFT_FOOT, RIGHT_FOOT }

class Goal:
	var target := Transform3D()
	var want_weight := 0.0
	var weight := 0.0
	var use_rotation := true
	var speed := 8.0             ## 1/s blend rate
	## Line goal (world direction, non-zero): the hand keeps its animated position along this
	## line through target.origin and is only pulled onto it (climbing a rope or pole), within
	## line_range metres of target.origin.
	## 0..1: fingers straightened toward the rest pose (an open hand pressed on a surface).
	var open := 0.0
	## 0..1: fingers closed round a bar (a fore-end, a rail) instead of the animated curl.
	var curl := 0.0
	var line_dir := Vector3.ZERO
	var line_range := Vector2(-0.8, 0.8)
	## The target in the skeleton's frame when it was set: a released goal fades out from
	## there, moving with the body (its world target went stale - at a sprint the hand was
	## dragged ~10 cm back toward it for the frame or two of the release).
	var target_sk := Transform3D()
	var has_sk := false
	## Held relative to the other hand (`rel_hand` >= 0, `rel` in that hand's frame): a support
	## hand on a gun the other hand holds, placed from where that hand ends up THIS frame. (A
	## world target worked out from last frame's gun trailed it, and jumped when the shouldered
	## pose took the goal over with the current one.)
	var rel_hand := -1
	var rel := Transform3D()
	## Curled fingers wrap this box (`wrap_box` centre / orientation and `wrap_half` extents in
	## `wrap_node`'s frame), each joint bending only until it touches: a fixed curl sized for
	## a 4 cm bar sank the fingers 2 cm into a handguard.
	var wrap_node: Node3D = null
	var wrap_box := Transform3D()
	var wrap_half := Vector3.ZERO

var goals := [Goal.new(), Goal.new(), Goal.new(), Goal.new()]
var last_error := [0.0, 0.0, 0.0, 0.0]
## Each arm's shoulder (upper arm head, skeleton space) as the pose reached this modifier last
## frame - after the inertial blend, before any IK. (Read in _process the shoulder is the raw
## clip pose, which jumps where the blend smooths a change of clip.)
var pre_shoulder := [Vector3.INF, Vector3.INF]

var _arms := []


func _ready() -> void:
	_resolve()


func _skeleton_changed(_o: Skeleton3D, _n: Skeleton3D) -> void:
	_resolve()


var _fingers := [PackedInt32Array(), PackedInt32Array()]


func _resolve() -> void:
	var sk := get_skeleton()
	if sk == null:
		return
	# (Packed arrays are values: fill locals, then store them.)
	var lists := [PackedInt32Array(), PackedInt32Array()]
	for i in 2:
		var side := "Left" if i == 0 else "Right"
		var l := PackedInt32Array()
		for b in sk.get_bone_count():
			var n := sk.get_bone_name(b)
			if n.begins_with(side) and (n.contains("Index") or n.contains("Middle") or n.contains("Ring") or n.contains("Little")):
				l.append(b)
		lists[i] = l
	_fingers = lists
	_arms = []
	for side in ["Left", "Right"]:
		_arms.append([sk.find_bone(side + "UpperArm"), sk.find_bone(side + "LowerArm"), sk.find_bone(side + "Hand")])
	for side in ["Left", "Right"]:
		_arms.append([sk.find_bone(side + "UpperLeg"), sk.find_bone(side + "LowerLeg"), sk.find_bone(side + "Foot")])


## Reach `hand` to `world_xform` (the hand bone's desired world transform).
func set_goal(hand: int, world_xform: Transform3D, weight := 1.0, use_rotation := true, speed := 8.0, open := 0.0) -> void:
	var g: Goal = goals[hand]
	g.line_dir = Vector3.ZERO
	g.open = open
	g.curl = 0.0
	g.target = world_xform
	g.rel_hand = -1
	var sk := get_skeleton()
	g.has_sk = sk != null
	if sk:
		g.target_sk = sk.global_transform.affine_inverse() * world_xform
	g.want_weight = clampf(weight, 0.0, 1.0)
	g.use_rotation = use_rotation
	g.speed = speed


## Hand on a line (rope, pole): keeps the animation's motion along it.
func set_line_goal(hand: int, point: Vector3, dir: Vector3, range_m := Vector2(-0.8, 0.8), weight := 1.0, speed := 10.0) -> void:
	set_goal(hand, Transform3D(Basis(), point), weight, false, speed)
	var g: Goal = goals[hand]
	g.line_dir = dir.normalized()
	g.line_range = range_m


## Keep `hand`'s goal (just set) where it is relative to `other`'s hand, `other_ref` being where
## the other hand was (world) when the goal was worked out. Solved after the other hand.
func follow_hand(hand: int, other: int, other_ref: Transform3D) -> void:
	var g: Goal = goals[hand]
	g.rel_hand = other
	g.rel = other_ref.affine_inverse() * g.target


## Close the fingers of `hand` round a bar (after set_goal, which resets it).
func set_curl(hand: int, amount: float) -> void:
	(goals[hand] as Goal).curl = clampf(amount, 0.0, 1.0)


## Wrap `hand`'s curled fingers round a box: `local` (centre / orientation) and `half` extents
## in `node`'s frame, followed as the node moves. `node` null = the fixed curl.
func set_wrap(hand: int, node: Node3D, local := Transform3D(), half := Vector3.ZERO) -> void:
	var g: Goal = goals[hand]
	g.wrap_node = node
	g.wrap_box = local
	g.wrap_half = half


func release(hand: int, speed := 6.0) -> void:
	var g: Goal = goals[hand]
	g.want_weight = 0.0
	g.speed = speed


var _palm_local := [Vector3.ZERO, Vector3.ZERO]


## World basis for the hand bone so its fingers point along `fingers` and the palm faces
## `palm`. The palm direction in the bone's own frame is learned from the animated (curled)
## fingers the first time it's asked.
func hand_basis(hand: int, fingers: Vector3, palm: Vector3) -> Basis:
	var sk := get_skeleton()
	if sk == null or hand > 1:
		return Basis()
	if _palm_local[hand] == Vector3.ZERO:
		var side := "Left" if hand == 0 else "Right"
		var hb := sk.get_bone_global_pose(sk.find_bone(side + "Hand"))
		var tip := Vector3.ZERO
		for f in ["MiddleDistal", "RingDistal", "IndexDistal"]:
			tip += sk.get_bone_global_pose(sk.find_bone(side + f)).origin / 3.0
		var v := hb.basis.orthonormalized().inverse() * (tip - hb.origin)
		v.y = 0.0
		if v.length() < 0.005:
			return Basis()
		_palm_local[hand] = v.normalized()
	var src_p: Vector3 = _palm_local[hand]
	var src := Basis(Vector3.UP.cross(src_p), Vector3.UP, src_p)
	var f := fingers.normalized()
	var p := (palm - f * palm.dot(f)).normalized()
	return Basis(f.cross(p), f, p) * src.inverse()


func hand_bone(hand: int) -> int:
	return _arms[hand][2] if _arms.size() > hand else -1


func _process_modification_with_delta(delta: float) -> void:
	var sk := get_skeleton()
	if sk == null or _arms.size() < 2:
		return
	var inv := sk.global_transform.affine_inverse()
	for i in 2:
		pre_shoulder[i] = sk.get_bone_global_pose(_arms[i][0]).origin
	# Hands that follow the other hand go after it.
	var order: Array[int] = []
	for i in mini(goals.size(), _arms.size()):
		if (goals[i] as Goal).rel_hand < 0:
			order.append(i)
	for i in mini(goals.size(), _arms.size()):
		if (goals[i] as Goal).rel_hand >= 0:
			order.append(i)
	for i in order:
		var g: Goal = goals[i]
		if g.rel_hand >= 0 and g.rel_hand < _arms.size() and g.want_weight > 0.0:
			g.target = sk.global_transform * sk.get_bone_global_pose(_arms[g.rel_hand][2]) * g.rel
			g.target_sk = inv * g.target
		g.weight = move_toward(g.weight, g.want_weight, delta * g.speed)
		var w := smoothstep(0.0, 1.0, g.weight)
		if w <= 0.001:
			last_error[i] = 0.0
			continue
		var t_sk := g.target_sk if g.want_weight <= 0.0 and g.has_sk else inv * g.target
		var arm: Array = _arms[i]
		if g.line_dir != Vector3.ZERO:
			var ld := (inv.basis * g.line_dir).normalized()
			var hp := sk.get_bone_global_pose(arm[2]).origin
			var along := clampf((hp - t_sk.origin).dot(ld), g.line_range.x, g.line_range.y)
			t_sk.origin = t_sk.origin + ld * along
		# Out of reach? Roll the clavicle toward the target first (shoulders come forward when
		# you push a pistol out), up to ~25°.
		var clav := sk.get_bone_parent(arm[0]) if i < 2 else -1
		if clav >= 0:
			var sh := sk.get_bone_global_pose(arm[0]).origin
			var reach := sh.distance_to(sk.get_bone_global_pose(arm[1]).origin) + sk.get_bone_global_pose(arm[1]).origin.distance_to(sk.get_bone_global_pose(arm[2]).origin)
			var short := sh.distance_to(t_sk.origin) - reach * 0.93
			if short > 0.0:
				var cg := sk.get_bone_global_pose(clav)
				var from := sh - cg.origin
				var to := t_sk.origin - cg.origin
				var r := UltraIK._rot_between(from, to)
				var ang := minf(r.get_rotation_quaternion().get_angle(), deg_to_rad(25.0)) * clampf(short / 0.025, 0.0, 1.0) * w
				var axis := from.cross(to)
				if axis.length() > 1e-5:
					cg.basis = Basis(axis.normalized(), ang) * cg.basis
					sk.set_bone_global_pose(clav, cg)
		var pole := Vector3(1.0 if i == 0 else -1.0, -0.6, -0.3) if i < 2 else Vector3(0, 0, 1)   # skeleton space
		var basis: Variant = t_sk.basis.orthonormalized() if g.use_rotation else null
		last_error[i] = UltraIK.two_bone(sk, arm[0], arm[1], arm[2], t_sk.origin, w, basis, pole)
		if g.open > 0.0 and i < 2:
			# Fingers flatten onto the surface (rest pose = straight), keeping a slight curl.
			for fb: int in _fingers[i]:
				var rest := sk.get_bone_rest(fb).basis.get_rotation_quaternion()
				var cur := sk.get_bone_pose_rotation(fb)
				sk.set_bone_pose_rotation(fb, cur.slerp(rest, g.open * w * 0.85))
		if g.curl > 0.0 and i < 2:
			var box := Transform3D()
			var half := Vector3.ZERO
			if g.wrap_node and is_instance_valid(g.wrap_node) and g.wrap_node.is_inside_tree():
				box = (inv * g.wrap_node.global_transform * g.wrap_box).affine_inverse()
				half = g.wrap_half
			_close_fingers(sk, i, g.curl * w, box, half)


## Fingers straightened, then bent toward the palm joint by joint (a grip round a ~4 cm bar).
const CURL_DEG := {"Proximal": 48.0, "Intermediate": 62.0, "Distal": 38.0}


## Wrapping a box: a joint bends only until the next joint (or the fingertip) is a finger's
## half thickness off the box's surface.
const FINGER_R := 0.009


func _close_fingers(sk: Skeleton3D, hand: int, amount: float, to_box := Transform3D(), half := Vector3.ZERO) -> void:
	if _palm_local[hand] == Vector3.ZERO:
		hand_basis(hand, Vector3.FORWARD, Vector3.UP)       # learns the palm direction
		if _palm_local[hand] == Vector3.ZERO:
			return
	var hb := sk.get_bone_global_pose(_arms[hand][2])
	var palm := (hb.basis.orthonormalized() * (_palm_local[hand] as Vector3)).normalized()
	for fb: int in _fingers[hand]:
		var n := sk.get_bone_name(fb)
		var deg := 0.0
		for k: String in CURL_DEG:
			if n.contains(k):
				deg = CURL_DEG[k]
		if deg == 0.0:
			continue
		var rest := sk.get_bone_rest(fb).basis.get_rotation_quaternion()
		sk.set_bone_pose_rotation(fb, sk.get_bone_pose_rotation(fb).slerp(rest, amount))
		var g := sk.get_bone_global_pose(fb)
		var dir := g.basis.y.normalized()
		var axis := dir.cross(palm)
		if axis.length() < 1e-4:
			continue
		var ang := deg_to_rad(deg) * amount
		if half != Vector3.ZERO:
			ang = _wrap_angle(sk, fb, g, axis.normalized(), ang, to_box, half)
		g.basis = Basis(axis.normalized(), ang) * g.basis
		sk.set_bone_global_pose(fb, g)


## The largest bend <= `full` about `axis` that keeps the rest of the finger, held straight,
## out of the box (`to_box`: skeleton space -> box frame) - the next joints then bend on round
## it. Full when even that is clear; 0 when the finger is inside the box anyway.
func _wrap_angle(sk: Skeleton3D, fb: int, g: Transform3D, axis: Vector3, full: float, to_box: Transform3D, half: Vector3) -> float:
	# The rest of the finger in this joint's frame, straight (the joints' rest rotations).
	var pts := PackedVector3Array()
	var xf := Transform3D()
	var b := fb
	var last := 0.02
	while true:
		var kids := sk.get_bone_children(b)
		if kids.is_empty():
			pts.append(xf * Vector3(0.0, last * 0.8, 0.0))       # (the fingertip)
			break
		var k: int = kids[0]
		var local := Transform3D(sk.get_bone_rest(k).basis, sk.get_bone_pose(k).origin)
		last = local.origin.length()
		xf = xf * local
		pts.append(xf.origin)
		b = k
	var hb := half + Vector3.ONE * FINGER_R
	if not _chain_in_box(pts, to_box, g, axis, full, hb):
		return full
	if _chain_in_box(pts, to_box, g, axis, 0.0, hb):
		return 0.0
	var lo := 0.0
	var hi := full
	for k in 8:
		var m := (lo + hi) * 0.5
		if _chain_in_box(pts, to_box, g, axis, m, hb):
			hi = m
		else:
			lo = m
	return lo


func _chain_in_box(pts: PackedVector3Array, to_box: Transform3D, g: Transform3D, axis: Vector3, ang: float, hb: Vector3) -> bool:
	var bb := Basis(axis, ang) * g.basis
	for q in pts:
		if _in_box(to_box * (g.origin + bb * q), hb):
			return true
	return false


func _in_box(p: Vector3, hb: Vector3) -> bool:
	return absf(p.x) < hb.x and absf(p.y) < hb.y and absf(p.z) < hb.z
