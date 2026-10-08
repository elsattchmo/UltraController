class_name MarksmanGunPass
extends RefCounted
## Marksman's gun pass (a SinewPoseModifier pass): the held firearm points where the character aims, the body
## doing it - a pass over the animated pose (after Sinew's gait and torso twist, before the physics), so what it
## makes is what shows and what the body's muscles track.
##  1. The gun: the right hand's pose x the item's grip (UltraEquipmentVisual attaches it so).
##  2. The aim point: where the gun ray (gun_ray(): the sim's aim + free-aim sway, from the shot origin) meets the
##     world, else 60 m out. The barrel (-Z of the gun) is turned onto it - the spine first (yaw and pitch spread
##     up Spine / Chest / UpperChest, <= SPINE_MAX), the rest at the shoulder (the whole gun arm), then a last
##     touch at the wrist; two rounds (each turn moves the muzzle).
##  3. The support hand back on the gun by two-bone IK: the item's fitted support grip (support_offset, rifle /
##     shotgun), else the hand where the clip had it relative to the gun (the pistol's two-handed hold).
## Weighted by how far the gun is up (UltraActionLayer.raised) and not carried low for a sprint (gun_low), eased.

const SPINE_SHARE := {"Spine": 0.2, "Chest": 0.3, "UpperChest": 0.5}
## Most the spine turns toward the aim (rad); the gun arm does the rest.
const SPINE_MAX := 0.6
## Aim point when the ray meets nothing (m).
const FAR := 60.0
## Aiming down the sights: the neck turns at most this far bringing the eye to the stock (rad), and this share of
## the way (the gun comes the rest - to the eye).
const NECK_MAX := 0.35
const HEAD_SHARE := 0.6
## The shoulder pocket off the right shoulder joint, in the chest's frame (x = left / inward, y = up, z = forward), m.
const POCKET := Vector3(0.06, -0.04, 0.05)

var character: UltraCharacter
var ragdoll: SinewRagdoll
## How much of the pass shows now (eased).
var weight := 0.0
## Last frame's numbers (tests): barrel error to the aim point (rad), support hand off its target (m).
var aim_error := 0.0
var support_error := 0.0
var aim_point := Vector3.ZERO          ## world
var support_target := Transform3D()    ## skeleton space

var _p := {}                            ## part name -> index
var _sub := {}                          ## part index -> [subtree part indices, itself first]
var _muzzle_local := Transform3D()
var _muzzle_for: Node3D = null
var _stock_local := Transform3D()
var _stock_for: Node3D = null
var _has_stock := false
var _eye_local := Vector3.INF
var _head_bone := -1
var _neck_bone := -1
var _rear_local := Vector3.ZERO
var _front_local := Vector3.ZERO
var _sights_for: Node3D = null
var _palm_local := Vector3.ZERO
var _grip_contact := Vector3.ZERO
var _grip_for: Node3D = null
## How far down the sights now (eased ADS x the pass's weight) and the eye it aimed from (skeleton space; tests).
var ads := 0.0
var ads_eye := Vector3.ZERO
## Last frame's shoulder pocket and stock (skeleton space; tests).
var pocket := Vector3.ZERO
var stock := Vector3.ZERO


func _init(c: UltraCharacter, r: SinewRagdoll) -> void:
	character = c
	ragdoll = r
	for i in r.parts.size():
		_p[String(r.parts[i].name)] = i


func _part(n: String) -> int:
	return int(_p.get(n, -1))


func _subtree(top: int) -> Array:
	if _sub.has(top):
		return _sub[top]
	var out := [top]
	for i in ragdoll.parts.size():
		var j := i
		while j >= 0 and j != top:
			j = int(ragdoll.parts[j].parent)
		if j == top and i != top:
			out.append(i)
	_sub[top] = out
	return out


func _equipment() -> UltraEquipmentVisual:
	return character.get_node_or_null("Equipment") as UltraEquipmentVisual


