@tool
class_name UltraWater
extends Node3D
## A box of water. Origin = centre of the surface at rest level; `size` is the x/z extent and
## `depth` how far it goes down. The motor asks it questions analytically (`find()`,
## `surface_y()`), never through area signals, so prediction and replays see the same water.
## The level can move (`set_on`, e.g. a valve): it's a function of the world tick, replicated
## as discrete state. Floating props get buoyancy, drag and current here (authority only).

static var all: Array[UltraWater] = []

@export var size := Vector2(10, 10):
	set(v):
		size = v
		_rebuild()
@export var depth := 3.0:
	set(v):
		depth = v
		_rebuild()
@export var current := Vector3.ZERO       ## m/s, world space (swimmers and props drift)
@export var density := 1000.0             ## kg/m3
@export var drag := 2.0                   ## props: linear drag (1/s) when fully submerged
@export var raised_offset := 0.0          ## set_on(true) moves the surface by this much
@export var raise_time := 6.0
@export var material: Material
@export var show_surface := true
## Gentle waves: floating props bob and rock on them and the surface mesh moves with them.
## Swimming itself uses the flat level (deterministic); swimmers only bob visually.
@export_range(0, 0.5, 0.005) var wave_height := 0.05
@export_range(0.5, 20, 0.1) var wave_length := 3.2
@export_range(0, 5, 0.05) var wave_speed := 1.1

## Shared clock for waves (physics and the shader read the same value).
static var wave_time := 0.0
static var _clock_owner: UltraWater

var on := false
var _from := 0.0
var _to := 0.0
var _t0 := 0
var _dur := 1
var _mesh: MeshInstance3D
var _area: Area3D
var _box: BoxShape3D


func _ready() -> void:
	_rebuild()
	if Engine.is_editor_hint():
		return
	all.append(self)
	if _area:
		_area.body_entered.connect(_on_body_entered)
	if find_child("NetObject", false, false) == null:
		var o := NetObject.new()
		o.name = "NetObject"
		add_child(o)


func _exit_tree() -> void:
	all.erase(self)


func _rebuild() -> void:
	if not is_inside_tree():
		return
	_register_globals()
	if _mesh == null:
		_mesh = MeshInstance3D.new()
		_mesh.name = "Surface"
		_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_mesh, false, Node.INTERNAL_MODE_FRONT)
	var pm := PlaneMesh.new()
	pm.size = size
	pm.subdivide_width = clampi(int(size.x / 0.5), 0, 120)
	pm.subdivide_depth = clampi(int(size.y / 0.5), 0, 120)
	_mesh.mesh = pm
	_mesh.material_override = material if material else default_material()
	_mesh.set_instance_shader_parameter("wave_height", wave_height)
	_mesh.set_instance_shader_parameter("wave_length", wave_length)
	_mesh.set_instance_shader_parameter("wave_speed", wave_speed)
	_mesh.set_instance_shader_parameter("flow", Vector2(current.x, current.z))
	_mesh.visible = show_surface
	if Engine.is_editor_hint():
		return
	if _area == null:
		_area = Area3D.new()
		_area.name = "Buoyancy"
		_area.collision_layer = 0
		_area.collision_mask = UltraLayers.WORLD_DYNAMIC
		_area.monitorable = false
		var cs := CollisionShape3D.new()
		_box = BoxShape3D.new()
		cs.shape = _box
		_area.add_child(cs)
		add_child(_area, false, Node.INTERNAL_MODE_FRONT)
	var top := maxf(raised_offset, 0.0) + 0.5
	var bottom := depth - minf(raised_offset, 0.0)
	_box.size = Vector3(size.x, top + bottom, size.y)
	(_area.get_child(0) as Node3D).position = Vector3(0, (top - bottom) * 0.5, 0)


static var _default_mat: ShaderMaterial


static func _register_globals() -> void:
	if not (&"ultra_wave_time" in RenderingServer.global_shader_parameter_get_list()):
		RenderingServer.global_shader_parameter_add(&"ultra_wave_time", RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 0.0)


