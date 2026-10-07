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


func _build_visual() -> void:
	super._build_visual()
	if not SinewWorld.available() or ragdoll == null or skeleton == null:
		return
	# The base made an UltraRagdoll (a PhysicalBoneSimulator3D in the skeleton's stack): out.
	var old := ragdoll
	if old.sim:
		old.sim.get_parent().remove_child(old.sim)
		old.sim.queue_free()
	remove_child(old)
	old.queue_free()
	var r := SinewRagdoll.new()
	r.name = "RagdollFX"
	ragdoll = r
	add_child(r)
	r.setup(self)
	physics = r.world.physics


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