## The pass. True when it changed the pose.
func apply(mod: SinewPoseModifier, sk: Skeleton3D) -> bool:
	var eq := _equipment()
	var def: ItemDefinition = eq.held_def if eq else null
	var gun_node: Node3D = eq.held_node if eq else null
	var dt := clampf(mod.get_process_delta_time(), 0.0, 0.1)
	var st := character.state
	var armed := def != null and gun_node != null and MarksmanStance.of_item(def) != "unarmed" and st.held_uid != 0
	var want := UltraActionLayer.raised(st) * (1.0 - st.gun_low) if armed else 0.0
	weight = move_toward(weight, want, 6.0 * dt)
	if weight <= 0.001 or not armed:
		return false
	var rh := _part("RightHand")
	var lh := _part("LeftHand")
	if rh < 0 or lh < 0:
		return false
	var pose: Array[Transform3D] = mod.anim_pose
	var grip: Transform3D = eq.grip()
	if _muzzle_for != gun_node:
		_muzzle_for = gun_node
		_muzzle_local = UltraPoseSampler.marker(gun_node, "M_Muzzle")
	# The clip's own support hand relative to its gun (kept where the item has no fitted grip).
	var gun0: Transform3D = pose[rh] * grip
	var support_rel: Transform3D = gun0.affine_inverse() * pose[lh]
	if def.two_handed and not def.support_offset.is_equal_approx(Transform3D.IDENTITY):
		support_rel = def.support_offset
	# Aim point (world -> skeleton space).
	var ray := eq.gun_ray()
	var origin: Vector3 = ray.origin
	var dir: Vector3 = ray.dir
	aim_point = origin + dir * FAR
	var space := character.get_world_3d().direct_space_state if character.is_inside_tree() else null
	if space:
		var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * FAR, UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC)
		q.exclude = [character.get_rid()]
		var hit := space.intersect_ray(q)
		if not hit.is_empty() and (hit.position as Vector3).distance_to(origin) > 0.5:
			aim_point = hit.position
	var to_sk := sk.global_transform.affine_inverse()
	var target_sk := to_sk * aim_point
	if _stock_for != gun_node:
		_stock_for = gun_node
		_stock_local = UltraPoseSampler.marker(gun_node, "M_Stock")
		_has_stock = gun_node.find_child("M_Stock", true, false) != null
	if def.two_handed and _has_stock:
		_shoulder(pose, rh, grip, target_sk)
	else:
		_hold_out(pose, rh, grip, target_sk)
	ads = eq.ads * weight
	if ads > 0.001:
		_aim_down_sights(sk, pose, rh, grip, target_sk, def)
	var gun: Transform3D = pose[rh] * grip
	aim_error = _barrel_turn(gun, target_sk).get_angle()
	# The support hand onto the gun: under the fore-end at M_SupportGrip where the item says how (support_fingers /
	# palm: on top, the fitted support_offset, the forearm rose across the sight picture in ADS), else support_rel.
	support_target = gun * support_rel
	if def.two_handed and def.support_fingers != Vector3.ZERO:
		var under := _support_under(sk, gun, def)
		if under != Transform3D():
			support_target = under
	_two_bone(pose, _part("LeftUpperArm"), _part("LeftLowerArm"), lh, support_target, weight)
	support_error = pose[lh].origin.distance_to(support_target.origin)
	return true


