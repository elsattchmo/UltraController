@tool
class_name UltraImportTools
extends RefCounted
## Shared helpers for every character / animation import (mannequin, Mixamo, Blender intake).

## Body regions for injuries, dismemberment and first-person head hiding.
enum Region { TORSO, HEAD, UPPERARM_L, FOREARM_L, UPPERARM_R, FOREARM_R, THIGH_L, SHIN_L, THIGH_R, SHIN_R }
const REGION_NAMES := ["torso", "head", "upperarm_l", "forearm_l", "upperarm_r", "forearm_r", "thigh_l", "shin_l", "thigh_r", "shin_r"]
## Humanoid profile bone that starts each region (everything below it belongs to it).
const REGION_ROOTS := {
	&"Head": Region.HEAD,
	&"LeftUpperArm": Region.UPPERARM_L, &"LeftLowerArm": Region.FOREARM_L,
	&"RightUpperArm": Region.UPPERARM_R, &"RightLowerArm": Region.FOREARM_R,
	&"LeftUpperLeg": Region.THIGH_L, &"LeftLowerLeg": Region.SHIN_L,
	&"RightUpperLeg": Region.THIGH_R, &"RightLowerLeg": Region.SHIN_R,
}
## Child regions removed with a parent when a limb is severed.
const REGION_CHILDREN := {
	Region.UPPERARM_L: [Region.FOREARM_L], Region.UPPERARM_R: [Region.FOREARM_R],
	Region.THIGH_L: [Region.SHIN_L], Region.THIGH_R: [Region.SHIN_R],
}

## Clips of the source models left out of their libraries (off-theme for this project: flying, dancing,
## farming, sitting, spells, bows, female gaits...). The mannequin import skips them; tools/purge_clips.gd
## takes them out of an already-saved library.
const PURGED := [
	"Flying_Forward", "Flying_Forward_Super", "Glide", "Levitate_Entrance", "Levitate_Idle",
	"Dance_Body_Roll", "Dance_Charleston", "Dance_Reach_Hip", "Dance_Simple",
	"Farm_Harvest", "Farm_PlantSeed", "Farm_Watering", "Fishing_Cast", "Fishing_Catch", "Fishing_Reel",
	"Golf_Drive", "Golf_idle", "Driving", "Sitting_Enter", "Sitting_Exit", "Sitting_Idle", "Sitting_Talking",
	"Sleeping", "Meditate", "Pushup", "Jumping_Jacks",
	"Spell_Simple_Enter", "Spell_Simple_Exit", "Spell_Simple_Idle", "Spell_Simple_Shoot",
	"Bow", "Bow_Pull_Back", "Bow_Pull_Hold", "Bow_Release",
	"NinjaJump_Idle", "NinjaJump_Land", "NinjaJump_Start", "Run_Female", "Walk_Female",
	"Cheer_One_arm", "Cheering_Two_Hands", "Victory", "Victory_Fist_Pump", "Salute", "Greeting",
]

## Default loop rules (regex on clip name). First match wins.
const LOOP_RULES := [
	["^(Idle|Fighting_Idle|Crouch_Idle|Crouch_Fwd|Crouch_Walk|Swim_|Ladder_Idle|Climb_Ladder|Climb_Wall|Pipe_Climb|Ledge_Hang|Levitate|Pistol_Idle|Pistol_Aim|Sitting_Idle|Driving|Dance|Glide|Flying_)", 1],
	["^(Walk|Jog|Sprint|Run_|Strafe_|Crawl$|Crawl_Fwd|Slide$|Jump_air|NinjaJump_Idle|Walk_)", 1],
	[".*_Loop$", 1],
]


static func loop_mode_for(clip: String) -> int:
	if clip.ends_with("_RM"):
		return Animation.LOOP_NONE
	for rule: Array in LOOP_RULES:
		var re := RegEx.create_from_string(rule[0])
		if re.search(clip):
			return int(rule[1])
	return Animation.LOOP_NONE


