class_name WorldItem
extends RigidBody3D
## An item lying in the world. Interact to pick it up (or grab it physically, M5).
## Spawned by the server with {item_id, count, item_data}; level designers can also place
## one and set `item_id`/`count` in the inspector.

@export var item_id: StringName
@export var count := 1
var item_data: Dictionary = {}


func _ready() -> void:
	collision_layer = UltraLayers.WORLD_DYNAMIC | UltraLayers.INTERACTABLE
	collision_mask = UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC
	var def := ItemDB.get_def(item_id)
	if def:
		mass = maxf(def.mass * count, 0.05)
	if find_child("Interactable", false, false) == null:
		var it := Interactable.new()
		it.name = "Interactable"
		it.kind = Interactable.Kind.PICKUP
		add_child(it)
	if find_child("NetObject", false, false) == null:
		var o := NetObject.new()
		o.name = "NetObject"
		add_child(o)
	continuous_cd = true


func make_instance() -> ItemInstance:
	return ItemInstance.make(item_id, count, item_data)


func interaction_prompt(_c: UltraCharacter) -> String:
	var def := ItemDB.get_def(item_id)
	var n := def.display_name if def else String(item_id)
	return "Pick up %s%s" % [n, (" ×%d" % count) if count > 1 else ""]


func get_net_state() -> Dictionary:
	return {"count": count}


func set_net_state(d: Dictionary) -> void:
	count = int(d.get("count", count))
