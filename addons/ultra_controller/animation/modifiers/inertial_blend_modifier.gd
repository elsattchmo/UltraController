@tool
class_name InertialBlendModifier
extends SkeletonModifier3D
## Inertialization: when the animation switches (a state change, a blend space snapping to
## another clip, a turn starting), the pose on screen settles onto the new animation on a
## critically damped spring instead of cutting.
##   * trigger() opens a short window (a few frames) in which the jump is looked for in the
##     incoming pose (acceleration spike at the hips / spine / head): the driver asks in
##     _process, often a frame before the AnimationTree actually changes the pose. Outside a
##     window nothing is touched - fast motion inside a clip (a roll, a jump) is real.
##   * The offset starts from where the output was heading and decays with zero initial rate
##     (no lurch as the fade starts, unlike an ease-out curve). It must NOT carry the old
##     velocity as offset velocity: that is added on top of the new clip's own motion and
##     flung fast-moving limbs (legs in a roll) twice as far.
## First modifier in the stack, so it works on the clip pose.

## Spring half-life (s): how long half the offset takes to fade.
@export_range(0.02, 0.5, 0.005) var halflife := 0.11
## A frame whose hips move this much more than they were moving (m) counts as a jump.
@export_range(0.002, 0.1, 0.001) var jump_pos := 0.012
## ... or whose core bones turn this much more than they were turning (degrees).
@export_range(0.5, 30.0, 0.5) var jump_rot_deg := 4.0
## ... or that moves faster than this on its own: hips m/s, core bones deg/s (relative to the
## body - a weight swept across in a couple of frames is a jump spread over them).
@export_range(0.2, 10.0, 0.1) var jump_speed := 3.0
@export_range(60.0, 2000.0, 10.0) var jump_turn_speed := 900.0

var _window := 0
const WINDOW := 4                        ## frames after a trigger() in which a jump is smoothed
var _hips := -1
var _core := PackedInt32Array()
var _in1: Array[Quaternion] = []
var _in2: Array[Quaternion] = []
var _out1: Array[Quaternion] = []
var _out2: Array[Quaternion] = []
var _hin1 := Vector3.ZERO
var _hin2 := Vector3.ZERO
var _hout1 := Vector3.ZERO
var _hout2 := Vector3.ZERO
var _frames := 0
const WARMUP := 10
const MAX_STEP := 0.12                   ## rad: at most this much of the last frame's motion carried on
var _dt1 := 1.0 / 60.0
var _off: Array[Vector3] = []           ## per-bone offset rotation (axis * angle) on the clip pose
var _offv: Array[Vector3] = []
var _hoff := Vector3.ZERO
var _hoffv := Vector3.ZERO
var _active := false
## Jumps smoothed so far (tests, tuning).
var jumps := 0
## 0..1 how much of the smoothing is shown (the driver fades it out where IK must be exact:
## hands and feet on rungs, ledges, ropes).
var amount := 1.0
## Off while a clip whose fast motion is real plays (a turn clip driven by the body's turn).
var detect := true
var reason := ""


func trigger() -> void:
	_window = WINDOW


