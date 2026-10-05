class_name UltraCombat
extends RefCounted
## Server-side hit resolution. Hitscan is lag-compensated: other characters are rewound to
## where the shooter saw them. Effects go out as events (`impact`, `hit`); the shooter already
## predicted its own muzzle flash / tracer / impact.

class DamageInfo:
	var amount := 0.0
	var dir := Vector3.FORWARD
	var point := Vector3.ZERO
	var normal := Vector3.UP
	var attacker_id := 0
	var kind := &"bullet"
	var collider: Object
	var shape := 0
	var region := -1                ## UltraLimbs.Region, -1 = work it out from the point
	## Knock-back (m/s, world): a shotgun blast's shove on the whole body - past
	## UltraCharacter.SHOVE_KNOCKDOWN it knocks you over, a lighter one rocks you back.
	var shove := Vector3.ZERO


const MASK := UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC | UltraLayers.CHARACTER | UltraLayers.HITBOX


static func hitscan(shooter: UltraCharacter, origin: Vector3, dir: Vector3, def: ItemDefinition) -> Dictionary:
	var space := shooter.get_world_3d().direct_space_state
	var excl: Array[RID] = [shooter.get_rid()]
	if shooter.hit_volume:
		excl.append(shooter.hit_volume.get_rid())
	var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * float(def.stat("range", 100.0)), MASK, excl)
	var hit: Dictionary = UltraNet.world.rewound(shooter, func() -> Dictionary: return _cast(space, q, origin, dir))
	if hit.is_empty():
		return {}
	var info := DamageInfo.new()
	info.amount = float(def.stat("damage", 10.0))
	info.dir = dir
	info.point = hit.position
	info.normal = hit.normal
	info.attacker_id = shooter.net_id
	info.collider = hit.collider
	info.shape = int(hit.get("shape", 0))
	info.region = int(hit.get("region", -1))
	apply(info, float(def.stat("impulse", 4.0)))
	var kind := &"flesh" if UltraCharacter.of_collider(hit.collider) else &"surface"
	var shooter_peer := 0
	var sp: NetPlayer = UltraNet.players.get(shooter.net_id)
	if sp and sp.role == NetPlayer.Role.AUTHORITY_REMOTE:
		shooter_peer = sp.peer_id
	UltraNet.world.broadcast(&"impact", [info.point, info.normal, kind, shooter.net_id], false, shooter_peer)
	return hit


## Buckshot: every pellet resolved like a bullet (lag-compensated, through limbs), then the
## pellets that struck the same region of the same character are dealt as ONE hit (their damage
## summed, kind `buckshot`): a close, tight pattern on a limb is far past its health and takes
## it off; a spread pattern at range just wounds. Everything else takes each pellet.
static func hitscan_pellets(shooter: UltraCharacter, origin: Vector3, dirs: Array, def: ItemDefinition) -> Array:
	var space := shooter.get_world_3d().direct_space_state
	var excl: Array[RID] = [shooter.get_rid()]
	if shooter.hit_volume:
		excl.append(shooter.hit_volume.get_rid())
	var rng := float(def.stat("range", 100.0))
	var hits: Array = UltraNet.world.rewound(shooter, func() -> Array:
		var out := []
		for d: Vector3 in dirs:
			var q := PhysicsRayQueryParameters3D.create(origin, origin + d * rng, MASK, excl.duplicate())
			var h := _cast(space, q, origin, d)
			if not h.is_empty():
				h["dir"] = d
				out.append(h)
		return out)
	var per := float(def.stat("damage", 10.0))
	var impulse := float(def.stat("impulse", 4.0))
	var groups := {}           # [character, region] -> DamageInfo
	var shooter_peer := 0
	var sp: NetPlayer = UltraNet.players.get(shooter.net_id)
	if sp and sp.role == NetPlayer.Role.AUTHORITY_REMOTE:
		shooter_peer = sp.peer_id
	for h: Dictionary in hits:
		var who := UltraCharacter.of_collider(h.collider)
		var info := DamageInfo.new()
		info.amount = per
		info.dir = h.dir
		info.point = h.position
		info.normal = h.normal
		info.attacker_id = shooter.net_id
		info.collider = h.collider
		info.shape = int(h.get("shape", 0))
		info.region = int(h.get("region", -1))
		UltraNet.world.broadcast(&"impact", [info.point, info.normal, &"flesh" if who else &"surface", shooter.net_id], false, shooter_peer)
		if who:
			var key := "%d:%d" % [who.get_instance_id(), info.region]
			if groups.has(key):
				var g: DamageInfo = groups[key]
				g.amount += per
				g.dir = (g.dir + info.dir).normalized()
			else:
				info.kind = &"buckshot"
				groups[key] = info
			continue
		apply(info, impulse)
	# The blast's shove on each character hit: how much of the load struck (fraction of the
	# pellets) and how close (full within ~3 m, fading out by ~20 m) - point blank lifts them
	# off their feet; a few stray pellets at range barely rock them. Given with the character's
	# first group so it lands once.
	var n := float(dirs.size())
	var shoved := {}
	for g: DamageInfo in groups.values():
		var who := UltraCharacter.of_collider(g.collider)
		if who == null or shoved.has(who.get_instance_id()):
			continue
		shoved[who.get_instance_id()] = true
		var count := 0.0
		var dir := Vector3.ZERO
		for g2: DamageInfo in groups.values():
			if UltraCharacter.of_collider(g2.collider) == who:
				count += g2.amount / per
				dir += g2.dir * g2.amount
		var near := 1.0 - smoothstep(3.0, 20.0, origin.distance_to(g.point))
		dir = Vector3(dir.x, 0.0, dir.z).normalized()
		g.shove = dir * float(def.stat("knockback", 9.0)) * (count / n) * lerpf(0.15, 1.0, near)
	for g: DamageInfo in groups.values():
		apply(g, impulse * g.amount / per)
	return hits


