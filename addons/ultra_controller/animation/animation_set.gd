@tool
class_name AnimationSet
extends Resource
## Maps semantic roles ("walk_f", "jump_start", "ledge_hang"...) to clips in the character's
## animation libraries, plus measured facts about each clip. Swapping a Mixamo or Blender
## clip in is an edit to this resource only; no code names a clip.

## role -> "library/clip" (or bare clip name in the default library)
@export var roles: Dictionary = {}
## clip -> authored ground speed (m/s) of an in-place locomotion cycle, measured from the feet
@export var authored_speed: Dictionary = {}
## clip -> normalized phase (0..1) at which the LEFT foot plants; used to align cycles
@export var plant_phase: Dictionary = {}
## Root-motion clips the motor may play, in a fixed order (index rides in MotorState.rm_clip).
@export var root_motion: Array[RootMotionCurve] = []
## clip -> loop flag decided at import
@export var loops: Dictionary = {}


func clip(role: StringName) -> StringName:
	return StringName(roles.get(role, ""))


func has_role(role: StringName) -> bool:
	return roles.has(role) and String(roles[role]) != ""


func speed_of(role: StringName, fallback: float) -> float:
	var c := String(clip(role))
	return float(authored_speed.get(c, fallback))


func rm_index(role_or_clip: StringName) -> int:
	var want := clip(role_or_clip) if roles.has(role_or_clip) else role_or_clip
	for i in root_motion.size():
		if root_motion[i].clip == want:
			return i
	return -1


func rm_curve(index: int) -> RootMotionCurve:
	return root_motion[index] if index >= 0 and index < root_motion.size() else null
