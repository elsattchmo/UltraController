class_name SinewMoveMetrics
extends RefCounted
## Measures a Sinew character's legs while it moves - the numbers behind "legs go through each other", "the hips
## dip", "feet sink into the ramp". Shared by the moves tour (demo/tours/sinew_moves_review.gd, which also films)
## and the moves suite (tests/suites/s10_sinew_moves.gd, headless), so both judge a move the same way.
## Sampled at Skeleton3D.skeleton_updated (the shown pose is only readable there).
##
##   var m := SinewMoveMetrics.new(character)
##   m.label = "strafe L"            # frames are grouped by label; "" or "@..." isn't recorded
##   ...
##   var s := m.summary("strafe L")  # gap_min, overlap, hips_drop, sink, leg_speed, pivot, steps
##   m.detach()

const BONES := ["Hips", "LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "LeftToes", "RightUpperLeg", "RightLowerLeg",
		"RightFoot", "RightToes", "LeftUpperArm", "RightUpperArm", "Head"]
## Leg capsules for the overlap test: segment (from bone, to bone) and radius (m) - the mannequin's thigh, shin, foot.
const SEGS := {"thigh": ["UpperLeg", "LowerLeg", 0.075], "shin": ["LowerLeg", "Foot", 0.055], "foot": ["Foot", "Toes", 0.045]}

var character: UltraCharacter
var ragdoll: SinewRagdoll
var label := ""
var frames: Array = []            ## every recorded frame: see _capture
var record_sinks := true
## Hip height over the lower toe when standing in the idle clip, and what the sink probe reads standing on flat
## ground (the bones aren't the soles): measured by calibrate(), used by summary().
var stand_hips := 0.0
var sink_zero := 0.0
var _ids: Dictionary = {}


func _init(c: UltraCharacter) -> void:
	character = c
	ragdoll = c.ragdoll as SinewRagdoll
	for b in BONES:
		_ids[b] = c.skeleton.find_bone(b)
	c.skeleton.skeleton_updated.connect(_on_posed)


func detach() -> void:
	if character and is_instance_valid(character) and character.skeleton.skeleton_updated.is_connected(_on_posed):
		character.skeleton.skeleton_updated.disconnect(_on_posed)


## Take the standing reference from the frames recorded under `idle_label` (standing on flat ground).
func calibrate(idle_label: String) -> void:
	var hs := 0.0
	var sk := 0.0
	var n := 0
	var ns := 0
	for f: Dictionary in frames:
		if f.label != idle_label:
			continue
		var b: Dictionary = f.bones
		hs += (b.Hips as Vector3).y - minf((b.LeftToes as Vector3).y, (b.RightToes as Vector3).y)
		n += 1
		for x: float in f.sink:
			sk += x
			ns += 1
	stand_hips = hs / maxf(n, 1)
	sink_zero = sk / maxf(ns, 1)


func _on_posed() -> void:
	if label == "" or label.begins_with("@") or ragdoll == null:
		return
	frames.append(_capture())


func _capture() -> Dictionary:
	var sk := character.skeleton
	var bones := {}
	for b: String in BONES:
		var i: int = _ids[b]
		if i >= 0:
			bones[b] = (sk.global_transform * sk.get_bone_global_pose(i)).origin
	var st: Dictionary = ragdoll.world.physics.call("character_gait_state", ragdoll._id)
	var st_c := character.state
	return {"t": Engine.get_physics_frames(), "label": label, "bones": bones,
			"aim": float(character.last_input.yaw) if character.last_input else st_c.body_yaw, "body": st_c.body_yaw,
			"state": MotorState.Id.keys()[st_c.state], "vel": Vector2(st_c.vel.x, st_c.vel.z), "pos": st_c.pos,
			"planted_l": bool(st.get("planted_l", true)), "planted_r": bool(st.get("planted_r", true)),
			"stepping": bool(st.get("stepping", false)), "gait_on": ragdoll.gait, "twist": ragdoll.torso_twist,
			"pelvis_turn": float(st.get("pelvis_turn", 0.0)), "drop": float(st.get("pelvis_drop", 0.0)),
			"cadence": float(st.get("cadence", 0.0)), "dirw": float(st.get("clip_dirw", -1.0)),
			"step_max": float(st.get("step_max", 0.0)), "sink": _sinks(bones) if record_sinks else [],
			"gait_ankles": [st.get("ankle_l", Vector3.ZERO), st.get("ankle_r", Vector3.ZERO)],
			"gait_gap": float(st.get("legs_gap", 1.0)), "gait_w": ragdoll.gait_w, "legs_w": ragdoll.gait_part_w[ragdoll._part("RightUpperLeg")] if ragdoll.gait_part_w.size() > 0 else -1.0}


## How far each sole point (toe tip, under the ankle, heel) is under the ground beneath it (m, + = into it),
## probed in Sinew's world from above (a toe inside a stair's riser reads as deep as it is).
func _sinks(bones: Dictionary) -> Array:
	var out := []
	for side in ["Left", "Right"]:
		if not bones.has(side + "Toes") or not bones.has(side + "Foot"):
			continue
		var toe: Vector3 = bones[side + "Toes"]
		var ankle: Vector3 = bones[side + "Foot"]
		var along := Vector3(toe.x - ankle.x, 0.0, toe.z - ankle.z)
		along = along.normalized() if along.length() > 1e-3 else Vector3.ZERO
		for pt: Array in [[toe + (toe - ankle) * 0.6, 0.03], [ankle, 0.08], [ankle - along * 0.06, 0.08]]:
			var p: Vector3 = pt[0]
			var hit: Dictionary = ragdoll.world.physics.call("ground_below", p + Vector3.UP * 0.45, 1.2)
			if bool(hit.get("hit", false)):
				out.append((hit.point as Vector3).y - (p.y - float(pt[1])))
	return out


