extends UltraTestSuite
## Sinew moves regression: the moves tour's segments (SinewMoveSegments), run headless, measured with
## SinewMoveMetrics and held to limits - legs never through each other, hips don't sag, soles don't sink into
## ramps / stairs, no flung legs. The safety net for gait changes AND for changed reference clips
## (sinew/ANIMATION_GUIDE.md): a new walk / strafe clip that crosses the legs or dips the hips fails here.
## (The armed segments are left to the tour: test characters carry no kit.)

## Limits per kind of segment: gap (m, the legs' closest approach: < 0 = through each other, allowed down to this),
## overlap (ticks through), hips (m below standing), sink (m into the ground past what flat walking reads), speed (m/s).
const LIMITS := {
	"walk": {"gap": -0.01, "overlap": 0, "hips": 0.22, "speed": 25.0},
	"strafe": {"gap": -0.01, "overlap": 0, "hips": 0.08, "speed": 30.0},
	"chaos": {"gap": -0.01, "overlap": 0, "hips": 0.28, "speed": 30.0},
	"sprint": {"gap": -0.01, "overlap": 0, "hips": 0.25, "speed": 30.0},
	"ramp": {"gap": -0.01, "overlap": 0, "sink": 0.03},
	# Known: stair treads shorter than the rig's foot still leave a toe or heel in a riser - held where it is.
	"stairs": {"gap": -0.01, "overlap": 0, "sink": 0.20},
}
## Known open problems, held where they are now so they can only get better (see sinew/ANIMATION_GUIDE.md):
## strafing LEFT from standing, the trailing foot stays planted while the body slides off it and the hips sag (strafing
## right - whose Mixamo clip isn't a mirror of the left one - doesn't), and backing straight out of that strafe.
const KNOWN := {
	"strafe L then": {"hips": 0.17},
	"back after strafe L": {"hips": 0.19},
	# (Since feet pivot instead of twisting - sinew/ANIMATION_GUIDE.md "Feet pivot, never twist", "Known open
	# problems": flicked round at a run the feet swap sides in the air and the legs pass through each other -
	# -3.3 cm / 4 ticks run alone, -11.4 cm / 11 ticks after s0 (the start differs). Was +1.6 cm. The sprint turn
	# touches for a tick.)
	"sprint flick 180": {"gap": -0.12, "overlap": 12},
	"sprint turn 90/s": {"overlap": 1},
	# (The thigh capsules brush at the roots - shallower than 1 cm - for a few ticks while the stick reverses at
	# 1-2 m/s; the committed margin before the hip-pop work was +1.0 cm.)
	"chaos sprint": {"gap": -0.01, "overlap": 10},
}


func _sinew(at: Vector3) -> SinewCharacter:
	var c := SinewCharacter.new()
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


## Runs the segments (armed ones skipped) and returns the metrics.
func _run(filter: Callable) -> SinewMoveMetrics:
	var map := load_playground()
	var c := _sinew(marker("spawn").global_position)
	await ticks(40)
	var r := c.ragdoll as SinewRagdoll
	var m := SinewMoveMetrics.new(c)
	var b := bot(c)
	for s: Array in SinewMoveSegments.all():
		var label: String = s[0]
		if label.contains("pistol") or label.contains("rifle") or not (label.begins_with("@") or filter.call(label)):
			continue
		var inp: Dictionary = s[2]
		if label.begins_with("@"):
			m.label = ""
			var at := SinewMoveSegments.place(label, map)
			if not at.is_empty():
				c.teleport(at[0], at[1])
				b.live_yaw = at[1]
		else:
			m.label = label
		var gait_on: bool = s[4]
		if r.gait != gait_on:
			r.gait = gait_on
			r._setup_gait()
		if inp.has("yaw_add"):
			b.live_yaw += deg_to_rad(float(inp.yaw_add))
		var step := {"ticks": int(s[1]) + 1, "move": inp.get("move", Vector2.ZERO), "buttons": int(inp.get("buttons", 0))}
		if inp.has("yaw"):
			step["yaw"] = deg_to_rad(float(inp.yaw))
		if inp.has("yaw_rate"):
			step["yaw_rate"] = deg_to_rad(float(inp.yaw_rate))
		b.set_steps([step])
		await ticks(int(s[1]))
	m.label = ""
	m.detach()
	# (Debugging: S10_DUMP=<label substring> prints that segment frame by frame.)
	var dump := OS.get_environment("S10_DUMP")
	if dump != "":
		m.calibrate("idle unarmed")
		for f: Dictionary in m.frames:
			if String(f.label).contains(dump):
				var bs: Dictionary = f.bones
				var h: Vector3 = bs.Hips
				var y := float(f.body)
				var fw := Vector3(-sin(y), 0, -cos(y))
				var rt := Vector3(cos(y), 0, -sin(y))
				var loc := func(p: Vector3) -> String: return "(%+.2f r %+.2f f %.2f)" % [(p - h).dot(rt), (p - h).dot(fw), p.y - (f.pos as Vector3).y]
				print("DUMP %s t%d pos %s hips %.2f drop %.3f gap %+.1f L%s R%s %s%s v %.2f dirw %.2f step %.2f" % [f.label, f.t, str((f.pos as Vector3).snapped(Vector3.ONE * 0.01)), h.y - (f.pos as Vector3).y,
						f.drop, SinewMoveMetrics.legs_gap(bs) * 100.0, loc.call(bs.LeftFoot), loc.call(bs.RightFoot),
						"L" if f.planted_l else "-", "R" if f.planted_r else "-", (f.vel as Vector2).length(), f.dirw, f.step_max],
						" piv %s gaitR %s %s gw %.2f lw %.2f %s gaitgap %+.1f sink %s" % [f.pivoting, loc.call(f.gait_ankles[1]), f.state, f.gait_w, f.legs_w, SinewMoveMetrics.legs_gap_pair(bs), f.gait_gap * 100.0, str(range(f.sink.size()).map(func(i: int) -> String: return "%.2f" % (float(f.sink[i]) - float(m.sink_zeros[i]) if i < m.sink_zeros.size() else 0.0)))])
	return m


