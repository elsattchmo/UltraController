extends SceneTree
## Stage 0a probe: can a navmesh be baked HEADLESS from a box list (no scene nodes), do door gaps +
## NavigationLink3D costs steer routes, do stairs connect, and what does a query cost?
##   godot --headless --path . --script res://tools/probe/probe_nav.gd
## Prints PROBE lines; the answers settle the mansion's nav pipeline (see the zombie plan).

const CELL := 0.1
const CELL_H := 0.05
const RADIUS := 0.38
const HEIGHT := 1.8

var boxes: Array = []          # [center, size] world-space axis-aligned boxes


func _initialize() -> void:
	print("PROBE nav: server=", NavigationServer3D.get_class(), " maps=", NavigationServer3D.get_maps().size())
	await _scenario("A open doorway", false, false)
	await _scenario("B plugged door + link", true, false)
	await _scenario("C plugged door + link, expensive", true, true)
	await _stairs()
	quit()


## Let the server take in what was set up (its command queue flushes on physics frames).
func _settle(map: RID) -> void:
	NavigationServer3D.map_force_update(map)
	var it0 := NavigationServer3D.map_get_iteration_id(map)
	var frames := 0
	while frames < 12:
		await physics_frame
		frames += 1
		if frames >= 2 and NavigationServer3D.map_get_closest_point(map, Vector3(-8, 0, -6)) != Vector3.ZERO:
			break
	print("PROBE   settle: %d physics frames, iteration %d -> %d" % [frames, it0, NavigationServer3D.map_get_iteration_id(map)])


func _box(c: Vector3, s: Vector3) -> void:
	boxes.append([c, s])


## Two rooms (x -10..-0.15 and 0.15..10, z -8..8) split by a wall with a doorway at z = 0 (1.3 m) and a
## second, open doorway at z = 6.2. A plug (door leaf) can close the first doorway.
func _build(plug: bool) -> void:
	boxes.clear()
	_box(Vector3(0, -0.5, 0), Vector3(24, 1.0, 20))                              # floor, top at y=0
	for sgn in [-1.0, 1.0]:                                                       # outer walls
		_box(Vector3(sgn * 10.25, 1.5, 0), Vector3(0.5, 3.0, 17))
		_box(Vector3(0, 1.5, sgn * 8.25), Vector3(21, 3.0, 0.5))
	# dividing wall x = 0 (0.3 thick), doorways at z 0 (width 1.3) and z 6.2 (width 1.3)
	var gaps := [[-0.65, 0.65], [5.55, 6.85]]
	var z := -8.0
	for g in gaps:
		_box(Vector3(0, 1.5, (z + g[0]) * 0.5), Vector3(0.3, 3.0, g[0] - z))
		z = g[1]
	_box(Vector3(0, 1.5, (z + 8.0) * 0.5), Vector3(0.3, 3.0, 8.0 - z))
	for g in gaps:                                                                # lintels above 2.2 m
		_box(Vector3(0, 2.6, (g[0] + g[1]) * 0.5), Vector3(0.3, 0.8, g[1] - g[0]))
	if plug:
		_box(Vector3(0, 1.1, 0), Vector3(0.1, 2.2, 1.3))                          # the closed door leaf


func _faces(c: Vector3, s: Vector3) -> PackedVector3Array:
	## Triangle soup, clockwise from outside (Godot's front face).
	var h := s * 0.5
	var f := PackedVector3Array()
	var quad := func(a: Vector3, b: Vector3, cc: Vector3, d: Vector3, out: Vector3) -> void:
		for t in [[a, b, cc], [a, cc, d]]:
			var n: Vector3 = ((t[1] as Vector3) - (t[0] as Vector3)).cross((t[2] as Vector3) - (t[0] as Vector3))
			if n.dot(out) > 0.0:
				f.append(t[0] + c); f.append(t[2] + c); f.append(t[1] + c)
			else:
				f.append(t[0] + c); f.append(t[1] + c); f.append(t[2] + c)
	quad.call(Vector3(-h.x, h.y, -h.z), Vector3(h.x, h.y, -h.z), Vector3(h.x, h.y, h.z), Vector3(-h.x, h.y, h.z), Vector3.UP)
	quad.call(Vector3(-h.x, -h.y, -h.z), Vector3(h.x, -h.y, -h.z), Vector3(h.x, -h.y, h.z), Vector3(-h.x, -h.y, h.z), Vector3.DOWN)
	quad.call(Vector3(h.x, -h.y, -h.z), Vector3(h.x, h.y, -h.z), Vector3(h.x, h.y, h.z), Vector3(h.x, -h.y, h.z), Vector3.RIGHT)
	quad.call(Vector3(-h.x, -h.y, -h.z), Vector3(-h.x, h.y, -h.z), Vector3(-h.x, h.y, h.z), Vector3(-h.x, -h.y, h.z), Vector3.LEFT)
	quad.call(Vector3(-h.x, -h.y, h.z), Vector3(h.x, -h.y, h.z), Vector3(h.x, h.y, h.z), Vector3(-h.x, h.y, h.z), Vector3.BACK)
	quad.call(Vector3(-h.x, -h.y, -h.z), Vector3(h.x, -h.y, -h.z), Vector3(h.x, h.y, -h.z), Vector3(-h.x, h.y, -h.z), Vector3.FORWARD)
	return f


