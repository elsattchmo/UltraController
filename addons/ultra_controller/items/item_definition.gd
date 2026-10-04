@tool
class_name ItemDefinition
extends Resource
## Everything about one kind of item. Instances (stacks, ammo, durability) are ItemInstance.
## Items live in res://assets/items/**/<id>_item.tres and are indexed by ItemDB.

enum Kind { MISC, FIREARM, AMMO, KEY, CONSUMABLE, THROWABLE, TOOL }
enum EquipSlot { NONE = 0, MAIN_HAND = 1, OFF_HAND = 2, HIP = 4, BACK = 8 }

@export var id: StringName
@export var display_name := ""
@export_multiline var description := ""
@export var icon: Texture2D
@export var kind := Kind.MISC
@export_range(0.0, 500.0, 0.01) var mass := 0.5
@export_range(1, 999) var max_stack := 1

@export_group("Scenes")
## Physics prop dropped into the world (RigidBody3D root with an Interactable).
@export var world_scene: PackedScene
## Visual held in the hand / worn on the body.
@export var equip_scene: PackedScene

@export_group("Equip")
@export_flags("Main hand", "Off hand", "Hip", "Back") var equip_slots := 0
## Item transform in the RightHand bone's frame (from tools/build_items.gd fitting).
@export var grip_offset := Transform3D.IDENTITY
## LeftHand bone transform in the item's frame (support hand), or identity = one-handed.
@export var support_offset := Transform3D.IDENTITY
@export var two_handed := false
## Item transform in the Hips bone frame when holstered.
@export var holster_offset := Transform3D.IDENTITY
## Upper-body animation roles while held: {"idle": role, "aim": role, "fire": role, "reload": role}
@export var anim_roles: Dictionary = {}
@export_range(0.05, 2.0, 0.01) var equip_time := 0.35

@export_group("Behaviour")
## Free-form numbers for the item's behaviour (fire interval, magazine size, damage...).
@export var stats: Dictionary = {}
## KEY items: which Lockable(s) this opens.
@export var key_id: StringName
@export var consumable_heal := 0.0


func stat(n: String, def: Variant = 0.0) -> Variant:
	return stats.get(n, def)


func can_equip(slot: int) -> bool:
	return (equip_slots & slot) != 0
