class_name Mansion
extends Node3D
## The mansion map: builds itself at load from MansionLayout (boxes -> merged meshes, colliders, hinged
## doors, lights, a moonlit lawn) and sets up AI navigation (UltraNav: the baked navmesh from
## `mansion_nav.res` - rebake with tools/bake_mansion_nav.gd after changing the layout - plus a link
## across every door whose cost follows the door's state).
##
## Same surface as the playground for the demo's code: `marker(name)`; also `door(name)`, `room_at()`.

const NAV_PATH := "res://demo/maps/mansion/mansion_nav.res"
const DOOR_WOOD := Color(0.23, 0.14, 0.08)

var built: MansionBuilder.Built
var doors := {}                       ## layout door name -> [UltraDoor leaf, ...]
var _links := {}                      ## door name -> RID
var _markers := {}


## The built geometry is the same every time: made once per process.
static var _cache: MansionBuilder.Built


static func make_built() -> MansionBuilder.Built:
	if _cache == null:
		_cache = MansionBuilder.build()
	return _cache


## A fingerprint of everything the navmesh depends on (stale-mesh detection).
static func nav_hash(b: MansionBuilder.Built) -> String:
	var h := 17
	for box in b.boxes.boxes:
		if BoxList.in_nav(box.kind):
			h = (h * 31 + box.key().hash()) & 0x7fffffff
	h = (h * 31 + hash(b.boxes.nav_extra)) & 0x7fffffff
	return "mansion:%d:%d" % [b.boxes.boxes.size(), h]


func _ready() -> void:
	built = make_built()
	_materials()
	var geo := Node3D.new()
	geo.name = "Geometry"
	add_child(geo)
	built.boxes.build_meshes(geo, _mats, _mats[&"plaster"])
	var col := Node3D.new()
	col.name = "Collision"
	add_child(col)
	built.boxes.build_collision(col, UltraLayers.WORLD_STATIC)
	_make_doors()
	_make_lights()
	_grounds_lights()
	_environment()
	_make_markers()
	_setup_nav()


func _exit_tree() -> void:
	UltraNav.teardown()


# ------------------------------------------------------------------ queries

func marker(n: String) -> Marker3D:
	return _markers.get(n) as Marker3D


func door(door_name: String) -> UltraDoor:
	var leaves: Array = doors.get(door_name, [])
	return leaves[0] as UltraDoor if not leaves.is_empty() else null


## Every door back as the layout has it (a scenario reset).
func reset_doors() -> void:
	for d: Dictionary in built.doors:
		if d.kind == "arch":
			continue
		for leaf: UltraDoor in doors[String(d.name)]:
			leaf.reset(d.state == "open", d.state == "locked", d.state == "barricaded", 150.0 if d.state == "barricaded" else (90.0 if d.state == "locked" else 60.0))


## Room name at world position `p` ("" outside).
func room_at(p: Vector3) -> String:
	return MansionLayout.room_at(Vector2(p.x, p.z), MansionLayout.floor_of(p.y))


# ------------------------------------------------------------------ materials

var _mats := {}


func _mat(n: StringName, c: Color, rough := 0.85, metal := 0.0) -> void:
	var m := StandardMaterial3D.new()
	m.resource_name = String(n)
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	_mats[n] = m


func _materials() -> void:
	_mat(&"floor_wood", Color(0.30, 0.20, 0.12), 0.55)
	_mat(&"floor_plank", Color(0.26, 0.2, 0.14), 0.8)
	_mat(&"floor_runner", Color(0.34, 0.11, 0.11), 0.9)
	_mat(&"floor_tile", Color(0.55, 0.55, 0.5), 0.4)
	_mat(&"floor_marble", Color(0.68, 0.66, 0.62), 0.25)
	_mat(&"floor_carpet", Color(0.27, 0.12, 0.15), 0.95)
	_mat(&"floor_stone", Color(0.28, 0.28, 0.3), 0.9)
	_mat(&"ceiling", Color(0.72, 0.69, 0.62), 0.95)
	_mat(&"plaster", Color(0.7, 0.64, 0.54), 0.9)
	_mat(&"stone_wall", Color(0.4, 0.4, 0.42), 0.95)
	_mat(&"brick", Color(0.48, 0.27, 0.21), 0.95)
	_mat(&"stair_wood", Color(0.32, 0.2, 0.12), 0.6)
	_mat(&"rail", Color(0.2, 0.14, 0.1), 0.6)
	_mat(&"grass", Color(0.17, 0.27, 0.12), 1.0)
	_mat(&"path", Color(0.5, 0.48, 0.44), 0.9)
	_mat(&"pillar", Color(0.8, 0.78, 0.72), 0.4)
	_mat(&"wood", Color(0.35, 0.22, 0.12), 0.6)
	_mat(&"wood_dark", Color(0.2, 0.12, 0.07), 0.55)
	_mat(&"counter", Color(0.6, 0.6, 0.58), 0.35)
	_mat(&"bed", Color(0.55, 0.5, 0.45), 0.9)
	_mat(&"sofa", Color(0.35, 0.12, 0.12), 0.95)
	_mat(&"crate", Color(0.45, 0.35, 0.2), 0.9)
	_mat(&"planter", Color(0.3, 0.25, 0.15), 0.9)
	_mat(&"metal", Color(0.3, 0.32, 0.34), 0.45, 0.6)
	_mat(&"tile_white", Color(0.8, 0.8, 0.8), 0.3)


