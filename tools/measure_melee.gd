extends SceneTree
## Measures melee / strike clips (library `mixamo`): per 1/30 s the right and left hand speed
## (character space), hips travel from frame 0, hips yaw and the chest's lean. Prints the hand
## speed peaks (contact candidates) so swing timings (hit_from, segments) can be chosen.
## Run: godot --headless --path . --script res://tools/measure_melee.gd -- M_AxeRL,M_SlashIn

const DIR := "res://assets/characters/mannequin/"
const AnimMeasure := preload("res://tools/anim_measure.gd")


func _init() -> void:
	var lib: AnimationLibrary = load(DIR + "anims/mixamo.res")
	var scene: Node = (load(DIR + "mannequin.glb") as PackedScene).instantiate()
	root.add_child(scene)
	var skel := scene.find_child("GeneralSkeleton", true, false) as Skeleton3D
	var args := OS.get_cmdline_user_args()
	var want: PackedStringArray = args[0].split(",") if not args.is_empty() else PackedStringArray()
	var rh := skel.find_bone("RightHand")
	var lh := skel.find_bone("LeftHand")
	var hips := skel.find_bone("Hips")
	var chest := skel.find_bone("UpperChest")
	for clip in want:
		var src := lib
		var key := clip
		if clip.begins_with("ual:"):
			src = load(DIR + "anims/ual.res")
			key = clip.substr(4)
		if not src.has_animation(key):
			push_warning("no clip " + clip)
			continue
		var anim := src.get_animation(key)
		var dt := 1.0 / 30.0
		var n := int(anim.length / dt)
		var prev_r := Vector3.ZERO
		var prev_l := Vector3.ZERO
		var hip0 := Vector3.ZERO
		var rows := []
		for k in n + 1:
			var t := minf(k * dt, anim.length)
			AnimMeasure.pose(anim, skel, t)
			var r := AnimMeasure.global_pose(skel, rh).origin
			var l := AnimMeasure.global_pose(skel, lh).origin
			var hx := AnimMeasure.global_pose(skel, hips)
			var cx := AnimMeasure.global_pose(skel, chest)
			if k == 0:
				hip0 = hx.origin
				prev_r = r
				prev_l = l
			var fwd := hx.basis * Vector3.FORWARD
			var yaw := rad_to_deg(atan2(fwd.x, fwd.z))
			var up := cx.basis * Vector3.UP
			var lean_f := rad_to_deg(atan2(up.z, up.y))       # + = chest tipped toward +Z (model forward)
			var lean_s := rad_to_deg(atan2(up.x, up.y))
			rows.append([t, r.distance_to(prev_r) / dt, l.distance_to(prev_l) / dt, hx.origin - hip0, yaw, lean_f, lean_s, r])
			prev_r = r
			prev_l = l
		print("== %s  %.2f s" % [clip, anim.length])
		for row in rows:
			var d: Vector3 = row[3]
			var r: Vector3 = row[7]
			print("  %.2f  R %5.2f  L %5.2f  hips (%5.2f %5.2f %5.2f)  yaw %6.1f  lean f %5.1f s %5.1f  rhand (%5.2f %5.2f %5.2f)" % [row[0], row[1], row[2], d.x, d.y, d.z, row[4], row[5], row[6], r.x, r.y, r.z])
	quit()
