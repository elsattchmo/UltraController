class_name MarksmanMMPass
extends RefCounted
## Motion matching's pose pass (a SinewPoseModifier pass, before the gun pass): fits the matched clip to the body's
## real motion.
## 0. Ground: the clip's soles onto the floor (clips are authored a few cm above or below it; per clip, eased).
## 0b. Ground fit (foot IK): each foot onto the surface under it (stairs, ramps, uneven ground) - see _ground_fit.
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
## What it applies this frame: weight, less the gait's share (a stumble), none while physics has the legs.
var _w := 0.0
var _physics_legs := false
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


## How much of the limp layer shows (MarksmanAnimDriver), 0 without one.
func _limp_w() -> float:
	var drv := character.anim as MarksmanAnimDriver
	if drv == null or drv.mm_limp == null or drv.mm_limp.db == null or drv.mm_limp.clip < 0:
		return 0.0
	return drv.limp_w


## Is the foot planted in what shows: the walk's frame, or the limp's once it is most of the picture.
func _planted(side: int) -> bool:
	if _limp_w() > 0.5:
		return (character.anim as MarksmanAnimDriver).mm_limp.planted(side)
	return matcher.planted(side)


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
	# (Standing aside while the gait has the legs - a stumble. A stagger keeps the pose as it was - the matcher
	# freezes, MarksmanAnimDriver - and only lets the feet go (easing off their locks): the balancer steps them now;
	# dropping the whole pass at once jumped the muscles' targets just as the balancer took over.)
	var w := weight * (1.0 - ragdoll.gait_w)
	_physics_legs = ragdoll.staggering() or ragdoll._handback_t >= 0.0
	if w <= 0.0 or matcher == null or matcher.db == null or matcher.clip < 0:
		locked = [false, false]
		warp = 0.0
		_ground_set = false
		_fit_set = false
		return false
	var pose := mod.anim_pose
	_w = w
	# The clip's floor onto the real one (eased: a switch between clips authored at different heights glides).
	var want: float = matcher.db.clips[matcher.clip].ground
	var lw := _limp_w()
	if lw > 0.0:
		var lm: MarksmanMotionMatcher = (character.anim as MarksmanAnimDriver).mm_limp
		want = lerpf(want, float(lm.db.clips[lm.clip].ground), lw)
	ground = move_toward(ground, want, GROUND_RATE * dt) if dt > 0.0 and _ground_set else want
	_ground_set = true
	if absf(ground) > 1e-5:
		var down := Vector3(0.0, -ground * _w, 0.0)
		for i in pose.size():
			pose[i].origin += down
	if OS.get_environment("MM_NOWARP") == "":
		_warp(sk, pose, dt)
	if OS.get_environment("MM_NOFIT") == "":
		_ground_fit(sk, pose, dt)
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
	var w := warp * _w
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
	var planted := _planted(side) and not _physics_legs
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
	# (A planted foot being drawn back onto a lip: its lock follows it there.)
	if locked[side] and _edge_pull[side] != Vector3.ZERO:
		lock_at[side] = foot_w
	var target := lock_at[side] if locked[side] else shown
	if target.distance_to(foot_w) < 1e-4:
		return
	var t_sk := xf.affine_inverse() * target
	_two_bone(pose, up_i, lo_i, ft_i, Transform3D(pose[ft_i].basis, t_sk), _w)


# ------------------------------------------------------------------ ground fit

## Probes start this far over the body's floor and reach this far under it (m).
const FIT_UP := 0.55
const FIT_DOWN := 0.7
## A foot's offset follows the ground under it at most this fast (m/s): up quicker than down (a toe meeting a riser).
const FIT_RISE := 3.5
const FIT_FALL := 2.0
## The hips go down for the lower foot (legs can't stretch), at most this far, following at this rate (m/s).
const PELVIS_MAX := 0.4
const PELVIS_RATE := 1.6
## Share of a leg's length it may straighten to (the rest is the hips going down).
const REACH := 0.97
## A planted sole turns onto the surface by at most this (rad).
const TILT_MAX := deg_to_rad(28.0)

