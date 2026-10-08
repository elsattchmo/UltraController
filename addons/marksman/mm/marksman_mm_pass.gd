class_name MarksmanMMPass
extends RefCounted
## Motion matching's pose pass (a SinewPoseModifier pass, before the gun pass): fits the matched clip to the body's
## real motion.
## 0. Ground: the clip's soles onto the floor (clips are authored a few cm above or below it; per clip, eased).
## 1. Direction warp: the clip's legs travel along ITS ground velocity; the body's goes elsewhere (a diagonal between
##    two clips' ways, a velocity still turning) - the whole body turns about the hips by the difference (<= WARP_MAX)
##    and the spine turns the chest back, so the legs walk where the body goes and the torso keeps facing the aim.
## 2. Foot lock: a foot the clip has planted stays where it was put down (world), the leg reaching it by two-bone IK;
##    released when the clip lifts it (or it is left more than RELEASE_DIST behind), easing back onto the clip over
##    RELEASE_TIME.

const WARP_MAX := deg_to_rad(50.0)
const WARP_RATE := 6.0              ## rad/s the warp may change
const RELEASE_DIST := 0.15
const RELEASE_TIME := 0.15
const SPINE_SHARE := {"Spine": 0.35, "Chest": 0.35, "UpperChest": 0.3}

var character: UltraCharacter
var ragdoll: SinewRagdoll
var matcher: MarksmanMotionMatcher
## 0..1: how much the pass does (the driver eases it with the "mm" state).
var weight := 0.0
var warp := 0.0
## The playing clip's floor height taken out of the pose (m, eased).
var ground := 0.0
var _ground_set := false
const GROUND_RATE := 0.3
## Per foot: locked (world position), the lock's offset fading after a release, its time left.
var locked: Array[bool] = [false, false]
var lock_at: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var release: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var release_t: Array[float] = [0.0, 0.0]
var _wait_lift: Array[bool] = [false, false]

var _p := {}
var _sub := {}
var _last_sk := Vector3.INF


func _init(c: UltraCharacter, r: SinewRagdoll, m: MarksmanMotionMatcher) -> void:
	character = c
	ragdoll = r
	matcher = m
	for i in r.parts.size():
		_p[String(r.parts[i].name)] = i


func _part(n: String) -> int:
	return int(_p.get(n, -1))


func apply(mod: SinewPoseModifier, sk: Skeleton3D) -> bool:
	var dt := clampf(character.get_process_delta_time(), 0.0, 0.1)
	var xf := sk.global_transform
	# (A teleport: nothing stays locked.)
	if _last_sk != Vector3.INF and xf.origin.distance_to(_last_sk) > 1.0:
		locked = [false, false]
		release_t = [0.0, 0.0]
	_last_sk = xf.origin
	if weight <= 0.0 or matcher == null or matcher.db == null or matcher.clip < 0:
		locked = [false, false]
		warp = 0.0
		_ground_set = false
		return false
	var pose := mod.anim_pose
	# The clip's floor onto the real one (eased: a switch between clips authored at different heights glides).
	var want: float = matcher.db.clips[matcher.clip].ground
	ground = move_toward(ground, want, GROUND_RATE * dt) if dt > 0.0 and _ground_set else want
	_ground_set = true
	if absf(ground) > 1e-5:
		var down := Vector3(0.0, -ground * weight, 0.0)
		for i in pose.size():
			pose[i].origin += down
	if OS.get_environment("MM_NOWARP") == "":
		_warp(sk, pose, dt)
	if OS.get_environment("MM_NOLOCK") == "":
		for side in 2:
			_foot(sk, pose, side, dt)
	return true


