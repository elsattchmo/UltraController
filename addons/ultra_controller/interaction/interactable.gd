class_name Interactable
extends Node
## Marks its parent as something a player can interact with. The parent decides what
## happens (implement `interact(character)`), except for item pickups which are built in.
## Needs a NetObject sibling so clients can name it in their InputFrame (target_id).

enum Kind { USE, PICKUP, GRAB, CARRY, TEAM_LIFT, PUSH }

@export var kind := Kind.USE
@export var prompt := "Use"
@export_range(0.5, 6.0, 0.1) var max_distance := 2.6
## Optional: where the hand should go when using it (hand IK), relative to the parent.
@export var hand_point := Vector3.ZERO
var enabled := true


func _ready() -> void:
	add_to_group(&"ultra_interactable")


func target() -> Node3D:
	return get_parent() as Node3D


func net_id() -> int:
	var o := get_parent().find_child("NetObject", false, false) as NetObject
	return o.net_id if o else 0


func current_prompt(c: UltraCharacter) -> String:
	var p := get_parent()
	if p.has_method("interaction_prompt"):
		return String(p.call("interaction_prompt", c))
	return prompt


## Server: perform the interaction (already validated for distance).
func interact(c: UltraCharacter) -> void:
	if not enabled:
		return
	var p := get_parent()
	if kind == Kind.PICKUP:
		UltraItems.pickup(c, p as Node3D)
	elif p.has_method("interact"):
		p.call("interact", c)


static func find_on(n: Node) -> Interactable:
	var cur := n
	for _i in 4:
		if cur == null:
			return null
		var it := cur.find_child("Interactable", false, false) as Interactable
		if it:
			return it
		cur = cur.get_parent()
	return null
