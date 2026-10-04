@tool
class_name UltraPoseSampler
extends RefCounted
## Evaluate a clip on a skeleton without an AnimationTree (offline tools: clip measuring,
## item grip fitting). Position tracks are scaled by motion_scale, as the mixer does.


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


## Bone transform in skeleton space, computed from local poses (no deferred update needed).
static func global_pose(skel: Skeleton3D, bone: int) -> Transform3D:
	var xf := skel.get_bone_pose(bone)
	var p := skel.get_bone_parent(bone)
	while p >= 0:
		xf = skel.get_bone_pose(p) * xf
		p = skel.get_bone_parent(p)
	return xf


## Transform of a named marker node relative to a scene's root (walks parent transforms).
static func marker(root: Node3D, marker_name: String) -> Transform3D:
	var n := root.find_child(marker_name, true, false) as Node3D
	if n == null:
		return Transform3D.IDENTITY
	var xf := n.transform
	var p := n.get_parent() as Node3D
	while p and p != root:
		xf = p.transform * xf
		p = p.get_parent() as Node3D
	return xf
