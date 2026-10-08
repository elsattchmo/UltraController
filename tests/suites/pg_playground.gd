extends UltraTestSuite
## The playground's own furniture: the animation gallery (a mannequin per clip, every library) stands on floor
## however many clips the intakes have added.


func test_every_gallery_mannequin_stands_on_floor() -> void:
	var map := load_playground()
	var g := map.find_child("AnimationGallery", true, false)
	if not check(g != null and g.has_method("build"), "the playground has its animation gallery"):
		return
	g.call("build")
	await ticks(3)
	var entries: Array = g.get("_entries")
	var space := (g as Node3D).get_world_3d().direct_space_state
	var off := []
	for e: Array in entries:
		var p: Vector3 = (e[0] as Node3D).global_position
		var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 0.5, p + Vector3.DOWN * 1.0, UltraLayers.WORLD_STATIC)
		var hit := space.intersect_ray(q)
		if hit.is_empty() or absf((hit.position as Vector3).y - p.y) > 0.05:
			off.append(String(e[2]))
	info("%d clips in the gallery" % entries.size())
	check(entries.size() > 150, "every library's clips are out (%d)" % entries.size())
	check(off.is_empty(), "every mannequin stands on the gallery floor (%d off: %s)" % [off.size(), off.slice(0, 5)])
