@tool
class_name BodyDynamicsModifier
extends SkeletonModifier3D
## Procedural layer on top of the animation, in one ordered pass:
##   * orientation warping  – hips/legs turn toward the movement direction, spine counter-turns
##   * aim offset           – aim yaw/pitch spread over spine, neck and head
##   * lean                 – roll/pitch from acceleration (weight shifting into turns and stops)
##   * pelvis offset        – landing compression and IK pelvis drop
##   * injury posture       – extra hunch / list (fed by the injury system later)
## Works in skeleton space, so it doesn't care about each bone's local axes. Skeleton space is
## the model's: +Y up, +Z forward, -X = character right.

## Inputs (radians / metres), set every frame by the AnimDriver.
var warp_yaw: float = 0.0        ## + = legs turn to the character's right
var aim_yaw: float = 0.0         ## + = look right of the hips
var aim_pitch: float = 0.0       ## + = look up
var lean_roll: float = 0.0       ## + = lean right
var lean_pitch: float = 0.0      ## + = lean forward
var pelvis_offset := Vector3.ZERO
var hunch: float = 0.0           ## + = bend forward (injury / carry)
## 0..1: a weapon is up. Aim pitch then lives in the spine so the arms track the crosshair.
var weapon_aim: float = 0.0
## The item clip's own hips yaw (skeleton space, atan2(z.x, z.z)); the upper body is turned by
## the difference to the locomotion hips, so an upper-body clip keeps the stance it was made in
## (and a mirrored clip isn't twisted by the unmirrored legs). NAN = off.
var item_hips_yaw: float = NAN

## Distribution weights over [Spine, Chest, UpperChest, Neck, Head].
@export var aim_pitch_weights := PackedFloat32Array([0.18, 0.22, 0.25, 0.17, 0.18])
## Looking down is mostly neck and head; bending the chest would put it under the eye.
@export var aim_pitch_down_weights := PackedFloat32Array([0.05, 0.07, 0.1, 0.36, 0.42])
@export var aim_yaw_weights := PackedFloat32Array([0.15, 0.2, 0.25, 0.2, 0.2])
@export var weapon_pitch_weights := PackedFloat32Array([0.24, 0.3, 0.34, 0.06, 0.06])
@export var weapon_yaw_weights := PackedFloat32Array([0.25, 0.3, 0.35, 0.05, 0.05])
@export var warp_counter_weights := PackedFloat32Array([0.3, 0.35, 0.35, 0.0, 0.0])

var _hips := -1
var _chain: PackedInt32Array = []


func _ready() -> void:
	_resolve()


func _skeleton_changed(_old: Skeleton3D, _new: Skeleton3D) -> void:
	_resolve()


func _resolve() -> void:
	var sk := get_skeleton()
	if sk == null:
		return
	_hips = sk.find_bone("Hips")
	_chain = PackedInt32Array()
	for n in ["Spine", "Chest", "UpperChest", "Neck", "Head"]:
		_chain.append(sk.find_bone(n))


func _process_modification_with_delta(_delta: float) -> void:
	var sk := get_skeleton()
	if sk == null or _hips < 0:
		_resolve()
		if _hips < 0:
			return
	# Hips: warp yaw, lean, offset. Rotations are applied in skeleton space about the hips.
	_measure_head(sk, _delta)
	var hips_g := sk.get_bone_global_pose(_hips)
	var hips_anim_yaw := atan2(hips_g.basis.z.x, hips_g.basis.z.z)
	# Sideways sway: keep the slow part, cut most of the step-to-step wobble.
	if is_nan(_hip_x_lp):
		_hip_x_lp = hips_g.origin.x
	_hip_x_lp = lerpf(_hip_x_lp, hips_g.origin.x, 1.0 - exp(-2.0 * maxf(_delta, 0.0)))
	hips_g.origin.x -= (hips_g.origin.x - _hip_x_lp) * hip_sway_damp * sway_weight
	var r_hips := Basis(Vector3.UP, -warp_yaw) * Basis(Vector3.BACK, lean_roll * 0.35) * Basis(Vector3.RIGHT, lean_pitch * 0.25)
	hips_g.basis = r_hips * hips_g.basis
	hips_g.origin += pelvis_offset
	sk.set_bone_global_pose(_hips, hips_g)
	# Spine chain: counter the warp, spread aim, lean and hunch.
	for k in _chain.size():
		var b := _chain[k]
		if b < 0:
			continue
		var g := sk.get_bone_global_pose(b)
		# Counter-rotate the warp (children inherit the hips turn) so the chest keeps facing aim.
		var yw := lerpf(aim_yaw_weights[k], weapon_yaw_weights[k], weapon_aim)
		var yaw := -warp_yaw * warp_counter_weights[k] + aim_yaw * yw
		var pw := aim_pitch_weights[k] if aim_pitch >= 0.0 else aim_pitch_down_weights[k]
		pw = lerpf(pw, weapon_pitch_weights[k], weapon_aim)
		var pitch := aim_pitch * pw - (hunch * (0.4 if k < 3 else 0.1))
		var roll := lean_roll * (0.25 if k < 3 else 0.0)
		var fwd_lean := lean_pitch * (0.2 if k < 2 else 0.0)
		var r := Basis(Vector3.UP, -yaw) * Basis(Vector3.RIGHT, -pitch + fwd_lean) * Basis(Vector3.BACK, roll)
		if k == 0 and not is_nan(item_hips_yaw) and weapon_aim > 0.0:
			r = Basis(Vector3.UP, angle_difference(hips_anim_yaw, item_hips_yaw) * weapon_aim) * r
		# Rotate about this bone's own origin.
		g.basis = r * g.basis
		sk.set_bone_global_pose(b, g)
	_stabilize_head(sk)
	_calm_head(sk, _delta)


