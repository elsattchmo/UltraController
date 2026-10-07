class_name SinewCharacter
extends UltraCharacter
## A player driven by Sinew, the active-physics body engine (sinew/ core, GDExtension in
## addons/sinew/bin). It inherits movement, weapons, input, net and HUD from UltraCharacter
## untouched; Sinew takes over the body: ragdoll, hit reactions, balance, behaviours.
##
## Stage S0: a stand-in. It plays exactly like the UltraController and only proves the
## extension loads (`physics` is a live Sinew world). S2 swaps the body in.

## The Sinew physics world this character's body lives in (null if the extension didn't load).
var physics: RefCounted


func _ready() -> void:
	super._ready()
	if ClassDB.class_exists(&"SinewPhysics"):
		physics = ClassDB.instantiate(&"SinewPhysics")
	else:
		push_warning("Sinew: the GDExtension isn't loaded (addons/sinew/bin) - playing as a plain UltraCharacter")


## "sinew 0.1.0 (box3d <commit>)", or "" without the extension.
static func engine_version() -> String:
	if not ClassDB.class_exists(&"SinewPhysics"):
		return ""
	return String(ClassDB.class_call_static(&"SinewPhysics", &"version"))
