@tool
class_name SinewAnimationSet
extends AnimationSet
## The clips a Sinew character references - plain clips as imported, played by SinewAnimDriver with no
## IK or procedural passes on top (Sinew's gait and item holding do that work instead).
##
## Re-point any role without code: set `overrides` (role -> "library/clip", e.g. "mixamo/Walk_02"; a
## bare name = the default library). Roles not overridden come from `base` (an AnimationSet; empty =
## the character's own BodyProfile set). The gait_* roles name the reference cycles the walk's key
## poses are sampled from (S6c).

@export var base: AnimationSet
## role -> clip: wins over `base`.
@export var overrides: Dictionary = {}
@export var gait_walk: StringName = &"walk_f"
@export var gait_run: StringName = &"jog_f"
@export var gait_sprint: StringName = &"sprint_f"


## A working copy for one character: base roles + overrides merged (items add their own roles to it,
## so it's never the shared resource).
func resolved(fallback: AnimationSet) -> SinewAnimationSet:
	var src: AnimationSet = base if base != null else fallback
	var out := SinewAnimationSet.new()
	if src:
		out.roles = src.roles.duplicate()
		out.authored_speed = src.authored_speed.duplicate()
		out.plant_phase = src.plant_phase.duplicate()
		out.root_motion = src.root_motion.duplicate()
		out.loops = src.loops.duplicate()
	for role in overrides:
		out.roles[StringName(role)] = StringName(overrides[role])
	out.gait_walk = gait_walk
	out.gait_run = gait_run
	out.gait_sprint = gait_sprint
	return out