func _bake(use_mesh_api: bool) -> NavigationMesh:
	var nm := NavigationMesh.new()
	nm.cell_size = CELL
	nm.cell_height = CELL_H
	nm.agent_radius = 0.4
	nm.agent_height = HEIGHT
	nm.agent_max_climb = 0.35
	nm.agent_max_slope = 40.0
	nm.filter_ledge_spans = true
	nm.filter_low_hanging_obstacles = true
	nm.filter_walkable_low_height_spans = true
	var data := NavigationMeshSourceGeometryData3D.new()
	var bm := BoxMesh.new()
	for b in boxes:
		if use_mesh_api:
			bm.size = b[1]
			data.add_mesh(bm, Transform3D(Basis(), b[0]))
		else:
			data.add_faces(_faces(b[0], b[1]), Transform3D())
	var t0 := Time.get_ticks_usec()
	NavigationServer3D.bake_from_source_geometry_data(nm, data)
	print("PROBE   bake (%s): %d polygons, %d vertices, %.1f ms" % ["add_mesh" if use_mesh_api else "add_faces", nm.get_polygon_count(), nm.get_vertices().size(), (Time.get_ticks_usec() - t0) / 1000.0])
	return nm


func _map(nm: NavigationMesh) -> RID:
	var map := NavigationServer3D.map_create()
	NavigationServer3D.map_set_cell_size(map, CELL)
	NavigationServer3D.map_set_cell_height(map, CELL_H)
	NavigationServer3D.map_set_edge_connection_margin(map, 0.3)
	NavigationServer3D.map_set_link_connection_radius(map, 0.5)
	NavigationServer3D.map_set_active(map, true)
	var region := NavigationServer3D.region_create()
	NavigationServer3D.region_set_map(region, map)
	NavigationServer3D.region_set_navigation_mesh(region, nm)
	NavigationServer3D.region_set_transform(region, Transform3D())
	return map


func _query(map: RID, a: Vector3, b: Vector3) -> NavigationPathQueryResult3D:
	var q := NavigationPathQueryParameters3D.new()
	q.map = map
	q.start_position = a
	q.target_position = b
	q.navigation_layers = 1
	q.metadata_flags = NavigationPathQueryParameters3D.PATH_METADATA_INCLUDE_ALL
	var r := NavigationPathQueryResult3D.new()
	NavigationServer3D.query_path(q, r)
	return r


func _len(p: PackedVector3Array) -> float:
	var l := 0.0
	for i in range(1, p.size()):
		l += p[i].distance_to(p[i - 1])
	return l


func _crossing_z(p: PackedVector3Array) -> float:
	## z where the path crosses the dividing wall x = 0 (NAN if it doesn't).
	for i in range(1, p.size()):
		if (p[i - 1].x < 0.0) != (p[i].x < 0.0):
			var t := (0.0 - p[i - 1].x) / (p[i].x - p[i - 1].x)
			return lerpf(p[i - 1].z, p[i].z, t)
	return NAN


