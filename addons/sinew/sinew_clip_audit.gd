class_name SinewClipAudit
extends RefCounted
## Checks the reference clips Sinew's gait reads its legs from (SinewAnimationSet gait_walk / run / sprint / back /
## left / right). Swapping one of those clips changes how the character walks, often subtly - a stylised stride, a
## crossover where none should be, a speed far from the motor's. The audit reads back what the gait took from each
## clip (Gait::clip_report), holds it to sanity rules, and compares it with the committed baseline
## (addons/sinew/clip_audit.json) so a change shows up as a list of differences. See sinew/ANIMATION_GUIDE.md.
##
## Run: suite s10 (test_clip_audit) - fails on a broken rule or an unexpected change;
##   CLIP_AUDIT_WRITE=1 ... --suite=s10 writes a new baseline after a deliberate clip change.

const BASELINE := "res://addons/sinew/clip_audit.json"
## Differences smaller than these aren't changes (per field).
const TOLERANCE := {"speed": 0.05, "true_speed": 0.08, "stride": 0.06, "cadence": 0.1, "duty": 0.04, "angle": 0.1,
		"width_min": 0.03, "width_max": 0.03, "lift_max": 0.03, "yaw_range": 0.08, "pelvis_bob": 0.02, "foot_off": 0.05}


## One entry per reference cycle: role, clip and the facts the gait read (see Gait::ClipReport).
static func report(c: SinewCharacter) -> Array:
	var r := c.ragdoll as SinewRagdoll
	if r == null or r.world == null:
		return []
	var facts: Array = r.world.physics.call("character_gait_clip_report", r._id)
	var drv := c.anim
	var aset := drv.anim_set as SinewAnimationSet
	var named := []           # [role, clip, authored speed] in the order SinewGaitCycles.build uses them
	if aset:
		var seen := {}
		for role: StringName in [aset.gait_walk, aset.gait_run, aset.gait_sprint, aset.gait_back, aset.gait_left, aset.gait_right]:
			if role == &"":
				continue
			var clip := String(drv.anim_set.clip(role))
			if clip == "" or seen.has(clip):
				continue
			seen[clip] = true
			named.append([String(role), clip, drv.anim_set.speed_of(role, 1.3)])
	var out := []
	for f: Dictionary in facts:
		var e := f.duplicate()
		e["role"] = "?"
		e["clip"] = "?"
		for n: Array in named:
			if absf(float(n[2]) - float(f.speed)) < 1e-3:
				e["role"] = n[0]
				e["clip"] = n[1]
		out.append(e)
	return out


