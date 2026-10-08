extends SceneTree
## Prints a clip's left ankle / toe height and ankle position along the hips over one loop (diagnostics).
## Run: godot --headless --path . --script res://tools/marksman/probe_feet.gd -- RFP_WalkCrouchingForward,...
const AnimMeasure := preload("res://tools/anim_measure.gd")


func _init() -> void:
	var lib: AnimationLibrary = load("res://assets/characters/mannequin/anims/mixamo.res")
	var scene: Node = (load("res://assets/characters/mannequin/mannequin.glb") as PackedScene).instantiate()
	root.add_child(scene)
	var sk := scene.find_child("GeneralSkeleton", true, false) as Skeleton3D
	var args := OS.get_cmdline_user_args()
	for clip in (args[0] if not args.is_empty() else "RFP_WalkCrouchingForward").split(","):
		var a := lib.get_animation(clip)
		var line := clip + "\n"
		for i in 24:
			AnimMeasure.pose(a, sk, a.length * i / 24.0)
			var la := AnimMeasure.global_pose(sk, sk.find_bone("LeftFoot")).origin
			var lt := AnimMeasure.global_pose(sk, sk.find_bone("LeftToes")).origin
			var h := AnimMeasure.global_pose(sk, sk.find_bone("Hips")).origin
			line += "%2d ankle y %.3f along %+.2f toe y %.3f hips y %.2f\n" % [i, la.y, la.z - h.z, lt.y, h.y]
		print(line)
	quit()