## Over a gap: the far edge takes the ankle this far past it (the heel lands on it), the near one keeps the ball this
## far short of it (m).
const GAP_HEEL := 0.09
const GAP_BALL := 0.03
## A foot over a drop at least the character's `ledge_height` (else this, m) below the ground under its own ankle is over
## an edge; only a body slower than EDGE_STILL (m/s) keeps its feet on the lip.
const EDGE_DROP := 0.3
const EDGE_STILL := 0.6
## Per foot: how far a planted foot over an edge is drawn back onto the lip (skeleton space).
var _edge_pull: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
## Per foot: how far its ground is above (+) / below (-) the body's floor (eased), and the surface's normal.
var fit_off: Array[float] = [0.0, 0.0]
var fit_normal: Array[Vector3] = [Vector3.UP, Vector3.UP]
var pelvis_off := 0.0
var _fit_set := false


## The matched clip walks on flat ground at the body's floor (the skeleton's origin); the world isn't flat. Under each
## foot's ankle and ball the ground is probed (the higher of the two: a ball on the next tread holds the foot up there);
## the hips lower for the lower foot, each leg reaches its foot onto its ground (two-bone IK) and a planted sole turns
## onto the surface. Followed per foot, so a swinging foot passing over a step edge rises instead of popping.
## No ground within reach under a foot (a gap): it keeps the floor's height.
func _ground_fit(sk: Skeleton3D, pose: Array[Transform3D], dt: float) -> void:
	var xf := sk.global_transform
	var floor_y := xf.origin.y
	var space := sk.get_world_3d().direct_space_state
	var to_sk := xf.basis.orthonormalized().inverse()
	var want: Array[float] = [0.0, 0.0]
	var normals: Array[Vector3] = [Vector3.UP, Vector3.UP]
	for side in 2:
		var ft := _part("LeftFoot" if side == 0 else "RightFoot")
		if ft < 0:
			return
		var ankle: Vector3 = xf * pose[ft].origin
		var ball := ankle + (xf.basis * (pose[ft].basis * _ball_local(sk, side)))
		var best := -INF
		var n := Vector3.UP
		for p: Vector3 in [ankle, ball]:
			var hit := _probe(space, p, floor_y)
			if not hit.is_empty() and float(hit.y) > best:
				best = hit.y
				n = hit.n
		want[side] = clampf(best - floor_y, -FIT_DOWN, FIT_UP) if best > -INF else 0.0
		normals[side] = n
		# Over an edge (nothing within reach under it, or a drop): a planted foot stays on the lip - drawn back toward
		# the body's centre onto the last solid ground (the body itself goes over only with its centre: the motor's
		# fall, MarksmanCharacter). A swinging foot may pass over.
		_edge_pull[side] = Vector3.ZERO
		# Crossing a gap in a stride (MarksmanCharacter.gap): over it the foot keeps the edges' height (a swinging foot
		# doesn't reach down into it), and a foot the clip plants in it lands on the nearer edge - the far one is the
		# long stride across.
		var g: Variant = character.get("gap")
		if g is Dictionary and not (g as Dictionary).is_empty():
			var gd: Dictionary = g
			var dir: Vector3 = gd.dir
			var width: float = gd.width
			var a_ank := (ankle - (gd.from as Vector3)).dot(dir)
			var a_ball := (ball - (gd.from as Vector3)).dot(dir)
			if (a_ank > -0.02 and a_ank < width + 0.02) or (a_ball > -0.02 and a_ball < width + 0.02):
				want[side] = float(gd.y) - floor_y
				normals[side] = Vector3.UP
				if _planted(side):
					var to_far := a_ank > width * 0.5 - 0.1
					# (Far edge: the heel just onto it; near edge: the ball just short of it.)
					var shift := (width + GAP_HEEL - a_ank) if to_far else (-GAP_BALL - a_ball)
					_edge_pull[side] = to_sk * (dir * shift)
				continue
		var still := Vector2(character.state.vel.x, character.state.vel.z).length() < EDGE_STILL
		if _planted(side) and still:
			# The ball first (the foot's front over the lip), then the whole foot: drawn back toward the body's centre
			# until the ball is on solid ground. A drop is measured from the ground under the foot's own ankle (going
			# down stairs or a slope, the ball's ground is lower than the body's floor without any edge), and only for a
			# body standing (walking on is going over).
			var ball_hit := _probe(space, ball, floor_y)
			var ankle_hit := _probe(space, ankle, floor_y)
			var own := float(ankle_hit.y) if not ankle_hit.is_empty() else floor_y
			var ledge: float = character.get("ledge_height") if character.get("ledge_height") != null else EDGE_DROP
			var ball_over := ball_hit.is_empty() or float(ball_hit.y) < own - ledge
			if ball_over:
				var centre := Vector3(xf.origin.x, ball.y, xf.origin.z)
				for k in range(1, 9):
					var p := ball.lerp(centre, k / 8.0)
					var h := _probe(space, p, floor_y)
					if not h.is_empty() and float(h.y) > own - ledge:
						_edge_pull[side] = to_sk * (ball.lerp(centre, minf((k + 0.3) / 8.0, 1.0)) - ball)
						want[side] = clampf(float(h.y) - floor_y, -FIT_DOWN, FIT_UP)
						normals[side] = h.n
						break

	for side in 2:
		if not _fit_set or dt <= 0.0:
			fit_off[side] = want[side]
		else:
			var rate := FIT_RISE if want[side] > fit_off[side] else FIT_FALL
			fit_off[side] = move_toward(fit_off[side], want[side], rate * dt)
		fit_normal[side] = fit_normal[side].slerp(normals[side], clampf(dt * 12.0, 0.0, 1.0)) if _fit_set else normals[side]
	# The hips only go down as far as a leg needs to reach its foot (straightening takes up the rest).
	var k := _w
	var need := 0.0
	for side in 2:
		var pre := "Left" if side == 0 else "Right"
		var up_i := _part(pre + "UpperLeg")
		var lo_i := _part(pre + "LowerLeg")
		var ft_i := _part(pre + "Foot")
		var hip: Vector3 = pose[up_i].origin
		var reach := (pose[up_i].origin.distance_to(pose[lo_i].origin) + pose[lo_i].origin.distance_to(pose[ft_i].origin)) * REACH
		var tgt: Vector3 = pose[ft_i].origin + Vector3(0.0, fit_off[side] * k, 0.0)
		var hz := Vector2(tgt.x - hip.x, tgt.z - hip.z).length()
		var v := hip.y - tgt.y
		var fits := sqrt(maxf(reach * reach - hz * hz, 0.0))
		need = maxf(need, v - fits)
	var p_want := -clampf(need, 0.0, PELVIS_MAX)
	pelvis_off = move_toward(pelvis_off, p_want, PELVIS_RATE * dt) if _fit_set and dt > 0.0 else p_want
	_fit_set = true
	if absf(pelvis_off) > 1e-4:
		var d := to_sk * Vector3(0.0, pelvis_off, 0.0)
		for i in pose.size():
			pose[i].origin += d
	for side in 2:
		var pre := "Left" if side == 0 else "Right"
		var up_i := _part(pre + "UpperLeg")
		var lo_i := _part(pre + "LowerLeg")
		var ft_i := _part(pre + "Foot")
		var lift := fit_off[side] * k - pelvis_off
		var b: Basis = pose[ft_i].basis
		# A planted sole onto the surface (its normal in the skeleton's frame), limited.
		if _planted(side):
			var n_sk := (to_sk * fit_normal[side]).normalized()
			var q := _arc(Vector3.UP, n_sk)
			var ang := q.get_angle()
			if ang > 1e-4:
				q = Quaternion(q.get_axis(), minf(ang, TILT_MAX) * k)
				b = Basis(q) * b
		if absf(lift) < 1e-4 and b == pose[ft_i].basis and _edge_pull[side] == Vector3.ZERO:
			continue
		var t := pose[ft_i].origin + Vector3(0.0, lift, 0.0) + _edge_pull[side] * k
		_two_bone(pose, up_i, lo_i, ft_i, Transform3D(b, t), 1.0)


