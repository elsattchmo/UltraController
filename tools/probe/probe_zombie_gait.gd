extends SceneTree
## Zombie gait cross-check: foot travel relative to the hips per clip (extent, cycles, implied speed),
## and the hands for the crawl.  godot --headless --path . --script res://tools/probe/probe_zombie_gait.gd
const Measure := preload("res://tools/anim_measure.gd")


func _initialize() -> void:
	var inst := (load("res://assets/characters/zombie/zombie.glb") as PackedScene).instantiate()
	root.add_child(inst)
	var sk := inst.find_child("GeneralSkeleton", true, false) as Skeleton3D
	var lib := load("res://assets/characters/mannequin/anims/mixamo.res") as AnimationLibrary
	var hips := sk.find_bone("Hips")
	for c in ["Z_Walk", "Z_Creep", "Z_Run", "Injured_Walk", "Z_Crawl", "Z_Idle1", "Z_Agonize"]:
		var a := lib.get_animation(c)
		var n := int(a.length * 30.0)
		for bn in ["LeftToes", "RightToes", "LeftHand", "RightHand"]:
			var b := sk.find_bone(bn)
			var zs := []
			var ys := []
			for i in n:
				Measure.pose(a, sk, a.length * i / n)
				var hp := Measure.global_pose(sk, hips)
				var p := hp.affine_inverse() * Measure.global_pose(sk, b).origin
				zs.append(p.z)
				ys.append(Measure.global_pose(sk, b).origin.y)
			var zmin := 1e9
			var zmax := -1e9
			var crossings := 0
			var mean := 0.0
			for z: float in zs:
				zmin = minf(zmin, z)
				zmax = maxf(zmax, z)
				mean += z
			mean /= zs.size()
			for i in zs.size():
				var j := (i + 1) % zs.size()
				if (zs[i] - mean) < 0.0 and (zs[j] - mean) >= 0.0:
					crossings += 1
			var ymin := 1e9
			var ymax := -1e9
			for y: float in ys:
				ymin = minf(ymin, y)
				ymax = maxf(ymax, y)
			# (hands only matter for the crawl)
			print("ZG %-12s %-10s len %.2f  z %.2f..%.2f (p-p %.2f)  cycles %d  y %.2f..%.2f  implied %.2f m/s if stance ~60%%" % [c, bn, a.length, zmin, zmax, zmax - zmin, crossings, ymin, ymax, (zmax - zmin) * crossings / a.length / 0.6])
	quit()
