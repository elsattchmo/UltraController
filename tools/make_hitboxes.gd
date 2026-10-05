extends Node
## Bakes the per-region hit capsules from the mannequin's idle pose into its BodyProfile
## (character space: feet at the origin, -Z forward). The server classifies hits with these,
## so a headless server needs no skeleton or animation.
## Run: godot --headless --path . res://tools/tool_runner.tscn -- --tool=res://tools/make_hitboxes.gd

const MANNEQUIN := "res://assets/characters/mannequin/"


func _ready() -> void:
	var scene: Node = (load(MANNEQUIN + "mannequin.glb") as PackedScene).instantiate()
	add_child(scene)
	var sk := scene.find_child("GeneralSkeleton", true, false) as Skeleton3D
	var lib: AnimationLibrary = load(MANNEQUIN + "anims/ual.res")
	UltraPoseSampler.pose(lib.get_animation("Idle_A"), sk, 0.0)
	var p := func(b: String) -> Vector3:
		var v := UltraPoseSampler.global_pose(sk, sk.find_bone(b)).origin
		return Vector3(-v.x, v.y, -v.z)                 # model faces +Z; character faces -Z
	var boxes := UltraHitboxes.build(p)
	var head: Vector3 = p.call("Head")
	var bp: BodyProfile = load(MANNEQUIN + "mannequin_body_profile.tres")
	bp.hitboxes = boxes
	print("hitboxes: %d capsules, head at %s, saved %d" % [boxes.size(), head, ResourceSaver.save(bp)])
	scene.queue_free()
