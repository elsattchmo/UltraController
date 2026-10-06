class_name FootIKModifier
extends SkeletonModifier3D
## Grounds the feet on whatever is really under them.
##  * probes the ground under each animated foot (rays from knee height)
##  * drops the pelvis so the lower foot can reach down (stairs, slopes, rocks)
##  * two-bone IK per leg, knee kept in its animated plane
##  * tilts planted feet to the surface (limited)
##  * foot locking: a planted foot stays put in the world until it lifts (kills residual skate)
## Weighted by `weight` (set per motor state by the AnimDriver). Purely presentational: the
## motor never reads it, so it can't affect netcode.

@export var max_pelvis_drop := 0.45
@export var max_foot_raise := 0.45
@export var max_slope_tilt_deg := 30.0
@export var lock_feet := true
@export var lock_release_distance := 0.22
@export var probe_mask := UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC

var weight := 1.0
var lock_weight := 1.0
var exclude: Array[RID] = []
## Debug output (read by tests / F3 overlay).
var last_targets: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var last_ground: Array[float] = [0.0, 0.0]
var pelvis_drop := 0.0

var _legs := []          # [[UpperLeg, LowerLeg, Foot], ...]
var _hips := -1
var _rest_foot_y := [0.0, 0.0]
var _pelvis_vel := 0.0
var _contact := [0.0, 0.0]
var _locked := [false, false]
var _lock_pos := [Vector3.ZERO, Vector3.ZERO]
var _lock_blend := [0.0, 0.0]
var _ray := PhysicsRayQueryParameters3D.new()


func _ready() -> void:
	_resolve()


func _skeleton_changed(_o: Skeleton3D, _n: Skeleton3D) -> void:
	_resolve()


func _resolve() -> void:
	var sk := get_skeleton()
	if sk == null:
		return
	_hips = sk.find_bone("Hips")
	_legs = []
	for side in ["Left", "Right"]:
		_legs.append([sk.find_bone(side + "UpperLeg"), sk.find_bone(side + "LowerLeg"), sk.find_bone(side + "Foot")])
	for i in 2:
		var f: int = _legs[i][2]
		_rest_foot_y[i] = sk.get_bone_global_rest(f).origin.y if f >= 0 else 0.0


func reset_locks() -> void:
	_locked = [false, false]
	_lock_blend = [0.0, 0.0]


func _process_modification_with_delta(delta: float) -> void:
	var sk := get_skeleton()
	if sk == null or _hips < 0 or _legs.size() < 2:
		return
	var w := clampf(weight, 0.0, 1.0)
	var xf := sk.global_transform
	var inv := xf.affine_inverse()
	var space := sk.get_world_3d().direct_space_state
	var feet_sk: Array[Vector3] = []
	var ground_h: Array[float] = []
	var ground_n: Array[Vector3] = []
	# 1) where is the ground under each animated foot? (skeleton space == character space,
	#    origin at the capsule's feet, +Y up)
	for i in 2:
		var foot_sk := sk.get_bone_global_pose(_legs[i][2]).origin
		feet_sk.append(foot_sk)
		var foot_w := xf * foot_sk
		var base_w := xf * Vector3(foot_sk.x, 0.0, foot_sk.z)
		_ray.from = base_w + Vector3.UP * max_foot_raise * 1.4
		_ray.to = base_w + Vector3.DOWN * (max_pelvis_drop + 0.25)
		_ray.collision_mask = probe_mask
		_ray.exclude = exclude
		var hit := space.intersect_ray(_ray)
		if hit.is_empty():
			# Nothing under the foot within reach (over a drop / a ledge's lip): leave it as
			# animated. (Counting it as ground at -max_pelvis_drop sank the hips 45 cm walking
			# up to every edge, then they popped back up as the climb-down started.)
			ground_h.append(0.0)
			ground_n.append(Vector3.UP)
		else:
			var hp: Vector3 = inv * (hit.position as Vector3)
			ground_h.append(clampf(hp.y, -max_pelvis_drop - 0.2, max_foot_raise))
			ground_n.append((inv.basis * (hit.normal as Vector3)).normalized())
		# contact: the animation has this foot down (near its rest height)
		var lift := foot_sk.y - float(_rest_foot_y[i])
		var c := 1.0 - smoothstep(0.03, 0.09, lift)
		_contact[i] = lerpf(float(_contact[i]), c, 1.0 - exp(-25.0 * delta))
		last_ground[i] = ground_h[i]
		var _unused := foot_w
	# 2) pelvis drop toward the lower supporting foot (spring, so it breathes on stairs)
	var want := minf(minf(ground_h[0], ground_h[1]), 0.0)
	want = maxf(want, -max_pelvis_drop) * w
	var k := 160.0
	_pelvis_vel += ((want - pelvis_drop) * k - _pelvis_vel * 2.0 * sqrt(k) * 0.9) * delta
	pelvis_drop += _pelvis_vel * delta
	pelvis_drop = clampf(pelvis_drop, -max_pelvis_drop, 0.05)
	if w <= 0.001 and absf(pelvis_drop) < 0.001:
		reset_locks()
		return
	var hips := sk.get_bone_global_pose(_hips)
	hips.origin.y += pelvis_drop
	sk.set_bone_global_pose(_hips, hips)
	# 3) legs
	for i in 2:
		var leg: Array = _legs[i]
		var target: Vector3 = feet_sk[i] + Vector3.UP * ground_h[i]
		# foot locking (world space), only while planted
		var lw := lock_weight * w if lock_feet else 0.0
		if lw > 0.0 and float(_contact[i]) > 0.85:
			var here := xf * target
			if not _locked[i]:
				_locked[i] = true
				_lock_pos[i] = here
			var locked_sk: Vector3 = inv * (_lock_pos[i] as Vector3)
			if Vector2(locked_sk.x - target.x, locked_sk.z - target.z).length() > lock_release_distance:
				_lock_pos[i] = here            # stretched too far: re-plant here
				locked_sk = target
			_lock_blend[i] = minf(float(_lock_blend[i]) + delta / 0.06, 1.0)
			target = target.lerp(Vector3(locked_sk.x, target.y, locked_sk.z), float(_lock_blend[i]) * lw)
		else:
			if _locked[i]:
				_locked[i] = false
			_lock_blend[i] = maxf(float(_lock_blend[i]) - delta / 0.12, 0.0)
			if float(_lock_blend[i]) > 0.0:
				var locked_sk2: Vector3 = inv * (_lock_pos[i] as Vector3)
				target = target.lerp(Vector3(locked_sk2.x, target.y, locked_sk2.z), float(_lock_blend[i]) * lw)
		# tilt the planted foot to the surface
		var n: Vector3 = ground_n[i]
		var ang := minf(Vector3.UP.angle_to(n), deg_to_rad(max_slope_tilt_deg))
		var axis := Vector3.UP.cross(n)
		var foot_g := sk.get_bone_global_pose(leg[2])
		var foot_basis := foot_g.basis
		if axis.length() > 0.0001 and ang > 0.001:
			foot_basis = Basis(axis.normalized(), ang * float(_contact[i])) * foot_g.basis
		last_targets[i] = target
		UltraIK.two_bone(sk, leg[0], leg[1], leg[2], target, w, foot_basis)