static func default_material() -> ShaderMaterial:
	_register_globals()
	if _default_mat == null:
		_default_mat = ShaderMaterial.new()
		_default_mat.shader = load("res://addons/ultra_controller/water/water.gdshader")
		for k: String in ["normal_a", "normal_b"]:
			var nt := NoiseTexture2D.new()
			nt.seamless = true
			nt.as_normal_map = true
			nt.bump_strength = 6.0
			nt.width = 256
			nt.height = 256
			var fn := FastNoiseLite.new()
			fn.frequency = 0.02 if k == "normal_a" else 0.035
			fn.seed = 7 if k == "normal_a" else 21
			nt.noise = fn
			_default_mat.set_shader_parameter(k, nt)
	return _default_mat


# ---------------------------------------------------------------- queries (deterministic)

## Surface height at a world tick.
func surface_y(tick: int) -> float:
	var k := clampf(float(tick - _t0) / float(maxi(_dur, 1)), 0.0, 1.0)
	return global_position.y + lerpf(_from, _to, smoothstep(0.0, 1.0, k))


func bottom_y() -> float:
	return global_position.y - depth - maxf(-raised_offset, 0.0)


func contains_xz(p: Vector3) -> bool:
	var l := global_transform.affine_inverse() * p
	return absf(l.x) <= size.x * 0.5 and absf(l.z) <= size.y * 0.5


## Wave offset at a world point (metres above the flat level).
func wave(p: Vector3, time := wave_time) -> float:
	if wave_height <= 0.0:
		return 0.0
	var k := TAU / wave_length
	var w := wave_speed * k
	return wave_height * (0.6 * sin(k * p.x + w * time) + 0.4 * sin(k * 0.73 * p.z - w * 1.27 * time + 1.3))


## The water whose box holds `p` (below its surface); the highest surface wins on overlap.
static func find(p: Vector3, tick: int) -> UltraWater:
	var best: UltraWater = null
	var best_y := -INF
	for w in all:
		if not w.contains_xz(p) or p.y < w.bottom_y() - 0.05:
			continue
		var sy := w.surface_y(tick)
		if p.y < sy and sy > best_y:
			best = w
			best_y = sy
	return best


## The water under or around `p` even if `p` is above the surface (for "about to enter").
static func find_column(p: Vector3) -> UltraWater:
	for w in all:
		if w.contains_xz(p) and p.y > w.bottom_y() - 0.05:
			return w
	return null


## How far below the surface `p` is (0 when not in water).
static func depth_at(p: Vector3, tick: int) -> float:
	var w := find(p, tick)
	return w.surface_y(tick) - p.y if w else 0.0


# ---------------------------------------------------------------- level (valve puzzles)

func set_on(v: bool) -> void:
	if v == on:
		return
	var now := TickPlatform.current_tick
	var cur := surface_y(now) - global_position.y
	on = v
	_from = cur
	_to = raised_offset if v else 0.0
	_t0 = now
	_dur = maxi(int(absf(_to - _from) / maxf(absf(raised_offset), 0.01) * raise_time * Engine.physics_ticks_per_second), 1)
	var o := find_child("NetObject", false, false) as NetObject
	if o:
		o.mark_dirty()


func get_net_state() -> Dictionary:
	return {"on": on, "from": _from, "to": _to, "t0": _t0, "dur": _dur}


func set_net_state(d: Dictionary) -> void:
	on = bool(d.get("on", on))
	_from = float(d.get("from", _from))
	_to = float(d.get("to", _to))
	_t0 = int(d.get("t0", _t0))
	_dur = int(d.get("dur", _dur))


# ---------------------------------------------------------------- presentation + props

func _process(_delta: float) -> void:
	if _mesh and not Engine.is_editor_hint():
		_mesh.position.y = surface_y(TickPlatform.current_tick) - global_position.y
		RenderingServer.global_shader_parameter_set(&"ultra_wave_time", wave_time)


func _physics_process(delta: float) -> void:
	if not Engine.is_editor_hint() and (_clock_owner == null or not is_instance_valid(_clock_owner)):
		_clock_owner = self
	if _clock_owner == self:
		wave_time += delta
	# Props are simulated wherever physics is authoritative (not on a client: they're kinematic).
	if Engine.is_editor_hint() or _area == null or UltraNet.mode == UltraNet.Mode.CLIENT:
		return
	var sy := surface_y(TickPlatform.current_tick)
	for body in _area.get_overlapping_bodies():
		var rb := body as RigidBody3D
		if rb == null or rb.freeze:
			continue
		_buoy(rb, sy)


