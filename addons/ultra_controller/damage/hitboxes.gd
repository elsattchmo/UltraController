class_name UltraHitboxes
extends RefCounted
## Which body region a shot hit: a ray against region capsules placed at the character's
## (possibly rewound) position and yaw. Where the character has a posed skeleton (single
## player, host, listen server) the capsules follow the live pose - crouch, lean, aimed arms,
## stride, a ragdoll lying any way round. A headless server falls back to the BodyProfile's
## capsules baked from the idle pose, bent to the stance. Severed regions can't be hit.

const Id := MotorState.Id


## Region capsules in world space for character `c` standing at `pos`.
static func capsules(c: UltraCharacter, pos: Vector3) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var s := c.state
	var xf := Transform3D(Basis(Vector3.UP, s.body_yaw), pos)
	if c.has_live_hitboxes():
		for h: Dictionary in c.live_hitboxes:
			if not (s.severed >> int(h.region)) & 1:
				out.append({"region": int(h.region), "a": xf * (h.a as Vector3), "b": xf * (h.b as Vector3), "r": float(h.r)})
		return out
	var bp := c.body_profile
	if bp == null or bp.hitboxes.is_empty():
		return out
	var stand := c.profile.stand_height if c.profile else 1.8
	var k := clampf(s.height / stand, 0.3, 1.0)
	var prone := s.state in [Id.CRAWL, Id.DIVE, Id.DEAD, Id.RAGDOLL] or (s.state == Id.SWIM and Vector2(s.vel.x, s.vel.z).length() > 0.6)
	for h: Dictionary in bp.hitboxes:
		if (s.severed >> int(h.region)) & 1:
			continue
		var a: Vector3 = h.a
		var b: Vector3 = h.b
		if prone:
			# Lying along the facing direction, hips at the capsule's middle height.
			a = _lay(a, s.height * 0.5)
			b = _lay(b, s.height * 0.5)
		elif k < 0.99:
			a.y *= k
			b.y *= k
		out.append({"region": int(h.region), "a": xf * a, "b": xf * b, "r": float(h.r)})
	return out


## The region capsules from bone positions: `p.call(bone_name) -> Vector3` in character space
## (feet at the origin, -Z forward); `head_up` the head bone's up axis (crown direction).
## Shared by the baking tool and the live pose.
static func build(p: Callable, head_up := Vector3.ZERO) -> Array[Dictionary]:
	var R := UltraLimbs.Region
	var boxes: Array[Dictionary] = []
	var cap := func(region: int, a: Vector3, b: Vector3, r: float) -> void:
		boxes.append({"region": region, "a": a, "b": b, "r": r})
	var head: Vector3 = p.call("Head")
	var neck: Vector3 = p.call("Neck")
	var up := head_up.normalized() if head_up != Vector3.ZERO else Vector3.UP
	cap.call(R.HEAD, head + up * 0.06, head + up * 0.17, 0.11)
	cap.call(R.TORSO, p.call("Hips"), p.call("Chest"), 0.16)
	cap.call(R.TORSO, p.call("Chest"), neck, 0.17)
	for side: String in ["Left", "Right"]:
		var l: bool = side == "Left"
		var hand: Vector3 = p.call(side + "Hand")
		var lower: Vector3 = p.call(side + "LowerArm")
		cap.call(R.ARM_L if l else R.ARM_R, p.call(side + "UpperArm"), lower, 0.065)
		cap.call(R.FOREARM_L if l else R.FOREARM_R, lower, hand, 0.05)
		cap.call(R.HAND_L if l else R.HAND_R, hand, hand + (hand - lower).normalized() * 0.1, 0.05)
		var knee: Vector3 = p.call(side + "LowerLeg")
		var foot: Vector3 = p.call(side + "Foot")
		var toes: Vector3 = p.call(side + "Toes")
		cap.call(R.THIGH_L if l else R.THIGH_R, p.call(side + "UpperLeg"), knee, 0.09)
		cap.call(R.SHIN_L if l else R.SHIN_R, knee, foot, 0.065)
		cap.call(R.FOOT_L if l else R.FOOT_R, foot + Vector3.UP * 0.02, toes + (toes - foot).normalized() * 0.04, 0.05)
	return boxes


