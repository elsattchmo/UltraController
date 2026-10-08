extends SceneTree
## Prints locomotion facts for clips (nothing is saved): authored ground speed (from the planted foot's
## slide), left plant phase, length, travel direction (+x = the character's left, +y = forward, as an
## angle), hip / shoulder facing and lean. For picking Marksman's stance sets.
## Run: godot --headless --path . --script res://tools/marksman/survey_clips.gd -- mixamo/RFP_WalkForward,ual/Walk,...
## (no list: every RFP_ / PST_ / SHT_ / SHB_ locomotion clip plus the unarmed references.)

const DIR := "res://assets/characters/mannequin/"
const AnimMeasure := preload("res://tools/anim_measure.gd")


func _init() -> void:
	var libs := {"mixamo": load(DIR + "anims/mixamo.res"), "ual": load(DIR + "anims/ual.res")}
	var scene: Node = (load(DIR + "mannequin.glb") as PackedScene).instantiate()
	root.add_child(scene)
	var skel := scene.find_child("GeneralSkeleton", true, false) as Skeleton3D
	var want: Array[String] = []
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		for a in args[0].split(","):
			want.append(a)
	else:
		for n in (libs.mixamo as AnimationLibrary).get_animation_list():
			var s := String(n)
			if s.begins_with("RFP_") or s.begins_with("PST_") or s.begins_with("SHT_") or s.begins_with("SHB_") or s.begins_with("LMM_") or s.begins_with("AAD_Crouch") or s.begins_with("INJ_"):
				want.append("mixamo/" + s)
	for full in want:
		var lib_name := full.get_slice("/", 0) if full.contains("/") else "ual"
		var key := full.get_slice("/", 1) if full.contains("/") else full
		var lib: AnimationLibrary = libs.get(lib_name)
		if lib == null or not lib.has_animation(key):
			print("%-42s MISSING" % full)
			continue
		var anim := lib.get_animation(key)
		var r: Array = AnimMeasure.measure(anim, skel)
		var dir: Vector2 = _travel_dir(anim, skel)
		var face: Vector2 = _facing(anim, skel)
		var lean: Vector2 = _lean(anim, skel)
		print("%-42s speed %5.2f  plant %.2f  len %.2f  travel %+5.0f deg  hips %+4.0f sh %+4.0f  lean %+3.0f/%+3.0f" % [full, r[0], r[1], anim.length,
				rad_to_deg(atan2(dir.x, dir.y)), face.x, face.y, lean.x, lean.y])
	quit()


# (Copied from tools/measure_mixamo.gd: that one is a SceneTree script whose _init measures AND saves the animset -
# instancing it to borrow these ran it.)
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


## Mean lean of the head over the hips (deg): x = sideways (+ = to the character's right,
## in the hips' own frame), y = forward.
func _lean(anim: Animation, skel: Skeleton3D) -> Vector2:
	var out := Vector2.ZERO
	var n := 16
	for i in n:
		AnimMeasure.pose(anim, skel, anim.length * i / n)
		var l := AnimMeasure.global_pose(skel, skel.find_bone("LeftUpperLeg")).origin
		var r := AnimMeasure.global_pose(skel, skel.find_bone("RightUpperLeg")).origin
		var right := Vector3(r.x - l.x, 0, r.z - l.z).normalized()
		var fwd := Vector3.UP.cross(right)
		var d := AnimMeasure.global_pose(skel, skel.find_bone("Head")).origin - AnimMeasure.global_pose(skel, skel.find_bone("Hips")).origin
		out.x += rad_to_deg(atan2(d.dot(right), d.y)) / n
		out.y += rad_to_deg(atan2(d.dot(fwd), d.y)) / n
	return out
