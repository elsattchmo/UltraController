class_name ZombieSenses
extends RefCounted
## What a zombie perceives. Pure functions of the world (physics queries) and the two characters:
## no animation, skeleton or render state, so server, offline and replay all agree.
##
## Sight: a cone (`sight_fov_deg` half-angle... the full arc is twice it) out to `sight_range`, scaled by
## how the target moves (still x0.7, sprinting x1.4) and holds itself (crouched x0.65, prone x0.4); a
## close sense (`close_sense` m) works from any side. Two rays (chest, head) from the eye must reach
## the target through WORLD_STATIC / WORLD_DYNAMIC geometry - a closed door blocks them.
## Hearing: a noise of loudness L carries `L x hearing` metres, +6 m of distance for every floor between
## and +5 m for every wall in the way (3 for a shut door), up to three of them.

const MASK := UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC
const FLOOR_HEIGHT := 3.65

static var _ray := PhysicsRayQueryParameters3D.new()


static func eye(c: UltraCharacter) -> Vector3:
	return c.state.pos + Vector3.UP * (c.state.height - 0.16)


static func forward(c: UltraCharacter) -> Vector3:
	return Vector3(-sin(c.state.body_yaw), 0.0, -cos(c.state.body_yaw))


## Is there a clear line from `a` to `b` (static world only), ignoring `exclude`?
static func clear_line(space: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3, exclude: Array[RID]) -> bool:
	_ray.from = a
	_ray.to = b
	_ray.collision_mask = MASK
	_ray.exclude = exclude
	_ray.hit_from_inside = false
	return space.intersect_ray(_ray).is_empty()


## How well `z` sees `t` right now: 0 not at all .. 1 right in front of its nose.
static func sight(z: UltraCharacter, a: ZombieArchetype, t: UltraCharacter, space: PhysicsDirectSpaceState3D) -> float:
	var e := eye(z)
	var chest := t.state.pos + Vector3.UP * minf(t.state.height * 0.65, 1.3)
	var to := chest - e
	var d := to.length()
	var motion := Vector2(t.state.vel.x, t.state.vel.z).length()
	var mult := 1.0
	if t.state.stance == MotorState.Stance.CRAWL:
		mult = 0.4
	elif t.state.stance == MotorState.Stance.CROUCH:
		mult = 0.65
	if motion < 0.3:
		mult *= 0.7
	elif t.state.has(MotorState.F_SPRINTING):
		mult *= 1.4
	var range_ := a.sight_range * mult
	var close := d <= a.close_sense
	if d > range_ and not close:
		return 0.0
	if not close:
		var flat := Vector3(to.x, 0.0, to.z)
		if flat.length() > 0.05:
			var ang := acos(clampf(forward(z).dot(flat.normalized()), -1.0, 1.0))
			if ang > deg_to_rad(a.sight_fov_deg):
				return 0.0
	var ex: Array[RID] = [z.get_rid()]
	if z.hit_volume:
		ex.append(z.hit_volume.get_rid())
	var head := t.state.pos + Vector3.UP * maxf(t.state.height - 0.15, 0.3)
	if not clear_line(space, e, chest, ex) and not clear_line(space, e, head, ex):
		return 0.0
	return clampf(1.0 - d / maxf(range_, 0.1), 0.15, 1.0)


## Does `z` hear a noise of `loud` metres at `pos`?
static func hears(z: UltraCharacter, a: ZombieArchetype, pos: Vector3, loud: float, space: PhysicsDirectSpaceState3D) -> bool:
	var reach := loud * a.hearing
	var zp := z.state.pos + Vector3.UP * 1.2
	var d := zp.distance_to(pos)
	if d > reach:
		return false
	var cost := d + 6.0 * absf(roundf((zp.y - pos.y) / FLOOR_HEIGHT))
	if cost > reach:
		return false
	# Walls between: up to three, each +5 m (a shut door +3).
	var from := pos
	var ex: Array[RID] = [z.get_rid()]
	if z.hit_volume:
		ex.append(z.hit_volume.get_rid())
	for k in 3:
		_ray.from = from
		_ray.to = zp
		_ray.collision_mask = MASK
		_ray.exclude = ex
		var hit := space.intersect_ray(_ray)
		if hit.is_empty():
			break
		# (A floor or ceiling is already paid for - 6 m a floor - only upright surfaces are walls.)
		if absf((hit.normal as Vector3).y) < 0.5:
			var door := (hit.collider as Node).get_parent() as UltraDoor if hit.collider is Node else null
			cost += 3.0 if door != null else 5.0
		if cost > reach:
			return false
		var dir := (zp - from).normalized()
		from = hit.position + dir * 0.08
	return cost <= reach
