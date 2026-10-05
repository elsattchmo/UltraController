extends RefCounted
## Clip measurements shared by tools/build_animset.gd and tools/measure_mixamo.gd.

## Returns [ground speed m/s, left-foot plant phase 0..1]. The clip is in place, so during
## stance the planted foot slides backwards under the body at exactly the authored speed.
static func measure(anim: Animation, skel: Skeleton3D, bone_l := "LeftToes", bone_r := "RightToes") -> Array:
	## Returns [ground speed m/s, left-foot plant phase 0..1]. The clip is in place, so the
	## supporting foot (the lower one, while on the ground) slides backwards under the body
	## at exactly the authored speed. Same rule the foot-slide test uses in-engine.
	var n := 240
	var feet := [skel.find_bone(bone_l), skel.find_bone(bone_r)]
	var pos := [[], []]
	for i in n:
		pose(anim, skel, anim.length * i / n)
		for f in 2:
			pos[f].append(global_pose(skel, feet[f]).origin)
	var miny := [INF, INF]
	for f in 2:
		for p: Vector3 in pos[f]:
			miny[f] = minf(miny[f], p.y)
	var dt := anim.length / n
	var vels: Array[Vector2] = []
	for i in n:
		var j := (i + 1) % n
		var lo := 0 if (pos[0][i] as Vector3).y <= (pos[1][i] as Vector3).y else 1
		var p: Vector3 = pos[lo][i]
		var q: Vector3 = pos[lo][j]
		if p.y > miny[lo] + 0.03 or q.y > miny[lo] + 0.03:
			continue
		vels.append(Vector2(q.x - p.x, q.z - p.z) / dt)
	var mean := Vector2.ZERO
	for v in vels:
		mean += v
	var dir := mean.normalized()
	var speeds: Array[float] = []
	for v in vels:
		speeds.append(maxf(v.dot(dir), 0.0))
	speeds.sort()
	var med := speeds[speeds.size() / 2] if not speeds.is_empty() else 0.0
	# Left-foot plant: first frame the left foot becomes the low, grounded foot.
	var plant := 0.0
	var was := true
	for i in n:
		var lo := 0 if (pos[0][i] as Vector3).y <= (pos[1][i] as Vector3).y else 1
		var down: bool = lo == 0 and (pos[0][i] as Vector3).y < float(miny[0]) + 0.03
		if down and not was:
			plant = float(i) / n
			break
		was = down
	return [med, plant]


static func global_pose(skel: Skeleton3D, bone: int) -> Transform3D:
	var xf := skel.get_bone_pose(bone)
	var p := skel.get_bone_parent(bone)
	while p >= 0:
		xf = skel.get_bone_pose(p) * xf
		p = skel.get_bone_parent(p)
	return xf


static func pose(anim: Animation, skel: Skeleton3D, t: float) -> void:
	for b in skel.get_bone_count():
		skel.reset_bone_pose(b)
	for tr in anim.get_track_count():
		var bone := skel.find_bone(String(anim.track_get_path(tr).get_concatenated_subnames()))
		if bone < 0:
			continue
		match anim.track_get_type(tr):
			Animation.TYPE_POSITION_3D:
				skel.set_bone_pose_position(bone, anim.position_track_interpolate(tr, t) * skel.motion_scale)
			Animation.TYPE_ROTATION_3D:
				skel.set_bone_pose_rotation(bone, anim.rotation_track_interpolate(tr, t))
			Animation.TYPE_SCALE_3D:
				skel.set_bone_pose_scale(bone, anim.scale_track_interpolate(tr, t))
