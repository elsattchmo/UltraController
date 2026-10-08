class_name SinewGaitCycles
extends RefCounted
## Key poses for Sinew's gait, sampled from reference clips: a cycle is the clip's pose at evenly
## spaced phases of one stride (phase 0 = the left foot's contact, its heel strike: the ankle furthest forward),
## as each Sinew part's rotation in its parent part's frame (the pelvis: in model space) plus the
## pelvis height. The gait blends them by phase and speed and fits the legs to its own footholds,
## so the clips give the style (arms, spine, knee bend, pelvis), never where the feet go.
##
## Which clips: SinewAnimationSet.gait_walk / gait_run / gait_sprint (roles; re-point them there).

const SAMPLES := 24


## Cycles for the gait from the driver's set: [{speed, samples, pelvis_height}] (missing roles skipped).
static func build(drv: UltraAnimDriver, parts: Array) -> Array:
	var out := []
	var aset := drv.anim_set as SinewAnimationSet
	var roles: Array[StringName] = [&"walk_f", &"jog_f", &"sprint_f"]
	if aset:
		roles = [aset.gait_walk, aset.gait_run, aset.gait_sprint]
		for r in [aset.gait_back, aset.gait_left, aset.gait_right]:
			if r != &"":
				roles.append(r)
	var seen := {}
	for role in roles:
		var clip := String(drv.anim_set.clip(role))
		if clip == "" or seen.has(clip):
			continue
		seen[clip] = true
		var a := drv._role_anim(role)
		if a == null:
			continue
		var c := sample_cycle(a, drv.skeleton, parts, float(drv.anim_set.plant_phase.get(clip, 0.0)))
		c["speed"] = drv.anim_set.speed_of(role, 1.3)
		c["clip"] = clip
		if aset and role == aset.gait_run and not aset.gait_run_upper.is_empty():
			_borrow_upper(c, drv, parts, aset.gait_run_upper)
		out.append(c)
	return out


## Cycles for one group of roles (a stance): `upper_from` role -> [roles] borrows that cycle's upper body (see
## _borrow_upper); every cycle carries `group`. Clips are sampled once per skeleton and clip (cached).
static func build_group(drv: UltraAnimDriver, parts: Array, roles: Array, upper_from: Dictionary, group: int) -> Array:
	var out := []
	var seen := {}
	for r in roles:
		var role := StringName(r)
		var clip := String(drv.anim_set.clip(role))
		if clip == "" or seen.has(clip):
			continue
		seen[clip] = true
		var a := drv._role_anim(role)
		if a == null:
			continue
		var c := _cached_cycle(a, drv.skeleton, parts, float(drv.anim_set.plant_phase.get(clip, 0.0)), clip).duplicate(true)
		c["speed"] = drv.anim_set.speed_of(role, 1.3)
		c["clip"] = clip
		c["group"] = group
		var borrow: Array = upper_from.get(String(role), upper_from.get(role, []))
		if not borrow.is_empty():
			var typed: Array[StringName] = []
			for b in borrow:
				typed.append(StringName(b))
			_borrow_upper(c, drv, parts, typed)
		out.append(c)
	return out


static var _cache := {}


static func _cached_cycle(a: Animation, sk: Skeleton3D, parts: Array, plant_phase: float, clip: String) -> Dictionary:
	var key := "%d|%s|%d" % [sk.get_bone_count(), clip, parts.size()]
	if not _cache.has(key):
		_cache[key] = sample_cycle(a, sk, parts, plant_phase)
	return _cache[key]


## Replaces a cycle's upper-body locals (everything but the pelvis and legs) with the average of other
## roles' cycles at the same phase (all sampled from the left heel strike).
static func _borrow_upper(c: Dictionary, drv: UltraAnimDriver, parts: Array, roles: Array[StringName]) -> void:
	var others := []
	for r in roles:
		var a := drv._role_anim(r)
		if a != null:
			var clip := String(drv.anim_set.clip(r))
			others.append(sample_cycle(a, drv.skeleton, parts, float(drv.anim_set.plant_phase.get(clip, 0.0))).samples)
	if others.is_empty():
		return
	var upper: Array[int] = []
	for i in parts.size():
		var bone := drv.skeleton.get_bone_name(parts[i].bone)
		if i != 0 and not (bone.contains("UpperLeg") or bone.contains("LowerLeg") or bone.contains("Foot") or bone.contains("Toes")):
			upper.append(i)
	var samples: Array = c.samples
	for k in samples.size():
		var loc: Array = samples[k]
		for i in upper:
			var q: Quaternion = others[0][k][i]
			for j in range(1, others.size()):
				q = q.slerp(others[j][k][i], 1.0 / float(j + 1))
			loc[i] = q
	c["upper_from"] = roles


## The idle pose (the clip's first frame) as gait locals: {locals, pelvis_height}.
static func idle_pose(drv: UltraAnimDriver, parts: Array, role: StringName = &"idle") -> Dictionary:
	var a := drv._role_anim(role)
	if a == null:
		return {}
	var g := _globals(a, drv.skeleton, 0.0)
	return {"locals": _locals(g, parts), "pelvis_height": g[parts[0].bone].origin.y}


