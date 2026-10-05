class_name UltraArmClear
extends SkeletonModifier3D
## Keeps the arms out of the torso. Clips made on a slimmer rig (the Mixamo rifle reload brings
## the right forearm across the chest) pass the arm through this mannequin's bulkier body. The
## torso is an ellipse round the hips->neck line (in the chest's own frame, plus the limb's
## thickness); an elbow inside it turns the upper arm out about the shoulder, a forearm or hand
## inside turns the forearm out about the elbow - just far enough. Runs after the body
## dynamics / foot IK and before the weapon pose / hand IK (whose targets win).

## Torso half-extents (metres) at the chest and at the waist (measured off the mannequin's
## mesh), plus the limb's thickness; in between by height.
const TORSO_HALF_WIDTH := 0.215
const TORSO_HALF_DEPTH := 0.185
const WAIST_HALF_WIDTH := 0.165
const WAIST_HALF_DEPTH := 0.15
## At most this much turn per joint and pass (degrees).
@export var max_turn_deg := 25.0
var amount := 1.0

var _b := {}


func _ready() -> void:
	_resolve()


func _skeleton_changed(_o: Skeleton3D, _n: Skeleton3D) -> void:
	_resolve()


func _resolve() -> void:
	var sk := get_skeleton()
	if sk == null:
		return
	_b = {}
	for n in ["Hips", "Neck", "LeftUpperArm", "RightUpperArm", "LeftLowerArm", "RightLowerArm", "LeftHand", "RightHand"]:
		_b[n] = sk.find_bone(n)


func _process_modification_with_delta(_delta: float) -> void:
	var sk := get_skeleton()
	if sk == null or amount <= 0.001:
		return
	if _b.is_empty() or (_b.values() as Array).has(-1):
		_resolve()
		if _b.is_empty() or (_b.values() as Array).has(-1):
			return
	var sc := maxf(sk.global_basis.get_scale().x, 0.001)
	for side in ["Left", "Right"]:
		# Elbow (and the middle of the upper arm, which crosses the chest when the elbow is
		# pulled across): turn the upper arm about the shoulder.
		# (A few passes: each turn changes where the point is on the curved torso.)
		for _i in 3:
			_clear(sk, sc, _b[side + "UpperArm"], [_b[side + "LowerArm"]], 0.55)
		# Forearm and hand: turn the forearm about the elbow.
		for _i in 2:
			_clear(sk, sc, _b[side + "LowerArm"], [_b[side + "Hand"]], 0.5)


## Turn `bone` about its joint so its child points (and, with `mid` > 0, the point that far along
## to the first one) come out of the torso.
func _clear(sk: Skeleton3D, sc: float, bone: int, children: Array, mid: float) -> void:
	var o := sk.get_bone_global_pose(bone).origin
	var pts: Array[Vector3] = []
	for c: int in children:
		var p := sk.get_bone_global_pose(c).origin
		pts.append(p)
		if mid > 0.0:
			pts.append(o.lerp(p, mid))
	var worst := 1.0
	var at := Vector3.ZERO
	var out := Vector3.ZERO
	var frame := _torso_frame(sk)
	for p in pts:
		var r := _inside(frame, p, sc)
		if r[0] < worst:
			worst = r[0]
			at = p
			out = r[1]
	if worst >= 1.0:
		return
	var a := at - o
	var b := out - o
	var axis := a.cross(b)
	if a.length() < 1e-4 or axis.length() < 1e-7:
		return
	var ang := minf(a.angle_to(b), deg_to_rad(max_turn_deg)) * amount
	var g := sk.get_bone_global_pose(bone)
	g.basis = Basis(axis.normalized(), ang) * g.basis
	sk.set_bone_global_pose(bone, g)


## [hips, axis (unit), length, right, fwd] in skeleton space.
func _torso_frame(sk: Skeleton3D) -> Array:
	var hips := sk.get_bone_global_pose(_b["Hips"]).origin
	var neck := sk.get_bone_global_pose(_b["Neck"]).origin
	var axis := (neck - hips).normalized()
	var right := sk.get_bone_global_pose(_b["RightUpperArm"]).origin - sk.get_bone_global_pose(_b["LeftUpperArm"]).origin
	right = (right - axis * right.dot(axis)).normalized()
	return [hips, axis, (neck - hips).length(), right, axis.cross(right).normalized()]


## [normalised ellipse distance (< 1 = inside), the nearest point on the surface].
func _inside(f: Array, p: Vector3, sc: float) -> Array:
	var hips: Vector3 = f[0]
	var axis: Vector3 = f[1]
	var t := clampf((p - hips).dot(axis), 0.15 / sc, float(f[2]))
	var c := hips + axis * t
	var d := p - c
	var k := clampf(t / maxf(float(f[2]), 0.001), 0.0, 1.0)
	var hw := lerpf(WAIST_HALF_WIDTH, TORSO_HALF_WIDTH, smoothstep(0.3, 0.8, k))
	var hd := lerpf(WAIST_HALF_DEPTH, TORSO_HALF_DEPTH, smoothstep(0.3, 0.8, k))
	var x := d.dot(f[3]) * sc / hw
	var y := d.dot(f[4]) * sc / hd
	var q := sqrt(x * x + y * y)
	if q >= 1.0:
		return [q, p]
	if q < 1e-3:
		x = 1.0
		y = 0.0
		q = 1.0
	var surf := c + ((f[3] as Vector3) * (x / q) * hw + (f[4] as Vector3) * (y / q) * hd) / sc
	return [q, surf + (p - c - (f[3] as Vector3) * d.dot(f[3]) - (f[4] as Vector3) * d.dot(f[4]))]
