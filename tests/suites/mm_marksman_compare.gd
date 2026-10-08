extends UltraTestSuite
## Motion-matching spike: the same moves - starts, stops, reversals, 90 deg stick turns, strafe flips, diagonals, sprint
## starts / stops / reversals and a seeded chaos stick - walked by Sinew's procedural gait and by motion matching
## (MarksmanCharacter.motion_matching), unarmed and with the rifle, measured the same way off the shown skeleton:
## planted-foot slide, legs' closest approach, hips drop, how far a planted foot is from under the hips (reach: the
## "leg compensation" lunges), steps, the fastest an ankle moves against the hips and the hips' sharpest acceleration
## (pops). Prints a table per stance; checks only that matching runs (it is a comparison, not a gate yet).
##   godot --headless --path . --fixed-fps 60 res://tests/test_runner.tscn -- --suite=mm

const D := 0.70710678
const SPRINT := InputFrame.B_SPRINT


func _marksman(at: Vector3, mm: bool) -> MarksmanCharacter:
	var c := MarksmanCharacter.new()
	c.motion_matching = mm
	c.profile = (load("res://addons/ultra_controller/profiles/fps.tres") as MovementProfile).duplicate(true)
	c.body_profile = CharacterModels.body_profile("mannequin")
	c.build_visuals = true
	var b := BotInputSource.new()
	b.name = "InputSource"
	c.add_child(b)
	c.input_source = b
	c.position = at
	add_child(c)
	b.body = c
	chars.append(c)
	return c


static func moves(seed := 11) -> Array:
	var out := [["idle", 60, Vector2.ZERO, 0], ["start fwd", 90, Vector2(0, 1), 0], ["reverse to back", 90, Vector2(0, -1), 0],
		["turn to right", 90, Vector2(1, 0), 0], ["flip to left", 90, Vector2(-1, 0), 0], ["fwd-left", 90, Vector2(-D, D), 0],
		["reverse back-right", 90, Vector2(D, -D), 0], ["stop", 60, Vector2.ZERO, 0], ["sprint start", 120, Vector2(0, 1), SPRINT],
		["sprint stop", 90, Vector2.ZERO, 0], ["sprint", 90, Vector2(0, 1), SPRINT], ["sprint reverse", 120, Vector2(0, -1), 0],
		["stop again", 60, Vector2.ZERO, 0]]
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var dirs := [Vector2(0, 1), Vector2(D, D), Vector2(1, 0), Vector2(D, -D), Vector2(0, -1), Vector2(-D, -D), Vector2(-1, 0), Vector2(-D, D), Vector2.ZERO]
	for k in 14:
		out.append(["chaos", rng.randi_range(15, 40), dirs[rng.randi_range(0, dirs.size() - 1)], 0])
	return out


func test_motion_matching_against_the_gait() -> void:
	load_playground()
	var spot := marker("spawn").global_position + Vector3(-16, 0, -3)
	for item: StringName in [&"", &"rifle"]:
		var rows := {}
		for mm in [false, true]:
			var c := _marksman(spot, mm)
			await ticks(40)
			var sl := 0
			if item != &"":
				UltraItems.give(c, item)
				for i in c.inventory.size():
					var it := c.inventory.get_slot(i)
					if it and it.def_id == item:
						sl = i + 1
			bot(c).live_yaw = 0.0
			bot(c).set_steps([{"ticks": 60, "slot": sl, "yaw": 0.0}])
			await ticks(60)
			var rec := Recorder.new(c)
			for mv: Array in moves():
				rec.label = mv[0]
				bot(c).set_steps([{"ticks": int(mv[1]) + 1, "move": mv[2], "buttons": int(mv[3]), "slot": sl, "yaw": 0.0}])
				await ticks(int(mv[1]))
			rec.label = ""
			rec.detach()
			rows[mm] = rec
			if mm:
				var drv := c.anim as MarksmanAnimDriver
				info("%s matching: %d searches, %d switches, %d frames, slowest search %.2f ms" % ["unarmed" if item == &"" else String(item),
						drv.mm.searches, drv.mm.switches, drv.mm.db.size(), drv.mm.search_us / 1000.0])
				check(drv.mm.switches > 3, "%s: the matcher picks clips (%d switches)" % [item, drv.mm.switches])
				check(rec.nan == 0, "%s: no NaN in the matched pose" % item)
			chars.erase(c)
			c.queue_free()
			await ticks(5)
		info("%s - gait | motion matching" % ("unarmed" if item == &"" else String(item)))
		info(Recorder.table(rows[false], rows[true]))


