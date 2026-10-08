class_name MarksmanEye
extends Node
## Body-true first person: the camera is the head's own eye. The UltraCameraRig (process priority 100) places its
## first-person eye from the Head bone smoothed (head yaw only, low-passed, kept off the neck); this runs right after
## it (101, before the equipment at 110) and moves the first-person part of the camera onto the posed head's eye
## point - what the gun pass made, so in ADS the eye is on the sights' line. The view's direction stays the
## rig's (the mouse's): only the position is the body's. Also keeps `fp_view` (what the equipment and the HUD read)
## and the shot origin (`aim_from`) on it. The down view (knocked down, dead, getting up) stays the rig's.

var character: UltraCharacter
var rig: UltraCameraRig
## The eye in the Head bone's frame (from BodyProfile.eye_offset, character space, on the rest pose).
var eye_local := Vector3.ZERO
## Last frame's eye (world) and how much of it the camera took (tests).
var eye := Vector3.ZERO
var weight := 0.0

var _head := -1
var _head_pose := Transform3D()
var _have := false
var _sk: Skeleton3D


func _init(c: UltraCharacter, r: UltraCameraRig) -> void:
	character = c
	rig = r
	name = "MarksmanEye"
	process_priority = 101


func _ready() -> void:
	_sk = character.skeleton
	if _sk == null:
		return
	_head = _sk.find_bone("Head")
	if _head < 0:
		return
	# Character space (facing -Z) -> skeleton / model space (facing +Z): the body node is turned 180 deg.
	var off := character.body_profile.eye_offset if character.body_profile else Vector3(0, 0.075, -0.1)
	var model := Vector3(-off.x, off.y, -off.z)
	eye_local = _sk.get_bone_global_rest(_head).basis.orthonormalized().inverse() * model
	_sk.skeleton_updated.connect(_capture)


## The shown pose is readable only now (after every modifier, the gun pass included).
func _capture() -> void:
	_head_pose = _sk.get_bone_global_pose(_head)
	_have = true


func _process(_delta: float) -> void:
	if not _have or rig == null or not is_instance_valid(rig) or rig.camera == null:
		return
	var st := character.state
	var down := st.state in [MotorState.Id.RAGDOLL, MotorState.Id.DEAD, MotorState.Id.GET_UP]
	weight = 0.0 if down else clampf(1.0 - rig.tp_blend, 0.0, 1.0)
	eye = _sk.global_transform * (_head_pose * eye_local)
	var eq := character.get_node_or_null("Equipment") as UltraEquipmentVisual
	if weight <= 0.0 or eq == null:
		return
	# The rig put the camera at fp.lerp(tp, tp_blend), fp = eq.fp_view.origin: shift its first-person share.
	# (The camera is the rig's child: moving the rig moves it.)
	var shift := (eye - eq.fp_view.origin) * weight
	rig.global_position += shift
	eq.fp_view = Transform3D(eq.fp_view.basis, eye)
	var src := character.input_source
	if src:
		src.aim_from = rig.global_position - (character.visual_feet + Vector3.UP * (character.state.height - 0.16))
