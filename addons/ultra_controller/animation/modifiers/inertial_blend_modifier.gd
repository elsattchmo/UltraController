@tool
class_name InertialBlendModifier
extends SkeletonModifier3D
## Transitions by dead blending (D. Holden, "Dead Blending", 2023): when the animation switches
## (a state change, a blend space snapping to another clip, a turn flipping, a layer filter
## changing), the pose on screen carries on along its own motion (each bone's last velocity,
## decaying) and is crossfaded into the new animation over `blend_time` with an ease-in-out.
##   * Continuous in position AND velocity at the switch: the blend starts from exactly the pose
##     and motion on screen, and the ease has zero slope at both ends.
##   * Interruptions are free: a trigger mid-blend starts again from what is on screen now.
##     (The AnimationTree's own crossfade drops its old state when interrupted - rapid inputs
##     popped; the previous inertializer restarted from rest, a velocity jump at every switch.)
##   * Triggered by the driver, unconditionally (no guessing at jumps from the pose). It asks in
##     _process, a frame or two before the tree shows the new pose, so the crossfade waits HOLD
##     first (the old motion carried on alone): mixing in even a little of the not-yet-switched
##     pose leaked a 12 cm dip when the root jumped 2 m (a climb-down; m10 edge test).
## First modifier in the stack, so it works on the clip pose.

## Seconds the crossfade into the new animation takes.
@export_range(0.05, 0.6, 0.01) var blend_time := 0.2
## Half-life (s) of the old motion carried on (how quickly the extrapolated pose slows down).
@export_range(0.01, 0.4, 0.005) var halflife := 0.08
## Speed caps for the carried-on motion: bones (rad/s), hips (m/s).
const MAX_TURN := 18.0
const HOLD := 2.0 / 60.0
const MAX_MOVE := 4.0

var _hips := -1
var _out1: Array[Quaternion] = []         ## last two output poses (local rotations)
var _out2: Array[Quaternion] = []
var _hout1 := Vector3.ZERO
var _hout2 := Vector3.ZERO
var _dt1 := 1.0 / 60.0
var _frames := 0
const WARMUP := 3

var _src: Array[Quaternion] = []          ## the pose on screen when the blend started
var _src_w: Array[Vector3] = []           ## its angular velocity (rotation vector / s, parent space)
var _src_p := Vector3.ZERO
var _src_v := Vector3.ZERO
var _t := 0.0                             ## time into the blend
var _len := 0.2
var _active := false
var _pending := false
var _pending_len := 0.2

## Blends started so far (tests, tuning).
var jumps := 0
## 0..1 how much of the blend is shown (the driver fades it where IK must be exact).
var amount := 1.0
## Kept for the driver's API: a turn clip's fast steps are real motion - while it's off,
## triggers are ignored (a blend would soften the steps).
var detect := true
var reason := ""


## Start a blend from what is on screen into whatever the animation shows next.
func trigger(length := -1.0) -> void:
	if not detect:
		return
	_pending = true
	_pending_len = length if length > 0.0 else blend_time


## The character's root moved by `d` (skeleton space) with the clip making up for it (a
## scripted move whose capsule jumps to its end, the clip offset back): move the remembered
## hips with it, so the jump isn't carried on as motion.
func shift(d: Vector3) -> void:
	_pending_shift += d


var _pending_shift := Vector3.ZERO


func _process_modification_with_delta(delta: float) -> void:
	var sk := get_skeleton()
	if sk == null:
		return
	var n := sk.get_bone_count()
	if _hips < 0 or _out1.size() != n:
		_setup(sk, n)
	var dt := maxf(delta, 0.0)
	if _pending_shift != Vector3.ZERO and _hips >= 0:
		var par := sk.get_bone_parent(_hips)
		var d := sk.get_bone_global_pose(par).basis.inverse() * _pending_shift if par >= 0 else _pending_shift
		_hout1 += d
		_hout2 += d
		_src_p += d
		_pending_shift = Vector3.ZERO
	if _pending and _frames >= WARMUP:
		_start(sk, n)
	_pending = false
	if _active:
		_t += dt
		var a := smoothstep(0.0, 1.0, (_t - HOLD) / maxf(_len, 1e-3))
		if a >= 1.0:
			_active = false
		else:
			# The old motion carried on, slowing down: x + v (1 - e^(-lt)) / l.
			var l := 0.69314718 / maxf(halflife, 1e-4)
			var f := (1.0 - exp(-l * _t)) / l
			var k := a + (1.0 - a) * (1.0 - amount)          # (amount < 1: less of the old)
			for b in n:
				var ext := (_from_vec(_src_w[b] * f) * _src[b]).normalized()
				var cur := sk.get_bone_pose_rotation(b)
				sk.set_bone_pose_rotation(b, ext.slerp(cur, k).normalized())
			if _hips >= 0:
				var hp := _src_p + _src_v * f
				sk.set_bone_pose_position(_hips, hp.lerp(sk.get_bone_pose_position(_hips), k))
	# History (output).
	for b in n:
		_out2[b] = _out1[b]
		_out1[b] = sk.get_bone_pose_rotation(b)
	_hout2 = _hout1
	_hout1 = sk.get_bone_pose_position(_hips) if _hips >= 0 else Vector3.ZERO
	_dt1 = maxf(dt, 1.0 / 240.0)
	_frames += 1


## The blend's source: the pose on screen last frame and how it was moving.
func _start(sk: Skeleton3D, n: int) -> void:
	for b in n:
		_src[b] = _out1[b]
		_src_w[b] = (_to_vec((_out1[b] * _out2[b].inverse()).normalized()) / _dt1).limit_length(MAX_TURN)
	_src_p = _hout1
	_src_v = ((_hout1 - _hout2) / _dt1).limit_length(MAX_MOVE)
	_t = 0.0
	_len = _pending_len
	_active = true
	jumps += 1


func _setup(sk: Skeleton3D, n: int) -> void:
	_hips = sk.find_bone("Hips")
	for arr: Array in [_out1, _out2, _src]:
		arr.resize(n)
		arr.fill(Quaternion.IDENTITY)
	_src_w.resize(n)
	_src_w.fill(Vector3.ZERO)
	for b in n:
		_out1[b] = sk.get_bone_pose_rotation(b)
		_out2[b] = _out1[b]
	_frames = 0
	_active = false


static func _to_vec(q: Quaternion) -> Vector3:
	if q.w < 0.0:
		q = -q
	var ang := q.get_angle()
	if ang < 1e-6:
		return Vector3.ZERO
	return q.get_axis().normalized() * ang


static func _from_vec(v: Vector3) -> Quaternion:
	var ang := v.length()
	if ang < 1e-6:
		return Quaternion.IDENTITY
	return Quaternion(v / ang, ang)