## Off the shown skeleton (at skeleton_updated), per label. Foot skating is the usual motion-matching measure (Zhang et
## al. 2018) on feet down for 4 frames or more (g1's rule): a foot's horizontal speed weighted by how close it is to the ground, 2 - 2^(h / H) (1 on the ground, 0
## from H up), h = the lower of its sole points (heel, ball) over the move's floor (its 5th percentile: clips stand at
## different heights).
class Recorder:
	extends RefCounted
	const H := 0.025
	var c: UltraCharacter
	var sk: Skeleton3D
	var label := ""
	var frames: Array = []
	var order: Array = []
	var nan := 0
	var _ids := {}
	var _feet: Array[int] = []
	var _heel: Array = []
	var _ball: Array = []

	func _init(ch: UltraCharacter) -> void:
		c = ch
		sk = ch.skeleton
		for b in SinewMoveMetrics.BONES:
			_ids[b] = sk.find_bone(b)
		# Sole points in the foot bone's frame (from rest, as g1): the heel under the ankle 6 cm back, the ball under
		# the toe joint.
		for side in 2:
			var f := sk.find_bone("LeftFoot" if side == 0 else "RightFoot")
			var t := sk.find_bone("LeftToes" if side == 0 else "RightToes")
			var rest := sk.get_bone_global_rest(f)
			_feet.append(f)
			_heel.append(rest.affine_inverse() * Vector3(rest.origin.x, 0.0, rest.origin.z - 0.06))
			_ball.append(rest.affine_inverse() * Vector3(sk.get_bone_global_rest(t).origin.x, 0.0, sk.get_bone_global_rest(t).origin.z))
		sk.skeleton_updated.connect(_on)

	func detach() -> void:
		if is_instance_valid(sk) and sk.skeleton_updated.is_connected(_on):
			sk.skeleton_updated.disconnect(_on)

	func _on() -> void:
		if label == "":
			frames.append({})        # (a break: no differences across it)
			return
		var b := {}
		for n: String in _ids:
			var i: int = _ids[n]
			if i >= 0:
				var p := (sk.global_transform * sk.get_bone_global_pose(i)).origin
				if not p.is_finite():
					nan += 1
					return
				b[n] = p
		if not order.has(label):
			order.append(label)
		var soles := []
		for side in 2:
			var ft := sk.global_transform * sk.get_bone_global_pose(_feet[side])
			soles.append([ft * (_heel[side] as Vector3), ft * (_ball[side] as Vector3)])
		frames.append({"label": label, "b": b, "gy": c.state.pos.y, "soles": soles})

	## Per label: skate (max / mean mm a frame, height-weighted), gap (cm), drop (cm), reach (m: a grounded foot from
	## under the hips), steps (touchdowns), leg (m/s, an ankle against the hips), acc (m/s2, the hips).
	func stats() -> Dictionary:
		var lo := [INF, INF, INF, INF]          # lowest ankle / toe height, left then right
		var stand := 0.0
		var ns := 0
		for f: Dictionary in frames:
			if f.is_empty():
				continue
			var b: Dictionary = f.b
			var gy: float = f.gy
			var hs := [b.LeftFoot.y - gy, b.LeftToes.y - gy, b.RightFoot.y - gy, b.RightToes.y - gy]
			for k in 4:
				lo[k] = minf(lo[k], hs[k])
			if f.label == "idle":
				stand += b.Hips.y - gy
				ns += 1
		stand /= maxi(ns, 1)
		# Each move's own floor: the 5th percentile of the lower sole point (clips stand at different heights).
		var hs_by := {}
		for f: Dictionary in frames:
			if f.is_empty():
				continue
			for side in 2:
				var so: Array = f.soles[side]
				if not hs_by.has(f.label):
					hs_by[f.label] = []
				hs_by[f.label].append(minf((so[0] as Vector3).y, (so[1] as Vector3).y) - float(f.gy))
		var floor_by := {}
		for lab: String in hs_by:
			var arr: Array = hs_by[lab]
			arr.sort()
			floor_by[lab] = float(arr[int(arr.size() * 0.05)])
		var out := {}
		var prev: Dictionary = {}
		var pv := Vector3.INF
		var down := [false, false]
		var low_run := [0, 0]
		var fps := float(Engine.physics_ticks_per_second)
		for f: Dictionary in frames:
			if f.is_empty():
				prev = {}
				pv = Vector3.INF
				low_run = [0, 0]
				continue
			var lab: String = f.label
			if not out.has(lab):
				out[lab] = {"skate": 0.0, "skate_sum": 0.0, "n": 0, "gap": 9.0, "drop": 0.0, "reach": 0.0, "steps": 0, "leg": 0.0, "acc": 0.0}
			var s: Dictionary = out[lab]
			var b: Dictionary = f.b
			var gy: float = f.gy
			var hips: Vector3 = b.Hips
			s.n += 1
			s.gap = minf(s.gap, SinewMoveMetrics.legs_gap(b))
			s.drop = maxf(s.drop, stand - (hips.y - gy))
			for side in 2:
				var ank: Vector3 = b.LeftFoot if side == 0 else b.RightFoot
				var toe: Vector3 = b.LeftToes if side == 0 else b.RightToes
				var sole: Array = f.soles[side]
				var h := minf((sole[0] as Vector3).y, (sole[1] as Vector3).y) - gy - float(floor_by[lab])
				low_run[side] = low_run[side] + 1 if h < H else 0
				if h < H * 0.5 and not down[side]:
					down[side] = true
					s.steps += 1
				elif h > H * 1.5:
					down[side] = false
				if h < H:
					s.reach = maxf(s.reach, Vector2(ank.x - hips.x, ank.z - hips.z).length())
				if prev.is_empty():
					continue
				var pb: Dictionary = prev.b
				var pa: Vector3 = pb.LeftFoot if side == 0 else pb.RightFoot
				var pt: Vector3 = pb.LeftToes if side == 0 else pb.RightToes
				s.leg = maxf(s.leg, ((ank - hips) - (pa - pb.Hips)).length() * fps)
				var ps: Array = prev.soles[side]
				var d := minf(_flat(sole[0] - ps[0]), _flat(sole[1] - ps[1]))
				# (Down 4 frames or more, as g1: a swinging foot skims the floor at toe-off and heel strike.)
				var w := clampf(2.0 - pow(2.0, maxf(h, 0.0) / H), 0.0, 1.0) if low_run[side] >= 4 else 0.0
				s.skate = maxf(s.skate, d * w)
				s.skate_sum += d * w
			if not prev.is_empty():
				var v := (hips - (prev.b.Hips as Vector3)) * fps
				if pv != Vector3.INF:
					s.acc = maxf(s.acc, (v - pv).length() * fps)
				pv = v
			prev = f
		return out

	static func _flat(v: Vector3) -> float:
		return Vector2(v.x, v.z).length()

	static func table(a: Recorder, b: Recorder) -> String:
		var sa := a.stats()
		var sb := b.stats()
		var lines := ["%-20s | %-41s | %-41s" % ["", "gait", "motion matching"],
				"%-20s | %s | %s" % ["move", _head(), _head()]]
		var tot := [{}, {}]
		for lab: String in a.order:
			var cols := []
			for k in 2:
				var s: Dictionary = (sa if k == 0 else sb).get(lab, {})
				cols.append(_row(s))
				for key: String in ["skate", "reach", "acc", "leg", "drop"]:
					tot[k][key] = maxf(float(tot[k].get(key, 0.0)), float(s.get(key, 0.0)))
				tot[k]["gap"] = minf(float(tot[k].get("gap", 9.0)), float(s.get("gap", 9.0)))
				for key: String in ["skate_sum", "n", "steps"]:
					tot[k][key] = float(tot[k].get(key, 0.0)) + float(s.get(key, 0.0))
			lines.append("%-20s | %s | %s" % [lab, cols[0], cols[1]])
		lines.append("%-20s | %s | %s" % ["WORST / TOTAL", _row(tot[0]), _row(tot[1])])
		return "\n".join(lines)

	static func _head() -> String:
		return "%5s %4s %5s %5s %5s %3s %4s %5s" % ["skate", "mean", "gap", "drop", "reach", "st", "leg", "acc"]

	static func _row(s: Dictionary) -> String:
		if s.is_empty():
			return "%41s" % "-"
		return "%5.1f %4.1f %5.1f %5.1f %5.2f %3d %4.1f %5.0f" % [float(s.skate) * 1000.0, float(s.skate_sum) / maxf(float(s.n), 1.0) * 1000.0,
				float(s.gap) * 100.0, float(s.drop) * 100.0, float(s.reach), int(s.steps), float(s.leg), float(s.acc)]
