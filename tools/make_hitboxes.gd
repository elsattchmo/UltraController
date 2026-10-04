extends Node
## Bakes the per-region hit capsules from the mannequin's idle pose into its BodyProfile
## (character space: feet at the origin, -Z forward). The server classifies hits with these,
## so a headless server needs no skeleton or animation.
## Run: godot --headless --path . res://tools/tool_runner.tscn -- --tool=res://tools/make_hitboxes.gd

const MANNEQUIN := "res://assets/characters/mannequin/"
const R := UltraLimbs.Region


func _ready() -> void:
	var scene: Node = (load(MANNEQUIN + "mannequin.glb") as PackedScene).instantiate()
	add_child(scene)
	var sk := scene.find_child("GeneralSkeleton", true, false) as Skeleton3D
	var lib: AnimationLibrary = load(MANNEQUIN + "anims/ual.res")
	UltraPoseSampler.pose(lib.get_animation("Idle_A"), sk, 0.0)
	var p := func(b: String) -> Vector3:
		var v := UltraPoseSampler.global_pose(sk, sk.find_bone(b)).origin
		return Vector3(-v.x, v.y, -v.z)                 # model faces +Z; character faces -Z
	var boxes: Array[Dictionary] = []
	var cap := func(region: int, a: Vector3, b: Vector3, r: float) -> void:
		boxes.append({"region": region, "a": a, "b": b, "r": r})
	var head: Vector3 = p.call("Head")
	cap.call(R.HEAD, head + Vector3(0, 0.06, 0), head + Vector3(0, 0.17, 0), 0.11)
	cap.call(R.TORSO, p.call("Hips"), p.call("Chest"), 0.16)
	cap.call(R.TORSO, p.call("Chest"), p.call("Neck"), 0.17)
	for side: String in ["Left", "Right"]:
		var l: bool = side == "Left"
		var hand: Vector3 = p.call(side + "Hand")
		var lower: Vector3 = p.call(side + "LowerArm")
		cap.call(R.ARM_L if l else R.ARM_R, p.call(side + "UpperArm"), lower, 0.065)
		cap.call(R.FOREARM_L if l else R.FOREARM_R, lower, hand + (hand - lower).normalized() * 0.09, 0.055)
		var knee: Vector3 = p.call(side + "LowerLeg")
		var foot: Vector3 = p.call(side + "Foot")
		cap.call(R.THIGH_L if l else R.THIGH_R, p.call(side + "UpperLeg"), knee, 0.09)
		cap.call(R.SHIN_L if l else R.SHIN_R, knee, foot, 0.065)
		cap.call(R.SHIN_L if l else R.SHIN_R, foot, p.call(side + "Toes") + Vector3(0, 0, -0.04), 0.05)
	var bp: BodyProfile = load(MANNEQUIN + "mannequin_body_profile.tres")
	bp.hitboxes = boxes
	print("hitboxes: %d capsules, head at %s, saved %d" % [boxes.size(), head, ResourceSaver.save(bp)])
	scene.queue_free()
