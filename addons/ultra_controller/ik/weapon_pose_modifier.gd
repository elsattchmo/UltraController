class_name WeaponPoseModifier
extends SkeletonModifier3D
## A gun with a stock, held shouldered.
##   First person: the gun is placed from the camera (sights on the view ray), so the body comes
##   to it - the spine turns and the shoulder shrugs until the shoulder pocket sits at the
##   stock, and the neck brings the head's eye back to the camera (cheek on the stock, as others
##   see it). The camera takes the eye from before this pass (`pre_head`), so the body chasing
##   the gun never feeds back into where the gun is.
##   Third person (`from_body`): the gun goes to the body instead - stock in the shoulder
##   pocket, barrel along `gun_dir`; aiming down sights the cheek comes down to the stock.
## Runs after BodyDynamics / FootIK and before HandIK, which puts both hands on the gun.

var weight := 0.0                   ## 0..1, set every frame by UltraEquipmentVisual
var gun := Transform3D()            ## world transform of the gun
var stock := Vector3.ZERO           ## butt point in the gun's frame
var side := 1                       ## 1 = right shoulder, -1 = left
var eye_target := Vector3.INF       ## world: where the head's eye should end up (the camera)
var eye_offset_sk := Vector3.ZERO   ## eye from the Head bone, head at rest, skeleton space
## Third person: the gun follows the body (stock in the pocket, along gun_dir) and this pass
## puts the hands on it (HandIK goals: `grip_inv` = hand from gun, `support` = left hand in the
## gun's frame). `eye_in_gun`: where the eye goes when aiming down sights (gun frame), `ads` 0..1.
var from_body := false
var gun_dir := Vector3.FORWARD
var ads := 0.0
var eye_in_gun := Vector3.ZERO
var grip_inv := Transform3D()
var support := Transform3D()
var hand_ik: HandIKModifier
## Third person: an extra offset of the gun in its own frame (a gun-butt strike).
var extra := Transform3D.IDENTITY
var _hands_set := false
var _rhand := -1
## Shoulder pocket from the UpperArm joint (metres; x toward the centre, y up, z forward).
@export var pocket := Vector3(0.06, -0.03, 0.06)
@export var max_spine_deg := 32.0
@export var max_shrug_deg := 16.0
@export var max_neck_deg := 40.0
## Stance: the chest faces this far off the gun, toward the gun side (shooter's right).
@export var blade_deg := 35.0
## How far the chest is turned to get there at most (the clip's stance does the rest).
@export var max_blade_turn_deg := 60.0

var pre_head := Transform3D()       ## Head bone pose (skeleton space) before this pass
var pre_neck := Vector3.ZERO        ## Neck bone origin (skeleton space) before this pass
var shouldered := false             ## this frame's pass moved the body
var last_gap := 0.0                 ## metres from the shoulder pocket to the stock afterwards
var last_blade := 0.0               ## degrees the chest faces off the gun (toward the gun side)

var _spine := -1
var _chest := -1
var _upper := -1
var _neck := -1
var _head := -1
var _ua := PackedInt32Array([-1, -1])     ## [right, left] UpperArm
var _clav := PackedInt32Array([-1, -1])
var _head_rest_inv := Basis()


func _ready() -> void:
	_resolve()


func _skeleton_changed(_o: Skeleton3D, _n: Skeleton3D) -> void:
	_resolve()


func _resolve() -> void:
	var sk := get_skeleton()
	if sk == null:
		return
	_spine = sk.find_bone("Spine")
	_chest = sk.find_bone("Chest")
	_upper = sk.find_bone("UpperChest")
	_neck = sk.find_bone("Neck")
	_head = sk.find_bone("Head")
	_ua = PackedInt32Array([sk.find_bone("RightUpperArm"), sk.find_bone("LeftUpperArm")])
	_clav = PackedInt32Array([sk.get_bone_parent(_ua[0]) if _ua[0] >= 0 else -1, sk.get_bone_parent(_ua[1]) if _ua[1] >= 0 else -1])
	if _head >= 0:
		_head_rest_inv = sk.get_bone_global_rest(_head).basis.orthonormalized().inverse()


func _process_modification_with_delta(_delta: float) -> void:
	var sk := get_skeleton()
	if sk == null:
		return
	if _head < 0 or _neck < 0 or _spine < 0 or _chest < 0 or _ua.has(-1):
		_resolve()
		if _head < 0 or _neck < 0 or _spine < 0 or _chest < 0 or _ua.has(-1):
			return
	pre_head = sk.get_bone_global_pose(_head)
	pre_neck = sk.get_bone_global_pose(_neck).origin
	shouldered = weight > 0.001
	if not (shouldered and from_body) and _hands_set and hand_ik:
		# By now the gun is back where the clip holds it (weight ~0): let the right hand go at
		# once; the support hand stays with UltraEquipmentVisual (on the handguard while ready).
		hand_ik.release(HandIKModifier.Hand.RIGHT, 30.0)
		_hands_set = false
	if not shouldered:
		last_gap = 0.0
		return
	var w := smoothstep(0.0, 1.0, weight)
	var inv := sk.global_transform.affine_inverse()
	var sc := maxf(sk.global_basis.get_scale().x, 0.001)
	var gdir := gun_dir if from_body else -gun.basis.z
	_blade(sk, (inv.basis * gdir).normalized(), w)
	if from_body:
		_gun_to_body(sk, sc, w)
		return
	var s := inv * (gun * stock)
	# Spine: two passes over Spine and Chest, each turning about its own joint.
	var per := deg_to_rad(max_spine_deg) / 4.0
	for _pass in 2:
		_turn_toward(sk, _spine, _pocket(sk, sc), s, per, 0.5 * w)
		_turn_toward(sk, _chest, _pocket(sk, sc), s, per, w)
	# Shoulder: shrug / roll forward the rest of the way.
	var i := 0 if side == 1 else 1
	if _clav[i] >= 0:
		_turn_toward(sk, _clav[i], _pocket(sk, sc), s, deg_to_rad(max_shrug_deg), w)
	last_gap = (_pocket(sk, sc) - s).length() * sc
	# Head: the eye back to the camera (the cheek comes down onto the stock).
	if eye_target != Vector3.INF:
		var e_t := inv * eye_target
		var h := sk.get_bone_global_pose(_head)
		var eye := h.origin + (h.basis.orthonormalized() * _head_rest_inv) * eye_offset_sk
		_turn_toward(sk, _neck, eye, e_t, deg_to_rad(max_neck_deg), w)


