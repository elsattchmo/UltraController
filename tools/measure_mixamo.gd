extends SceneTree
## Measures in-place Mixamo locomotion cycles (library `mixamo`) and records them in
## mannequin_animset.tres: authored ground speed (m/s), left-foot plant phase, and prints the
## travel direction (model space, +Z forward, +X = the character's left) as a check.
## Run: godot --headless --path . --script res://tools/measure_mixamo.gd [-- clip1,clip2]
## (no list: every mixamo clip whose name starts U_/R_ plus the strafe walks.)

const DIR := "res://assets/characters/mannequin/"
const AnimMeasure := preload("res://tools/anim_measure.gd")


func _init() -> void:
	var lib: AnimationLibrary = load(DIR + "anims/mixamo.res")
	var scene: Node = (load(DIR + "mannequin.glb") as PackedScene).instantiate()
	root.add_child(scene)
	var skel := scene.find_child("GeneralSkeleton", true, false) as Skeleton3D
	var want: Array[String] = []
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		for a in args[0].split(","):
			want.append(a)
	else:
		for n in lib.get_animation_list():
			var s := String(n)
			if (s.begins_with("U_") or s.begins_with("R_")) and not s.contains("_fit_") and not s.contains("_seg_") and not s.ends_with("_M"):
				want.append(s)
	var set: AnimationSet = load(DIR + "mannequin_animset.tres")
	for clip in want:
		if not lib.has_animation(clip):
			push_warning("no clip " + clip)
			continue
		var anim := lib.get_animation(clip)
		var m: Array = AnimMeasure.measure(anim, skel)
		var dir := _travel_dir(anim, skel)
		set.authored_speed["mixamo/" + clip] = snappedf(m[0], 0.001)
		set.plant_phase["mixamo/" + clip] = snappedf(m[1], 0.001)
		var face := _facing(anim, skel)
		print("%-20s speed=%.3f m/s  plant=%.3f  len=%.3f  dir=(%.2f, %.2f)  hips %+.0f shoulders %+.0f deg" % [clip, m[0], m[1], anim.length, dir.x, dir.y, face.x, face.y])
	print("saved err=", ResourceSaver.save(set, DIR + "mannequin_animset.tres"))
	quit()


## Travel direction (x = model +X = left, y = forward): opposite to the planted foot's slide.
func _travel_dir(anim: Animation, skel: Skeleton3D) -> Vector2:
	var feet := [skel.find_bone("LeftToes"), skel.find_bone("RightToes")]
	var n := 120
	var pos := [[], []]
	for i in n:
		AnimMeasure.pose(anim, skel, anim.length * i / n)
		for f in 2:
			pos[f].append(AnimMeasure.global_pose(skel, feet[f]).origin)
	var miny := [INF, INF]
	for f in 2:
		for p: Vector3 in pos[f]:
			miny[f] = minf(miny[f], p.y)
	var sum := Vector2.ZERO
	for i in n:
		var j := (i + 1) % n
		var lo := 0 if (pos[0][i] as Vector3).y <= (pos[1][i] as Vector3).y else 1
		var p: Vector3 = pos[lo][i]
		var q: Vector3 = pos[lo][j]
		if p.y > miny[lo] + 0.03 or q.y > miny[lo] + 0.03:
			continue
		sum += Vector2(q.x - p.x, q.z - p.z)
	return (-sum).normalized()


## Mean facing (deg, + = toward the character's left) of the hip line and the shoulder line:
## a neutral walk faces its own forward; stance clips (rifle, combat) are turned.
func _facing(anim: Animation, skel: Skeleton3D) -> Vector2:
	var out := Vector2.ZERO
	var n := 16
	for i in n:
		AnimMeasure.pose(anim, skel, anim.length * i / n)
		for k in 2:
			var a := ["LeftUpperLeg", "LeftUpperArm"][k] as String
			var b := ["RightUpperLeg", "RightUpperArm"][k] as String
			var l := AnimMeasure.global_pose(skel, skel.find_bone(a)).origin
			var r := AnimMeasure.global_pose(skel, skel.find_bone(b)).origin
			var f := Vector3.UP.cross(r - l)
			out[k] += rad_to_deg(atan2(f.x, f.z)) / n
	return out
