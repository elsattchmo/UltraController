@tool
class_name BodyProfile
extends Resource
## Everything specific to one character model. Swap this (and its AnimationSet) to use a
## different humanoid; the controller code never names a mesh, clip or bone directly.

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