## Buoyancy from 8 sample points of the body's first shape (so it rights itself and bobs),
## plus drag toward the current.
func _buoy(rb: RigidBody3D, sy: float) -> void:
	var cs: CollisionShape3D = null
	for c in rb.get_children():
		if c is CollisionShape3D:
			cs = c
			break
	if cs == null or cs.shape == null:
		return
	var ext := Vector3.ONE * 0.25
	var vol := 0.125
	var sh := cs.shape
	if sh is BoxShape3D:
		ext = (sh as BoxShape3D).size * 0.5
		vol = ext.x * ext.y * ext.z * 8.0
	elif sh is SphereShape3D:
		var r := (sh as SphereShape3D).radius
		ext = Vector3.ONE * r * 0.75
		vol = 4.0 / 3.0 * PI * r * r * r
	elif sh is CylinderShape3D:
		var cy := sh as CylinderShape3D
		ext = Vector3(cy.radius * 0.8, cy.height * 0.5, cy.radius * 0.8)
		vol = PI * cy.radius * cy.radius * cy.height
	elif sh is CapsuleShape3D:
		var cp := sh as CapsuleShape3D
		ext = Vector3(cp.radius * 0.8, cp.height * 0.5, cp.radius * 0.8)
		vol = PI * cp.radius * cp.radius * (cp.height - cp.radius * 2.0) + 4.0 / 3.0 * PI * pow(cp.radius, 3.0)
	var xf := rb.global_transform * cs.transform
	var g := float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	var per := density * g * vol / 8.0
	# Sample points at the centres of the eight octants; each owns a slab of half the height,
	# so submersion is exactly linear from the bottom face to the top face.
	var band := maxf(ext.y * 0.5, 0.03)
	var sub_total := 0.0
	var lift := float(rb.get_meta("buoyancy", 1.0))      # hollow / dense props tune how they sit
	for k in 8:
		var lp := Vector3(ext.x * (1.0 if k & 1 else -1.0), ext.y * (1.0 if k & 2 else -1.0), ext.z * (1.0 if k & 4 else -1.0)) * 0.5
		var wp := xf * lp
		var sub := clampf((sy + wave(wp) - wp.y) / (2.0 * band) + 0.5, 0.0, 1.0)
		if sub <= 0.0:
			continue
		sub_total += sub
		rb.apply_force(Vector3.UP * per * sub * lift, wp - rb.global_position)
	if sub_total <= 0.0:
		return
	var frac := sub_total / 8.0
	var contact := clampf(frac * 5.0, 0.0, 1.0)        # even a light float rides the current
	var rel := rb.linear_velocity - current
	# Heave: the waterline is a stiff spring (rho g A); damp it near critical so floats settle
	# after a few bobs instead of ringing. Fully under, plain drag.
	var k_wp := density * g * 4.0 * ext.x * ext.z * lift
	var c_heave := 2.0 * 0.7 * sqrt(k_wp * rb.mass)
	var c_v := c_heave if frac < 0.98 else drag * rb.mass
	var f := Vector3(-rel.x * drag * rb.mass * contact, -rel.y * c_v * contact, -rel.z * drag * rb.mass * contact)
	rb.apply_central_force(f)
	rb.apply_torque(-rb.angular_velocity * rb.mass * ext.length_squared() * 4.0 * contact)


## Something fell in: splash (presentation, every machine that simulates the prop).
func _on_body_entered(body: Node) -> void:
	var rb := body as RigidBody3D
	if rb == null:
		return
	var v := rb.linear_velocity
	if v.y < -2.0:
		var fx := UltraEffects.instance()
		if fx:
			var p := rb.global_position
			fx.splash(Vector3(p.x, surface_y(TickPlatform.current_tick) + wave(p), p.z), clampf(-v.y / 8.0 * sqrt(rb.mass / 20.0), 0.2, 1.2))
