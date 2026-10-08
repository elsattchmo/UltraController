class_name MarksmanFreelook
extends Node
## Freelook (V4b; Sandstorm's Alt - here `marksman_freelook`, H: Alt is walk): held, the mouse turns the head and the
## first-person view while the aim - and the gun, and every shot - stays where it was. Presentation only: the aim the
## input source samples is held still (this node runs before the sampler each physics tick and before the camera rig
## each frame, and takes any turn the mouse made into `offset`); MarksmanEye turns the camera by `offset`, the gun pass
## turns the neck and head toward it. Let go, the view eases back onto the aim. First person only.

const ACTION := &"marksman_freelook"
const YAW_MAX := 1.3                   ## rad either side
const PITCH_MAX := 0.7
const BACK_RATE := 9.0                 ## 1/s: easing back onto the aim after letting go

var character: UltraCharacter
var rig: UltraCameraRig
## The view's turn off the aim (yaw, pitch; rad).
var offset := Vector2.ZERO
## Held this frame (tests may set `force`).
var active := false
var force := false
var _aim := Vector2.ZERO


func _init(c: UltraCharacter, r: UltraCameraRig) -> void:
	character = c
	rig = r
	name = "MarksmanFreelook"
	process_priority = 99              # (before the rig, 100)
	process_physics_priority = -100    # (before UltraNet samples the input)


func _wanted() -> bool:
	if force:
		return true
	if not InputMap.has_action(ACTION) or not Input.is_action_pressed(ACTION):
		return false
	var src := character.input_source as LocalInputSource
	return src != null and src.enabled and rig != null and rig.tp_blend < 0.5 \
			and not character.state.state in [MotorState.Id.RAGDOLL, MotorState.Id.DEAD, MotorState.Id.GET_UP]


func _hold() -> void:
	var src := character.input_source
	if src == null:
		return
	var want := _wanted()
	if want and not active:
		_aim = Vector2(src.live_yaw, src.live_pitch)
	active = want
	if not active:
		return
	# The mouse's turn since last time goes into the view, the aim stays.
	offset.x = clampf(offset.x + angle_difference(_aim.x, src.live_yaw), -YAW_MAX, YAW_MAX)
	offset.y = clampf(offset.y + (src.live_pitch - _aim.y), -PITCH_MAX, PITCH_MAX)
	src.live_yaw = _aim.x
	src.live_pitch = _aim.y


func _physics_process(_delta: float) -> void:
	_hold()


func _process(delta: float) -> void:
	_hold()
	if not active:
		offset = offset.lerp(Vector2.ZERO, 1.0 - exp(-BACK_RATE * delta))
		if offset.length() < 1e-3:
			offset = Vector2.ZERO