## A gun held out (a pistol): the barrel turned onto the aim point by the spine, then the gun arm, then the wrist
## until it's on (each turn moves the muzzle - aiming down at the floor 2 m off, two rounds left 4 deg).
func _hold_out(pose: Array[Transform3D], rh: int, grip: Transform3D, target_sk: Vector3) -> void:
	var turn := _barrel_turn(pose[rh] * grip, target_sk)
	var spine_turn := _limit(turn, SPINE_MAX)
	for n: String in SPINE_SHARE:
		var i := _part(n)
		if i >= 0:
			_turn_subtree(pose, i, Quaternion.IDENTITY.slerp(spine_turn, float(SPINE_SHARE[n]) * weight), pose[i].origin)
	turn = _barrel_turn(pose[rh] * grip, target_sk)
	var ua := _part("RightUpperArm")
	if ua >= 0:
		_turn_subtree(pose, ua, Quaternion.IDENTITY.slerp(turn, weight), pose[ua].origin)
	for k in 4:
		turn = _barrel_turn(pose[rh] * grip, target_sk)
		if turn.get_angle() < 0.002:
			break
		_turn_subtree(pose, rh, Quaternion.IDENTITY.slerp(turn, weight), pose[rh].origin)


## A shouldered gun (two-handed, with an M_Stock): placed gun first - the stock in the right shoulder's pocket, the
## barrel from there onto the aim point, level (no cant) - and the gun hand brought onto its grip by two-bone IK.
## The spine leans into the aim's pitch (its yaw is the torso twist's); the clip's own hands held ITS rifle across
## the chest, the stock out past the left shoulder.
func _shoulder(pose: Array[Transform3D], rh: int, grip: Transform3D, target_sk: Vector3) -> void:
	var uc := _part("UpperChest")
	var sh := _part("RightUpperArm")
	if uc < 0 or sh < 0:
		_hold_out(pose, rh, grip, target_sk)
		return
	# Lean into the pitch (half of it, up the spine).
	var p0 := _pocket(pose, uc, sh)
	var d0 := (target_sk - p0).normalized()
	var pitch := asin(clampf(d0.y, -1.0, 1.0))
	var lean := Quaternion(_chest_axes(pose, uc).x, pitch * 0.5)
	for n: String in SPINE_SHARE:
		var i := _part(n)
		if i >= 0:
			_turn_subtree(pose, i, Quaternion.IDENTITY.slerp(lean, float(SPINE_SHARE[n]) * weight), pose[i].origin)
	pocket = _pocket(pose, uc, sh)
	# The gun: stock in the pocket, barrel (-Z) onto the aim point from the muzzle (two rounds: the muzzle sits off
	# the line from the pocket).
	var gun := Transform3D(Basis(), pocket)
	var d := (target_sk - pocket).normalized()
	for k in 2:
		var z := -d
		var x := Vector3.UP.cross(z)
		x = x.normalized() if x.length() > 1e-4 else Vector3.RIGHT
		gun.basis = Basis(x, z.cross(x).normalized(), z)
		gun.origin = pocket - gun.basis * _stock_local.origin
		var muzzle := gun * _muzzle_local.origin
		d = (target_sk - muzzle).normalized()
	stock = gun * _stock_local.origin
	_two_bone(pose, sh, _part("RightLowerArm"), rh, gun * grip.affine_inverse(), weight)


## The right shoulder's pocket (skeleton space): just inside the shoulder joint, a little forward and down - where
## a stock sits.
func _pocket(pose: Array[Transform3D], uc: int, sh: int) -> Vector3:
	var ax := _chest_axes(pose, uc)
	return pose[sh].origin + ax.x * POCKET.x + ax.y * POCKET.y + ax.z * POCKET.z


## The chest's own axes in skeleton space (x = the character's left, y = up, z = forward), from its rest pose.
func _chest_axes(pose: Array[Transform3D], uc: int) -> Basis:
	var rest: Transform3D = ragdoll.parts[uc].rest
	return (pose[uc].basis * rest.basis.inverse()).orthonormalized()


