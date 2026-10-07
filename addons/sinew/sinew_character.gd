class_name SinewCharacter
extends UltraCharacter
## A player driven by Sinew, the active-physics body engine (sinew/ core, GDExtension in
## addons/sinew/bin). It inherits movement, weapons, input, net and HUD from UltraCharacter
## untouched; Sinew takes over the body: ragdoll, hit reactions, balance, behaviours.
##
## The body you see is Sinew's (SinewRagdoll replaces the UltraRagdoll the base builds).
## Standing it's powered: muscles track the animation and hits push it for real (S3); knocked
## down, dead or falling it's a muscled physics body lying in Sinew's mirror of the level,
## handing back to the get-up clips.

## The Sinew physics world this character's body lives in (null if the extension didn't load).
var physics: RefCounted


func _ready() -> void:
	super._ready()
	if not SinewWorld.available():
		push_warning("Sinew: the GDExtension isn't loaded (addons/sinew/bin) - playing as a plain UltraCharacter")


## The clips this character references (re-point roles there; see SinewAnimationSet). Empty =
## addons/sinew/sinew_animset.tres if present, else the body profile's own set, as imported.
@export var sinew_anim_set: SinewAnimationSet


## The base's visual build with Sinew's own pieces: SinewAnimDriver (the clips as they are - no IK,
## no procedural passes) instead of UltraAnimDriver, no TraversalHands (rope / ladder / ledge hand IK),
## and a SinewRagdoll instead of the UltraRagdoll. The UltraCharacter itself is untouched.
func _build_visual() -> void:
	visual_root = Node3D.new()
	visual_root.name = "VisualRoot"
	visual_root.top_level = true
	visual_root.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(visual_root)
	if body_profile == null or body_profile.body_scene == null or not build_visuals:
		return
	body_node = body_profile.body_scene.instantiate() as Node3D
	body_node.name = "Body"
	if body_profile.model_faces_positive_z:
		body_node.rotation.y = PI
	visual_root.add_child(body_node)
	skeleton = body_node.find_child(body_profile.skeleton_name, true, false) as Skeleton3D
	if skeleton:
		skeleton.skeleton_updated.connect(_capture_hitboxes)
	head_mesh = body_node.find_child(body_profile.head_mesh_name, true, false) as MeshInstance3D if body_profile.head_mesh_name != "" else null
	var bm := body_node.find_child(body_profile.body_mesh_name, true, false) as MeshInstance3D
	if body_profile.cap_meshes:
		for capme: MeshInstance3D in [bm, head_mesh]:
			if capme and capme.mesh is ArrayMesh:
				capme.mesh = UltraMeshCap.capped(capme.mesh as ArrayMesh)
	for mi: MeshInstance3D in [bm, head_mesh]:
		if mi == null or mi.mesh == null:
			continue
		for si in mi.mesh.get_surface_count():
			var m := mi.get_active_material(si) as BaseMaterial3D
			if m:
				mi.set_surface_override_material(si, _near_fade_mat(m))
	var player := body_node.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if player == null or skeleton == null:
		set_view_index(view_index)
		_sync_visual(1.0)
		return
	var set_res := sinew_anim_set
	if set_res == null and ResourceLoader.exists(DEFAULT_ANIM_SET):
		set_res = load(DEFAULT_ANIM_SET) as SinewAnimationSet
	if set_res == null:
		set_res = SinewAnimationSet.new()
	var drv := SinewAnimDriver.new()
	drv.name = "AnimDriver"
	drv.anim_set = set_res.resolved(body_profile.anim_set)
	drv.library = body_profile.library
	drv.extra_libraries = body_profile.extra_libraries
	drv.get_up_time = profile.get_up_time
	anim = drv
	add_child(drv)
	drv.setup(player, skeleton)
	var eq := UltraEquipmentVisual.new()
	eq.name = "Equipment"
	add_child(eq)
	eq.setup(self)
	item_event.connect(func(kind: StringName, d: Dictionary) -> void: anim.item_event(kind, d))
	body_fx = UltraBodyFX.new()
	body_fx.name = "BodyFX"
	add_child(body_fx)
	body_fx.setup(self)
	if SinewWorld.available():
		var r := SinewRagdoll.new()
		r.name = "RagdollFX"
		ragdoll = r
		add_child(r)
		r.setup(self)
		physics = r.world.physics
	else:
		ragdoll = UltraRagdoll.new()
		ragdoll.name = "RagdollFX"
		add_child(ragdoll)
		ragdoll.setup(self)
	set_view_index(view_index)
	_sync_visual(1.0)


const DEFAULT_ANIM_SET := "res://addons/sinew/sinew_animset.tres"


func _process(delta: float) -> void:
	super._process(delta)
	# The equipment's prop-carrying path drives hand IK unguarded: lend it an inactive one.
	if anim is SinewAnimDriver:
		anim.hand_ik = (anim as SinewAnimDriver).prop_hand_ik if state.held_id != 0 else null


## A hit lands on the Sinew body too (every machine: this runs from the `hit` event).
func react_to_hit(region: int, dir: Vector3, amount: float, kind := &"bullet") -> void:
	super.react_to_hit(region, dir, amount, kind)
	if ragdoll is SinewRagdoll:
		(ragdoll as SinewRagdoll).hit(region, dir, amount)


## "sinew 0.1.0 (box3d <commit>)", or "" without the extension.
static func engine_version() -> String:
	if not ClassDB.class_exists(&"SinewPhysics"):
		return ""
	return String(ClassDB.class_call_static(&"SinewPhysics", &"version"))