## Turn the upper body so the chest faces blade_deg off the gun (the bladed clips, the aim
## offset and the legs' warp can leave it square or side-on); the head keeps its heading.
func _blade(sk: Skeleton3D, d: Vector3, w: float) -> void:
	var across := sk.get_bone_global_pose(_ua[0]).origin - sk.get_bone_global_pose(_ua[1]).origin   # left -> right
	var fwd := Vector3.UP.cross(across)
	if fwd.length() < 1e-4 or Vector2(d.x, d.z).length() < 0.05:
		last_blade = 0.0
		return
	var cur := atan2(fwd.x, fwd.z)
	var want := atan2(d.x, d.z) - deg_to_rad(blade_deg) * float(side)
	var diff := clampf(angle_difference(cur, want), -deg_to_rad(max_blade_turn_deg), deg_to_rad(max_blade_turn_deg)) * w
	for pair: Array in [[_spine, 0.4], [_chest, 0.3], [_upper, 0.3], [_neck, -1.0]]:
		var b: int = pair[0]
		if b < 0:
			continue
		var g := sk.get_bone_global_pose(b)
		g.basis = Basis(Vector3.UP, diff * float(pair[1])) * g.basis
		sk.set_bone_global_pose(b, g)
	last_blade = rad_to_deg(angle_difference(atan2(d.x, d.z), cur + diff)) * float(side)


## Third person: stock in the shoulder pocket, barrel along gun_dir (level, uncanted), hands on
## it; aiming, the neck brings the eye down behind the sights.
func _gun_to_body(sk: Skeleton3D, sc: float, w: float) -> void:
	var xf := sk.global_transform
	var d := gun_dir.normalized()
	var up := Vector3.UP - d * d.dot(Vector3.UP)
	up = up.normalized() if up.length() > 0.05 else Vector3.BACK
	var b := Basis.looking_at(d, up)
	var p := xf * _pocket(sk, sc)
	# Blend the gun itself from where the clip's hand holds it to the shouldered pose, and keep
	# both hands fully on that: raising / lowering (sprint, reload) never switches hand targets.
	if _rhand < 0:
		_rhand = sk.find_bone("RightHand" if side == 1 else "LeftHand")
	var clip_gun := (xf * sk.get_bone_global_pose(_rhand)) * grip_inv.affine_inverse()
	gun = clip_gun.orthonormalized().interpolate_with(Transform3D(b, p - b * stock), w) * extra
	last_gap = 0.0
	if ads > 0.0:
		var inv := xf.affine_inverse()
		var h := sk.get_bone_global_pose(_head)
		var eye := h.origin + (h.basis.orthonormalized() * _head_rest_inv) * eye_offset_sk
		_turn_toward(sk, _neck, eye, inv * (gun * eye_in_gun), deg_to_rad(max_neck_deg), w * smoothstep(0.0, 1.0, ads))
	if hand_ik and side == 1:
		hand_ik.set_goal(HandIKModifier.Hand.RIGHT, gun * grip_inv, 1.0, true, 30.0)
		hand_ik.set_goal(HandIKModifier.Hand.LEFT, gun * support, 1.0, true, 30.0)
		hand_ik.set_curl(HandIKModifier.Hand.LEFT, 1.0)
		_hands_set = true


## The shoulder pocket (skeleton space): just in from the shoulder joint, on the front of the chest.
func _pocket(sk: Skeleton3D, sc: float) -> Vector3:
	var i := 0 if side == 1 else 1
	var ua := sk.get_bone_global_pose(_ua[i]).origin
	var across := sk.get_bone_global_pose(_ua[1 - i]).origin - ua
	if across.length() < 1e-4:
		return ua
	across = across.normalized()
	var top := _upper if _upper >= 0 else _chest
	var up := sk.get_bone_global_pose(_neck).origin - sk.get_bone_global_pose(top).origin
	up = (up - across * up.dot(across)).normalized()
	var fwd := across.cross(up) * float(side)          # model +Z forward
	return ua + (across * pocket.x + up * pocket.y + fwd * pocket.z) / sc


## Turn `bone` about its own joint so `p` (a point it carries) swings toward `target`: `frac` of
## the way, at most `max_ang`.
func _turn_toward(sk: Skeleton3D, bone: int, p: Vector3, target: Vector3, max_ang: float, frac: float) -> void:
	var g := sk.get_bone_global_pose(bone)
	var a := p - g.origin
	var b := target - g.origin
	var axis := a.cross(b)
	if a.length() < 1e-4 or b.length() < 1e-4 or axis.length() < 1e-7:
		return
	var ang := minf(a.angle_to(b) * frac, max_ang)
	g.basis = Basis(axis.normalized(), ang) * g.basis
	sk.set_bone_global_pose(bone, g)
