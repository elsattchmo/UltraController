extends Node
## Builds demo/maps/playground.tscn from code, so the playground is reproducible and every
## measurement in it is exact. Each zone is a function; later milestones add zones here.
## Run: godot --headless --path . res://tools/tool_runner.tscn -- --tool=res://demo/maps/playground/build_playground.gd

const OUT := "res://demo/maps/playground.tscn"

var scene_root: Node3D
var grid: ShaderMaterial
var grid_dark: ShaderMaterial
var grid_accent: ShaderMaterial
var grid_ice: ShaderMaterial
var markers: Node3D


func _ready() -> void:
	scene_root = Node3D.new()
	scene_root.name = "Playground"
	scene_root.set_script(load("res://demo/maps/playground/playground.gd"))
	grid = _grid_mat(Color(0.56, 0.58, 0.61), Color(0.3, 0.32, 0.35))
	grid_dark = _grid_mat(Color(0.36, 0.38, 0.42), Color(0.22, 0.23, 0.26))
	grid_accent = _grid_mat(Color(0.86, 0.56, 0.26), Color(0.55, 0.32, 0.12))
	grid_ice = _grid_mat(Color(0.7, 0.86, 0.95), Color(0.45, 0.62, 0.75))
	markers = _node(scene_root, "Markers")
	_environment()
	_ground()
	_hub()
	_locomotion_yard()
	_platforms()
	_props()
	_gallery()
	(load("res://demo/maps/playground/zones_m4.gd") as Script).new(self).build()
	var ps := PackedScene.new()
	var err := ps.pack(scene_root)
	if err == OK:
		err = ResourceSaver.save(ps, OUT)
	print("playground saved: ", err)
	scene_root.free()


# ------------------------------------------------------------------ helpers

func _grid_mat(base: Color, line: Color) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://demo/shaders/proto_grid.gdshader")
	m.set_shader_parameter("base_color", base)
	m.set_shader_parameter("line_color", line)
	return m


func _node(parent: Node, n: String, type := "Node3D") -> Node3D:
	var x: Node3D = ClassDB.instantiate(type)
	x.name = n
	parent.add_child(x)
	x.owner = scene_root
	return x


func _own(n: Node) -> void:
	n.owner = scene_root
	for c in n.get_children():
		_own(c)


## Static box with collision. `pos` is the CENTRE; rot in degrees.
func _box(parent: Node, n: String, size: Vector3, pos: Vector3, rot := Vector3.ZERO, mat: Material = null, friction := -1.0) -> StaticBody3D:
	var sb := StaticBody3D.new()
	sb.name = n
	sb.collision_layer = UltraLayers.WORLD_STATIC
	sb.collision_mask = 0
	sb.position = pos
	sb.rotation_degrees = rot
	if friction >= 0.0:
		var pm := PhysicsMaterial.new()
		pm.friction = friction
		sb.physics_material_override = pm
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat if mat else grid
	sb.add_child(mi)
	var cs := CollisionShape3D.new()
	cs.name = "Shape"
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	sb.add_child(cs)
	parent.add_child(sb)
	_own(sb)
	return sb


## Box whose TOP face sits at `top_y`, footprint centred at (x, z).
func _block(parent: Node, n: String, size: Vector3, x: float, z: float, top_y: float, mat: Material = null, friction := -1.0) -> StaticBody3D:
	return _box(parent, n, size, Vector3(x, top_y - size.y * 0.5, z), Vector3.ZERO, mat, friction)


func _marker(n: String, pos: Vector3, yaw_deg := 0.0) -> void:
	var m := Marker3D.new()
	m.name = n
	m.position = pos
	m.rotation_degrees.y = yaw_deg
	markers.add_child(m)
	m.owner = scene_root


func _label(parent: Node, text: String, pos: Vector3, size := 64, yaw_deg := 0.0) -> void:
	var l := Label3D.new()
	l.text = text
	l.position = pos
	l.rotation_degrees.y = yaw_deg
	l.font_size = size
	l.outline_size = 12
	l.pixel_size = 0.006
	l.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	l.double_sided = true
	parent.add_child(l)
	l.owner = scene_root


# ------------------------------------------------------------------ zones

