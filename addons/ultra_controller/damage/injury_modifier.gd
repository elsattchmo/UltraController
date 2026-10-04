@tool
class_name InjuryModifier
extends SkeletonModifier3D
## Procedural injuries on top of the animated (and IK'd) pose:
##   * dangle - a crippled arm hangs from the shoulder as a damped pendulum that swings with the
##              body's motion (the elbow a little bent), instead of following the animation
##   * flinch - every hit kicks the bone that was hit (and what hangs off it) along the shot,
##              on a spring, so a shot leg jerks back and a shot shoulder twists
## Skeleton space = model space: +Y up, +Z forward.

## 0..1 per arm (set by the AnimDriver from the limb status).
var dangle_l := 0.0
var dangle_r := 0.0
## Character acceleration in skeleton space (drives the swing).
var accel := Vector3.ZERO

var _arm := {}                     ## side -> [upper, lower, hand]
var _swing := {}                   ## side -> [dir: Vector3, vel: Vector3]
var _flinch: Array[Dictionary] = []  ## {bone, axis, angle, vel}


func _ready() -> void:
	_resolve()


func _skeleton_changed(_o: Skeleton3D, _n: Skeleton3D) -> void:
	_resolve()


func _resolve() -> void:
	var sk := get_skeleton()
	if sk == null:
		return
	for side in ["Left", "Right"]:
		_arm[side] = [sk.find_bone(side + "UpperArm"), sk.find_bone(side + "LowerArm"), sk.find_bone(side + "Hand")]
		_swing[side] = [Vector3.DOWN, Vector3.ZERO]


## Kick `bone_name` around `axis_world` (an impulse in rad/s).
func flinch(bone_name: String, dir_skel: Vector3, strength: float) -> void:
	var sk := get_skeleton()
	if sk == null:
		return
	var b := sk.find_bone(bone_name)
	if b < 0:
		return
	var axis := Vector3.UP.cross(dir_skel)
	if axis.length() < 0.01:
		axis = Vector3.RIGHT
	_flinch.append({"bone": b, "axis": axis.normalized(), "angle": 0.0, "vel": strength})
	if _flinch.size() > 8:
		_flinch.pop_front()


func _process_modification_with_delta(delta: float) -> void:
	var sk := get_skeleton()
	if sk == null or _arm.is_empty():
		_resolve()
		return
	delta = minf(delta, 0.05)
	_dangle(sk, "Left", dangle_l, delta)
	_dangle(sk, "Right", dangle_r, delta)
	# Flinch springs (k = 160, lightly damped): kick out, settle back in ~0.3 s.
	for i in range(_flinch.size() - 1, -1, -1):
		var f := _flinch[i]
		f.vel = float(f.vel) + (-160.0 * float(f.angle) - 2.0 * 0.45 * sqrt(160.0) * float(f.vel)) * delta
		f.angle = float(f.angle) + float(f.vel) * delta
		if absf(f.angle) < 0.002 and absf(f.vel) < 0.02:
			_flinch.remove_at(i)
			continue
		var g := sk.get_bone_global_pose(f.bone)
		g.basis = Basis(f.axis, clampf(f.angle, -0.6, 0.6)) * g.basis
		sk.set_bone_global_pose(f.bone, g)


func _dangle(sk: Skeleton3D, side: String, w: float, delta: float) -> void:
	var bones: Array = _arm[side]
	var sw: Array = _swing[side]
	if w <= 0.001 or bones[0] < 0:
		sw[0] = Vector3.DOWN
		sw[1] = Vector3.ZERO
		return
	# Pendulum on a unit direction: gravity pulls it down, the body's acceleration throws it.
	var d: Vector3 = sw[0]
	var v: Vector3 = sw[1]
	var pull := Vector3.DOWN * 9.8 - accel * 0.6
	var tangential := pull - d * pull.dot(d)
	v += tangential * 1.6 * delta
	v *= exp(-3.0 * delta)
	d = (d + v * delta).normalized()
	v -= d * v.dot(d)
	sw[0] = d
	sw[1] = v
	var out := Vector3(1 if side == "Left" else -1, 0, 0)
	var hang := (d + out * 0.08).normalized()
	var up_g := sk.get_bone_global_pose(bones[0])
	var cur_dir := up_g.basis.y.normalized()
	var target := Basis(Quaternion(cur_dir, hang)) * up_g.basis
	up_g.basis = up_g.basis.slerp(target.orthonormalized(), w)
	sk.set_bone_global_pose(bones[0], up_g)
	# Elbow: hang on, a little bent forward.
	var lo_g := sk.get_bone_global_pose(bones[1])
	var lo_dir := lo_g.basis.y.normalized()
	var lo_target := Basis(Quaternion(lo_dir, (hang + Vector3(0, 0, 0.25)).normalized())) * lo_g.basis
	lo_g.basis = lo_g.basis.slerp(lo_target.orthonormalized(), w)
	sk.set_bone_global_pose(bones[1], lo_g)
