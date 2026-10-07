class_name SinewGaitCycles
extends RefCounted
## Key poses for Sinew's gait, sampled from reference clips: a cycle is the clip's pose at evenly
## spaced phases of one stride (phase 0 = the left foot's contact, from AnimationSet.plant_phase),
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
		out.append(c)
	return out


## The idle pose (the clip's first frame) as gait locals: {locals, pelvis_height}.
static func idle_pose(drv: UltraAnimDriver, parts: Array) -> Dictionary:
	var a := drv._role_anim(&"idle")
	if a == null:
		return {}
	var g := _globals(a, drv.skeleton, 0.0)
	return {"locals": _locals(g, parts), "pelvis_height": g[parts[0].bone].origin.y}


static func sample_cycle(a: Animation, sk: Skeleton3D, parts: Array, plant_phase: float) -> Dictionary:
	var samples := []
	var heights := PackedFloat32Array()
	for k in SAMPLES:
		var t := fposmod(plant_phase + float(k) / SAMPLES, 1.0) * a.length
		var g := _globals(a, sk, t)
		samples.append(_locals(g, parts))
		heights.append(g[parts[0].bone].origin.y)
	return {"samples": samples, "pelvis_height": heights}


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
