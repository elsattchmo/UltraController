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


const MASK := UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC | UltraLayers.CHARACTER | UltraLayers.HITBOX


static func hitscan(shooter: UltraCharacter, origin: Vector3, dir: Vector3, def: ItemDefinition) -> Dictionary:
	var space := shooter.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * float(def.stat("range", 100.0)), MASK, [shooter.get_rid()])
	var hit: Dictionary = UltraNet.world.rewound(shooter, func() -> Dictionary: return space.intersect_ray(q))
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
	apply(info, float(def.stat("impulse", 4.0)))
	var kind := &"flesh" if hit.collider is UltraCharacter else &"surface"
	var shooter_peer := 0
	var sp: NetPlayer = UltraNet.players.get(shooter.net_id)
	if sp and sp.role == NetPlayer.Role.AUTHORITY_REMOTE:
		shooter_peer = sp.peer_id
	UltraNet.world.broadcast(&"impact", [info.point, info.normal, kind, shooter.net_id], false, shooter_peer)
	return hit


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
	if col is RigidBody3D and not (col as RigidBody3D).freeze:
		var rb := col as RigidBody3D
		rb.apply_impulse(info.dir * impulse, info.point - rb.global_position)
