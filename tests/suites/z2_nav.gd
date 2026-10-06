extends UltraTestSuite
## Zombie stage 2: the mansion and its navigation. The map builds from MansionLayout, the navmesh (the
## saved mansion_nav.res) takes in doors as links, every room can be walked to from the front lawn -
## through doors, up the grand stairs, up the back stair, down the cellar stair - closed / locked doors
## cost more but a path through them is still found (the AI has to bash), nothing is walkable over the
## Great Hall's void.

const L := preload("res://demo/maps/mansion/mansion_layout.gd")

var mansion: Mansion


func before_each() -> void:
	mansion = load_map("res://demo/maps/mansion.tscn") as Mansion
	await UltraNav.wait_ready(get_tree())


func after_each() -> void:
	await super.after_each()
	check(not UltraNav.exists(), "leaving the map tears the nav map down")


func _spawn() -> Vector3:
	return mansion.marker("spawn").global_position


## A point on the floor of room `r` that is clear of furniture: its middle, else the nearest of a ring of
## offsets whose nearest navmesh point is right there at floor level.
func _room_point(r: Array) -> Vector3:
	var rect := L.rect_of(r)
	var fy := L.floor_y(int(r[1]))
	for radius in [0.0, 1.0, 2.0, 3.0]:
		for k in (1 if radius == 0.0 else 8):
			var a := TAU * k / 8.0
			var p := Vector3(rect.get_center().x + cos(a) * radius, fy + 0.1, rect.get_center().y + sin(a) * radius)
			if not rect.grow(-0.5).has_point(Vector2(p.x, p.z)):
				continue
			var q := UltraNav.snap(p)
			if Vector2(q.x - p.x, q.z - p.z).length() < 0.25 and absf(q.y - p.y) < 0.35:
				return p
	info("no clear point found in %s" % r[0])
	return Vector3(rect.get_center().x, fy + 0.1, rect.get_center().y)


func _door_names(res: NavigationPathQueryResult3D) -> Array:
	var out := []
	for c: Array in UltraNav.crossings(res):
		out.append(String((c[1] as UltraDoor).door_name))
	return out


func test_the_house_builds() -> void:
	var b := mansion.built
	info("%d boxes (%d walls, %d floors, %d stairs, %d solid), %d doors, %d lights, %d rails, %d props" % [b.boxes.boxes.size(), b.boxes.count(BoxList.Kind.WALL), b.boxes.count(BoxList.Kind.FLOOR), b.boxes.count(BoxList.Kind.STAIR), b.boxes.count(BoxList.Kind.SOLID), b.doors.size(), b.lights.size(), b.rails, b.props])
	check(b.boxes.boxes.size() > 300 and b.boxes.boxes.size() < 2500, "a few hundred boxes (%d)" % b.boxes.boxes.size())
	check(b.doors.size() >= 55, "plenty of doors (%d)" % b.doors.size())
	var arches := 0
	for d in b.doors:
		if d.kind == "arch":
			arches += 1
	check(mansion.doors.size() == b.doors.size() - arches, "a UltraDoor for every door that isn't an archway")
	check(UltraNav.mesh != null and UltraNav.mesh.get_polygon_count() > 100, "a navmesh (%d polygons)" % UltraNav.mesh.get_polygon_count())
	check(UltraNav.mesh.resource_name == Mansion.nav_hash(b), "the saved navmesh matches the layout (rebake: tools/bake_mansion_nav.gd)")
	check(UltraNav.ready_for_queries(), "the nav map answers")
	# Every door joins two known rooms (or a room and the outside).
	for d in b.doors:
		var rooms: Array = d.rooms
		check(String(rooms[0]) != "" or String(rooms[1]) != "", "door %s joins something (%s | %s)" % [d.name, rooms[0], rooms[1]])
		check(String(rooms[0]) != String(rooms[1]), "door %s joins two different rooms (%s)" % [d.name, rooms[0]])


func test_every_room_is_reachable_from_the_lawn() -> void:
	var bad := []
	var total := 0.0
	for r: Array in L.ROOMS:
		var at := _room_point(r)
		var res := UltraNav.query(_spawn(), at)
		var pts := res.path
		if pts.size() < 2:
			bad.append("%s: no path" % r[0])
			continue
		var end := pts[pts.size() - 1]
		if Vector2(end.x - at.x, end.z - at.z).length() > 1.3 or absf(end.y - at.y) > 0.6:
			bad.append("%s: path ends at %s, %.1f m from the target %s (snap %s, path %d points, last of them %s)" % [r[0], end, end.distance_to(at), at, UltraNav.snap(at), pts.size(), str(pts.slice(maxi(pts.size() - 3, 0)))])
		total += UltraNav.length(pts)
	info("every room: %.0f m of path in all" % total)
	check(bad.is_empty(), "all rooms reachable: " + str(bad))


func test_doors_show_up_as_crossings() -> void:
	var res := UltraNav.query(_spawn(), Vector3(28, 0.1, 31))                 # the foyer
	var names := _door_names(res)
	check("d_front" in names and "d_vest_foyer" in names, "lawn -> foyer goes through the front doors then the vestibule's (%s)" % str(names))
	check(res.path[0].y < 0.5 and res.path[res.path.size() - 1].y < 0.5, "and stays on the ground")