func _scenario(label: String, plug: bool, expensive: bool) -> void:
	print("PROBE == ", label)
	_build(plug)
	for api in [false, true]:
		var nm := _bake(api)
		if nm.get_polygon_count() == 0:
			print("PROBE   -> EMPTY mesh with ", "add_mesh" if api else "add_faces")
			continue
		var map := _map(nm)
		var link := RID()
		if plug:
			link = NavigationServer3D.link_create()
			NavigationServer3D.link_set_map(link, map)
			NavigationServer3D.link_set_start_position(link, Vector3(-0.8, 0, 0))
			NavigationServer3D.link_set_end_position(link, Vector3(0.8, 0, 0))
			NavigationServer3D.link_set_bidirectional(link, true)
			NavigationServer3D.link_set_enter_cost(link, 100.0 if expensive else 1.0)
			NavigationServer3D.link_set_travel_cost(link, 100.0 if expensive else 1.0)
			NavigationServer3D.link_set_owner_id(link, 4242)
			NavigationServer3D.link_set_enabled(link, true)
		await _settle(map)
		var a := Vector3(-8, 0, -6)
		var b := Vector3(8, 0, -6)
		var vs := nm.get_vertices()
		var lo := Vector3(INF, INF, INF)
		var hi := Vector3(-INF, -INF, -INF)
		for v in vs:
			lo = lo.min(v)
			hi = hi.max(v)
		print("PROBE   mesh bounds ", lo, " .. ", hi, "; map regions=", NavigationServer3D.map_get_regions(map).size(), " active=", NavigationServer3D.map_is_active(map), " iteration=", NavigationServer3D.map_get_iteration_id(map), " closest(a)=", NavigationServer3D.map_get_closest_point(map, a), " old-api path=", NavigationServer3D.map_get_path(map, a, b, true).size())
		var r := _query(map, a, b)
		var path := r.path
		print("PROBE   [%s] path: %d points, len %.1f (straight %.1f), crosses wall at z=%.2f, owners=%s, types=%s" % ["add_mesh" if api else "add_faces", path.size(), _len(path), a.distance_to(b), _crossing_z(path), r.path_owner_ids, r.path_types])
		if not api and plug == false:
			# Timing: 1000 queries across the rooms.
			var t0 := Time.get_ticks_usec()
			for i in 1000:
				_query(map, Vector3(-8 + (i % 7), 0, -6 + (i % 5)), Vector3(8 - (i % 6), 0, 5 - (i % 9) * 0.3))
			print("PROBE   1000 queries: %.1f ms (%.3f ms each)" % [(Time.get_ticks_usec() - t0) / 1000.0, (Time.get_ticks_usec() - t0) / 1000000.0])
		if plug:
			# Flip the link's cost at runtime: the route must change without rebaking.
			var other := 1.0 if expensive else 100.0
			NavigationServer3D.link_set_enter_cost(link, other)
			NavigationServer3D.link_set_travel_cost(link, other)
			await _settle(map)
			var r2 := _query(map, a, b)
			print("PROBE   [%s] after cost -> %.0f: crosses wall at z=%.2f, len %.1f" % ["add_mesh" if api else "add_faces", other, _crossing_z(r2.path), _len(r2.path)])
			NavigationServer3D.link_set_enabled(link, false)
			await _settle(map)
			var r3 := _query(map, a, b)
			print("PROBE   [%s] link disabled: crosses wall at z=%.2f, len %.1f" % ["add_mesh" if api else "add_faces", _crossing_z(r3.path), _len(r3.path)])
		NavigationServer3D.free_rid(map)


func _stairs() -> void:
	print("PROBE == stairs + upper floor")
	boxes.clear()
	_box(Vector3(0, -0.5, 0), Vector3(24, 1.0, 20))
	# a flight: 8 risers of 0.175 up to y = 1.4, treads 0.28 deep, 1.4 m wide, running +x from x = -2
	for i in 8:
		var top := 0.175 * (i + 1)
		_box(Vector3(-2.0 + 0.28 * (i + 0.5), top * 0.5, 0), Vector3(0.28, top, 1.4))
	# landing/platform slab at y = 1.4 (x -2+2.24 .. 8), with 2 m of headroom above the floor under it
	# (starts where the flight ends - x 0.24 - or it roofs the stairs and takes their headroom)
	_box(Vector3(4.12, 1.35, 0), Vector3(7.76, 0.1, 6.0))
	for z in [-3.1, 3.1]:   # supports so the slab is not floating
		_box(Vector3(6.5, 0.7, z), Vector3(1.0, 1.4, 0.2))
	var nm := _bake(false)
	var map := _map(nm)
	await _settle(map)
	var r := _query(map, Vector3(-6, 0, 0), Vector3(6, 1.4, 0))
	print("PROBE   stairs path: %d points, len %.1f, ends y=%.2f (want 1.4)" % [r.path.size(), _len(r.path), r.path[r.path.size() - 1].y if r.path.size() > 0 else NAN])
	var under := _query(map, Vector3(6, 0, 1.5), Vector3(-6, 0, 0))
	print("PROBE   under-slab reachable at ground: %d points" % under.path.size())
	NavigationServer3D.free_rid(map)
