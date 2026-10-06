@tool
class_name BodyProfile
extends Resource
## Everything specific to one character model. Swap this (and its AnimationSet) to use a
## different humanoid; the controller code never names a mesh, clip or bone directly.

## How much of the animation / presentation stack the character gets: FULL is the player's (IK,
## aim spread, equipment and traversal visuals, ~1.5 ms a frame); LITE is an NPC's - the small
## UltraLiteAnimDriver tree, foot IK for stairs, body gore and a ragdoll, nothing for items.
enum Tier { FULL, LITE }
@export var visual_tier := Tier.FULL
## Close the open loops of the body mesh with skin-coloured fans (the neck opening the first
## person head hide leaves, ...). Off for a model whose mouth / eye holes would be fanned over.
@export var cap_meshes := true
@export var body_scene: PackedScene
@export var anim_set: AnimationSet
@export var library: AnimationLibrary
## Extra libraries (Mixamo / Blender intake), added under their own prefixes.
@export var extra_libraries: Dictionary = {}
## The model's own facing in its file: true when it faces +Z (glTF), so it is turned 180°.
@export var model_faces_positive_z := true
## Node names inside body_scene.
@export var skeleton_name := "GeneralSkeleton"
@export var head_mesh_name := "HeadMesh"
@export var body_mesh_name := "BodyMesh"
## Eye position relative to the Head bone at rest, in character space (-Z forward).
@export var eye_offset := Vector3(0.0, 0.075, -0.1)
## Hit regions: capsules {region, a, b, r} in character space (feet origin, -Z forward), baked
## from the idle pose by tools/make_hitboxes.gd. Used to tell which limb a shot hit.
@export var hitboxes: Array[Dictionary] = []
## The model pre-cut for dismemberment (tools/blender/ultra_blender.py make-cuts; UltraCutBody):
## each region its own mesh, fitted ends for every cut, head chunks, an opened belly, the torso
## in two. Null: severed limbs collapse under caps built at runtime.
@export var cut_scene: PackedScene