func _kind(label: String) -> String:
	for k in ["chaos", "strafe", "ramp", "stairs", "sprint"]:
		if label.contains(k):
			return k
	return "walk"


func _judge(m: SinewMoveMetrics, flat_sink: float) -> void:
	for lab: String in m.labels():
		if lab.begins_with("idle") or lab.ends_with("(clip)"):
			continue      # (references, not judged)
		var s := m.summary(lab)
		var lim: Dictionary = LIMITS[_kind(lab)].duplicate()
		lim.merge(KNOWN.get(lab, {}), true)
		var what := "%s: gap %.1f cm, %d ticks through, hips -%.1f cm, sink %.1f cm, legs %.1f m/s" % [lab, s.gap_min * 100.0,
				s.overlap, s.hips_drop * 100.0, (s.sink - flat_sink) * 100.0, s.leg_speed]
		var ok: bool = float(s.gap_min) >= float(lim.gap) and int(s.overlap) <= int(lim.overlap)
		if lim.has("hips"):
			ok = ok and float(s.hips_drop) <= float(lim.hips)
		if lim.has("sink"):
			ok = ok and float(s.sink) - flat_sink <= float(lim.sink)
		if lim.has("speed"):
			ok = ok and float(s.leg_speed) <= float(lim.speed)
		check(ok, what)


func test_walking_turning_and_ground() -> void:
	var m := await _run(func(l: String) -> bool: return l == "idle unarmed" or not (l.contains("chaos") or l.contains("strafe")))
	m.calibrate("idle unarmed")
	info("\n" + m.table())
	_judge(m, m.summary("walk fwd").sink)


func test_strafing_and_direction_chaos() -> void:
	var m := await _run(func(l: String) -> bool: return l == "idle unarmed" or l == "walk fwd" or l.contains("chaos") or l.contains("strafe"))
	m.calibrate("idle unarmed")
	info("\n" + m.table())
	_judge(m, m.summary("walk fwd").sink)


## The reference clips the gait reads its legs from: sanity rules, and the same as the committed baseline
## (addons/sinew/clip_audit.json). After a deliberate clip change: CLIP_AUDIT_WRITE=1 writes a new baseline -
## read the differences first (sinew/ANIMATION_GUIDE.md).
func test_clip_audit() -> void:
	load_playground()
	var c := _sinew(marker("spawn").global_position)
	await ticks(40)
	var entries := SinewClipAudit.report(c)
	info("\n" + SinewClipAudit.table(entries))
	check(entries.size() >= 3, "the gait read its reference cycles (%d)" % entries.size())
	for msg: String in SinewClipAudit.rules(entries, c.profile):
		check(false, msg)
	if OS.get_environment("CLIP_AUDIT_WRITE") != "":
		SinewClipAudit.save_baseline(entries)
		info("baseline written: " + SinewClipAudit.BASELINE)
		return
	var base := SinewClipAudit.load_baseline()
	check(not base.is_empty(), "a clip audit baseline exists (%s)" % SinewClipAudit.BASELINE)
	var changes := SinewClipAudit.diff(entries, base)
	for msg: String in changes:
		info("changed: " + msg)
	check(changes.is_empty(), "the reference clips read as in the baseline (%d changes; deliberate? CLIP_AUDIT_WRITE=1)" % changes.size())