func _environment() -> void:
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	var env := Environment.new()
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.32, 0.5, 0.78)
	sm.sky_horizon_color = Color(0.72, 0.78, 0.86)
	sm.ground_horizon_color = Color(0.6, 0.62, 0.65)
	sky.sky_material = sm
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.9
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.ssao_enabled = true
	env.glow_enabled = true
	env.glow_intensity = 0.3
	we.environment = env
	scene_root.add_child(we)
	we.owner = scene_root
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-52, -35, 0)
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 120.0
	scene_root.add_child(sun)
	sun.owner = scene_root


func _ground() -> void:
	_block(scene_root, "Ground", Vector3(400, 1, 400), 0, 0, 0.0, grid_dark)


func _hub() -> void:
	var hub := _node(scene_root, "Hub")
	_block(hub, "Pad", Vector3(24, 0.2, 24), 0, 0, 0.2, grid)
	_marker("spawn", Vector3(0, 0.25, 4), 0)
	_marker("spawn_2", Vector3(2.5, 0.25, 4), 0)
	_marker("spawn_3", Vector3(-2.5, 0.25, 4), 0)
	_marker("spawn_4", Vector3(0, 0.25, 7), 0)
	_label(hub, "ULTRA PLAYGROUND\nNorth: Locomotion Yard   West: Animation Gallery   East: Physics Sandbox", Vector3(0, 3.2, -8), 96)


