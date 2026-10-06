class_name UltraNav
extends RefCounted
## Navigation for AI characters: ONE private NavigationServer3D map (no scene regions, no project
## navigation settings), a baked mesh and a NavigationLink per door. Queries go straight to the server
## (`query_path`), reusing one parameters / result object - a character that thinks ten times a second
## costs a few tens of microseconds per query.
##
## The mesh is baked from boxes (BoxList.nav_source) at cell 0.1 - the default 0.25 closes a 1 m doorway
## (the agent radius is 0.4: the erosion eats the opening) - and agent height 1.8, climb 0.35 (a 0.174
## stair step), slope 40 deg. A closed door is a PLUG in the geometry plus a link across it whose cost
## says how bad crossing is (open 0, shut 3, locked / barricaded 20+: a detour of up to that many
## metres is preferred; a path that does cross a locked door tells the AI to bash it).
##
## The server takes a few physics frames to take in a new map: `ready_for_queries()` / `wait_ready()`.

const CELL := 0.1
const CELL_H := 0.05
const AGENT_RADIUS := 0.4
const AGENT_HEIGHT := 1.8
const MAX_CLIMB := 0.35
const MAX_SLOPE := 40.0
const LAYERS := 1

static var map := RID()
static var region := RID()
static var mesh: NavigationMesh
static var _links: Array[RID] = []
static var _query := NavigationPathQueryParameters3D.new()
static var _result := NavigationPathQueryResult3D.new()
static var queries := 0                      ## path queries made since setup (stats, tests)


## The standard mesh settings (everything that matters for doorways and stairs).
static func make_mesh() -> NavigationMesh:
	var nm := NavigationMesh.new()
	nm.cell_size = CELL
	nm.cell_height = CELL_H
	nm.agent_radius = AGENT_RADIUS
	nm.agent_height = AGENT_HEIGHT
	nm.agent_max_climb = MAX_CLIMB
	nm.agent_max_slope = MAX_SLOPE
	nm.filter_ledge_spans = true
	nm.filter_low_hanging_obstacles = true
	nm.filter_walkable_low_height_spans = true
	return nm


## Bake `source` (BoxList.nav_source()). Takes seconds for a building: save the result (a .res) and
## load that at runtime.
static func bake(source: NavigationMeshSourceGeometryData3D) -> NavigationMesh:
	var nm := make_mesh()
	NavigationServer3D.bake_from_source_geometry_data(nm, source)
	return nm


## Make the map from a baked mesh (replacing any earlier one).
static func setup(nm: NavigationMesh) -> void:
	teardown()
	mesh = nm
	map = NavigationServer3D.map_create()
	NavigationServer3D.map_set_cell_size(map, CELL)
	NavigationServer3D.map_set_cell_height(map, CELL_H)
	NavigationServer3D.map_set_edge_connection_margin(map, 0.3)
	NavigationServer3D.map_set_link_connection_radius(map, 0.5)
	NavigationServer3D.map_set_use_async_iterations(map, false)       # (changes show up on the next sync, not one later)
	NavigationServer3D.map_set_active(map, true)
	region = NavigationServer3D.region_create()
	NavigationServer3D.region_set_map(region, map)
	NavigationServer3D.region_set_navigation_layers(region, LAYERS)
	NavigationServer3D.region_set_navigation_mesh(region, nm)
	NavigationServer3D.region_set_transform(region, Transform3D())
	queries = 0


static func teardown() -> void:
	for l in _links:
		NavigationServer3D.free_rid(l)
	_links.clear()
	if region.is_valid():
		NavigationServer3D.free_rid(region)
	if map.is_valid():
		NavigationServer3D.free_rid(map)
	region = RID()
	map = RID()
	mesh = null


static func exists() -> bool:
	return map.is_valid()


## True once the server answers for this map.
static func ready_for_queries() -> bool:
	return map.is_valid() and NavigationServer3D.map_get_iteration_id(map) > 1


## Await (up to `frames` physics frames) the map being usable. Returns whether it is.
static func wait_ready(tree: SceneTree, frames := 90) -> bool:
	NavigationServer3D.map_force_update(map)
	for i in frames:
		if ready_for_queries():
			return true
		await tree.physics_frame
	return ready_for_queries()


## Let the server take in what changed (costs, links): force an update and wait two physics frames.
## (Not needed in play - a character that asks a frame later sees it - but a test that changes a door
## and queries at once does.)
static func settle(tree: SceneTree) -> void:
	await tree.physics_frame                  # (the server's command queue flushes)
	NavigationServer3D.map_force_update(map)
	await tree.physics_frame
	await tree.physics_frame


## A link across a door (or any one-off connection): both ends on the mesh, both ways. `owner`
## (the door) comes back in `path_owner_ids` when a path crosses it.
static func add_link(link_owner: Object, a: Vector3, b: Vector3, enter := 0.0, travel := 1.0) -> RID:
	var link := NavigationServer3D.link_create()
	NavigationServer3D.link_set_map(link, map)
	NavigationServer3D.link_set_start_position(link, a)
	NavigationServer3D.link_set_end_position(link, b)
	NavigationServer3D.link_set_bidirectional(link, true)
	NavigationServer3D.link_set_enter_cost(link, enter)
	NavigationServer3D.link_set_travel_cost(link, travel)
	NavigationServer3D.link_set_navigation_layers(link, LAYERS)
	NavigationServer3D.link_set_owner_id(link, link_owner.get_instance_id())
	NavigationServer3D.link_set_enabled(link, true)
	_links.append(link)
	return link


static func set_link_costs(link: RID, enter: float, travel := 1.0) -> void:
	NavigationServer3D.link_set_enter_cost(link, enter)
	NavigationServer3D.link_set_travel_cost(link, travel)


## The nearest point on the mesh to `p` (Vector3.ZERO-free: INF when there is no mesh).
static func snap(p: Vector3) -> Vector3:
	if not map.is_valid():
		return Vector3.INF
	return NavigationServer3D.map_get_closest_point(map, p)


## A path from `from` to `to` (both snapped to the mesh by the server), world space, with the
## server's metadata. The returned object is SHARED: read it before the next query.
static func query(from: Vector3, to: Vector3) -> NavigationPathQueryResult3D:
	_query.map = map
	_query.start_position = from
	_query.target_position = to
	_query.navigation_layers = LAYERS
	_query.metadata_flags = NavigationPathQueryParameters3D.PATH_METADATA_INCLUDE_ALL
	_query.path_postprocessing = NavigationPathQueryParameters3D.PATH_POSTPROCESSING_CORRIDORFUNNEL
	_result.reset()
	NavigationServer3D.query_path(_query, _result)
	queries += 1
	return _result


## Just the points ([] when there is no way).
static func path(from: Vector3, to: Vector3) -> PackedVector3Array:
	return query(from, to).path.duplicate()


## Path length in metres (INF when there is none).
static func length(pts: PackedVector3Array) -> float:
	if pts.size() < 2:
		return INF if pts.is_empty() else 0.0
	var l := 0.0
	for i in range(1, pts.size()):
		l += pts[i].distance_to(pts[i - 1])
	return l


## The links a result crosses, in order: [[point index, owner Object], ...] (a door per entry).
static func crossings(r: NavigationPathQueryResult3D) -> Array:
	var out := []
	var types := r.path_types
	var owners := r.path_owner_ids
	for i in types.size():
		if types[i] == NavigationPathQueryResult3D.PATH_SEGMENT_TYPE_LINK:
			var id := int(owners[i])
			if id != 0 and is_instance_id_valid(id):
				out.append([i, instance_from_id(id)])
	return out
