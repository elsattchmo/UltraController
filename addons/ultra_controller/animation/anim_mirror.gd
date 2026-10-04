class_name UltraAnimMirror
extends RefCounted
## Left/right mirror of a humanoid clip at runtime. The retargeted skeleton is mirror-symmetric
## about the model's YZ plane (rest_R = M rest_L M, M = diag(-1, 1, 1); checked to 0.04 deg by
## tools/probe/probe_mirror.gd), so mirroring is: swap Left*/Right* tracks, reflect positions
## (x -> -x) and conjugate rotations by M (x, y, z, w) -> (x, -y, -z, w).

static func mirror(src: Animation) -> Animation:
	var a := src.duplicate(true) as Animation
	for t in a.get_track_count():
		var path := a.track_get_path(t)
		var bone := String(path.get_concatenated_subnames())
		var node := String(path.get_concatenated_names())
		var swapped := bone
		if bone.begins_with("Left"):
			swapped = "Right" + bone.substr(4)
		elif bone.begins_with("Right"):
			swapped = "Left" + bone.substr(5)
		if swapped != bone:
			a.track_set_path(t, NodePath(node + ":" + swapped))
		match a.track_get_type(t):
			Animation.TYPE_POSITION_3D:
				for k in a.track_get_key_count(t):
					var v: Vector3 = a.track_get_key_value(t, k)
					a.track_set_key_value(t, k, Vector3(-v.x, v.y, v.z))
			Animation.TYPE_ROTATION_3D:
				for k in a.track_get_key_count(t):
					var q: Quaternion = a.track_get_key_value(t, k)
					a.track_set_key_value(t, k, Quaternion(q.x, -q.y, -q.z, q.w))
	return a


## The same transform on the other side of the body (bone-local mirror: a proper rotation).
static func mirror_xform(t: Transform3D) -> Transform3D:
	var m := Basis(Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1))
	return Transform3D(m * t.basis * m, Vector3(-t.origin.x, t.origin.y, t.origin.z))