## Remove tracks that hold a bone at exactly its rest pose for the whole clip, and exact
## duplicate tracks. (Godot's own "remove immutable tracks" would also drop constant
## non-rest poses such as held finger curls, which then blend back to rest.)
static func clean_tracks(anim: Animation, skel: Skeleton3D) -> int:
	var removed := 0
	var seen := {}
	for t in range(anim.get_track_count() - 1, -1, -1):
		var path := anim.track_get_path(t)
		var key := "%s|%d" % [path, anim.track_get_type(t)]
		if seen.has(key):
			anim.remove_track(t)
			removed += 1
			continue
		seen[key] = true
	for t in range(anim.get_track_count() - 1, -1, -1):
		var path := anim.track_get_path(t)
		var bone := skel.find_bone(String(path.get_concatenated_subnames()))
		if bone < 0 or bone == 0:
			continue                                   # keep Root (root motion) tracks
		var rest := skel.get_bone_rest(bone)
		var n := anim.track_get_key_count(t)
		if n == 0:
			continue
		var constant_at_rest := true
		match anim.track_get_type(t):
			Animation.TYPE_POSITION_3D:
				for k in n:
					if not (anim.track_get_key_value(t, k) as Vector3).is_equal_approx(rest.origin):
						constant_at_rest = false
						break
			Animation.TYPE_ROTATION_3D:
				var rq := rest.basis.get_rotation_quaternion()
				for k in n:
					var q: Quaternion = anim.track_get_key_value(t, k)
					if absf(q.dot(rq)) < 0.99999:
						constant_at_rest = false
						break
			Animation.TYPE_SCALE_3D:
				for k in n:
					if not (anim.track_get_key_value(t, k) as Vector3).is_equal_approx(Vector3.ONE):
						constant_at_rest = false
						break
			_:
				constant_at_rest = false
		if constant_at_rest:
			anim.remove_track(t)
			removed += 1
	return removed


## Bake the Root bone's translation (and yaw) into a RootMotionCurve in character space.
## `motion_scale` undoes the importer's position normalisation; `model_forward_z` flips
## +Z-forward source models to Godot's -Z-forward character space.
static func bake_root_motion(anim: Animation, clip: StringName, root_track_path: String, motion_scale: float, model_forward_z := true) -> RootMotionCurve:
	var pt := anim.find_track(NodePath(root_track_path), Animation.TYPE_POSITION_3D)
	var rt := anim.find_track(NodePath(root_track_path), Animation.TYPE_ROTATION_3D)
	var c := RootMotionCurve.new()
	c.clip = clip
	c.length = anim.length
	c.sample_rate = 60.0
	var n := int(ceil(anim.length * c.sample_rate)) + 1
	var p0 := Vector3.ZERO
	var q0 := Quaternion.IDENTITY
	if pt >= 0:
		p0 = anim.position_track_interpolate(pt, 0.0)
	if rt >= 0:
		q0 = anim.rotation_track_interpolate(rt, 0.0)
	var yaw0 := _yaw_of(q0)
	for i in n:
		var t := minf(i / c.sample_rate, anim.length)
		var p := Vector3.ZERO
		if pt >= 0:
			p = (anim.position_track_interpolate(pt, t) - p0) * motion_scale
		if model_forward_z:
			p = Vector3(-p.x, p.y, -p.z)
		c.positions.append(p)
		var yaw := 0.0
		if rt >= 0:
			yaw = angle_difference(yaw0, _yaw_of(anim.rotation_track_interpolate(rt, t)))
			if not c.yaws.is_empty():          # unwrap
				var last: float = c.yaws[c.yaws.size() - 1]
				yaw = last + angle_difference(last, yaw)
		c.yaws.append(yaw)
	# Some clips snap the root back to the start at the very end (ClimbUp_1m_RM): if the path
	# ends far short of its furthest point, crop it at the peak so the motor never sees it.
	var far_i := 0
	var far_d := 0.0
	for k in c.positions.size():
		var d := c.positions[k].length()
		if d > far_d:
			far_d = d
			far_i = k
	if far_d > 0.5 and c.positions[c.positions.size() - 1].length() < far_d * 0.3:
		c.positions.resize(far_i + 1)
		c.yaws.resize(far_i + 1)
		c.length = float(far_i) / c.sample_rate
	return c