## A melee blow (swing `sw` from UltraActionLayer.melee_swing): rays fanned across the aim from
## the eye out to the swing's reach, characters through their limbs (lag-compensated like a
## shot). The nearest thing struck takes it - a character first if any ray finds one. With
## `deal`, the authority deals the damage (and the shove: a club rocks you, a big one floors
## you; to the head it knocks you out); without, it's the predicting client's look (effects).
## Returns {hit, point, normal, dir, character (net id or 0), region}.
static func melee_sweep(c: UltraCharacter, s: MotorState, i: InputFrame, sw: Dictionary, deal: bool) -> Dictionary:
	var space := c.get_world_3d().direct_space_state
	var excl: Array[RID] = [c.get_rid()]
	if c.hit_volume:
		excl.append(c.hit_volume.get_rid())
	var eye := s.pos + Vector3.UP * (s.height - 0.16)
	var reach := float(sw.reach)
	var probe := func() -> Dictionary:
		var best := {}
		var best_d := INF
		for off_deg: float in [0.0, -14.0, 14.0, -28.0, 28.0]:
			var d := UltraActionLayer.gun_dir(i.yaw + deg_to_rad(off_deg), i.pitch, Vector2.ZERO)
			var q := PhysicsRayQueryParameters3D.create(eye, eye + d * reach, MASK, excl.duplicate())
			var h := _cast(space, q, eye, d)
			if h.is_empty():
				continue
			h["dir"] = d
			var who := UltraCharacter.of_collider(h.collider)
			# Characters first, then the ray nearest the aim (aim at an arm, hit the arm).
			var dist := eye.distance_to(h.position) * 0.01 + absf(off_deg) - (1000.0 if who else 0.0)
			if dist < best_d:
				best_d = dist
				best = h
		return best
	var hit: Dictionary = UltraNet.world.rewound(c, probe) if deal else probe.call()
	if hit.is_empty():
		return {"hit": false}
	var dir: Vector3 = hit.dir
	var who := UltraCharacter.of_collider(hit.collider)
	var out := {"hit": true, "point": hit.position, "normal": hit.normal, "dir": dir, "character": who.net_id if who else 0, "region": int(hit.get("region", -1))}
	if deal:
		var info := DamageInfo.new()
		info.amount = float(sw.damage)
		info.kind = StringName(sw.kind)
		info.dir = dir
		info.point = hit.position
		info.normal = hit.normal
		info.attacker_id = c.net_id
		info.collider = hit.collider
		info.region = int(hit.get("region", -1))
		var flat := Vector3(dir.x, 0.0, dir.z).normalized()
		if who:
			info.shove = flat * float(sw.knockback)
		apply(info, float(sw.get("impulse", 8.0)))
		var sp: NetPlayer = UltraNet.players.get(c.net_id)
		var peer := sp.peer_id if sp and sp.role == NetPlayer.Role.AUTHORITY_REMOTE else 0
		UltraNet.world.broadcast(&"impact", [info.point, info.normal, &"flesh" if who else &"surface", c.net_id], false, peer)
	return out


## The shot's ray resolved like a real shot (characters only through a limb) - for the HUD's
## gun dot (no lag compensation: the local view).
static func trace(space: PhysicsDirectSpaceState3D, q: PhysicsRayQueryParameters3D, origin: Vector3, dir: Vector3) -> Dictionary:
	return _cast(space, q, origin, dir)


## A ray that knows bodies aren't capsules: a character's capsule only counts if the ray also
## passes through one of its limbs (checked where the character *was*, under lag compensation);
## otherwise the shot carries on past it.
static func _cast(space: PhysicsDirectSpaceState3D, q: PhysicsRayQueryParameters3D, origin: Vector3, dir: Vector3) -> Dictionary:
	for _i in 4:
		var hit := space.intersect_ray(q)
		var c := UltraCharacter.of_collider(hit.get("collider")) if not hit.is_empty() else null
		if c == null:
			return hit
		var xf: Transform3D = PhysicsServer3D.body_get_state(c.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM)
		var rh := UltraHitboxes.raycast(c, xf.origin, origin, dir)
		if not rh.is_empty():
			hit.collider = c
			hit.region = rh.region
			hit.position = rh.point
			return hit
		var ex := q.exclude
		ex.append(c.get_rid())
		if c.hit_volume:
			ex.append(c.hit_volume.get_rid())
		q.exclude = ex
	return {}


## Deliver damage + impulse to whatever was hit (characters, damageables, rigid bodies).
static func apply(info: DamageInfo, impulse: float) -> void:
	var col := info.collider
	var target: Object = col
	# Hitboxes and child colliders forward to the nearest damageable ancestor.
	while target is Node and not (target is UltraCharacter) and not (target as Node).has_method("take_damage"):
		target = (target as Node).get_parent()
		if target == null or target is Window:
			target = null
			break
	if target is UltraCharacter:
		(target as UltraCharacter).apply_damage(info)
	elif target and target.has_method("take_damage"):
		target.call("take_damage", info)
	else:
		var br := UltraBreakable.find_on(col)
		if br:
			br.take_damage(info)
	if col is RigidBody3D and not (col as RigidBody3D).freeze:
		var rb := col as RigidBody3D
		rb.apply_impulse(info.dir * impulse, info.point - rb.global_position)
