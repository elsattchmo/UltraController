class_name MarksmanLedgePass
extends RefCounted
## Hanging from a ledge the hands HOLD it (the user: "we aren't really grabbing the edge when hanging"): each palm flat on
## top of the lip, fingers over the edge, the wrist just behind it - UltraTraversalVisual's ledge grip, which Marksman
## never had (Sinew's driver has no hand IK; the hang clips only had their hips shifted so the AVERAGE hand met the
## lip). Each hand keeps the clip's sideways place (the shimmy goes hand over hand), clamped near the body, and comes off
## the lip by as much as the clip lifts it (the shimmy's reach) - so a hand lets go and takes hold, it doesn't slide. A
## SinewPoseModifier pass on the animated pose, eased in / out over FADE (into a climb-up the clip has the hands).

const FADE := 0.12
## Taking hold eases in over this (s): the capsule has just snapped onto the ledge, and pulled on in FADE the fingers
## whipped 25 m/s (g9).
const FADE_IN := 0.25
## Hands a hand's breadth either side of the middle, at most this far out (m).
const SIDE := Vector2(0.08, 0.45)
## The wrist this far above the top, this far back from the edge (m).
const ABOVE := 0.035
const BACK := 0.015
## Share of the arm's length a hanging arm straightens to before the body is lifted to the hands.
const REACH := 0.99
## How far a clip's lift shows (share of the clip hand's rise over its lowest in the hang).
const LIFT_SHARE := 1.0

var character: UltraCharacter
var ragdoll: SinewRagdoll
var weight := 0.0
var _p := {}
var _low := [INF, INF]            ## each clip hand's lowest height off the lip seen this hang (its grip height)


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
	var on := st.state == MotorState.Id.LEDGE_HANG
	weight = move_toward(weight, 1.0 if on else 0.0, dt / (FADE_IN if on else FADE))
	# (Only a shimmy lifts a hand off the lip, hand over hand: the catch's hands rise from low as the body settles - read as
	# a lift they stood 20-47 cm over the lip.)
	var drv := character.anim as UltraAnimDriver
	var shimmying := on and drv != null and drv._cur_loco == "hang" and absf(drv.climb_speed) > 0.05
	if not shimmying:
		_low = [INF, INF]
	if weight <= 0.001:
		return false
	var gp := (ragdoll as MarksmanRagdoll).gun_pass if ragdoll is MarksmanRagdoll else null
	if gp == null or not gp._learn_palm(sk):
		return false
	var pose := mod.anim_pose
	var to_sk := sk.global_transform.affine_inverse()
	var tb := to_sk.basis.orthonormalized()
	var n := (tb * st.trav_normal).normalized()
	var up := (tb * Vector3.UP).normalized()
	var right := (tb * Vector3(cos(st.body_yaw), 0.0, -sin(st.body_yaw))).normalized()
	var lip := to_sk * st.trav_point
	var fingers := (-n * 0.85 - up * 0.15).normalized()
	var targets := {}
	var short := 0.0
	for hs: int in [-1, 1]:
		var pre := "Left" if hs == -1 else "Right"
		var h := _part(pre + "Hand")
		var ua := _part(pre + "UpperArm")
		var la := _part(pre + "LowerArm")
		if h < 0 or ua < 0 or la < 0:
			continue
		var hand: Vector3 = pose[h].origin
		var side := (hand - lip).dot(right)
		side = clampf(side, -SIDE.y, -SIDE.x) if hs == -1 else clampf(side, SIDE.x, SIDE.y)
		var k := 0 if hs == -1 else 1
		var lift := 0.0
		if shimmying:
			var rise := (hand - lip).dot(up)
			_low[k] = minf(float(_low[k]), rise)
			lift = maxf(rise - float(_low[k]), 0.0) * LIFT_SHARE
		var contact := lip + up * (ABOVE + lift) + right * side + n * BACK
		var target: Transform3D = gp._hand(hs, fingers, -up, contact)
		targets[hs] = [ua, la, h, target]
		var reach: float = pose[ua].origin.distance_to(pose[la].origin) + pose[la].origin.distance_to(pose[h].origin)
		short = maxf(short, pose[ua].origin.distance_to(target.origin) - reach * REACH)
	# The body hangs FROM the hands: where the clip has it too low for straight arms to reach the lip (the catch settles
	# lower than its average - the hands came 6 cm short), the whole body comes up.
	var k := smoothstep(0.0, 1.0, weight)
	if short > 0.0:
		var lift_body := up * short * k
		for i in pose.size():
			pose[i].origin += lift_body
	gp.keep_elbow = true
	for hs: int in targets:
		var tg: Array = targets[hs]
		gp._two_bone(pose, int(tg[0]), int(tg[1]), int(tg[2]), tg[3], k)
	gp.keep_elbow = false
	return true