func _process_modification_with_delta(delta: float) -> void:
	var sk := get_skeleton()
	if sk == null:
		return
	var n := sk.get_bone_count()
	if _hips < 0 or _in1.size() != n:
		_setup(sk, n)
	var q_in: Array[Quaternion] = []
	q_in.resize(n)
	for b in n:
		q_in[b] = sk.get_bone_pose_rotation(b)
	var h_in := sk.get_bone_pose_position(_hips) if _hips >= 0 else Vector3.ZERO
	var dt := maxf(delta, 0.0)
	# (Not while warming up: the first frames go from the rest pose to the first clip.)
	if _frames >= WARMUP and _window > 0 and detect and _jumped(q_in, h_in):
		# This frame shows exactly where the old motion was heading; the spring takes it from here.
		_restart(q_in, h_in)
	elif _active:
		var y := 4.0 * 0.69314718 / maxf(halflife, 1e-4) / 2.0        # critically damped
		var e := exp(-y * dt)
		var big := 0.0
		for b in n:
			var x := _off[b]
			if x == Vector3.ZERO and _offv[b] == Vector3.ZERO:
				continue
			var j1 := _offv[b] + x * y
			_off[b] = e * (x + j1 * dt)
			_offv[b] = e * (_offv[b] - j1 * y * dt)
			big = maxf(big, _off[b].length() + _offv[b].length() * 0.05)
		var j1h := _hoffv + _hoff * y
		_hoff = e * (_hoff + j1h * dt)
		_hoffv = e * (_hoffv - j1h * y * dt)
		big = maxf(big, (_hoff.length() + _hoffv.length() * 0.05) * 10.0)
		_active = big > 1e-4
		if not _active:
			_off.fill(Vector3.ZERO)
			_offv.fill(Vector3.ZERO)
			_hoff = Vector3.ZERO
			_hoffv = Vector3.ZERO
	_window = maxi(_window - 1, 0)
	if _active and amount > 0.001:
		for b in n:
			if _off[b] != Vector3.ZERO:
				sk.set_bone_pose_rotation(b, (_from_vec(_off[b] * amount) * q_in[b]).normalized())
		if _hips >= 0:
			sk.set_bone_pose_position(_hips, h_in + _hoff * amount)
	# History (incoming and output).
	for b in n:
		_in2[b] = _in1[b]
		_in1[b] = q_in[b]
		_out2[b] = _out1[b]
		_out1[b] = sk.get_bone_pose_rotation(b)
	_hin2 = _hin1
	_hin1 = h_in
	_hout2 = _hout1
	_hout1 = sk.get_bone_pose_position(_hips) if _hips >= 0 else Vector3.ZERO
	_dt1 = dt
	_frames += 1


func _setup(sk: Skeleton3D, n: int) -> void:
	_hips = sk.find_bone("Hips")
	_core = PackedInt32Array()
	for nm in ["Hips", "Spine", "Chest", "UpperChest", "Neck", "Head"]:
		var b := sk.find_bone(nm)
		if b >= 0:
			_core.append(b)
	for arr: Array in [_in1, _in2, _out1, _out2]:
		arr.resize(n)
		arr.fill(Quaternion.IDENTITY)
	_off.resize(n)
	_off.fill(Vector3.ZERO)
	_offv.resize(n)
	_offv.fill(Vector3.ZERO)
	_frames = 0
	_active = false


## Did the incoming pose jump this frame (inside a trigger window)? Its acceleration spiked, or
## it moved faster than a body part moves on its own.
func _jumped(q_in: Array[Quaternion], h_in: Vector3) -> bool:
	var v := h_in - _hin1
	if (v - (_hin1 - _hin2)).length() > jump_pos or v.length() > jump_speed * maxf(_dt1, 1.0 / 240.0):
		reason = "hips acc %.3f vel %.3f" % [(v - (_hin1 - _hin2)).length(), v.length()]
		return true
	var lim := deg_to_rad(jump_rot_deg)
	var vlim := deg_to_rad(jump_turn_speed) * maxf(_dt1, 1.0 / 240.0)
	for b: int in _core:
		var d1 := (q_in[b] * _in1[b].inverse()).normalized()
		var d0 := (_in1[b] * _in2[b].inverse()).normalized()
		if (d1 * d0.inverse()).normalized().get_angle() > lim or d1.get_angle() > vlim:
			reason = "bone %d acc %.1f vel %.1f" % [b, rad_to_deg((d1 * d0.inverse()).normalized().get_angle()), rad_to_deg(d1.get_angle())]
			return true
	return false


## Re-inertialize: this frame shows where the output was heading (its last pose moved on by
## its last motion, capped); the offset from the new pose to that then decays from rest.
func _restart(q_in: Array[Quaternion], h_in: Vector3) -> void:
	for b in q_in.size():
		var step := (_out1[b] * _out2[b].inverse()).normalized()
		if step.get_angle() > MAX_STEP:
			step = Quaternion.IDENTITY.slerp(step, MAX_STEP / step.get_angle())
		var pred := (step * _out1[b]).normalized()
		_off[b] = _to_vec((pred * q_in[b].inverse()).normalized())
		_offv[b] = Vector3.ZERO
	if _hips >= 0:
		_hoff = (_hout1 + (_hout1 - _hout2).limit_length(0.03)) - h_in
		_hoffv = Vector3.ZERO
	_active = true
	jumps += 1


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
