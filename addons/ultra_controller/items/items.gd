class_name UltraItems
extends RefCounted
## Server-side item operations: pick up, drop, use, grant. All inventory changes go through
## here (or Inventory directly on the server) and are then replicated to the owner.


static func pickup(c: UltraCharacter, world_item: Node3D) -> bool:
	if not UltraNet.is_server() or world_item == null:
		return false
	var wi := world_item as WorldItem
	if wi == null:
		return false
	var inst := wi.make_instance()
	var left := c.inventory.add(inst)
	if left == inst.count:
		UltraNet.world.broadcast(&"pickup_failed", [c.net_id, "Too heavy" if not c.inventory.fits(inst) else "Inventory full"], true)
		return false
	c.inventory_changed_by_server()
	var o := wi.find_child("NetObject", false, false) as NetObject
	if left == 0:
		if o:
			UltraNet.world.despawn(o.net_id)
		else:
			wi.queue_free()
	else:
		wi.count = left
		if o:
			o.mark_dirty()
	UltraNet.world.broadcast(&"pickup", [c.net_id, String(inst.def_id), inst.count - left], true)
	return true


## Spawn an item into the world in front of the character (dropping or throwing).
static func drop_into_world(c: UltraCharacter, inst: ItemInstance, extra_vel: Vector3) -> Node3D:
	var def := inst.def()
	if def == null or def.world_scene == null:
		return null
	# Let fall from the hands, just in front of the feet: it drops, tumbles and settles.
	var fwd := Vector3(-sin(c.state.body_yaw), 0, -cos(c.state.body_yaw))
	var at := c.state.pos + Vector3.UP * (c.state.height * 0.55) + fwd * 0.3
	var tilt := Basis(Vector3.RIGHT, randf_range(-0.5, 0.5)) * Basis(Vector3.FORWARD, randf_range(-0.6, 0.6))
	var xf := Transform3D(Basis(Vector3.UP, c.state.body_yaw) * tilt, at)
	var vel := c.state.vel * 0.6 + fwd * 0.4 + extra_vel
	return UltraNet.world.spawn(def.world_scene.resource_path, xf, {"item_id": inst.def_id, "count": inst.count, "item_data": inst.data}, vel)


static func use_item(c: UltraCharacter, slot: int) -> void:
	var it := c.inventory.get_slot(slot)
	if it == null or it.def() == null:
		return
	var def := it.def()
	if def.kind == ItemDefinition.Kind.CONSUMABLE:
		if def.consumable_heal > 0.0 and c.state.hp < 100.0:
			c.state.hp = minf(c.state.hp + def.consumable_heal, 100.0)
			c.inventory.remove_slot(slot, 1)
			UltraNet.world.broadcast(&"used", [c.net_id, String(def.id)], true)


static func give(c: UltraCharacter, id: StringName, n := 1) -> int:
	if ItemDB.get_def(id) == null:
		push_warning("unknown item " + id)
		return n
	var left := c.inventory.add(ItemInstance.make(id, n))
	c.inventory_changed_by_server()
	return left


## Server: B_INTERACT on the object the client named. Validates reach.
static func interact(c: UltraCharacter, target_id: int) -> void:
	var o := UltraNet.world.get_object(target_id)
	if o == null:
		return
	var it := Interactable.find_on(o.get_parent())
	if it == null or not it.enabled:
		return
	var eye := c.state.pos + Vector3.UP * (c.state.height - 0.16)
	var tp := it.target().global_position
	if eye.distance_to(tp) > it.max_distance + 0.8:
		return
	it.interact(c)
