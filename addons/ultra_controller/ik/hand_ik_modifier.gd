class_name HandIKModifier
extends SkeletonModifier3D
## Puts hands on things: held-prop grips, ledges, ladder rungs, a weapon's support grip.
## Gameplay sets a WORLD-space target transform per hand plus a weight; weights move on a
## spring so hands reach and release smoothly. The elbow keeps its animated bend plane,
## nudged outward/down by `pole_hint`.

enum Hand { LEFT, RIGHT }

class Goal:
	var target := Transform3D()
	var want_weight := 0.0
	var weight := 0.0
	var use_rotation := true
	var speed := 8.0             ## 1/s blend rate

var goals := [Goal.new(), Goal.new()]
var last_error := [0.0, 0.0]

var _arms := []


func _ready() -> void:
	_resolve()


func _skeleton_changed(_o: Skeleton3D, _n: Skeleton3D) -> void:
	_resolve()


func _resolve() -> void:
	var sk := get_skeleton()
	if sk == null:
		return
	_arms = []
	for side in ["Left", "Right"]:
		_arms.append([sk.find_bone(side + "UpperArm"), sk.find_bone(side + "LowerArm"), sk.find_bone(side + "Hand")])


## Reach `hand` to `world_xform` (the hand bone's desired world transform).
func set_goal(hand: int, world_xform: Transform3D, weight := 1.0, use_rotation := true, speed := 8.0) -> void:
	var g: Goal = goals[hand]
	g.target = world_xform
	g.want_weight = clampf(weight, 0.0, 1.0)
	g.use_rotation = use_rotation
	g.speed = speed


func release(hand: int, speed := 6.0) -> void:
	var g: Goal = goals[hand]
	g.want_weight = 0.0
	g.speed = speed


func hand_bone(hand: int) -> int:
	return _arms[hand][2] if _arms.size() > hand else -1


func _process_modification_with_delta(delta: float) -> void:
	var sk := get_skeleton()
	if sk == null or _arms.size() < 2:
		return
	var inv := sk.global_transform.affine_inverse()
	for i in 2:
		var g: Goal = goals[i]
		g.weight = move_toward(g.weight, g.want_weight, delta * g.speed)
		var w := smoothstep(0.0, 1.0, g.weight)
		if w <= 0.001:
			last_error[i] = 0.0
			continue
		var t_sk := inv * g.target
		var arm: Array = _arms[i]
		# Out of reach? Roll the clavicle toward the target first (shoulders come forward when
		# you push a pistol out), up to ~25°.
		var clav := sk.get_bone_parent(arm[0])
		if clav >= 0:
			var sh := sk.get_bone_global_pose(arm[0]).origin
			var reach := sh.distance_to(sk.get_bone_global_pose(arm[1]).origin) + sk.get_bone_global_pose(arm[1]).origin.distance_to(sk.get_bone_global_pose(arm[2]).origin)
			var short := sh.distance_to(t_sk.origin) - reach * 0.93
			if short > 0.0:
				var cg := sk.get_bone_global_pose(clav)
				var from := sh - cg.origin
				var to := t_sk.origin - cg.origin
				var r := UltraIK._rot_between(from, to)
				var ang := minf(r.get_rotation_quaternion().get_angle(), deg_to_rad(25.0)) * clampf(short / 0.025, 0.0, 1.0) * w
				var axis := from.cross(to)
				if axis.length() > 1e-5:
					cg.basis = Basis(axis.normalized(), ang) * cg.basis
					sk.set_bone_global_pose(clav, cg)
		var pole := Vector3(1.0 if i == 0 else -1.0, -0.6, -0.3)   # skeleton space: out & down
		var basis: Variant = t_sk.basis.orthonormalized() if g.use_rotation else null
		last_error[i] = UltraIK.two_bone(sk, arm[0], arm[1], arm[2], t_sk.origin, w, basis, pole)
