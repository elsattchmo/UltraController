@tool
class_name MarksmanStanceSet
extends SinewAnimationSet
## Marksman's clip references: a SinewAnimationSet (roles -> clips in `overrides`, measured speeds) plus the
## STANCES the gait walks in - one group of reference cycles per stance and posture (unarmed / rifle / pistol,
## standing / crouched). Written by tools/marksman/build_stance_sets.gd (it measures every clip); re-point a
## role there or here, then re-run the clip audit (suite g1, sinew/ANIMATION_GUIDE.md).
##
## A group: {"name": "rifle_stand", "stance": "rifle", "posture": "stand", "idle": role (the standing pose and
## the clip feet), "aim": role (standing, gun up; optional), "cycles": [role, ...] (any directions and speeds -
## the core finds each clip's way of travel and blends by speed), "upper_from": {role: [roles]} (that cycle's
## spine and arms are the average of these roles' at the same phase - a clip with good legs and the wrong
## arms), "arms_from": {role: [roles]} (the same for the shoulders, arms and hands only - the cycle keeps its own
## spine and head), "turn_l" / "turn_r": roles (turning on the spot)}.

@export var groups: Array[Dictionary] = []


func resolved(fallback: AnimationSet) -> SinewAnimationSet:
	var base_out := super.resolved(fallback)
	var out := MarksmanStanceSet.new()
	out.roles = base_out.roles
	out.authored_speed = base_out.authored_speed
	out.plant_phase = base_out.plant_phase
	out.root_motion = base_out.root_motion
	out.loops = base_out.loops
	for k in authored_speed:
		out.authored_speed[k] = authored_speed[k]
	for k in plant_phase:
		out.plant_phase[k] = plant_phase[k]
	out.gait_walk = gait_walk
	out.gait_run = gait_run
	out.gait_sprint = gait_sprint
	out.gait_run_upper = gait_run_upper
	out.gait_back = gait_back
	out.gait_left = gait_left
	out.gait_right = gait_right
	out.groups = groups.duplicate(true)
	return out


## The group index for a stance and posture (-1: none).
func group_index(stance: String, posture: String) -> int:
	for i in groups.size():
		if groups[i].get("stance", "") == stance and groups[i].get("posture", "") == posture:
			return i
	return -1