## Aiming down the sights, through the body: the neck brings the eye toward where the held gun's sight line wants it
## (cheek down to the stock, <= NECK_MAX), then the gun goes onto the eye's line - rear sight `fp_ads_distance` in
## front of it, front sight on the aim point - and the gun hand follows by IK. The camera is this eye (MarksmanEye):
## the sights are on the view.
func _aim_down_sights(sk: Skeleton3D, pose: Array[Transform3D], rh: int, grip: Transform3D, target_sk: Vector3, def: ItemDefinition) -> void:
	var neck := _part("Neck")
	if neck < 0 or _eye_local == Vector3.INF:
		_eye_setup(sk)
	if neck < 0 or _head_bone < 0:
		return
	if _sights_for != _muzzle_for:
		_sights_for = _muzzle_for
		_rear_local = UltraPoseSampler.marker(_muzzle_for, "M_RearSight").origin
		_front_local = UltraPoseSampler.marker(_muzzle_for, "M_FrontSight").origin
		if _front_local.is_equal_approx(_rear_local):
			_front_local = _rear_local + Vector3(0, 0, -0.3)
	var dist := def.fp_ads_distance
	var gun_now: Transform3D = pose[rh] * grip
	# Where the held gun wants the eye: on its sight line, `dist` behind the rear sight.
	var line_g := (_front_local - _rear_local).normalized()
	var want_eye := gun_now * (_rear_local - line_g * dist)
	var eye := _eye(sk, pose, neck)
	var j := pose[neck].origin
	var bend := _limit(_arc((eye - j).normalized(), (want_eye - j).normalized()), NECK_MAX)
	_turn_subtree(pose, neck, Quaternion.IDENTITY.slerp(bend, ads * HEAD_SHARE), j)
	eye = _eye(sk, pose, neck)
	ads_eye = eye
	# The gun on the eye's line.
	var d := (target_sk - eye).normalized()
	var z := -d
	var x := Vector3.UP.cross(z)
	x = x.normalized() if x.length() > 1e-4 else Vector3.RIGHT
	var b := Basis(x, z.cross(x).normalized(), z)
	var line_w := b * line_g
	b = Basis(_arc(line_w, d)) * b
	var gun_ads := Transform3D(b, eye + d * dist - b * _rear_local)
	var g := gun_now.interpolate_with(gun_ads, smoothstep(0.0, 1.0, ads))
	_two_bone(pose, _part("RightUpperArm"), _part("RightLowerArm"), rh, g * grip.affine_inverse(), 1.0)


## The eye (skeleton space) on this pose: the neck part x the Head bone's own pose under it x the eye offset.
func _eye(sk: Skeleton3D, pose: Array[Transform3D], neck: int) -> Vector3:
	return (pose[neck] * _neck_to_head(sk)) * _eye_local


func _neck_to_head(sk: Skeleton3D) -> Transform3D:
	var t := Transform3D()
	var b := _head_bone
	while b >= 0 and b != _neck_bone:
		t = sk.get_bone_pose(b) * t
		b = sk.get_bone_parent(b)
	return t


func _eye_setup(sk: Skeleton3D) -> void:
	_head_bone = sk.find_bone("Head")
	_neck_bone = int(ragdoll.parts[_part("Neck")].bone) if _part("Neck") >= 0 else -1
	if _head_bone < 0:
		return
	var off := character.body_profile.eye_offset if character.body_profile else Vector3(0, 0.075, -0.1)
	_eye_local = sk.get_bone_global_rest(_head_bone).basis.orthonormalized().inverse() * Vector3(-off.x, off.y, -off.z)


## The support hand under the fore-end (skeleton space): its fingers along `support_fingers`, palm toward
## `support_palm` (item frame), the palm on M_SupportGrip - as UltraEquipmentVisual._support_under does it.
func _support_under(sk: Skeleton3D, gun: Transform3D, def: ItemDefinition) -> Transform3D:
	if _palm_local == Vector3.ZERO:
		var hb := sk.get_bone_global_rest(sk.find_bone("LeftHand"))
		var tip := Vector3.ZERO
		for f in ["LeftMiddleDistal", "LeftRingDistal", "LeftIndexDistal"]:
			tip += sk.get_bone_global_rest(sk.find_bone(f)).origin / 3.0
		var v := hb.basis.orthonormalized().inverse() * (tip - hb.origin)
		v.y = 0.0
		if v.length() < 0.005:
			return Transform3D()
		_palm_local = v.normalized()
	if _grip_for != _muzzle_for:
		_grip_for = _muzzle_for
		_grip_contact = UltraPoseSampler.marker(_muzzle_for, "M_SupportGrip").origin
	var gb := gun.basis.orthonormalized()
	var f := (gb * def.support_fingers).normalized()
	var p := (gb * def.support_palm)
	p = (p - f * p.dot(f)).normalized()
	var src := Basis(Vector3.UP.cross(_palm_local), Vector3.UP, _palm_local)
	var b := Basis(f.cross(p), f, p) * src.inverse()
	# (The hand bone sits at the wrist: back along the hand, down off the palm.)
	return Transform3D(b, gun * _grip_contact - f * 0.065 - p * 0.03)


