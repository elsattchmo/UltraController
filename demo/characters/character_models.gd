class_name CharacterModels
extends RefCounted
## What the main menu's Character section offers: which controller drives the local player
## (the UltraController as it is, Sinew's physics body, or Marksman - Sinew built round the gun packs) and which rigged model it wears.
## Dummies, the companion and zombies are never affected: they stay ordinary UltraCharacters.

const MANNEQUIN_BODY := "res://assets/characters/mannequin/mannequin_body_profile.tres"
const ZOMBIE_BODY := "res://assets/characters/zombie/zombie_body_profile.tres"

const CONTROLLERS := [
	{"key": "ultra", "title": "UltraController", "blurb": "the controller as it is"},
	{"key": "sinew", "title": "Sinew", "blurb": "physics body (in development)"},
	{"key": "marksman", "title": "Marksman", "blurb": "Sinew body + rifle / pistol packs (in development)"},
]
const MODELS := [
	{"key": "mannequin", "title": "Mannequin", "blurb": "Quaternius mannequin"},
	{"key": "zombie", "title": "Zombie", "blurb": "Mixamo Romero"},
]


static func has_controller(key: String) -> bool:
	return CONTROLLERS.any(func(d: Dictionary) -> bool: return d.key == key)


static func has_model(key: String) -> bool:
	return MODELS.any(func(d: Dictionary) -> bool: return d.key == key)


## A new local player character for the picked controller.
static func make(controller: String) -> UltraCharacter:
	if controller == "sinew":
		return SinewCharacter.new()
	if controller == "marksman":
		return MarksmanCharacter.new()
	return UltraCharacter.new()


static var _cache := {}


## The BodyProfile for a model, at the player's FULL visual tier.
## The zombie is the Romero mesh on the mannequin's animation set: both skeletons are
## retargeted to the same humanoid profile, and its own (zombie) profile is the LITE NPC one.
static func body_profile(model: String) -> BodyProfile:
	if _cache.has(model):
		return _cache[model]
	var body: BodyProfile = load(MANNEQUIN_BODY)
	if model != "zombie":
		return body
	var z: BodyProfile = load(ZOMBIE_BODY)
	var p := body.duplicate() as BodyProfile
	p.body_scene = _without_clips(z.body_scene)
	p.cut_scene = z.cut_scene
	p.hitboxes = z.hitboxes
	p.cap_meshes = z.cap_meshes
	p.head_mesh_name = z.head_mesh_name
	p.body_mesh_name = z.body_mesh_name
	p.skeleton_name = z.skeleton_name
	p.model_faces_positive_z = z.model_faces_positive_z
	p.eye_offset = z.eye_offset
	_cache[model] = p
	return p


## A model scene whose AnimationPlayer carries no libraries of its own. The AnimDriver only adds
## the profile's libraries under names the player doesn't have yet, and a .glb imports with its own
## (here empty) default library "" - which hid the mannequin's clips: the borrowed set never played
## and the body stood in its rest (T) pose.
static func _without_clips(scene: PackedScene) -> PackedScene:
	var root := scene.instantiate()
	for ap: AnimationPlayer in root.find_children("*", "AnimationPlayer", true, false):
		for lib in ap.get_animation_library_list():
			ap.remove_animation_library(lib)
	var packed := PackedScene.new()
	packed.pack(root)
	root.free()
	return packed
