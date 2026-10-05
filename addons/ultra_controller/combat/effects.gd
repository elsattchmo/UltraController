class_name UltraEffects
extends Node3D
## Cosmetic combat effects for one world: muzzle flashes, ejected shells, tracers, impact
## sparks, blood puffs. Driven by character item events (predicted / remote) and the
## server's impact / hit events. Pooled and cheap; no gameplay state.

const MAX_SHELLS := 40

var _shells: Array[RigidBody3D] = []
var _flash_mat: StandardMaterial3D
var _tracer_mat: StandardMaterial3D
var _spark_mat: StandardMaterial3D
var _blood_mat: StandardMaterial3D
var _shell_mesh: CylinderMesh
var _shell_mat: StandardMaterial3D
## Characters controlled on this machine: their impacts were already predicted.
var local_ids: Array[int] = []

static var _current: UltraEffects


## The effects node of the running world (null in tools / tests without one).
static func instance() -> UltraEffects:
	return _current if is_instance_valid(_current) else null


func _ready() -> void:
	_current = self
	_flash_mat = _unshaded(Color(1.0, 0.75, 0.35), 4.0)
	_tracer_mat = _unshaded(Color(1.0, 0.85, 0.5), 2.0)
	_spark_mat = _unshaded(Color(1.0, 0.7, 0.3), 3.0)
	_blood_mat = _unshaded(Color(0.45, 0.02, 0.02), 0.0)
	_shell_mesh = CylinderMesh.new()
	_shell_mesh.top_radius = 0.0045
	_shell_mesh.bottom_radius = 0.0045
	_shell_mesh.height = 0.019
	_shell_mat = StandardMaterial3D.new()
	_shell_mat.albedo_color = Color(0.85, 0.65, 0.25)
	_shell_mat.metallic = 0.9
	_shell_mat.roughness = 0.3
	UltraNet.world.on_event(&"impact", _on_impact)
	UltraNet.world.on_event(&"hit", _on_hit)


static func _unshaded(c: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	m.emission_enabled = energy > 0.0
	m.emission = c
	m.emission_energy_multiplier = energy
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m


## Hook a character's item events (call for every character with visuals).
func watch(c: UltraCharacter) -> void:
	c.item_event.connect(func(kind: StringName, data: Dictionary) -> void: _on_item(c, kind, data))


func _on_item(c: UltraCharacter, kind: StringName, data: Dictionary) -> void:
	if kind != &"fire":
		return
	var eq := c.get_node_or_null("Equipment") as UltraEquipmentVisual
	var muzzle := eq.muzzle_transform() if eq else c.visual_root.global_transform
	flash(muzzle)
	if eq:
		shell(eq.eject_transform(), c.visual_root.global_basis * Vector3.RIGHT)
	# Tracer + predicted impact for shots this machine simulated (data carries the ray).
	if data.has("origin"):
		var space := get_world_3d().direct_space_state
		var to: Vector3 = data.origin + (data.dir as Vector3) * 120.0
		var ex: Array[RID] = [c.get_rid()]
		if c.hit_volume:
			ex.append(c.hit_volume.get_rid())
		var q := PhysicsRayQueryParameters3D.create(data.origin, to, UltraCombat.MASK, ex)
		var hit := UltraCombat._cast(space, q, data.origin, data.dir)   # same limb test as the server
		var end: Vector3 = hit.position if not hit.is_empty() else to
		tracer(muzzle.origin, end)
		if not hit.is_empty():
			var who := UltraCharacter.of_collider(hit.collider)
			if who:
				if who.damage_profile.blood_on():
					blood(hit.position, hit.normal)
			else:
				sparks(hit.position, hit.normal)
	else:
		tracer(muzzle.origin, muzzle.origin + (-muzzle.basis.z) * 40.0)


func _on_impact(pos: Vector3, normal: Vector3, kind: StringName, shooter_id: int) -> void:
	if shooter_id in local_ids:
		return
	if kind == &"flesh":
		blood(pos, normal)
	else:
		sparks(pos, normal)


func _on_hit(target_id: int, pos: Vector3, dir: Vector3, amount: float, attacker_id: int, region := -1, kind := &"bullet") -> void:
	var c := UltraNet.world.character(target_id)
	if c:
		c.react_to_hit(region, dir, amount)
	if attacker_id in local_ids or kind == &"impact" or kind == &"drown":
		return
	if c == null or c.damage_profile.blood_on():
		blood(pos, -dir)


func flash(at: Transform3D) -> void:
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.75, 0.4)
	light.light_energy = 3.0
	light.omni_range = 4.0
	light.shadow_enabled = false
	add_child(light)
	light.global_position = at.origin
	var quad := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(0.09, 0.09)
	quad.mesh = qm
	quad.material_override = _flash_mat
	quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(quad)
	quad.global_transform = Transform3D(at.basis.rotated(at.basis.z.normalized(), randf() * TAU), at.origin + (-at.basis.z) * 0.03)
	var t := create_tween()
	t.tween_property(light, "light_energy", 0.0, 0.06)
	t.parallel().tween_property(quad, "scale", Vector3.ONE * 1.6, 0.05)
	t.tween_callback(light.queue_free)
	t.tween_callback(quad.queue_free)


