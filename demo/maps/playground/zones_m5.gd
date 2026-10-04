extends RefCounted
## M5 playground: physics sandbox (grabbable crates, balls, barrels, a box tower), the
## two-person beam, crate stairs to the green key + storeroom, the heavy-gate log, and a
## seesaw catapult.

var b: Node
var m4: RefCounted         ## zones_m4 helpers (_room, _door, _world_item, _scripted)


func _init(builder: Node) -> void:
	b = builder
	m4 = (load("res://demo/maps/playground/zones_m4.gd") as Script).new(builder)


func build() -> void:
	var z: Node3D = b._node(b.scene_root, "PhysicsYard")
	z.position = Vector3(48, 0, 22)
	b._block(z, "Floor", Vector3(40, 0.05, 36), 0, 0, 0.05, b.grid)
	b._label(z, "PHYSICS YARD   (hold E to grab · G to throw · Q to drop · F8 for a helper)", Vector3(0, 4.0, -17), 60)
	_sandbox(z)
	_beam(z)
	_crate_stairs(z)
	_heavy_gate(z)
	_seesaw(z)


## Rigid prop with collision, grab interactable (by mass) and replication.
func prop(parent: Node, n: String, shape: String, size: Vector3, mass: float, pos: Vector3, color := Color(-1, 0, 0)) -> RigidBody3D:
	var rb := RigidBody3D.new()
	rb.name = n
	rb.mass = mass
	rb.collision_layer = UltraLayers.WORLD_DYNAMIC | UltraLayers.INTERACTABLE
	rb.collision_mask = UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC | UltraLayers.CHARACTER
	rb.position = pos
	rb.physics_material_override = _prop_material()
	var mi := MeshInstance3D.new()
	var cs := CollisionShape3D.new()
	match shape:
		"sphere":
			var sm := SphereMesh.new()
			sm.radius = size.x
			sm.height = size.x * 2.0
			mi.mesh = sm
			var ss := SphereShape3D.new()
			ss.radius = size.x
			cs.shape = ss
		"cylinder":
			var cm := CylinderMesh.new()
			cm.top_radius = size.x
			cm.bottom_radius = size.x
			cm.height = size.y
			mi.mesh = cm
			var cy := CylinderShape3D.new()
			cy.radius = size.x
			cy.height = size.y
			cs.shape = cy
		_:
			var bm := BoxMesh.new()
			bm.size = size
			mi.mesh = bm
			var bs := BoxShape3D.new()
			bs.size = size
			cs.shape = bs
	if color.r >= 0.0:
		var m := StandardMaterial3D.new()
		m.albedo_color = color
		mi.material_override = m
	else:
		mi.material_override = b.grid_accent
	rb.add_child(mi)
	rb.add_child(cs)
	var it := Interactable.new()
	it.name = "Interactable"
	if mass <= 25.0:
		it.kind = Interactable.Kind.GRAB
		it.prompt = "Grab (%d kg)" % int(mass)
	elif mass <= 60.0:
		it.kind = Interactable.Kind.CARRY
		it.prompt = "Carry (%d kg)" % int(mass)
	else:
		it.kind = Interactable.Kind.PUSH
		it.prompt = "Too heavy to lift — push it"
		it.enabled = true
	rb.add_child(it)
	var no := NetObject.new()
	no.name = "NetObject"
	rb.add_child(no)
	parent.add_child(rb)
	b._own(rb)
	return rb


static var _pm: PhysicsMaterial


static func _prop_material() -> PhysicsMaterial:
	if _pm == null:
		_pm = PhysicsMaterial.new()
		_pm.friction = 0.45           # wooden crate on a floor
		_pm.bounce = 0.05
	return _pm


func _sandbox(z: Node3D) -> void:
	var masses := [1.0, 5.0, 20.0, 60.0, 200.0]
	for i in masses.size():
		var m: float = masses[i]
		var s := 0.35 + pow(m, 1.0 / 3.0) * 0.12
		prop(z, "Crate%dkg" % int(m), "box", Vector3.ONE * s, m, Vector3(-16 + i * 3.0, s * 0.5 + 0.06, -12))
		b._label(z, "%d kg" % int(m), Vector3(-16 + i * 3.0, s + 0.45, -12), 44)
	b._marker("sandbox", z.position + Vector3(-10, 0.1, -7), 180)
	prop(z, "BallLight", "sphere", Vector3(0.2, 0, 0), 1.5, Vector3(-16, 0.3, -8), Color(0.9, 0.3, 0.2))
	prop(z, "BallHeavy", "sphere", Vector3(0.3, 0, 0), 12.0, Vector3(-14, 0.4, -8), Color(0.3, 0.3, 0.35))
	for i in 3:
		prop(z, "Barrel%d" % i, "cylinder", Vector3(0.3, 0.9, 0), 30.0, Vector3(-11 + i * 0.8, 0.5, -8), Color(0.55, 0.25, 0.1))
	# Box tower to knock over.
	for row in 5:
		for col in 2:
			prop(z, "TowerBox%d_%d" % [row, col], "box", Vector3(0.4, 0.4, 0.4), 3.0, Vector3(-5 + col * 0.42, 0.26 + row * 0.41, -10), Color(0.85, 0.75, 0.4))


func _beam(z: Node3D) -> void:
	# 120 kg: one person can lift an end, two can carry it.
	var rb := prop(z, "TeamBeam", "box", Vector3(3.2, 0.32, 0.32), 120.0, Vector3(4, 0.25, -11), Color(0.45, 0.3, 0.15))
	var it := rb.get_node("Interactable") as Interactable
	it.kind = Interactable.Kind.TEAM_LIFT
	it.prompt = "Lift an end (120 kg — needs two)"
	it.max_distance = 2.2
	for i in 2:
		var g := Marker3D.new()
		g.name = "Grip%d" % i
		g.position = Vector3(-1.4 if i == 0 else 1.4, 0, 0)
		rb.add_child(g)
		g.owner = b.scene_root
	b._label(z, "TEAM LIFT 120 kg", Vector3(4, 1.2, -11), 48)
	b._marker("team_beam", z.position + Vector3(4, 0.1, -8.5), 180)