## Closest the two legs come, as capsules (thigh, shin, foot), minus their radii (m; < 0 = through each other).
static func legs_gap(b: Dictionary) -> float:
	var best := 9.0
	for na: String in SEGS:
		for nb: String in SEGS:
			var sa: Array = SEGS[na]
			var sb: Array = SEGS[nb]
			if not (b.has("Left" + sa[0]) and b.has("Left" + sa[1]) and b.has("Right" + sb[0]) and b.has("Right" + sb[1])):
				continue
			var d := _seg_seg(b["Left" + sa[0]], b["Left" + sa[1]], b["Right" + sb[0]], b["Right" + sb[1]])
			best = minf(best, d - float(sa[2]) - float(sb[2]))
	return best


## Which parts are closest ("thigh/shin" = left thigh vs right shin) - for tracing.
static func legs_gap_pair(b: Dictionary) -> String:
	var best := 9.0
	var which := ""
	for na: String in SEGS:
		for nb: String in SEGS:
			var sa: Array = SEGS[na]
			var sb: Array = SEGS[nb]
			if not (b.has("Left" + sa[0]) and b.has("Left" + sa[1]) and b.has("Right" + sb[0]) and b.has("Right" + sb[1])):
				continue
			var d := _seg_seg(b["Left" + sa[0]], b["Left" + sa[1]], b["Right" + sb[0]], b["Right" + sb[1]]) - float(sa[2]) - float(sb[2])
			if d < best:
				best = d
				which = na + "/" + nb
	return which


static func _seg_seg(p1: Vector3, q1: Vector3, p2: Vector3, q2: Vector3) -> float:
	var a := Geometry3D.get_closest_points_between_segments(p1, q1, p2, q2)
	return (a[0] as Vector3).distance_to(a[1])


static func _foot_yaw(ankle: Vector3, toe: Vector3) -> float:
	return atan2(-(toe.x - ankle.x), -(toe.z - ankle.z))


## Per-label summary: gap_min (m), overlap (ticks the legs are through each other), hips_drop (m below the standing
## height), sink (m into the ground, past the flat-ground reading), leg_speed (fastest an ankle moves relative to
## the hips, m/s), pivot (largest yaw change of a planted foot, deg), steps (touchdowns), frames.
func summary(lab: String) -> Dictionary:
	var gap := 9.0
	var over := 0
	var drop := 0.0
	var sink := 0.0
	var speed := 0.0
	var pivot := 0.0
	var steps := 0
	var n := 0
	var prev: Dictionary = {}
	var yaw0 := {}
	for f: Dictionary in frames:
		if f.label != lab:
			continue
		n += 1
		var b: Dictionary = f.bones
		var g := legs_gap(b)
		gap = minf(gap, g)
		over += 1 if g < 0.0 else 0
		for x: float in f.sink:
			sink = maxf(sink, x - sink_zero)
		var h: Vector3 = b.Hips
		if stand_hips > 0.0:
			drop = maxf(drop, stand_hips - (h.y - minf((b.LeftToes as Vector3).y, (b.RightToes as Vector3).y)))
		for side in ["Left", "Right"]:
			var key := "planted_l" if side == "Left" else "planted_r"
			var y := _foot_yaw(b[side + "Foot"], b[side + "Toes"])
			if not prev.is_empty():
				var pb: Dictionary = prev.bones
				var rel: Vector3 = (b[side + "Foot"] as Vector3) - h
				var prel: Vector3 = (pb[side + "Foot"] as Vector3) - (pb.Hips as Vector3)
				speed = maxf(speed, rel.distance_to(prel) * float(Engine.physics_ticks_per_second))
				if f[key] and not prev[key]:
					steps += 1
			if f[key] and not prev.is_empty() and prev[key] and yaw0.has(side):
				pivot = maxf(pivot, absf(rad_to_deg(angle_difference(yaw0[side], y))))
			elif f[key]:
				yaw0[side] = y
			else:
				yaw0.erase(side)
		prev = f
	return {"gap_min": gap, "overlap": over, "hips_drop": drop, "sink": sink, "leg_speed": speed, "pivot": pivot,
			"steps": steps, "frames": n}


## Every label in recording order.
func labels() -> Array:
	var out := []
	for f: Dictionary in frames:
		if not out.has(f.label):
			out.append(f.label)
	return out


## One line per label, for logs.
func table() -> String:
	var lines := ["%-24s %8s %7s %9s %7s %9s %6s %5s" % ["segment", "gap cm", "overlap", "hips cm", "sink cm", "leg m/s", "pivot", "steps"]]
	for lab: String in labels():
		var s := summary(lab)
		lines.append("%-24s %8.1f %7d %9.1f %7.1f %9.1f %6.0f %5d" % [lab, s.gap_min * 100.0, s.overlap, s.hips_drop * 100.0,
				s.sink * 100.0, s.leg_speed, s.pivot, s.steps])
	return "\n".join(lines)