# ------------------------------------------------------------------ doors

func _make_doors() -> void:
	var root := Node3D.new()
	root.name = "Doors"
	add_child(root)
	var wood := StandardMaterial3D.new()
	wood.albedo_color = DOOR_WOOD
	wood.roughness = 0.6
	var boards := StandardMaterial3D.new()
	boards.albedo_color = Color(0.36, 0.28, 0.17)
	boards.roughness = 0.95
	for d: Dictionary in built.doors:
		if d.kind == "arch":
			continue
		var w: float = d.w
		var double: bool = d.kind == "double"
		var leaves: Array = []
		for k in (2 if double else 1):
			var door := UltraDoor.new()
			door.name = "%s_%d" % [d.name, k]
			door.door_name = StringName(d.name)
			var leaf_w := (w * 0.5 - 0.03) if double else (w - 0.04)
			door.size = Vector3(leaf_w, MansionLayout.DOOR_H - 0.03, 0.07)
			door.material = boards if d.state == "barricaded" else wood
			door.locked = d.state == "locked"
			door.key_id = StringName(d.key) if d.key != "" else &""
			door.barricaded = d.state == "barricaded"
			door.hp = 150.0 if door.barricaded else (90.0 if door.locked else 60.0)
			door.is_open = d.state == "open"
			var c: float = d.c
			var hinge: float = c - w * 0.5 + 0.02 if k == 0 else c + w * 0.5 - 0.02
			var turn: float
			if d.axis == "z":
				door.position = Vector3(hinge, d.center.y, d.at)
				turn = 0.0 if k == 0 else PI
			else:
				door.position = Vector3(d.at, d.center.y, hinge)
				turn = -PI * 0.5 if k == 0 else PI * 0.5
			door.basis = Basis(Vector3.UP, turn)
			root.add_child(door)
			leaves.append(door)
		if leaves.size() == 2:
			(leaves[0] as UltraDoor).partner = leaves[1]
			(leaves[1] as UltraDoor).partner = leaves[0]
		doors[String(d.name)] = leaves


# ------------------------------------------------------------------ lights, sky

## The room lights near a viewer are on, the rest are off (Forward+ pays for every lit light, through walls too).
const LIGHT_ON_RANGE := 24.0
var _lights: Array[Light3D] = []
var _light_t := 0.0


func _process(delta: float) -> void:
	_light_t -= delta
	if _light_t > 0.0 or DisplayServer.get_name() == "headless":
		return
	_light_t = 0.4
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var at := cam.global_position
	for l in _lights:
		var near: bool = l.global_position.distance_to(at) < LIGHT_ON_RANGE + (l as OmniLight3D).omni_range * 0.5
		if l.visible != near:
			l.visible = near


func _make_lights() -> void:
	var root := Node3D.new()
	root.name = "Lights"
	add_child(root)
	for l: Dictionary in built.lights:
		var o := OmniLight3D.new()
		o.position = l.pos
		o.light_color = l.color
		o.light_energy = l.energy
		o.omni_range = l.range
		o.omni_attenuation = 1.4
		o.shadow_enabled = bool(l.shadow)
		o.light_specular = 0.3
		o.distance_fade_enabled = true
		o.distance_fade_begin = 28.0
		o.distance_fade_length = 10.0
		root.add_child(o)
		_lights.append(o)


