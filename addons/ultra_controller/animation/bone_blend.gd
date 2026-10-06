class_name UltraBoneBlend
extends RefCounted
## Dead blending for a modifier's own output (InertialBlendModifier does it for the clips, before
## the modifiers): when a modifier switches how it works - a mode flipped, a target handed to
## another owner - the bones it moves carry on from the pose on screen along their own motion
## and crossfade into the new result. Call apply() at the end of the modifier's pass, every
## frame, and trigger() on the switch.

var bones := PackedInt32Array()
var blend_time := 0.25
var halflife := 0.08
const HOLD := 1.0 / 60.0
const MAX_TURN := 18.0
var _out1: Array[Quaternion] = []
var _out2: Array[Quaternion] = []
var _src: Array[Quaternion] = []
var _src_w: Array[Vector3] = []
var _t := 0.0
var _active := false
var _pending := false
var _frames := 0
var _dt1 := 1.0 / 60.0


func _init(p_bones := PackedInt32Array(), p_time := 0.25) -> void:
	bones = p_bones
	blend_time = p_time


func trigger() -> void:
	_pending = true


func apply(sk: Skeleton3D, delta: float) -> void:
	var n := bones.size()
	if _out1.size() != n:
		for arr: Array in [_out1, _out2, _src]:
			arr.resize(n)
		_src_w.resize(n)
		for i in n:
			var q := sk.get_bone_pose_rotation(bones[i]) if bones[i] >= 0 else Quaternion.IDENTITY
			_out1[i] = q
			_out2[i] = q
		_frames = 0
	if _pending and _frames >= 2:
		for i in n:
			_src[i] = _out1[i]
			_src_w[i] = (InertialBlendModifier._to_vec((_out1[i] * _out2[i].inverse()).normalized()) / _dt1).limit_length(MAX_TURN)
		_t = 0.0
		_active = true
	_pending = false
	if _active:
		_t += maxf(delta, 0.0)
		var a := smoothstep(0.0, 1.0, (_t - HOLD) / maxf(blend_time, 1e-3))
		if a >= 1.0:
			_active = false
		else:
			var l := 0.69314718 / maxf(halflife, 1e-4)
			var f := (1.0 - exp(-l * _t)) / l
			for i in n:
				if bones[i] < 0:
					continue
				var ext := (InertialBlendModifier._from_vec(_src_w[i] * f) * _src[i]).normalized()
				sk.set_bone_pose_rotation(bones[i], ext.slerp(sk.get_bone_pose_rotation(bones[i]), a).normalized())
	for i in n:
		_out2[i] = _out1[i]
		_out1[i] = sk.get_bone_pose_rotation(bones[i]) if bones[i] >= 0 else Quaternion.IDENTITY
	_dt1 = maxf(delta, 1.0 / 240.0)
	_frames += 1
