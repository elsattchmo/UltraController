class_name UltraHitboxes
extends RefCounted
## Which body region a shot hit: a ray against the BodyProfile's region capsules, placed at the
## character's (possibly rewound) position and yaw and bent to its stance. Pure maths, so the
## server needs no skeleton; the capsule collider still decides *whether* a character was hit.

const Id := MotorState.Id


## Region capsules in world space for character `c` standing at `pos`.
static func capsules(c: UltraCharacter, pos: Vector3) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var bp := c.body_profile
	if bp == null or bp.hitboxes.is_empty():
		return out
	var s := c.state
	var xf := Transform3D(Basis(Vector3.UP, s.body_yaw), pos)
	var stand := c.profile.stand_height if c.profile else 1.8
	var k := clampf(s.height / stand, 0.3, 1.0)
	var prone := s.state in [Id.CRAWL, Id.DIVE, Id.DEAD, Id.RAGDOLL] or (s.state == Id.SWIM and Vector2(s.vel.x, s.vel.z).length() > 0.6)
	for h: Dictionary in bp.hitboxes:
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
	var best := UltraLimbs.Region.TORSO
	var best_d := INF
	for cap in capsules(c, c.state.pos):
		var q := Geometry3D.get_closest_point_to_segment(p, cap.a, cap.b)
		var dd := q.distance_to(p) - float(cap.r)
		if dd < best_d:
			best_d = dd
			best = cap.region
	return best


## Entry distance of a ray into a capsule (approximate at the caps), -1 if it misses.
static func _ray_capsule(o: Vector3, d: Vector3, a: Vector3, b: Vector3, r: float) -> float:
	var pts := Geometry3D.get_closest_points_between_segments(o, o + d * 1000.0, a, b)
	var dist := (pts[0] as Vector3).distance_to(pts[1])
	if dist > r:
		return -1.0
	var t := (pts[0] as Vector3).distance_to(o)
	return maxf(t - sqrt(r * r - dist * dist), 0.0)