## Turn-in-place clips rotate the HIPS, not the root. Move that yaw onto the Root bone so
## root-motion extraction removes it: the skeleton steps in place facing forward and the
## motor turns the body by any angle.
static func hips_yaw_to_root(anim: Animation, hips_path: String, root_path: String) -> void:
	var rt := anim.find_track(NodePath(hips_path), Animation.TYPE_ROTATION_3D)
	if rt < 0 or anim.track_get_key_count(rt) == 0:
		return
	var y0 := _yaw_of(anim.track_get_key_value(rt, 0))
	var yaw_at := func(t: float) -> float:
		return angle_difference(y0, _yaw_of(anim.rotation_track_interpolate(rt, t)))
	# Unwrap so a 180° turn doesn't flip sign half way.
	var pt := anim.find_track(NodePath(hips_path), Animation.TYPE_POSITION_3D)
	if pt >= 0:
		for k in anim.track_get_key_count(pt):
			var t := anim.track_get_key_time(pt, k)
			var p: Vector3 = anim.track_get_key_value(pt, k)
			anim.track_set_key_value(pt, k, Basis(Vector3.UP, -yaw_at.call(t)) * p)
	var unwrapped := 0.0
	var prev := 0.0
	var yaws := PackedFloat32Array()
	for k in anim.track_get_key_count(rt):
		var y: float = yaw_at.call(anim.track_get_key_time(rt, k))
		unwrapped += angle_difference(prev, y)
		prev = y
		yaws.append(unwrapped)
	for k in anim.track_get_key_count(rt):
		var q: Quaternion = anim.track_get_key_value(rt, k)
		anim.track_set_key_value(rt, k, Quaternion(Vector3.UP, -yaws[k]) * q)
	var root_rt := anim.find_track(NodePath(root_path), Animation.TYPE_ROTATION_3D)
	var base := Quaternion.IDENTITY
	if root_rt >= 0:
		base = anim.track_get_key_value(root_rt, 0)
		anim.remove_track(root_rt)
	root_rt = anim.add_track(Animation.TYPE_ROTATION_3D)
	anim.track_set_path(root_rt, NodePath(root_path))
	for k in anim.track_get_key_count(rt):
		anim.rotation_track_insert_key(root_rt, anim.track_get_key_time(rt, k), Quaternion(Vector3.UP, yaws[k]) * base)


static func _yaw_of(q: Quaternion) -> float:
	var f := Basis(q) * Vector3.FORWARD
	return atan2(-f.x, -f.z)


## Strongest-weighted region per vertex for a skinned surface.
static func vertex_regions(arrays: Array, skin: Skin, skel: Skeleton3D) -> PackedInt32Array:
	var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
	var vcount: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var per := bones.size() / maxi(vcount, 1)
	var bind_region := PackedInt32Array()
	for b in skin.get_bind_count():
		var bone := skin.get_bind_bone(b)
		if bone < 0:
			bone = skel.find_bone(String(skin.get_bind_name(b)))
		bind_region.append(region_of_bone(skel, bone))
	var out := PackedInt32Array()
	out.resize(vcount)
	for v in vcount:
		var best := 0
		var best_w := -1.0
		for k in per:
			var w := weights[v * per + k]
			if w > best_w:
				best_w = w
				best = bones[v * per + k]
		out[v] = bind_region[best] if best < bind_region.size() else Region.TORSO
	return out


## Per-vertex weight on the given bones (e.g. Neck + Head for first-person hiding).
static func vertex_weight_on(arrays: Array, skin: Skin, skel: Skeleton3D, bone_names: PackedStringArray) -> PackedFloat32Array:
	var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
	var vcount: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var per := bones.size() / maxi(vcount, 1)
	var wanted := {}
	for n in bone_names:
		wanted[skel.find_bone(n)] = true
	var bind_hit := PackedByteArray()
	for b in skin.get_bind_count():
		var bone := skin.get_bind_bone(b)
		if bone < 0:
			bone = skel.find_bone(String(skin.get_bind_name(b)))
		# Children of a wanted bone count too (head_leaf etc.).
		var hit := 0
		var p := bone
		while p >= 0:
			if wanted.has(p):
				hit = 1
				break
			p = skel.get_bone_parent(p)
		bind_hit.append(hit)
	var out := PackedFloat32Array()
	out.resize(vcount)
	for v in vcount:
		var w := 0.0
		for k in per:
			var bi := bones[v * per + k]
			if bi < bind_hit.size() and bind_hit[bi] == 1:
				w += weights[v * per + k]
		out[v] = w
	return out


static func region_of_bone(skel: Skeleton3D, bone: int) -> int:
	var b := bone
	while b >= 0:
		var n := StringName(skel.get_bone_name(b))
		if REGION_ROOTS.has(n):
			return REGION_ROOTS[n]
		b = skel.get_bone_parent(b)
	return Region.TORSO