## People keep their head steady while the shoulders swing (the sprint clip turns the head
## ~45 deg side to side). Remove most of the fast yaw / roll swing of the head, keeping slow,
## deliberate turns (aiming, looking around).
@export_range(0, 1, 0.01) var head_stabilize := 0.95
## Sideways hip sway removed at speed (the walk cycle played briskly wobbles the body).
@export_range(0, 1, 0.01) var hip_sway_damp := 0.6
## 0..1 how much of hip_sway_damp applies (the driver raises it with speed; 0 standing).
var sway_weight := 0.0
var _hip_x_lp := NAN
var _head_ref := Vector3.ZERO
var _head_dev := 0.0
## 0..1 how much of the stabiliser applies (0 while the body is down / getting up).
var stabilize_w := 1.0
var _head_yaw_lp := NAN


## Measure the clip's own head yaw (before aim / warp / lean are added) and track its slow part.
func _measure_head(sk: Skeleton3D, delta: float) -> void:
	var head := _chain[4] if _chain.size() > 4 else -1
	if head < 0:
		return
	if _head_ref == Vector3.ZERO:
		_head_ref = sk.get_bone_global_rest(head).basis.orthonormalized().inverse() * Vector3(0, 0, 1)
	var f := sk.get_bone_global_pose(head).basis.orthonormalized() * _head_ref
	var yaw := atan2(f.x, f.z)
	if is_nan(_head_yaw_lp):
		_head_yaw_lp = yaw
	_head_yaw_lp = lerp_angle(_head_yaw_lp, yaw, 1.0 - exp(-1.5 * maxf(delta, 0.0)))
	_head_dev = angle_difference(_head_yaw_lp, yaw)


## Take most of that swing back out (split over neck and head so the neck doesn't kink).
func _stabilize_head(sk: Skeleton3D) -> void:
	if head_stabilize == 0.0 or _chain.size() < 5 or stabilize_w <= 0.0:
		return
	# (Skeleton space is the model's mirrored frame: undo the swing by turning the same way.)
	var dy := _head_dev * head_stabilize * stabilize_w
	for pair: Array in [[_chain[3], 0.4], [_chain[4], 0.6]]:
		var b: int = pair[0]
		if b < 0:
			continue
		var gb := sk.get_bone_global_pose(b)
		gb.basis = Basis(Vector3.UP, dy * pair[1]) * gb.basis
		sk.set_bone_global_pose(b, gb)


## 0..1: low-pass the neck and head against the chest. Get-up clips (mocap) whip the head
## around, worse when played faster to fit the get-up time; this keeps where it looks and
## drops the wobble.
var head_calm := 0.0
var _calm_q: Array[Quaternion] = [Quaternion(), Quaternion()]
var _calm_live := false


func _calm_head(sk: Skeleton3D, delta: float) -> void:
	if head_calm <= 0.0 or _chain.size() < 5 or _chain[3] < 0 or _chain[4] < 0:
		_calm_live = false
		return
	var chest := _chain[2] if _chain[2] >= 0 else _chain[1]
	var base := sk.get_bone_global_pose(chest).basis.get_rotation_quaternion()
	var rels: Array[Quaternion] = []
	for j in 2:
		rels.append(base.inverse() * sk.get_bone_global_pose(_chain[3 + j]).basis.get_rotation_quaternion())
	var k := 1.0 - exp(-5.0 * maxf(delta, 0.0))
	for j in 2:
		_calm_q[j] = rels[j] if not _calm_live else _calm_q[j].slerp(rels[j], k)
		var g := sk.get_bone_global_pose(_chain[3 + j])          # (head: after the neck moved)
		var want := base * _calm_q[j].slerp(rels[j], 1.0 - head_calm)
		g.basis = Basis(want) * Basis.from_scale(g.basis.get_scale())
		sk.set_bone_global_pose(_chain[3 + j], g)
	_calm_live = true
