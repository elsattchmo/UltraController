class_name MarksmanRopePass
extends RefCounted
## On a swing rope the hands hold it (the climb clip) and the legs pump the swing: they kick out with the arc - forward
## at the front of the swing, back at the back - a little ahead of it (the way you pump a swing), as the UltraController's
## UltraTraversalVisual._rope_legs does it. A SinewPoseModifier pass on the animated pose (no physics: the user found
## the hanging physical body looked wrong). Climbing the rope, the clip's legs.

## Leg angle off the rope (rad) per rad of the rope's own angle, and its range (back .. front).
const GAIN := 1.2
const RANGE := Vector2(-0.55, 0.95)
## Seconds the legs lead the swing.
const LEAD := 0.25
## Hip to foot along the leg (m) and each foot's sideways offset.
const REACH := 0.84
const FOOT_SIDE := 0.1

var character: UltraCharacter
var ragdoll: SinewRagdoll
var weight := 0.0
var angle := 0.0               ## the legs' angle now (rad; + = out in front)
var _theta := INF
var _p := {}


func _init(c: UltraCharacter, r: SinewRagdoll) -> void:
	character = c
	ragdoll = r
	for i in r.parts.size():
		_p[r.parts[i].name] = i


func _part(n: String) -> int:
	return int(_p.get(n, -1))


func apply(mod: SinewPoseModifier, sk: Skeleton3D) -> bool:
	var dt := clampf(mod.get_process_delta_time(), 0.0, 0.1)
	var st := character.state
	var rope := UltraRope.find(st.trav_id) if st.state == MotorState.Id.ROPE else null
	var on := rope != null and absf(UltraRope.climb_input(rope, character.last_input)) <= 0.0
	weight = move_toward(weight, 1.0 if on else 0.0, 4.0 * dt)
	if rope != null:
		# The rope's angle from straight down, along the facing (+ = the body out in front of the anchor), and where it
		# will be LEAD s on.
		var grip := UltraTraversalVisual.rope_grip(character)
		var up := (rope.anchor() - grip).normalized()
		var flat := Basis(Vector3.UP, st.body_yaw) * Vector3.FORWARD
		var theta := asin(clampf(-up.dot(flat), -1.0, 1.0))
		var rate := (theta - _theta) / dt if _theta != INF and dt > 0.0 else 0.0
		_theta = theta
		var want := clampf((theta + rate * LEAD) * GAIN, RANGE.x, RANGE.y)
		angle = lerpf(angle, want, 1.0 - exp(-8.0 * dt)) if dt > 0.0 else want
	else:
		_theta = INF
	if weight <= 0.001:
		return false
	var gp := (ragdoll as MarksmanRagdoll).gun_pass if ragdoll is MarksmanRagdoll else null
	var hips := _part("Hips")
	if gp == null or hips < 0:
		return false
	var pose := mod.anim_pose
	# Skeleton space: the model faces +Z, its left is +X; the visual root hangs along the rope (+Y = up the rope).
	var leg := (Vector3.DOWN * cos(angle) + Vector3.BACK * sin(angle)) * REACH
	for side in 2:
		var pre := "Left" if side == 0 else "Right"
		var up_i := _part(pre + "UpperLeg")
		var lo_i := _part(pre + "LowerLeg")
		var ft_i := _part(pre + "Foot")
		if up_i < 0 or lo_i < 0 or ft_i < 0:
			continue
		var target := pose[hips].origin + leg + Vector3(FOOT_SIDE if side == 0 else -FOOT_SIDE, 0.0, 0.0)
		# (The foot keeps its clip orientation, pitched with the leg.)
		var b := Basis(Vector3.RIGHT, -angle) * pose[ft_i].basis
		gp._two_bone(pose, up_i, lo_i, ft_i, Transform3D(b, target), weight)
	return true
