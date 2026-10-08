class_name MarksmanClipAudit
extends RefCounted
## The clip audit (SinewClipAudit) per stance group: what the gait read off every reference cycle of every
## stance, the same sanity rules (forward clips against the motor's speeds for that posture: walk / jog /
## sprint standing, the crouch speed crouched), and a committed baseline per controller
## (addons/marksman/clip_audit.json). See sinew/ANIMATION_GUIDE.md "Stance sets".

const BASELINE := "res://addons/marksman/clip_audit.json"


## One entry per reference cycle: SinewClipAudit's facts + group (name), role, clip.
static func report(c: SinewCharacter) -> Array:
	var r := c.ragdoll as SinewRagdoll
	var aset := c.anim.anim_set as MarksmanStanceSet
	if r == null or r.world == null or aset == null:
		return []
	var facts: Array = r.world.physics.call("character_gait_clip_report", r._id)
	var out := []
	var used := {}
	for f: Dictionary in facts:
		var e := f.duplicate()
		var gi := int(f.get("group", 0))
		var g: Dictionary = aset.groups[gi] if gi < aset.groups.size() else {}
		e["group_name"] = g.get("name", "?")
		e["role"] = "?"
		e["clip"] = "?"
		for role in g.get("cycles", []):
			var key := "%d|%s" % [gi, role]
			if used.has(key):
				continue
			if absf(aset.speed_of(StringName(role), 1.3) - float(f.speed)) < 1e-3:
				e["role"] = "%s/%s" % [e.group_name, role]
				e["clip"] = String(aset.clip(StringName(role)))
				used[key] = true
				break
		out.append(e)
	return out


static func rules(entries: Array, profile: MovementProfile) -> Array:
	var bad := []
	var by_group := {}
	for e: Dictionary in entries:
		var gn: String = e.group_name
		if not by_group.has(gn):
			by_group[gn] = []
		by_group[gn].append(e)
	for gn: String in by_group:
		var crouch := gn.ends_with("_crouch")
		var p := profile.duplicate() as MovementProfile
		if crouch:
			# (Crouched the motor moves at one speed: every forward clip stands in for it.)
			p.walk_speed = profile.crouch_speed
			p.jog_speed = profile.crouch_speed
			p.sprint_speed = profile.crouch_speed
		for msg: String in SinewClipAudit.rules(by_group[gn], p):
			bad.append(msg)
	bad.append_array(direction_rules(entries))
	return bad


## Direction role suffixes -> the way that clip must travel (rad off forward, + left).
const DIR_ANGLE := {"_f": 0.0, "_fl": PI / 4.0, "_l": PI / 2.0, "_bl": 3.0 * PI / 4.0, "_b": PI, "_br": -3.0 * PI / 4.0,
		"_r": -PI / 2.0, "_fr": -PI / 4.0, "strafe_l": PI / 2.0, "strafe_r": -PI / 2.0}


## A clip named for a direction must travel that way (within 25 deg).
static func direction_rules(entries: Array) -> Array:
	var bad := []
	for e: Dictionary in entries:
		var role := String(e.role)
		for suf: String in DIR_ANGLE:
			if role.ends_with(suf):
				var off := absf(angle_difference(float(e.angle), DIR_ANGLE[suf]))
				if off > deg_to_rad(25.0):
					bad.append("%s (%s): named %s but travels %.0f deg off it" % [role, e.clip, suf, rad_to_deg(off)])
				break
	return bad


static func load_baseline() -> Array:
	if not FileAccess.file_exists(BASELINE):
		return []
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(BASELINE))
	return data.get("cycles", []) if data is Dictionary else []


static func save_baseline(entries: Array) -> void:
	var f := FileAccess.open(BASELINE, FileAccess.WRITE)
	f.store_string(JSON.stringify({"note": "Marksman's stance reference clips as read by Gait::clip_report - see sinew/ANIMATION_GUIDE.md",
			"cycles": entries}, "  "))
	f.close()


static func table(entries: Array) -> String:
	return SinewClipAudit.table(entries)
