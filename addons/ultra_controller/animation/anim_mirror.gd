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


## A segment of a clip (forwards), its first frame held for `hold` seconds before it plays.
static func segment(src: Animation, from: float, to: float, hold := 0.0, fps := 30.0) -> Animation:
	var a := Animation.new()
	var seg := to - from
	a.length = hold + seg
	a.loop_mode = Animation.LOOP_NONE
	var n := maxi(int(ceil(seg * fps)), 1)
	for t in src.get_track_count():
		var ty := src.track_get_type(t)
		if ty != Animation.TYPE_ROTATION_3D and ty != Animation.TYPE_POSITION_3D and ty != Animation.TYPE_SCALE_3D:
			continue
		var nt := a.add_track(ty)
		a.track_set_path(nt, src.track_get_path(t))
		var times: Array[float] = []
		if hold > 0.0:
			times.append(0.0)
		for k in n + 1:
			times.append(hold + minf(k / fps, seg))
		for tt in times:
			var st := from + maxf(tt - hold, 0.0)
			match ty:
				Animation.TYPE_ROTATION_3D:
					a.rotation_track_insert_key(nt, tt, src.rotation_track_interpolate(t, st))
				Animation.TYPE_POSITION_3D:
					a.position_track_insert_key(nt, tt, src.position_track_interpolate(t, st))
				Animation.TYPE_SCALE_3D:
					a.scale_track_insert_key(nt, tt, src.scale_track_interpolate(t, st))
	return a


## A segment of a clip played backwards, as its own clip (resampled at `fps`).
static func reversed_segment(src: Animation, from: float, to: float, fps := 30.0) -> Animation:
	var a := Animation.new()
	var len := to - from
	a.length = len
	a.loop_mode = Animation.LOOP_NONE
	var n := maxi(int(ceil(len * fps)), 1)
	for t in src.get_track_count():
		var ty := src.track_get_type(t)
		if ty != Animation.TYPE_ROTATION_3D and ty != Animation.TYPE_POSITION_3D and ty != Animation.TYPE_SCALE_3D:
			continue
		var nt := a.add_track(ty)
		a.track_set_path(nt, src.track_get_path(t))
		for k in n + 1:
			var tt := minf(k / fps, len)
			var st := to - tt
			match ty:
				Animation.TYPE_ROTATION_3D:
					a.rotation_track_insert_key(nt, tt, src.rotation_track_interpolate(t, st))
				Animation.TYPE_POSITION_3D:
					a.position_track_insert_key(nt, tt, src.position_track_interpolate(t, st))
				Animation.TYPE_SCALE_3D:
					a.scale_track_insert_key(nt, tt, src.scale_track_interpolate(t, st))
	return a


## The same transform on the other side of the body (bone-local mirror: a proper rotation).
static func mirror_xform(t: Transform3D) -> Transform3D:
	var m := Basis(Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1))
	return Transform3D(m * t.basis * m, Vector3(-t.origin.x, t.origin.y, t.origin.z))