func _crate_stairs(z: Node3D) -> void:
	# A 3.5 m shelf with the green key; stack the crates to climb up.
	b._block(z, "Shelf", Vector3(3, 3.5, 2), 12, -12, 3.5, b.grid_dark)
	m4._world_item(z, "res://assets/items/keys/key_green_world.tscn", Vector3(12, 3.62, -12))
	b._label(z, "green key up there — stack the crates", Vector3(12, 4.4, -10.9), 44)
	for i in 4:
		prop(z, "StairCrate%d" % i, "box", Vector3(0.9, 0.9, 0.9), 18.0, Vector3(8 + (i % 2) * 1.1, 0.5, -7 + (i / 2) * 1.1))
	var door_at: Vector3 = m4._room(z, "GreenStore", Vector3(16, 0, 4), Vector2(5, 5))
	m4._door(z, "GreenDoor", door_at, {"locked": true, "key_id": &"green", "locked_text": "Locked. The green key is on the shelf."})
	m4._world_item(z, "res://assets/items/ammo/ammo_9mm_world.tscn", Vector3(16, 0.3, 5), 48)
	m4._world_item(z, "res://assets/items/medkit/medkit_world.tscn", Vector3(15, 0.3, 5))
	b._marker("crate_stairs", z.position + Vector3(9, 0.1, -5), 180)


func _heavy_gate(z: Node3D) -> void:
	# A 150 kg log lies across a doorway: two people (or you + the helper) move it.
	var door_at: Vector3 = m4._room(z, "GateRoom", Vector3(-12, 0, 8), Vector2(6, 5))
	var rb := prop(z, "GateLog", "box", Vector3(2.4, 0.5, 0.5), 150.0, door_at + Vector3(0, 0.3, -0.6), Color(0.4, 0.27, 0.15))
	var it := rb.get_node("Interactable") as Interactable
	it.kind = Interactable.Kind.TEAM_LIFT
	it.prompt = "Lift an end (150 kg — needs two)"
	for i in 2:
		var g := Marker3D.new()
		g.name = "Grip%d" % i
		g.position = Vector3(-1.0 if i == 0 else 1.0, 0, 0)
		rb.add_child(g)
		g.owner = b.scene_root
	b._block(z, "GateBlockL", Vector3(0.5, 1.6, 0.5), door_at.x - 1.35, door_at.z - 0.6, 1.6, b.grid_dark)
	b._block(z, "GateBlockR", Vector3(0.5, 1.6, 0.5), door_at.x + 1.35, door_at.z - 0.6, 1.6, b.grid_dark)
	b._label(z, "HEAVY GATE — carry the log away together", door_at + Vector3(0, 2.6, -0.3), 44)
	m4._world_item(z, "res://assets/items/ammo/ammo_9mm_world.tscn", door_at + Vector3(0, 0.3, 2.5), 36)
	b._marker("heavy_gate", z.position + door_at + Vector3(0, 0.1, -3.0), 180)


func _seesaw(z: Node3D) -> void:
	# Plank on a fulcrum (hinge). Drop something heavy on the high end to launch the light crate.
	var base := Vector3(-2, 0, 6)
	b._block(z, "Fulcrum", Vector3(0.4, 0.6, 0.8), base.x, base.z, 0.6, b.grid_dark)
	var plank := RigidBody3D.new()
	plank.name = "SeesawPlank"
	plank.mass = 25.0
	plank.collision_layer = UltraLayers.WORLD_DYNAMIC
	plank.collision_mask = UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC | UltraLayers.CHARACTER
	plank.position = base + Vector3(0, 0.68, 0)
	plank.rotation_degrees.z = -14
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(5.0, 0.12, 0.8)
	mi.mesh = bm
	mi.material_override = b.grid_accent
	plank.add_child(mi)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = bm.size
	cs.shape = bs
	plank.add_child(cs)
	var no := NetObject.new()
	no.name = "NetObject"
	plank.add_child(no)
	z.add_child(plank)
	b._own(plank)
	var hinge := HingeJoint3D.new()
	hinge.name = "SeesawHinge"
	hinge.position = base + Vector3(0, 0.68, 0)
	hinge.rotation_degrees.y = 90
	z.add_child(hinge)
	hinge.owner = b.scene_root
	hinge.node_a = NodePath("../SeesawPlank")
	hinge.set_flag(HingeJoint3D.FLAG_USE_LIMIT, true)
	hinge.set_param(HingeJoint3D.PARAM_LIMIT_LOWER, deg_to_rad(-18))
	hinge.set_param(HingeJoint3D.PARAM_LIMIT_UPPER, deg_to_rad(18))
	prop(z, "LaunchCrate", "box", Vector3(0.4, 0.4, 0.4), 4.0, base + Vector3(-2.2, 1.5, 0), Color(0.3, 0.6, 0.9))
	b._block(z, "LaunchLedge", Vector3(3, 3, 3), base.x - 6, base.z + 5, 3.0, b.grid_dark)
	m4._world_item(z, "res://assets/items/medkit/medkit_world.tscn", base + Vector3(-6, 3.15, 5))
	b._label(z, "SEESAW — drop a heavy crate on the high end", base + Vector3(0, 2.4, -1), 44)
	b._marker("seesaw", z.position + base + Vector3(3, 0.1, -3), 180)