## Rules every reference clip should meet; returns the broken ones as messages.
static func rules(entries: Array, profile: MovementProfile) -> Array:
	var bad := []
	var forward := []
	for e: Dictionary in entries:
		var who := "%s (%s)" % [e.role, e.clip]
		var ang := absf(float(e.angle))
		var side := absf(ang - PI / 2.0) < 0.6
		if float(e.stride) <= 0.0:
			bad.append("%s: no leg paths read (the clip's feet never plant?)" % who)
			continue
		if float(e.cadence) < 1.0 or float(e.cadence) > 5.5:
			bad.append("%s: %.1f steps/s - not a walking / running cycle (a whole stride per clip?)" % [who, e.cadence])
		if float(e.duty) < 0.2 or float(e.duty) > 0.8:
			bad.append("%s: feet on the ground %.0f %% of the cycle - stylised or not a loop" % [who, float(e.duty) * 100.0])
		if absf(float(e.true_speed) - float(e.speed)) > 0.35 * maxf(float(e.speed), 0.3):
			bad.append("%s: authored %.2f m/s but its planted feet move at %.2f - the feet will skate" % [who, e.speed, e.true_speed])
		# A run's feet land near the midline and a sprint's a little across it (S_Fast: -8 cm) - the gait keeps them
		# apart; a walk's crossing is a stylised (catwalk) clip. Only side steps may cross over freely.
		var cross_ok := -0.12 if float(e.speed) > 3.0 else 0.0
		if bool(e.crossover) and not side and float(e.width_min) < cross_ok:
			bad.append("%s: the feet cross over (%.0f cm) - only side steps (and runs, a little) may: legs pass through each other" % [who, float(e.width_min) * 100.0])
		if float(e.width_max) > 0.65:
			bad.append("%s: the feet spread %.0f cm apart - the hips sink to reach them" % [who, float(e.width_max) * 100.0])
		if ang < 0.6:
			forward.append(e)
		if e.role.contains("back") and ang < 2.5:
			bad.append("%s: a back clip that travels %.0f deg off backwards" % [who, rad_to_deg(PI - ang)])
		if (e.role.contains("left") or e.role.contains("strafe_l")) and not (float(e.angle) > 0.9 and float(e.angle) < 2.2):
			bad.append("%s: a left side step that travels %.0f deg off the left" % [who, rad_to_deg(float(e.angle))])
	# The forward cycles stand in for the motor's walk / jog / sprint, slowest first.
	forward.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.speed) < float(b.speed))
	var motor := [profile.walk_speed, profile.jog_speed, profile.sprint_speed]
	for k in mini(forward.size(), 3):
		var e: Dictionary = forward[k]
		if absf(float(e.speed) - motor[k]) > 0.35 * motor[k]:
			bad.append("%s: %.2f m/s against the motor's %s %.2f - the gait would stretch it %.0f %%" % ["%s (%s)" % [e.role, e.clip],
					e.speed, ["walk", "jog", "sprint"][k], motor[k], (motor[k] / float(e.speed) - 1.0) * 100.0])
	return bad


## Differences against a baseline (both from report()); [] = the same clips, read the same way.
static func diff(entries: Array, baseline: Array) -> Array:
	var out := []
	var by_role := {}
	for b: Dictionary in baseline:
		by_role[b.role] = b
	for e: Dictionary in entries:
		if not by_role.has(e.role):
			out.append("%s: new reference cycle (%s)" % [e.role, e.clip])
			continue
		var b: Dictionary = by_role[e.role]
		by_role.erase(e.role)
		if String(b.clip) != String(e.clip):
			out.append("%s: clip changed %s -> %s" % [e.role, b.clip, e.clip])
		for k: String in TOLERANCE:
			if b.has(k) and e.has(k) and absf(float(e[k]) - float(b[k])) > float(TOLERANCE[k]):
				out.append("%s: %s %.3f -> %.3f" % [e.role, k, float(b[k]), float(e[k])])
		if b.has("crossover") and bool(b.crossover) != bool(e.crossover):
			out.append("%s: crossover %s -> %s" % [e.role, b.crossover, e.crossover])
	for role: String in by_role:
		out.append("%s: reference cycle gone (%s)" % [role, by_role[role].clip])
	return out


static func load_baseline() -> Array:
	if not FileAccess.file_exists(BASELINE):
		return []
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(BASELINE))
	return data.get("cycles", []) if data is Dictionary else []


static func save_baseline(entries: Array) -> void:
	var f := FileAccess.open(BASELINE, FileAccess.WRITE)
	f.store_string(JSON.stringify({"note": "Sinew gait reference clips as read by Gait::clip_report - see sinew/ANIMATION_GUIDE.md",
			"cycles": entries}, "  "))
	f.close()


## A readable table of a report.
static func table(entries: Array) -> String:
	var lines := ["%-10s %-24s %6s %6s %6s %6s %6s %6s %7s %7s %5s" % ["role", "clip", "m/s", "true", "stride", "steps", "duty",
			"angle", "w min", "w max", "cross"]]
	for e: Dictionary in entries:
		lines.append("%-10s %-24s %6.2f %6.2f %6.2f %6.2f %6.2f %6.0f %6.0fcm %6.0fcm %5s" % [e.role, String(e.clip).right(24),
				e.speed, e.true_speed, e.stride, e.cadence, e.duty, rad_to_deg(float(e.angle)), float(e.width_min) * 100.0,
				float(e.width_max) * 100.0, "yes" if e.crossover else "no"])
	return "\n".join(lines)
