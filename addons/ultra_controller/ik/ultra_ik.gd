class_name UltraIK
extends RefCounted
## Analytic two-bone IK in skeleton space (hip-knee-ankle, shoulder-elbow-wrist).
## Keeps the bend plane the animation chose (knees/elbows point where they were animated),
## so IK corrects position without fighting the pose.


## Solve root->mid->end to put `end` at `target` (skeleton space). `weight` blends from the
## animated pose. `end_basis` (optional) sets the end bone's final orientation; otherwise the
## end bone keeps its animated global orientation. `pole_hint` is used only when the limb is
## animated perfectly straight. Returns the reach error (m) after solving.
static func two_bone(sk: Skeleton3D, root: int, mid: int, end: int, target: Vector3, weight: float, end_basis: Variant = null, pole_hint := Vector3.FORWARD) -> float:
	if weight <= 0.0001:
		return 0.0
	var gr := sk.get_bone_global_pose(root)
	var gm := sk.get_bone_global_pose(mid)
	var ge := sk.get_bone_global_pose(end)
	var a := gr.origin
	var b := gm.origin
	var c := ge.origin
	var t := c.lerp(target, clampf(weight, 0.0, 1.0))
	var lab := a.distance_to(b)
	var lbc := b.distance_to(c)
	var d_vec := t - a
	var d := clampf(d_vec.length(), absf(lab - lbc) + 0.001, lab + lbc - 0.0005)
	var dir := d_vec.normalized() if d_vec.length() > 0.0001 else (c - a).normalized()
	# Bend direction: the animated knee's offset from the hip->ankle line.
	var ac := (c - a)
	var bend := (b - a) - ac.normalized() * (b - a).dot(ac.normalized()) if ac.length() > 0.0001 else Vector3.ZERO
	if bend.length() < 0.001:
		bend = pole_hint
	bend = (bend - dir * bend.dot(dir)).normalized()
	var along := (lab * lab - lbc * lbc + d * d) / (2.0 * d)
	var h := sqrt(maxf(lab * lab - along * along, 0.0))
	var nb := a + dir * along + bend * h
	# Root: rotate the upper segment onto the new knee.
	var r1 := _rot_between(b - a, nb - a)
	gr.basis = r1 * gr.basis
	sk.set_bone_global_pose(root, gr)
	# Mid: re-read (it followed its parent), rotate the lower segment onto the target.
	gm = sk.get_bone_global_pose(mid)
	var c_now := sk.get_bone_global_pose(end).origin
	var r2 := _rot_between(c_now - gm.origin, (a + dir * d) - gm.origin)
	gm.basis = r2 * gm.basis
	sk.set_bone_global_pose(mid, gm)
	# End: restore (or set) its orientation.
	var ge2 := sk.get_bone_global_pose(end)
	if end_basis != null:
		ge2.basis = (ge.basis as Basis).slerp(end_basis, clampf(weight, 0.0, 1.0)).orthonormalized() * Basis.from_scale(ge.basis.get_scale())
	else:
		ge2.basis = ge.basis
	sk.set_bone_global_pose(end, ge2)
	return ge2.origin.distance_to(t)


static func _rot_between(from: Vector3, to: Vector3) -> Basis:
	var f := from.normalized()
	var t := to.normalized()
	var axis := f.cross(t)
	var s := axis.length()
	if s < 1e-6:
		return Basis()
	return Basis(axis / s, atan2(s, f.dot(t)))
