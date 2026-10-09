extends SceneTree
## A jump clip's timeline, for timing it to the sim: per sample, the hips' height and the lower foot's (toe / ankle)
## height above the clip's own floor; then take-off (both feet leave the floor), apex (hips highest in the air),
## touchdown (a foot back on the floor) and when the landing has settled (hips back within 3 cm of where they end).
## Run: godot --headless --path . --script res://tools/marksman/measure_jumps.gd -- mixamo/LMM_Jump,Jump_Start,...

const DIR := "res://assets/characters/mannequin/"
const AnimMeasure := preload("res://tools/anim_measure.gd")


func _init() -> void:
	var libs := {"mixamo": load(DIR + "anims/mixamo.res"), "ual": load(DIR + "anims/ual.res")}
	var scene: Node = (load(DIR + "mannequin.glb") as PackedScene).instantiate()
	root.add_child(scene)
	var skel := scene.find_child("GeneralSkeleton", true, false) as Skeleton3D
	var verbose := OS.get_cmdline_user_args().has("--verbose")
	for full in OS.get_cmdline_user_args()[0].split(","):
		var lib_name := full.get_slice("/", 0) if full.contains("/") else "ual"
		var key := full.get_slice("/", 1) if full.contains("/") else full
		var lib: AnimationLibrary = libs.get(lib_name)
		if lib == null or not lib.has_animation(key):
			print("%s MISSING" % full)
			continue
		var anim := lib.get_animation(key)
		var n := 120
		var hips := []
		var foot := []
		var b := {}
		for nm in ["Hips", "LeftToes", "RightToes", "LeftFoot", "RightFoot"]:
			b[nm] = skel.find_bone(nm)
		for i in n + 1:
			var t := anim.length * i / n
			AnimMeasure.pose(anim, skel, t)
			hips.append(AnimMeasure.global_pose(skel, b.Hips).origin.y)
			var lo := INF
			for nm in ["LeftToes", "RightToes", "LeftFoot", "RightFoot"]:
				lo = minf(lo, AnimMeasure.global_pose(skel, b[nm]).origin.y - (0.0 if nm.ends_with("Toes") else 0.06))
			foot.append(lo)
		var floor_y: float = (foot.duplicate() as Array).min()
		var off := -1
		var down := -1
		for i in n + 1:
			var air: bool = float(foot[i]) > floor_y + 0.04
			if air and off < 0:
				off = i
			elif not air and off >= 0 and down < 0:
				down = i
		var apex := off
		if off >= 0:
			for i in range(off, (down if down >= 0 else n) + 1):
				if float(hips[i]) > float(hips[apex]):
					apex = i
		var end_h: float = hips[n]
		var settled := n
		for i in range(n, (down if down >= 0 else 0), -1):
			if absf(float(hips[i]) - end_h) > 0.03:
				settled = i + 1
				break
		var dt := anim.length / n
		print("%-34s len %.2f  take-off %s  apex %s (hips +%.2f)  touchdown %s  settled %.2f  lowest hips %.2f (rest %.2f)" % [full, anim.length,
				"%.2f" % (off * dt) if off >= 0 else "-", "%.2f" % (apex * dt) if apex >= 0 else "-",
				(float(hips[apex]) - float(hips[0])) if apex >= 0 else 0.0, "%.2f" % (down * dt) if down >= 0 else "-", settled * dt,
				(hips.duplicate() as Array).min(), float(hips[0])])
		if verbose:
			for i in range(0, n + 1, 4):
				print("   t %.2f hips %.2f foot %+.2f" % [i * dt, float(hips[i]), float(foot[i]) - floor_y])
	quit()