func _locomotion_yard() -> void:
	var y := _node(scene_root, "LocomotionYard")
	# Speed lane: 70 m with a post every 5 m.
	var lane := _node(y, "SpeedLane")
	_block(lane, "Lane", Vector3(4, 0.05, 72), -24, -50, 0.05, grid)
	for i in 15:
		var z := -14.0 - i * 5.0
		_block(lane, "Post%02d" % i, Vector3(0.15, 1.2, 0.15), -26.4, z, 1.2, grid_accent)
		_label(lane, "%d m" % (i * 5), Vector3(-26.4, 1.5, z), 48, 90)
	_marker("speed_start", Vector3(-24, 0.1, -14), 0)
	_marker("speed_end", Vector3(-24, 0.1, -84), 0)

	# Ramps: 10..50°, each 4 m wide with a landing on top.
	var ramps := _node(y, "Ramps")
	var angles := [10, 20, 30, 40, 45, 50]
	for i in angles.size():
		var a: float = angles[i]
		var x := -10.0 + i * 5.0
		var rise := 2.5
		var run := rise / tan(deg_to_rad(a))
		var len := sqrt(rise * rise + run * run)
		var z0 := -20.0
		# Slab rotated about X; centre at mid-slope, pushed down by half thickness.
		var t := 0.4
		var mid := Vector3(x, rise * 0.5 - cos(deg_to_rad(a)) * t * 0.5, z0 - run * 0.5 - sin(deg_to_rad(a)) * t * 0.5)
		_box(ramps, "Ramp%d" % a, Vector3(4, t, len), mid, Vector3(a, 0, 0), grid_accent if a >= 45 else grid)
		_block(ramps, "Top%d" % a, Vector3(4, rise, 4), x, z0 - run - 2.0, rise, grid)
		_label(ramps, "%d°" % a, Vector3(x, 0.6, z0 + 0.6), 64)
		_marker("ramp_%d" % a, Vector3(x, 0.1, z0 + 3.0), 0)
		_marker("ramp_%d_top" % a, Vector3(x, rise + 0.05, z0 - run - 2.0), 0)

	# Stairs: four flights, 2 m total rise each, tread 0.32 m.
	var stairs := _node(y, "Stairs")
	var risers := [0.15, 0.20, 0.30, 0.45]
	for i in risers.size():
		var r: float = risers[i]
		var x := 25.0 + i * 5.0
		var n := int(ceil(2.0 / r))
		for s in n:
			var top := (s + 1) * r
			_block(stairs, "Step%d_%d" % [int(r * 100), s], Vector3(4, top, 0.32), x, -20.0 - s * 0.32, top, grid if s % 2 == 0 else grid_dark)
		_block(stairs, "Landing%d" % int(r * 100), Vector3(4, n * r, 3), x, -20.0 - n * 0.32 - 1.5 + 0.16, n * r, grid)
		_label(stairs, "riser %d cm" % int(r * 100), Vector3(x, 0.8, -18.6), 56)
		_marker("stairs_%d" % int(r * 100), Vector3(x, 0.1, -16.5), 0)
		_marker("stairs_%d_top" % int(r * 100), Vector3(x, n * r + 0.05, -20.0 - n * 0.32 - 1.5), 0)

	# Rock field for foot IK.
	var rocks := _node(y, "RockField")
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	for i in 70:
		var p := Vector3(rng.randf_range(-12, 12), 0, rng.randf_range(-50, -70))
		var s := Vector3(rng.randf_range(0.4, 1.6), rng.randf_range(0.1, 0.45), rng.randf_range(0.4, 1.6))
		_box(rocks, "Rock%02d" % i, s, p + Vector3(0, s.y * 0.3, 0), Vector3(rng.randf_range(-12, 12), rng.randf_range(0, 180), rng.randf_range(-12, 12)), grid_dark)
	_marker("rocks", Vector3(0, 0.1, -46), 0)

	# Ice pad.
	_block(y, "Ice", Vector3(12, 0.06, 12), 22, -60, 0.06, grid_ice, 0.04)
	_label(y, "ICE", Vector3(22, 0.8, -53.5), 80)
	_marker("ice", Vector3(22, 0.1, -52), 0)

	# Crouch gap (1.25 m clearance) and crawl tunnel (0.75 m).
	var low := _node(y, "LowClearance")
	_block(low, "CrouchRoof", Vector3(4, 0.4, 8), 38, -60, 1.65, grid_dark)
	_block(low, "CrouchWallL", Vector3(0.4, 1.25, 8), 35.8, -60, 1.25)
	_block(low, "CrouchWallR", Vector3(0.4, 1.25, 8), 40.2, -60, 1.25)
	_label(low, "crouch 1.25 m", Vector3(38, 2.2, -55.8), 56)
	_marker("crouch_gap", Vector3(38, 0.1, -54), 0)
	_block(low, "CrawlRoof", Vector3(4, 0.4, 8), 45, -60, 1.15, grid_dark)
	_block(low, "CrawlWallL", Vector3(0.4, 0.75, 8), 42.8, -60, 0.75)
	_block(low, "CrawlWallR", Vector3(0.4, 0.75, 8), 47.2, -60, 0.75)
	_label(low, "crawl 0.75 m", Vector3(45, 1.7, -55.8), 56)
	_marker("crawl_tunnel", Vector3(45, 0.1, -54), 0)

	# Slalom poles.
	for i in 8:
		_block(y, "Pole%d" % i, Vector3(0.25, 2.0, 0.25), -6.0 + (i % 2) * 3.0, -82.0 - i * 4.0, 2.0, grid_accent)
	_marker("slalom", Vector3(-4.5, 0.1, -78), 0)

	# Ledge walls (traversal arrives in M6; walls are here for the jump/landing tests now).
	var ledges := _node(y, "LedgeWalls")
	var hs := [0.5, 1.0, 1.5, 2.0, 2.5]
	for i in hs.size():
		var h: float = hs[i]
		var x := 58.0 + i * 5.0
		_block(ledges, "Wall%d" % int(h * 100), Vector3(4, h, 4), x, -30, h, grid if i % 2 == 0 else grid_dark)
		_label(ledges, "%.1f m" % h, Vector3(x, h + 0.4, -27.9), 56)
		_marker("ledge_%d" % int(h * 100), Vector3(x, 0.1, -24), 0)
	# Drop tower for landing tests (2/4/6/9 m).
	var drops := [2.0, 4.0, 6.0, 9.0]
	for i in drops.size():
		var h: float = drops[i]
		var x := 58.0 + i * 6.0
		_block(ledges, "Drop%d" % int(h), Vector3(4, h, 4), x, -48, h, grid_accent)
		_label(ledges, "drop %d m" % int(h), Vector3(x, h + 0.5, -45.9), 56)
		_marker("drop_%d" % int(h), Vector3(x, h + 0.05, -48), 180)


