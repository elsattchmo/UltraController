extends "res://tools/build_animset.gd"
## Authored speed and stride of every walking cycle in the library.
func _init() -> void:
	var scene: Node = (load("res://assets/characters/mannequin/mannequin.glb") as PackedScene).instantiate()
	root.add_child(scene)
	var skel := scene.find_child("GeneralSkeleton", true, false) as Skeleton3D
	var lib: AnimationLibrary = load("res://assets/characters/mannequin/anims/ual.res")
	for clip in ["Walk", "Walk_Formal", "Walk_Large", "Walk_Stealth", "Walk_Carry", "Zombie_Walk", "Jog", "Run_Stealth", "Sprint"]:
		if not lib.has_animation(clip):
			continue
		var a := lib.get_animation(clip)
		var m := _measure(a, skel)
		print("WALKS %-13s speed %.2f m/s  cycle %.2f s  stride %.2f m  cadence %.0f steps/min" % [clip, m[0], a.length, m[0] * a.length / 2.0, 120.0 / a.length])
	quit()
