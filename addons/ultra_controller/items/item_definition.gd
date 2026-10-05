@tool
class_name ItemDefinition
extends Resource
## Everything about one kind of item. Instances (stacks, ammo, durability) are ItemInstance.
## Items live in res://assets/items/**/<id>_item.tres and are indexed by ItemDB.

enum Kind { MISC, FIREARM, AMMO, KEY, CONSUMABLE, THROWABLE, TOOL }
enum EquipSlot { NONE = 0, MAIN_HAND = 1, OFF_HAND = 2, HIP = 4, BACK = 8 }
enum FireMode { SEMI, AUTO }

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
## Support hand placed under the fore-end (at the item's M_SupportGrip marker) instead of
## `support_offset`: the direction the hand points (wrist to knuckles) and the way the palm
## faces, in the item's frame (x right, y up, -z forward). Zero = use support_offset.
@export var support_fingers := Vector3.ZERO
@export var support_palm := Vector3.ZERO
## Item transform in `holster_bone`'s frame when holstered (hip holster, slung on the back).
@export var holster_offset := Transform3D.IDENTITY
@export var holster_bone := &"Hips"
## Upper-body animation roles while held: {"idle": role, "aim": role, "fire": role, "reload": role}
@export var anim_roles: Dictionary = {}
## AnimationSet roles this item brings along: role -> clip, or a list of clips (first one the
## character has wins). Only used for roles the character's AnimationSet doesn't define, so a
## project can still map them to its own clips there.
@export var anim_clips: Dictionary = {}
## Where the "aim" clip points the gun (degrees, x = yaw to the left, y = pitch up) relative to
## the model's straight ahead; third person turns the upper body back by it so the barrel
## follows the aim. Measured by tools/build_items.gd.
@export var aim_clip_offset := Vector2.ZERO
@export_range(0.05, 2.0, 0.01) var equip_time := 0.35

@export_group("Firearm")
@export var fire_mode := FireMode.SEMI
## First person, hip: where the rear sight sits relative to the eye (x right, y up, z forward).
@export var fp_hip_offset := Vector3(0.16, -0.17, 0.42)
## First person, aiming down sights: rear sight this far in front of the eye.
@export_range(0.03, 0.8, 0.005) var fp_ads_distance := 0.37
## First person, aiming down sights: the head drops onto the stock - the eye moves by this
## (metres, x right, y up, z forward in the view). Zero for guns without a stock.
@export var fp_ads_eye := Vector3.ZERO

@export_group("Free aim")
## The gun has its own direction: aim + an offset on a damped spring (MotorState.sway).
## Fraction of a turn the gun doesn't follow straight away (inertia: heavier = more lag).
@export_range(0.0, 1.0, 0.01) var sway_inertia := 0.3
## How fast the gun swings back onto the aim (spring frequency, Hz) and its damping ratio.
@export_range(0.2, 10.0, 0.05) var sway_return_hz := 2.4
@export_range(0.05, 2.0, 0.01) var sway_damping := 0.75
## Free-aim zone: how far (degrees) the gun may drift from the aim before it drags along.
@export_range(0.0, 30.0, 0.1) var free_aim_deg := 4.0
## Movement / breathing sway multiplier (1 = pistol).
@export_range(0.0, 5.0, 0.01) var sway_amount := 1.0
## Sway, lag and free-aim zone multiplier while aiming down sights.
@export_range(0.0, 1.0, 0.01) var ads_sway_mult := 0.35
## Upward kick of the gun per shot (degrees, the spring takes it back).
@export_range(0.0, 20.0, 0.05) var recoil_gun_deg := 2.0
## Sprinting carries the gun low: pitch (down, degrees) and yaw (toward the off side).
@export var sprint_lower_deg := Vector2(10.0, -18.0)

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