func _warp(sk: Skeleton3D, pose: Array[Transform3D], dt: float) -> void:
	var cv := matcher.clip_velocity()
	var inv := sk.global_transform.basis.orthonormalized().inverse()
	var v3 := inv * Vector3(character.state.vel.x, 0.0, character.state.vel.z)
	var v := Vector2(v3.x, v3.z)
	var want := 0.0
	if cv.length() > 0.3 and v.length() > 0.3:
		# Signed turn from the clip's way to the body's, about the skeleton's up (+Y): x -> z is -Y.
		want = clampf(-cv.angle_to(v), -WARP_MAX, WARP_MAX)
	warp = move_toward(warp, want, WARP_RATE * dt) if dt > 0.0 else want
	var w := warp * weight
	if absf(w) < 1e-4:
		return
	var hips := _part("Hips")
	if hips < 0:
		hips = 0
	var up := Vector3.UP
	var about: Vector3 = pose[hips].origin
	var turn := Transform3D(Basis(up, w), about - Basis(up, w) * about)
	for i in pose.size():
		pose[i] = turn * pose[i]
	# The chest back to the facing, spread up the spine.
	for n: String in SPINE_SHARE:
		var i := _part(n)
		if i < 0:
			continue
		var b := Basis(up, -w * float(SPINE_SHARE[n]))
		var piv: Vector3 = pose[i].origin
		var x := Transform3D(b, piv - b * piv)
		for j: int in _subtree(i):
			pose[j] = x * pose[j]


func _foot(sk: Skeleton3D, pose: Array[Transform3D], side: int, dt: float) -> void:
	var pre := "Left" if side == 0 else "Right"
	var up_i := _part(pre + "UpperLeg")
	var lo_i := _part(pre + "LowerLeg")
	var ft_i := _part(pre + "Foot")
	if up_i < 0 or lo_i < 0 or ft_i < 0:
		return
	var xf := sk.global_transform
	var foot_w: Vector3 = xf * pose[ft_i].origin
	var planted := matcher.planted(side)
	# Where the foot shows now: the clip's, plus what is left of a released lock's offset.
	var shown := foot_w
	if not locked[side] and release_t[side] > 0.0:
		release_t[side] = maxf(release_t[side] - dt, 0.0)
		shown = foot_w + release[side] * smoothstep(0.0, 1.0, release_t[side] / RELEASE_TIME)
	if not planted:
		_wait_lift[side] = false
	# A plant locks where the foot is SHOWN (a fresh lock never jumps it); a foot pulled out of its lock waits for the
	# clip's next plant (re-locking on the spot it was dragged from held it there).
	if planted and not locked[side] and not _wait_lift[side]:
		locked[side] = true
		lock_at[side] = shown
		release_t[side] = 0.0
	if locked[side] and (not planted or lock_at[side].distance_to(foot_w) > RELEASE_DIST):
		locked[side] = false
		_wait_lift[side] = planted
		release[side] = lock_at[side] - foot_w
		release_t[side] = RELEASE_TIME
		shown = lock_at[side]
	var target := lock_at[side] if locked[side] else shown
	if target.distance_to(foot_w) < 1e-4:
		return
	var t_sk := xf.affine_inverse() * target
	_two_bone(pose, up_i, lo_i, ft_i, Transform3D(pose[ft_i].basis, t_sk), weight)


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


## Two-bone IK on the pose (as MarksmanGunPass._two_bone): the knee keeps the side the clip bends it to; the
## children of the foot (toes) follow it as bones without parts do.
func _two_bone(pose: Array[Transform3D], up: int, lo: int, end: int, target: Transform3D, w: float) -> void:
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
	pose[end] = Transform3D(target.basis, C2)


static func _arc(a: Vector3, b: Vector3) -> Quaternion:
	var d := clampf(a.dot(b), -1.0, 1.0)
	if d > 0.999999:
		return Quaternion.IDENTITY
	var ax := a.cross(b)
	if ax.length() < 1e-6:
		ax = a.cross(Vector3.RIGHT if absf(a.x) < 0.9 else Vector3.UP)
	return Quaternion(ax.normalized(), acos(d))