## The heart (world) of `c` standing at `pos`: in the upper torso capsule, 30 % up from the
## chest, 6 cm in front of its axis and 3.5 cm to the left. Vector3.INF without a torso.
static func heart(c: UltraCharacter, pos: Vector3) -> Vector3:
	var torso: Array[Dictionary] = []
	for h in capsules(c, pos):
		if int(h.region) == UltraLimbs.Region.TORSO:
			torso.append(h)
	if torso.size() < 2:
		return Vector3.INF
	var chest: Vector3 = torso[1].a
	var neck: Vector3 = torso[1].b
	var up := (neck - chest).normalized()
	var yaw := c.state.body_yaw
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	fwd = fwd - up * fwd.dot(up)
	if fwd.length() < 0.2:
		fwd = Vector3.DOWN - up * Vector3.DOWN.dot(up)          # (lying: the chest faces the ground)
	fwd = fwd.normalized()
	var left := fwd.cross(up).normalized()
	return chest + (neck - chest) * 0.3 + fwd * 0.06 + left * 0.035


## Bones `build` reads.
const BONES := ["Head", "Neck", "Hips", "Chest", "LeftHand", "LeftLowerArm", "LeftUpperArm",
	"LeftLowerLeg", "LeftFoot", "LeftToes", "LeftUpperLeg", "RightHand", "RightLowerArm",
	"RightUpperArm", "RightLowerLeg", "RightFoot", "RightToes", "RightUpperLeg"]


## The region capsule nearest to `p`: {region, d (to its surface, < 0 inside), point (on it)}.
static func closest(c: UltraCharacter, p: Vector3) -> Dictionary:
	var best := {"region": UltraLimbs.Region.TORSO, "d": INF, "point": c.state.pos + Vector3.UP}
	for cap in capsules(c, c.state.pos):
		var q := Geometry3D.get_closest_point_to_segment(p, cap.a, cap.b)
		var dd := q.distance_to(p) - float(cap.r)
		if dd < float(best.d):
			best = {"region": cap.region, "d": dd, "point": q + (p - q).normalized() * float(cap.r)}
	return best


static func _lay(p: Vector3, y0: float) -> Vector3:
	return Vector3(p.x, y0 + p.z * 0.3, -(p.y - 0.95))      # rotate -90 deg about X around the hips


## First region the ray o + d*t (t <= max_t) passes through, or {} if it slips past the body.
static func raycast(c: UltraCharacter, pos: Vector3, o: Vector3, d: Vector3, max_t := 1000.0) -> Dictionary:
	var best := {}
	var best_t := max_t
	for cap in capsules(c, pos):
		var t := _ray_capsule(o, d, cap.a, cap.b, cap.r)
		if t >= 0.0 and t < best_t:
			best_t = t
			best = {"region": cap.region, "t": t, "point": o + d * t}
	return best


## Region nearest to a point (explosions, falls, scripted damage).
static func nearest(c: UltraCharacter, p: Vector3) -> int:
	return int(closest(c, p).region)


## Entry distance of a ray into a capsule (approximate at the caps), -1 if it misses.
static func _ray_capsule(o: Vector3, d: Vector3, a: Vector3, b: Vector3, r: float) -> float:
	var pts := Geometry3D.get_closest_points_between_segments(o, o + d * 1000.0, a, b)
	var dist := (pts[0] as Vector3).distance_to(pts[1])
	if dist > r:
		return -1.0
	var t := (pts[0] as Vector3).distance_to(o)
	return maxf(t - sqrt(r * r - dist * dist), 0.0)
