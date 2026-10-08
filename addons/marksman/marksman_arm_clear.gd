class_name MarksmanArmClear
extends RefCounted
## The arms out of the body, on the pose as it SHOWS (MarksmanGunPass.apply_post, after the physics and the support
## hand): UltraArmClear's torso - an ellipse round the hips -> neck line, measured off the mannequin's mesh, the limb's
## thickness included - and its keep-hands swing: an elbow (or the middle of the upper arm) inside turns the whole arm
## about the shoulder -> wrist line, by the smallest angle either way that gets it out; the hand stays where it was (on
## the gun). Where that can't clear the forearm, the forearm turns about the elbow and the hand is put back. The pistol
## held close at the hip had the upper arm 3-5 cm in the chest; a kicked gun drove the forearm 7-8 cm in.

const SIDES := ["Left", "Right"]
var _b := {}
var swung := 0.0                       ## (tests) the largest swing this frame (rad)


func _bones(sk: Skeleton3D) -> bool:
	if _b.is_empty():
		for n in ["Hips", "Neck", "LeftUpperArm", "RightUpperArm", "LeftLowerArm", "RightLowerArm", "LeftHand", "RightHand"]:
			_b[n] = sk.find_bone(n)
	return not (_b.values() as Array).has(-1)


func apply(sk: Skeleton3D) -> void:
	swung = 0.0
	if not _bones(sk):
		return
	for side: String in SIDES:
		_swing_out(sk, _b[side + "UpperArm"], _b[side + "LowerArm"], _b[side + "Hand"])


func _frame(sk: Skeleton3D) -> Array:
	var hips := sk.get_bone_global_pose(_b.Hips).origin
	var neck := sk.get_bone_global_pose(_b.Neck).origin
	var axis := (neck - hips).normalized()
	var right := sk.get_bone_global_pose(_b.RightUpperArm).origin - sk.get_bone_global_pose(_b.LeftUpperArm).origin
	right = (right - axis * right.dot(axis)).normalized()
	return [hips, axis, (neck - hips).length(), right, axis.cross(right).normalized()]


## The normalised ellipse distance (< 1 = inside).
static func inside(f: Array, p: Vector3) -> float:
	var hips: Vector3 = f[0]
	var axis: Vector3 = f[1]
	var along := (p - hips).dot(axis)
	if along > float(f[2]) + 0.05:
		return 2.0            # (above the neck)
	var t := clampf(along, 0.15, float(f[2]))
	var d := p - (hips + axis * t)
	var k := clampf(t / maxf(float(f[2]), 0.001), 0.0, 1.0)
	var hw := lerpf(UltraArmClear.WAIST_HALF_WIDTH, UltraArmClear.TORSO_HALF_WIDTH, smoothstep(0.3, 0.8, k))
	var hd := lerpf(UltraArmClear.WAIST_HALF_DEPTH, UltraArmClear.TORSO_HALF_DEPTH, smoothstep(0.3, 0.8, k))
	var x := d.dot(f[3]) / hw
	var y := d.dot(f[4]) / hd
	return sqrt(x * x + y * y)


func _worst(f: Array, s: Vector3, e: Vector3, h: Vector3) -> float:
	return minf(minf(inside(f, e), inside(f, s.lerp(e, 0.55))), inside(f, e.lerp(h, 0.5)))


func _swing_out(sk: Skeleton3D, ua: int, la: int, hand: int) -> void:
	var f := _frame(sk)
	var s := sk.get_bone_global_pose(ua).origin
	var e := sk.get_bone_global_pose(la).origin
	var hx := sk.get_bone_global_pose(hand)
	var h := hx.origin
	var worst := _worst(f, s, e, h)
	if worst >= 1.0:
		return
	var u := h - s
	if u.length() < 1e-3:
		return
	u = u.normalized()
	# The smallest swing (5 deg steps, either way, <= 110) that gets the elbow, the upper arm and the forearm out.
	var best := 0.0
	var best_q := worst
	for k in range(1, 23):
		for sgn in [1.0, -1.0]:
			var ang: float = deg_to_rad(5.0 * k) * sgn
			var e2 := s + Basis(u, ang) * (e - s)
			var q := _worst(f, s, e2, h)
			if q > best_q + 0.005:
				best_q = q
				best = ang
		if best_q >= 1.0:
			break
	if best != 0.0:
		var g := sk.get_bone_global_pose(ua)
		g.basis = Basis(u, best) * g.basis
		sk.set_bone_global_pose(ua, g)
		sk.set_bone_global_pose(hand, hx)          # (the hand: where it was)
		swung = maxf(swung, absf(best))