func _platform(parent: Node, n: String, size: Vector3, pos: Vector3, mode: int, travel := Vector3.ZERO, leg := 4.0, pause := 1.0, spin := 0.0) -> TickPlatform:
	var tp := TickPlatform.new()
	tp.name = n
	tp.mode = mode
	tp.travel = travel
	tp.leg_time = leg
	tp.pause = pause
	tp.spin_deg = spin
	tp.position = pos
	tp.collision_layer = UltraLayers.WORLD_STATIC
	tp.collision_mask = 0
	var mi := MeshInstance3D.new()
	var bm: PrimitiveMesh = BoxMesh.new() if mode != TickPlatform.Mode.ROTATE else CylinderMesh.new()
	if bm is BoxMesh:
		(bm as BoxMesh).size = size
	else:
		(bm as CylinderMesh).top_radius = size.x * 0.5
		(bm as CylinderMesh).bottom_radius = size.x * 0.5
		(bm as CylinderMesh).height = size.y
	mi.mesh = bm
	mi.material_override = grid_accent
	tp.add_child(mi)
	var cs := CollisionShape3D.new()
	if mode == TickPlatform.Mode.ROTATE:
		var cyl := CylinderShape3D.new()
		cyl.radius = size.x * 0.5
		cyl.height = size.y
		cs.shape = cyl
	else:
		var bs := BoxShape3D.new()
		bs.size = size
		cs.shape = bs
	tp.add_child(cs)
	parent.add_child(tp)
	_own(tp)
	return tp


func _platforms() -> void:
	var p := _node(scene_root, "MovingPlatforms")
	_platform(p, "Linear", Vector3(4, 0.4, 4), Vector3(-40, 0.6, -30), TickPlatform.Mode.LINEAR, Vector3(0, 0, -16), 5.0, 1.5)
	_marker("platform_linear", Vector3(-40, 0.85, -30), 0)
	_platform(p, "Rotating", Vector3(8, 0.4, 8), Vector3(-40, 0.3, -60), TickPlatform.Mode.ROTATE, Vector3.ZERO, 4.0, 0.0, 35.0)
	_marker("platform_rotate", Vector3(-38, 0.55, -60), 0)
	_platform(p, "Elevator", Vector3(3.5, 0.3, 3.5), Vector3(-40, 0.2, -80), TickPlatform.Mode.ELEVATOR, Vector3(0, 6, 0), 4.0, 2.0)
	_block(p, "ElevatorTop", Vector3(6, 6.2, 6), -40, -85.5, 6.2, grid)
	_marker("platform_elevator", Vector3(-40, 0.4, -80), 180)
	_label(p, "MOVING PLATFORMS", Vector3(-40, 3, -24), 72)


func _props() -> void:
	var p := _node(scene_root, "PhysicsSandbox")
	var masses := [1.0, 5.0, 20.0, 60.0, 200.0]
	for i in masses.size():
		var m: float = masses[i]
		var s := 0.35 + pow(m, 1.0 / 3.0) * 0.12
		var rb := RigidBody3D.new()
		rb.name = "Crate%dkg" % int(m)
		rb.mass = m
		rb.collision_layer = UltraLayers.WORLD_DYNAMIC
		rb.collision_mask = UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC | UltraLayers.CHARACTER
		rb.position = Vector3(30 + i * 3.0, s * 0.5 + 0.01, 10)
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3.ONE * s
		mi.mesh = bm
		mi.material_override = grid_accent
		rb.add_child(mi)
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = Vector3.ONE * s
		cs.shape = bs
		rb.add_child(cs)
		p.add_child(rb)
		_own(rb)
		_label(p, "%d kg" % int(m), Vector3(30 + i * 3.0, s + 0.4, 10), 48)
	_marker("sandbox", Vector3(36, 0.1, 16), 0)


func _gallery() -> void:
	var g := _node(scene_root, "AnimationGallery")
	g.position = Vector3(-50, 0, 0)
	g.set_script(load("res://demo/maps/playground/animation_gallery.gd"))
	_block(scene_root, "GalleryFloor", Vector3(60, 0.1, 80), -75, 0, 0.1, grid)
	_marker("gallery", Vector3(-45, 0.15, 0), 90)