func _probe(space: PhysicsDirectSpaceState3D, p: Vector3, floor_y: float) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(Vector3(p.x, floor_y + FIT_UP, p.z), Vector3(p.x, floor_y - FIT_DOWN, p.z),
			UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC)
	q.exclude = [character.get_rid()]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return {}
	return {"y": (hit.position as Vector3).y, "n": hit.normal as Vector3}


## The ball of the foot (the sole under the toe joint) in the foot bone's frame, from the rest pose.
var _ball_cache: Array = [null, null]
func _ball_local(sk: Skeleton3D, side: int) -> Vector3:
	if _ball_cache[side] == null:
		var f := sk.find_bone("LeftFoot" if side == 0 else "RightFoot")
		var t := sk.find_bone("LeftToes" if side == 0 else "RightToes")
		var rest := sk.get_bone_global_rest(f)
		var tr := sk.get_bone_global_rest(t)
		_ball_cache[side] = rest.basis.inverse() * (Vector3(tr.origin.x, 0.0, tr.origin.z) - rest.origin)
	return _ball_cache[side]


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
	# The knee's way, swung with the leg onto the new hip -> foot line (a foot lifted 0.4 m onto a higher tread turns
	# that line far: the knee's old offset, measured against the new line, pointed across the other leg).
	var swing := _arc((C - A).normalized(), dir) if (C - A).length() > 1e-5 else Quaternion.IDENTITY
	var knee := Basis(swing) * (B - A)
	var pole := knee - dir * knee.dot(dir)
	# (Plus the way this knee bends - the thigh's own forward: on a nearly straight leg the knee's offset is a few mm and
	# its direction anything; the knee flipped sideways for a frame and the thighs went through each other.)
	var hint := pose[up].basis * _knee_fwd(up)
	hint -= dir * hint.dot(dir)
	# (Only where the knee's own offset is too small to say: a bent knee keeps the clip's direction - the rifle stance's
	# knees point out, and a fixed forward pull crossed the legs.)
	var fill := clampf(KNEE_HINT - pole.length(), 0.0, KNEE_HINT)
	pole = pole + hint.normalized() * fill if hint.length() > 1e-4 else pole
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


## Below this knee offset (m) the thigh's forward fills in for the knee's bend direction.
const KNEE_HINT := 0.08
var _knee_cache := {}


## The model's forward (+Z: the way knees bend) in the thigh part's bone frame, from the rest pose.
func _knee_fwd(up: int) -> Vector3:
	if not _knee_cache.has(up):
		var sk := character.skeleton
		var rest := sk.get_bone_global_rest(int(ragdoll.parts[up].bone))
		_knee_cache[up] = (rest.basis.orthonormalized().inverse() * Vector3.FORWARD * -1.0).normalized()
	return _knee_cache[up]


static func _arc(a: Vector3, b: Vector3) -> Quaternion:
	var d := clampf(a.dot(b), -1.0, 1.0)
	if d > 0.999999:
		return Quaternion.IDENTITY
	var ax := a.cross(b)
	if ax.length() < 1e-6:
		ax = a.cross(Vector3.RIGHT if absf(a.x) < 0.9 else Vector3.UP)
	return Quaternion(ax.normalized(), acos(d))