func shell(at: Transform3D, right: Vector3) -> void:
	var rb: RigidBody3D
	if _shells.size() >= MAX_SHELLS:
		rb = _shells.pop_front()
	else:
		rb = RigidBody3D.new()
		rb.collision_layer = 0
		rb.collision_mask = UltraLayers.WORLD_STATIC
		rb.mass = 0.01
		var mi := MeshInstance3D.new()
		mi.mesh = _shell_mesh
		mi.material_override = _shell_mat
		rb.add_child(mi)
		var cs := CollisionShape3D.new()
		var cyl := CylinderShape3D.new()
		cyl.radius = 0.0045
		cyl.height = 0.019
		cs.shape = cyl
		rb.add_child(cs)
		add_child(rb)
	_shells.append(rb)
	rb.global_transform = Transform3D(Basis(Vector3.BACK, PI * 0.5) * at.basis, at.origin)
	rb.linear_velocity = right * randf_range(1.6, 2.4) + Vector3.UP * randf_range(1.5, 2.2)
	rb.angular_velocity = Vector3(randf_range(-20, 20), randf_range(-20, 20), randf_range(-20, 20))


func tracer(from: Vector3, to: Vector3) -> void:
	var len := from.distance_to(to)
	if len < 0.5:
		return
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.008, 0.008, minf(len, 3.0))
	mi.mesh = bm
	mi.material_override = _tracer_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	var dir := (to - from) / len
	var basis := Basis.looking_at(dir, Vector3.UP if absf(dir.y) < 0.99 else Vector3.RIGHT)
	mi.global_transform = Transform3D(basis, from + dir * minf(len, 3.0) * 0.5)
	var t := create_tween()
	t.tween_property(mi, "global_position", to - dir * minf(len, 3.0) * 0.5, clampf(len / 300.0, 0.02, 0.4))
	t.tween_callback(mi.queue_free)


func sparks(at: Vector3, normal: Vector3) -> void:
	_burst(at, normal, _spark_mat, 10, 3.0, 0.25)


var _splash_mat: StandardMaterial3D
var _ring_mat: StandardMaterial3D


## Something hit the water at `at` (on the surface); strength ~0.2 (a pebble) .. 1.2 (a dive).
func splash(at: Vector3, strength := 1.0) -> void:
	if _splash_mat == null:
		_splash_mat = StandardMaterial3D.new()
		_splash_mat.albedo_color = Color(0.85, 0.94, 1.0, 0.85)
		_splash_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_splash_mat.roughness = 0.1
		_ring_mat = StandardMaterial3D.new()
		_ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_ring_mat.albedo_color = Color(0.92, 0.97, 1.0, 0.7)
		_ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Droplets thrown up and out.
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.emitting = false
	p.amount = int(lerpf(16, 70, clampf(strength, 0.0, 1.0)))
	p.lifetime = 0.9
	p.explosiveness = 0.92
	p.direction = Vector3.UP
	p.spread = 32.0
	p.initial_velocity_min = 1.5 * strength + 0.5
	p.initial_velocity_max = 4.5 * strength + 1.0
	p.gravity = Vector3(0, -9.8, 0)
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_RING
	p.emission_ring_axis = Vector3.UP
	p.emission_ring_radius = 0.25 + 0.2 * strength
	p.emission_ring_inner_radius = 0.05
	p.emission_ring_height = 0.0
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.6
	var m := SphereMesh.new()
	m.radius = 0.025
	m.height = 0.05
	m.radial_segments = 6
	m.rings = 3
	p.mesh = m
	p.material_override = _splash_mat
	add_child(p)
	p.global_position = at + Vector3.UP * 0.02
	p.emitting = true
	get_tree().create_timer(1.3).timeout.connect(p.queue_free)
	# A column of spray for big entries.
	if strength > 0.5:
		var col := p.duplicate() as CPUParticles3D
		col.amount = 30
		col.spread = 8.0
		col.emission_ring_radius = 0.12
		col.initial_velocity_min = 3.0 * strength
		col.initial_velocity_max = 5.5 * strength
		add_child(col)
		col.global_position = at
		col.emitting = true
		get_tree().create_timer(1.5).timeout.connect(col.queue_free)
	# A ring spreading out on the surface.
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.42
	tm.outer_radius = 0.5
	tm.rings = 24
	tm.ring_segments = 4
	ring.mesh = tm
	ring.material_override = _ring_mat.duplicate()
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ring)
	ring.global_position = at + Vector3.UP * 0.01
	ring.scale = Vector3(0.5, 0.05, 0.5)
	var grow := 1.5 + 2.5 * strength
	var tw := create_tween()
	tw.tween_property(ring, "scale", Vector3(grow, 0.05, grow), 1.2).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tw.parallel().tween_property(ring.material_override, "albedo_color:a", 0.0, 1.2)
	tw.tween_callback(ring.queue_free)


func blood(at: Vector3, normal: Vector3) -> void:
	_burst(at, normal, _blood_mat, 14, 1.8, 0.45)


func _burst(at: Vector3, normal: Vector3, mat: Material, n: int, speed: float, life: float) -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.emitting = false
	p.amount = n
	p.lifetime = life
	p.explosiveness = 1.0
	p.direction = normal
	p.spread = 55.0
	p.initial_velocity_min = speed * 0.5
	p.initial_velocity_max = speed
	p.gravity = Vector3(0, -9.8, 0)
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.2
	var m := SphereMesh.new()
	m.radius = 0.012
	m.height = 0.024
	m.radial_segments = 4
	m.rings = 2
	p.mesh = m
	p.material_override = mat
	add_child(p)
	p.global_position = at + normal * 0.01
	p.emitting = true
	get_tree().create_timer(life + 0.2).timeout.connect(p.queue_free)