func test_stairs_connect_the_floors() -> void:
	# Hall to the master bedroom upstairs: up a grand flight, round the gallery, through its door.
	var master := _room_point(L.room("master"))
	var res := UltraNav.query(Vector3(28, 0.1, 26), master)
	var pts := res.path
	var top := 0.0
	for p in pts:
		top = maxf(top, p.y)
	check(pts.size() > 3 and top > 3.4, "hall -> master climbs to the second floor (top %.2f, %d points)" % [top, pts.size()])
	check(absf(pts[pts.size() - 1].y - 3.75) < 0.4, "and arrives on it (y %.2f)" % pts[pts.size() - 1].y)
	# Upstairs west bedroom to the lobby below: the back stair.
	var down := UltraNav.query(_room_point(L.room("br3")), _room_point(L.room("w_lobby")))
	check(down.path.size() > 3 and absf(down.path[down.path.size() - 1].y - 0.1) < 0.6, "br3 -> lobby comes back down")
	# The cellar: from the kitchen, through the pantry and down its stair.
	var cellar := UltraNav.query(_room_point(L.room("kitchen")), _room_point(L.room("boiler")))
	var low := 0.0
	for p in cellar.path:
		low = minf(low, p.y)
	check(cellar.path.size() > 3 and low < -3.0, "kitchen -> boiler goes down to the basement (lowest %.2f)" % low)


func test_nothing_walkable_over_the_void() -> void:
	var vs := UltraNav.mesh.get_vertices()
	var bad := []
	for v in vs:
		if v.y > 3.4 and v.y < 4.2:
			var in_room := L.room_at(Vector2(v.x, v.z), 1) != ""
			var on_landing := false
			for lr: Array in L.LANDINGS:
				if Rect2(lr[0], lr[1], lr[2] - lr[0], lr[3] - lr[1]).grow(0.2).has_point(Vector2(v.x, v.z)):
					on_landing = true
			if not in_room and not on_landing:
				bad.append(v)
	check(bad.is_empty(), "no nav vertices on the second floor outside its rooms and landings (%d, first %s)" % [bad.size(), str(bad[0]) if not bad.is_empty() else ""])
	# A path from the gallery to a point over the void's middle can't end there.
	var res := UltraNav.query(_room_point(L.room("gallery_s")), Vector3(28, 3.75, 17))
	var end := res.path[res.path.size() - 1]
	check(end.y < 1.0 or Vector2(end.x - 28.0, end.z - 17.0).length() > 2.0, "a path to the middle of the void doesn't end up in the air (%s)" % str(end))


func test_a_locked_door_costs_more_and_gets_bashed() -> void:
	# parlor -> salon: the connecting door, or round by the corridor.
	var a := _room_point(L.room("parlor"))
	var b := _room_point(L.room("salon"))
	var res := UltraNav.query(a, b)
	var direct := UltraNav.length(res.path)
	var names := _door_names(res)
	check(names == ["d_parlor_salon"], "the short way is the connecting door (%s, %.1f m)" % [str(names), direct])
	var door := mansion.door("d_parlor_salon")
	door.set_locked(true)
	await UltraNav.settle(get_tree())
	var res2 := UltraNav.query(a, b)
	var names2 := _door_names(res2)
	info("with it locked: %s, %.1f m" % [str(names2), UltraNav.length(res2.path)])
	check("d_parlor_salon" not in names2, "locked: the path goes round (%s)" % str(names2))
	door.break_open()
	await UltraNav.settle(get_tree())
	var res3 := UltraNav.query(a, b)
	var names3 := _door_names(res3)
	check(names3 == ["d_parlor_salon"], "broken open: straight through again (%s)" % str(names3))


func test_door_rules() -> void:
	var shut := mansion.door("d_lib_corr")
	var locked := mansion.door("d_study_corr")
	var boards := mansion.door("u_guest_closet")
	check(not shut.is_open and not shut.is_blocked(), "an ordinary door starts shut and free")
	check(shut.ai_open(Vector3(0, 0, 0)) and shut.is_open, "ai_open opens it")
	check(locked.is_blocked() and not locked.ai_open(Vector3.ZERO) and not locked.is_open, "a locked one doesn't open for the AI")
	check(boards.barricaded and not boards.ai_open(Vector3.ZERO), "nor a barricaded one")
	var hp0 := boards.hp
	boards.bash(40.0, Vector3.ZERO)
	check(boards.hp == hp0 - 40.0 and not boards.broken, "a blow takes health off")
	for i in 5:
		boards.bash(40.0, Vector3.ZERO)
	check(boards.broken and boards.is_open and not boards.barricaded, "enough blows break it open for good")
	var link_cost: Array = Mansion.door_cost(locked)
	check(link_cost[0] > 20.0, "a locked door's crossing cost is steep (%.1f)" % link_cost[0])


func test_query_cost_budget() -> void:
	var rects := L.ROOMS
	var pts := []
	for r: Array in rects:
		pts.append(_room_point(r))
	var t0 := Time.get_ticks_usec()
	var n := 400
	for i in n:
		UltraNav.query(pts[i % pts.size()], pts[(i * 7 + 3) % pts.size()])
	var per := (Time.get_ticks_usec() - t0) / 1000.0 / n
	info("%d queries across the house: %.3f ms each" % [n, per])
	check(per < 1.5, "a path query is cheap (%.3f ms)" % per)