## The turn (skeleton space) taking the gun's barrel (-Z) from its muzzle onto `target`.
func _barrel_turn(gun: Transform3D, target: Vector3) -> Quaternion:
	var muzzle := gun * _muzzle_local.origin
	var b := -gun.basis.z.normalized()
	var d := target - muzzle
	if d.length() < 0.05:
		return Quaternion.IDENTITY
	return _arc(b, d.normalized())


func _arc(a: Vector3, b: Vector3) -> Quaternion:
	var c := a.cross(b)
	var dt := clampf(a.dot(b), -1.0, 1.0)
	if c.length() < 1e-6:
		return Quaternion.IDENTITY
	return Quaternion(c.normalized(), acos(dt))


func _limit(q: Quaternion, most: float) -> Quaternion:
	var a := q.get_angle()
	return q if a <= most else Quaternion.IDENTITY.slerp(q, most / a)


## Turns part `top` and everything below it by `q` about `about` (skeleton space).
func _turn_subtree(pose: Array[Transform3D], top: int, q: Quaternion, about: Vector3) -> void:
	var b := Basis(q)
	var xf := Transform3D(b, about - b * about)
	for j: int in _subtree(top):
		pose[j] = xf * pose[j]


## Two-bone IK on the pose: upper / lower / end parts reach `target` (origin; the end takes its basis), keeping the
## bend on the side the pose has it (the elbow's own direction is the pole). Blended by `w`.
func _two_bone(pose: Array[Transform3D], up: int, lo: int, end: int, target: Transform3D, w: float) -> void:
	if up < 0 or lo < 0 or end < 0:
		return
	var A := pose[up].origin
	var B := pose[lo].origin
	var C := pose[end].origin
	var a := A.distance_to(B)
	var b := B.distance_to(C)
	if a < 1e-4 or b < 1e-4:
		return
	var T := C.lerp(target.origin, w)
	var at := T - A
	var c := clampf(at.length(), absf(a - b) + 1e-3, a + b - 1e-3)
	var dir := at.normalized() if at.length() > 1e-5 else (C - A).normalized()
	var pole := (B - A) - dir * (B - A).dot(dir)
	if pole.length() < 1e-4:
		pole = (C - A).cross(Vector3.UP).cross(dir)
	pole = pole.normalized()
	var cos_a := clampf((a * a + c * c - b * b) / (2.0 * a * c), -1.0, 1.0)
	var B2 := A + dir * (a * cos_a) + pole * (a * sqrt(maxf(1.0 - cos_a * cos_a, 0.0)))
	var C2 := A + dir * c
	var q_up := _arc((B - A).normalized(), (B2 - A).normalized())
	pose[up] = Transform3D(Basis(q_up) * pose[up].basis, A)
	var lo_dir := (Basis(q_up) * (C - B)).normalized()
	var q_lo := _arc(lo_dir, (C2 - B2).normalized())
	pose[lo] = Transform3D(Basis(q_lo) * Basis(q_up) * pose[lo].basis, B2)
	var end_b := Basis(q_lo) * Basis(q_up) * pose[end].basis
	pose[end] = Transform3D(end_b.orthonormalized().slerp(target.basis.orthonormalized(), w), C2)