static func sample_cycle(a: Animation, sk: Skeleton3D, parts: Array, plant_phase: float) -> Dictionary:
	var samples := []
	var heights := PackedFloat32Array()
	# The legs' own paths (skeleton = model space, the ground point at the origin): where the gait
	# takes its stride, ground contact, swing lift and foot roll from.
	var feet := [sk.find_bone("LeftFoot"), sk.find_bone("RightFoot")]
	var toes := [sk.find_bone("LeftToes"), sk.find_bone("RightToes")]
	var paths := {"ankle_l": PackedVector3Array(), "ankle_r": PackedVector3Array(), "toe_l": PackedVector3Array(), "toe_r": PackedVector3Array()}
	# Some clips hold two strides (or more): sample just one, from the left foot's contact.
	var strides := stride_count(a, sk, parts)
	var span := a.length / float(strides)
	# Phase 0 = the left heel strike (the ankle furthest forward of the hips) - the clip's plant_phase is
	# the toe going down, a quarter stride later on a walk.
	var strike := contact_phase(a, sk, parts)
	if strike >= 0.0:
		plant_phase = strike
	for k in SAMPLES:
		var t := fposmod(plant_phase * a.length + float(k) / SAMPLES * span, a.length)
		var g := _globals(a, sk, t)
		samples.append(_locals(g, parts))
		heights.append(g[parts[0].bone].origin.y)
		var hips: Vector3 = g[parts[0].bone].origin
		for i in 2:
			var side := "l" if i == 0 else "r"
			if feet[i] >= 0:
				paths["ankle_" + side].append(g[feet[i]].origin - Vector3(hips.x, 0.0, hips.z))
			if toes[i] >= 0:
				paths["toe_" + side].append(g[toes[i]].origin - Vector3(hips.x, 0.0, hips.z))
	var out := {"samples": samples, "pelvis_height": heights, "length": span, "strides": strides}
	out.merge(paths)
	return out


## How many strides a cycle clip holds: the left ankle's furthest-forward points (relative to the hips)
## over the whole clip, counted cyclically (a stride is one of them).
static func stride_count(a: Animation, sk: Skeleton3D, parts: Array) -> int:
	var z := _ankle_along(a, sk, parts, 96)
	if z.is_empty():
		return 1
	const N := 96
	var lo := INF
	var hi := -INF
	for x in z:
		lo = minf(lo, x)
		hi = maxf(hi, x)
	var n := 0
	for k in N:
		var x := z[k]
		var is_max := true
		for d in range(-6, 7):
			if d != 0 and z[(k + d + N) % N] > x:
				is_max = false
				break
		if is_max and x > lo + 0.6 * (hi - lo):
			n += 1
	return clampi(n, 1, 4)


## The left ankle off the hips over the clip (n samples), along the way its feet move most (forward for
## a walk, sideways for a strafe); empty without feet.
static func _ankle_along(a: Animation, sk: Skeleton3D, parts: Array, n: int) -> PackedFloat32Array:
	var foot := sk.find_bone("LeftFoot")
	var out := PackedFloat32Array()
	if foot < 0:
		return out
	var pts: Array[Vector2] = []
	var mean := Vector2.ZERO
	for k in n:
		var g := _globals(a, sk, float(k) / n * a.length)
		var d := g[foot].origin - g[parts[0].bone].origin
		pts.append(Vector2(d.x, d.z))
		mean += Vector2(d.x, d.z) / n
	# Principal axis of the horizontal spread.
	var sxx := 0.0
	var szz := 0.0
	var sxz := 0.0
	for p in pts:
		var q := p - mean
		sxx += q.x * q.x
		szz += q.y * q.y
		sxz += q.x * q.y
	var ang := 0.5 * atan2(2.0 * sxz, sxx - szz)
	var axis := Vector2(cos(ang), sin(ang))
	# (Sign: the forward-most for a walk - keep +Z positive when the axis is mostly along it.)
	if absf(axis.y) >= absf(axis.x) and axis.y < 0.0:
		axis = -axis
	for p in pts:
		out.append(p.dot(axis))
	return out


## The left heel strike as a phase of the clip (the left ankle furthest forward of the hips); -1 without feet.
static func contact_phase(a: Animation, sk: Skeleton3D, parts: Array) -> float:
	const N := 96
	var z := _ankle_along(a, sk, parts, N)
	if z.is_empty():
		return -1.0
	var at := 0
	for k in N:
		if z[k] > z[at]:
			at = k
	return float(at) / N


## Every bone's skeleton-space transform at time t (the clip's tracks over the rest pose).
static func _globals(a: Animation, sk: Skeleton3D, t: float) -> Array[Transform3D]:
	var n := sk.get_bone_count()
	var pos: Array[Vector3] = []
	var rot: Array[Quaternion] = []
	var scl: Array[Vector3] = []
	for b in n:
		var r := sk.get_bone_rest(b)
		pos.append(r.origin)
		rot.append(r.basis.get_rotation_quaternion())
		scl.append(r.basis.get_scale())
	var ms := sk.motion_scale
	for i in a.get_track_count():
		var b := sk.find_bone(a.track_get_path(i).get_concatenated_subnames())
		if b < 0:
			continue
		match a.track_get_type(i):
			Animation.TYPE_POSITION_3D:
				pos[b] = a.position_track_interpolate(i, t) * ms
			Animation.TYPE_ROTATION_3D:
				rot[b] = a.rotation_track_interpolate(i, t)
			Animation.TYPE_SCALE_3D:
				scl[b] = a.scale_track_interpolate(i, t)
	var g: Array[Transform3D] = []
	g.resize(n)
	for b in n:      # Godot keeps parents before children
		var local := Transform3D(Basis(rot[b]).scaled(scl[b]), pos[b])
		var p := sk.get_bone_parent(b)
		g[b] = g[p] * local if p >= 0 else local
	return g


static func _locals(g: Array[Transform3D], parts: Array) -> Array:
	var out := []
	for i in parts.size():
		var q := g[parts[i].bone].basis.get_rotation_quaternion()
		var p: int = parts[i].parent
		if p >= 0:
			q = g[parts[p].bone].basis.get_rotation_quaternion().inverse() * q
		out.append(q.normalized())
	return out
