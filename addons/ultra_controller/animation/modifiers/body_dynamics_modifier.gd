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

## Distribution weights over [Spine, Chest, UpperChest, Neck, Head].
@export var aim_pitch_weights := PackedFloat32Array([0.18, 0.22, 0.25, 0.17, 0.18])
## Looking down is mostly neck and head; bending the chest would put it under the eye.
@export var aim_pitch_down_weights := PackedFloat32Array([0.05, 0.07, 0.1, 0.36, 0.42])
@export var aim_yaw_weights := PackedFloat32Array([0.15, 0.2, 0.25, 0.2, 0.2])
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
	var hips_g := sk.get_bone_global_pose(_hips)
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
		var yaw := -warp_yaw * warp_counter_weights[k] + aim_yaw * aim_yaw_weights[k]
		var pw := aim_pitch_weights[k] if aim_pitch >= 0.0 else aim_pitch_down_weights[k]
		var pitch := aim_pitch * pw - (hunch * (0.4 if k < 3 else 0.1))
		var roll := lean_roll * (0.25 if k < 3 else 0.0)
		var fwd_lean := lean_pitch * (0.2 if k < 2 else 0.0)
		var r := Basis(Vector3.UP, -yaw) * Basis(Vector3.RIGHT, -pitch + fwd_lean) * Basis(Vector3.BACK, roll)
		# Rotate about this bone's own origin.
		g.basis = r * g.basis
		sk.set_bone_global_pose(b, g)
