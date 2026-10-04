@tool
class_name InertialBlendModifier
extends SkeletonModifier3D
## Smooths animation state changes (inertialization): when the driver switches state it calls
## trigger(); the difference between the pose that was on screen and the new animation's pose
## is captured per bone and faded out over `duration` with an ease-out curve, on top of the
## state machine's own crossfade. First modifier in the stack, so it works on the clip pose.

@export_range(0.05, 1.0, 0.01) var duration := 0.26

var _prev_rot: Array[Quaternion] = []
var _prev_hips := Vector3.ZERO
var _off_rot: Array[Quaternion] = []
var _off_hips := Vector3.ZERO
var _t := 1.0
var _pending := false
var _hips := -1


func trigger() -> void:
	_pending = true


func _process_modification_with_delta(delta: float) -> void:
	var sk := get_skeleton()
	if sk == null:
		return
	var n := sk.get_bone_count()
	if _hips < 0:
		_hips = sk.find_bone("Hips")
	if _pending and _prev_rot.size() == n:
		_off_rot.resize(n)
		for b in n:
			_off_rot[b] = (_prev_rot[b] * sk.get_bone_pose_rotation(b).inverse()).normalized()
		_off_hips = _prev_hips - sk.get_bone_pose_position(_hips) if _hips >= 0 else Vector3.ZERO
		_t = 0.0
	_pending = false
	if _t < 1.0 and _off_rot.size() == n:
		_t = minf(_t + delta / duration, 1.0)
		var w := pow(1.0 - _t, 3.0)                 # ease out: most of it fades early
		for b in n:
			var q := Quaternion.IDENTITY.slerp(_off_rot[b], w)
			sk.set_bone_pose_rotation(b, (q * sk.get_bone_pose_rotation(b)).normalized())
		if _hips >= 0:
			sk.set_bone_pose_position(_hips, sk.get_bone_pose_position(_hips) + _off_hips * w)
	if _prev_rot.size() != n:
		_prev_rot.resize(n)
	for b in n:
		_prev_rot[b] = sk.get_bone_pose_rotation(b)
	if _hips >= 0:
		_prev_hips = sk.get_bone_pose_position(_hips)
