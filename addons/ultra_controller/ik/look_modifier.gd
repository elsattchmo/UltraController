class_name LookModifier
extends SkeletonModifier3D
## Turns the neck and head toward a world point (interest points, other players, the aim
## point in third person), within human limits, blended by weight. Applied after the aim
## offset, so in first person (where the aim already drives the head) its weight stays 0.

@export var max_yaw_deg := 70.0
@export var max_pitch_deg := 40.0
@export var neck_share := 0.4

## Gameplay look target (interest points, other players): wins when active.
var target := Vector3.ZERO
var want_weight := 0.0
## Aim glance (free third person: the head follows the camera). Set by the AnimDriver.
var glance_target := Vector3.ZERO
var glance_weight := 0.0
var weight := 0.0
var speed := 4.0
var _rel := NAN                     ## target yaw off the chest, unwrapped (continuous)
var _yaw := 0.0                     ## yaw / pitch the head is turned (smoothed)
var _pitch := 0.0

var _neck := -1
var _head := -1
var _chest := -1


func _ready() -> void:
	_resolve()


func _skeleton_changed(_o: Skeleton3D, _n: Skeleton3D) -> void:
	_resolve()


func _resolve() -> void:
	var sk := get_skeleton()
	if sk == null:
		return
	_neck = sk.find_bone("Neck")
	_head = sk.find_bone("Head")
	_chest = sk.find_bone("UpperChest")


func look_at_point(p: Vector3, w := 1.0) -> void:
	target = p
	want_weight = w


func _process_modification_with_delta(delta: float) -> void:
	var sk := get_skeleton()
	var use_poi := want_weight > 0.001
	var goal_w := want_weight if use_poi else glance_weight
	var goal_p := target if use_poi else glance_target
	weight = move_toward(weight, goal_w, delta * speed)
	if sk == null or _head < 0 or weight <= 0.001:
		return
	# (Turned toward as angles, not by easing a world point: a point eased across to a target
	# behind passed through the head itself.)
	var t_sk := sk.global_transform.affine_inverse() * goal_p
	var head := sk.get_bone_global_pose(_head)
	var to := t_sk - head.origin
	if to.length() < 0.2:
		return
	# Yaw / pitch relative to the chest's facing (skeleton space: +Z forward, +Y up).
	var chest_fwd := (sk.get_bone_global_pose(_chest).basis * sk.get_bone_global_rest(_chest).basis.inverse()) * Vector3.BACK if _chest >= 0 else Vector3.BACK
	chest_fwd.y = 0.0
	chest_fwd = chest_fwd.normalized()
	var flat := Vector3(to.x, 0, to.z).normalized()
	# The yaw kept continuous through the back (a target swung round behind stays over the
	# shoulder it went round - wrapped, the clamped yaw flipped from one side to the other).
	var raw := chest_fwd.signed_angle_to(flat, Vector3.UP)
	if is_nan(_rel):
		_rel = raw
	var u := _rel + angle_difference(wrapf(_rel, -PI, PI), raw)
	if absf(u) > deg_to_rad(200.0):
		u = raw
	_rel = u
	var k := 1.0 - exp(-12.0 * delta)
	_yaw = lerpf(_yaw, clampf(u, -deg_to_rad(max_yaw_deg), deg_to_rad(max_yaw_deg)), k)
	_pitch = lerpf(_pitch, clampf(atan2(to.y, Vector2(to.x, to.z).length()), -deg_to_rad(max_pitch_deg), deg_to_rad(max_pitch_deg)), k)
	var yaw := _yaw
	var pitch := _pitch
	var w := smoothstep(0.0, 1.0, weight)
	for pair in [[_neck, neck_share], [_head, 1.0 - neck_share]]:
		var b: int = pair[0]
		if b < 0:
			continue
		var g := sk.get_bone_global_pose(b)
		var right := Vector3.UP.cross(flat).normalized() if flat.length() > 0.01 else Vector3.RIGHT
		var r := Basis(Vector3.UP, yaw * float(pair[1]) * w) * Basis(right, -pitch * float(pair[1]) * w)
		g.basis = r * g.basis
		sk.set_bone_global_pose(b, g)