## Lamps out on the grounds: the porch and the path to the gate.
func _grounds_lights() -> void:
	var root := get_node("Lights")
	for p: Vector3 in [Vector3(25.2, 2.7, 41.4), Vector3(30.8, 2.7, 41.4), Vector3(23.5, 2.6, 50.0), Vector3(32.5, 2.6, 50.0), Vector3(23.5, 2.6, 59.0), Vector3(32.5, 2.6, 59.0), Vector3(23.5, 2.6, 68.0), Vector3(32.5, 2.6, 68.0)]:
		var o := OmniLight3D.new()
		o.position = p
		o.light_color = Color(1.0, 0.82, 0.55)
		o.light_energy = 2.4
		o.omni_range = 11.0
		o.omni_attenuation = 1.3
		o.distance_fade_enabled = true
		o.distance_fade_begin = 40.0
		o.distance_fade_length = 15.0
		root.add_child(o)
		# (A post under each lamp on the path: collision + a visible lamp head.)
		if p.z > 45.0:
			var post := MeshInstance3D.new()
			var cm := CylinderMesh.new()
			cm.top_radius = 0.05
			cm.bottom_radius = 0.07
			cm.height = p.y
			post.mesh = cm
			post.material_override = _mats[&"metal"]
			post.position = Vector3(p.x, p.y * 0.5, p.z)
			add_child(post)


func _environment() -> void:
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	var env := Environment.new()
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.02, 0.03, 0.07)
	sm.sky_horizon_color = Color(0.07, 0.09, 0.14)
	sm.ground_horizon_color = Color(0.05, 0.06, 0.08)
	sm.ground_bottom_color = Color(0.02, 0.02, 0.03)
	sky.sky_material = sm
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.24, 0.27, 0.36)
	env.ambient_light_energy = 0.5
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.ssao_enabled = true
	env.glow_enabled = true
	env.glow_intensity = 0.4
	env.fog_enabled = true
	env.fog_light_color = Color(0.05, 0.06, 0.09)
	env.fog_density = 0.004
	we.environment = env
	add_child(we)
	var moon := DirectionalLight3D.new()
	moon.name = "Moon"
	moon.rotation_degrees = Vector3(-48, 28, 0)
	moon.light_color = Color(0.55, 0.65, 1.0)
	moon.light_energy = 0.9
	moon.shadow_enabled = true
	moon.directional_shadow_max_distance = 70.0
	add_child(moon)


# ------------------------------------------------------------------ markers

func _make_markers() -> void:
	var root := Node3D.new()
	root.name = "Markers"
	add_child(root)
	var spots := {"spawn": Vector3(28, 0.05, 58), "spawn_2": Vector3(24, 0.05, 58), "spawn_3": Vector3(32, 0.05, 58), "spawn_4": Vector3(28, 0.05, 62)}
	for n: String in spots:
		var m := Marker3D.new()
		m.name = n
		m.position = spots[n]
		root.add_child(m)
		_markers[n] = m


# ------------------------------------------------------------------ navigation

func _setup_nav() -> void:
	var nm: NavigationMesh = load(NAV_PATH) as NavigationMesh if ResourceLoader.exists(NAV_PATH) else null
	if nm == null or nm.resource_name != nav_hash(built):
		push_warning("mansion navmesh missing or stale: baking now (godot --headless --path . res://tools/tool_runner.tscn -- --tool=res://tools/bake_mansion_nav.gd)")
		nm = UltraNav.bake(built.boxes.nav_source())
	UltraNav.setup(nm)
	for d: Dictionary in built.doors:
		if d.kind == "arch":
			continue
		var leaves: Array = doors[String(d.name)]
		var lead: UltraDoor = leaves[0]
		var cost := door_cost(lead)
		_links[String(d.name)] = UltraNav.add_link(lead, d.a, d.b, cost[0], cost[1])
		var dn := String(d.name)
		for leaf: UltraDoor in leaves:
			leaf.state_changed.connect(_refresh_link.bind(dn))


## [enter cost, travel cost] of crossing a door as it stands: open 0, shut 3, locked / barricaded 20 + hp / 10
## (a detour that long is preferred; a path that does go through needs the door bashed).
static func door_cost(d: UltraDoor) -> Array:
	if d.broken or d.is_open:
		return [0.0, 1.0]
	if d.is_blocked():
		return [20.0 + d.hp / 10.0, 1.0]
	return [3.0, 1.0]


func _refresh_link(door_name: String) -> void:
	var link: RID = _links.get(door_name, RID())
	if not link.is_valid():
		return
	var cost := door_cost((doors[door_name] as Array)[0])
	UltraNav.set_link_costs(link, cost[0], cost[1])
