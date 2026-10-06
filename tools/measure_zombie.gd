extends SceneTree
## Measures the zombie clips on the zombie skeleton: ground speed + plant phase of the locomotion
## cycles, and for the attacks the moments the hands move fastest / reach furthest (contact).
##   godot --headless --path . --script res://tools/measure_zombie.gd
const Measure := preload("res://tools/anim_measure.gd")


func _initialize() -> void:
	var inst := (load("res://assets/characters/zombie/zombie.glb") as PackedScene).instantiate()
	root.add_child(inst)
	var sk := inst.find_child("GeneralSkeleton", true, false) as Skeleton3D
	var lib := load("res://assets/characters/mannequin/anims/mixamo.res") as AnimationLibrary
	print("ZM motion_scale ", sk.motion_scale)
	for c in ["Z_Walk", "Z_Creep", "Z_Run", "Injured_Walk", "Z_Crawl"]:
		var a := lib.get_animation(c)
		var m: Array = Measure.measure(a, sk)
		print("ZM loco %s len %.2f speed %.3f plant %.3f" % [c, a.length, m[0], m[1]])
	var hips := sk.find_bone("Hips")
	var lh := sk.find_bone("LeftHand")
	var rh := sk.find_bone("RightHand")
	for c in ["Z_Swipe", "Z_Overhead", "Z_Punch", "Z_Jab", "Z_Scream", "Z_Alert", "Z_Hit1", "Z_Hit2"]:
		var a := lib.get_animation(c)
		var n := int(a.length * 30.0)
		var best := [0.0, 0.0, 0.0]        # speed, time, hand (0 left 1 right)
		var reach := [0.0, 0.0]
		var prev := [Vector3.ZERO, Vector3.ZERO]
		var rows := []
		for i in n + 1:
			var t := minf(i / 30.0, a.length)
			Measure.pose(a, sk, t)
			var hp := Measure.global_pose(sk, hips)
			var cur := []
			for h in [lh, rh]:
				var p := hp.affine_inverse() * Measure.global_pose(sk, h).origin
				cur.append(p)
			if i > 0:
				for k in 2:
					var v := ((cur[k] as Vector3) - (prev[k] as Vector3)).length() * 30.0
					if v > best[0]:
						best = [v, t, float(k)]
			for k in 2:
				var fwd: float = (cur[k] as Vector3).z
				if fwd > reach[0]:
					reach = [fwd, t]
			prev = cur
			if i % 6 == 0:
				rows.append("%.2f:%.2f/%.2f" % [t, (cur[0] as Vector3).z, (cur[1] as Vector3).z])
		print("ZM attack %s len %.2f peak hand speed %.1f m/s at %.2f s (%s hand); max forward reach %.2f m at %.2f s" % [c, a.length, best[0], best[1], "R" if best[2] > 0.5 else "L", reach[0], reach[1]])
		print("ZM    forward z L/R every 0.2s: ", " ".join(rows))
	quit()
