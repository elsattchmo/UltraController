extends UltraTestSuite
## The playground's own furniture: the animation gallery (a mannequin per clip, every library) stands on floor
## however many clips the intakes have added; the sprint track's dummy sprints round its square.

var main: Node


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


## The sprint track: a dummy sprinting round its square for as long as the session runs (a moving target).
func test_sprinter_runs_its_loop() -> void:
	var had := UltraDummyPost.auto_spawn
	UltraDummyPost.auto_spawn = true          # (tests keep the yard's dummies off; this one is about one)
	main = (load("res://demo/main.tscn") as PackedScene).instantiate()
	add_child(main)
	await ticks(3)
	UltraNet.stop()
	await ticks(2)
	main.call("menu_start", "single")
	await ticks(30)
	var s: UltraCharacter = null
	for p: NetPlayer in UltraNet.players.values():
		if p.is_bot and p.display_name == "Sprinter":
			s = p.character
	if not check(s != null, "the sprint track has its Sprinter"):
		UltraDummyPost.auto_spawn = had
		UltraNet.stop()
		main.queue_free()
		main = null
		return
	var post := main.find_child("Sprinter", true, false) as Node3D
	var fast := 0
	var far := 0.0
	for i in 600:
		await ticks(1)
		if Vector2(s.state.vel.x, s.state.vel.z).length() > 5.0:
			fast += 1
		far = maxf(far, Vector2(s.state.pos.x - post.global_position.x, s.state.pos.z - post.global_position.z).length())
	info("Sprinter: %d of 600 ticks over 5 m/s, furthest %.1f m from its post" % [fast, far])
	check(fast > 300, "it sprints most of the time (%d ticks over 5 m/s)" % fast)
	check(far < 18.0 * 1.5 + 2.0, "and stays on its square (furthest %.1f m)" % far)
	UltraDummyPost.auto_spawn = had
	UltraNet.stop()
	main.queue_free()
	main = null
	await ticks(3)
