extends RefCounted
## M6 playground: timed parkour course (vault, mantle, ledge, shimmy, ladder, rope swing,
## pipe), rope zone (climb ropes, rappel cliff), ladders, pulley lift, rope drawbridge.

var b: Node


func _init(builder: Node) -> void:
	b = builder


func build() -> void:
	_parkour()
	_ropes()
	_puzzles()


func _ladder(parent: Node, n: String, pos: Vector3, h: float, yaw := 0.0, kind := 0) -> Node3D:
	var l := Node3D.new()
	l.set_script(load("res://addons/ultra_controller/traversal/ultra_ladder.gd"))
	l.name = n
	l.position = pos
	l.rotation_degrees.y = yaw
	l.set("height", h)
	l.set("kind", kind)
	parent.add_child(l)
	l.owner = b.scene_root
	return l


func _rope(parent: Node, n: String, anchor: Vector3, length: float, kind := 0) -> Node3D:
	var r := Node3D.new()
	r.set_script(load("res://addons/ultra_controller/traversal/ultra_rope.gd"))
	r.name = n
	r.position = anchor
	r.set("length", length)
	r.set("kind", kind)
	parent.add_child(r)
	r.owner = b.scene_root
	# A beam to hang it from.
	b._block(parent, n + "Beam", Vector3(0.3, 0.3, 2.0), anchor.x, anchor.z, anchor.y + 0.3, b.grid_dark)
	return r


func _gate(parent: Node, n: String, pos: Vector3, size: Vector3) -> Area3D:
	var a := Area3D.new()
	a.name = n
	a.position = pos
	a.collision_layer = 0
	a.collision_mask = UltraLayers.CHARACTER
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	a.add_child(cs)
	parent.add_child(a)
	b._own(a)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(size.x, 0.05, 0.3)
	mi.mesh = bm
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.2, 0.9, 0.4) if n.begins_with("Start") else Color(0.95, 0.3, 0.2)
	m.emission_enabled = true
	m.emission = m.albedo_color
	mi.material_override = m
	mi.position = pos + Vector3(0, -size.y * 0.5 + 0.03, 0)
	parent.add_child(mi)
	mi.owner = b.scene_root
	return a


func _parkour() -> void:
	var p: Node3D = b._node(b.scene_root, "Parkour")
	var x := 110.0
	b._label(p, "PARKOUR — run it for time", Vector3(x, 3.0, -8), 80)
	_gate(p, "StartGate", Vector3(x, 1.0, -10), Vector3(4, 2, 1))
	b._marker("parkour_start", Vector3(x, 0.1, -7), 0)
	# 1) vault boxes
	for i in 2:
		b._block(p, "Vault%d" % i, Vector3(3, 1.0, 0.4), x, -16.0 - i * 6.0, 1.0, b.grid_accent)
	# 2) mantle block 1.3 m
	b._block(p, "Mantle", Vector3(3, 1.3, 3), x, -31.5, 1.3, b.grid)
	b._block(p, "MantleDown", Vector3(3, 0.65, 1.0), x, -33.5, 0.65, b.grid_dark)
	# 3) ledge 2.1 m with a platform
	b._block(p, "LedgeWall", Vector3(3, 2.1, 4), x, -40, 2.1, b.grid)
	# 4) shimmy: hang on a shallow ledge and move right to where the overhang ends
	b._block(p, "ShimmyWall", Vector3(8, 2.2, 1.0), x + 2.5, -46.0, 2.2, b.grid_dark)
	b._block(p, "ShimmyOverhang", Vector3(6, 1.6, 1.0), x + 1.5, -46.2, 3.8, b.grid_dark)
	b._block(p, "ShimmyBack", Vector3(8, 2.2, 2.0), x + 2.5, -47.6, 2.2, b.grid)
	# drop down into a ladder well
	b._block(p, "Tower", Vector3(4, 6.0, 4), x + 6.0, -54.0, 6.0, b.grid)
	_ladder(p, "TowerLadder", Vector3(x + 6.0, 0, -51.95), 6.0, 0)
	# 5) rope swing across a gap to the far platform
	b._block(p, "FarPlatform", Vector3(4, 6.0, 4), x + 6.0, -66.0, 6.0, b.grid)
	_rope(p, "SwingRope", Vector3(x + 6.0, 11.0, -60.0), 4.4, 0)
	# 6) pipe down
	_ladder(p, "DownPipe", Vector3(x + 8.1, 0, -66.0), 6.0, 90, 1)
	_gate(p, "FinishGate", Vector3(x + 9.5, 1.0, -66.0), Vector3(1, 2, 4))
	var t := Node3D.new()
	t.set_script(load("res://demo/puzzles/parkour_timer.gd"))
	t.name = "ParkourTimer"
	t.set("start_gate", NodePath("../StartGate"))
	t.set("finish_gate", NodePath("../FinishGate"))
	p.add_child(t)
	t.owner = b.scene_root
	b._marker("parkour_ledge", Vector3(x, 0.1, -36.5), 0)
	b._marker("parkour_shimmy", Vector3(x, 0.1, -44.8), 0)
	b._marker("parkour_ladder", Vector3(x + 6.0, 0.1, -50.0), 0)
	b._marker("parkour_rope", Vector3(x + 6.0, 6.05, -52.4), 0)


func _ropes() -> void:
	var r: Node3D = b._node(b.scene_root, "RopeZone")
	var x := 130.0
	b._label(r, "ROPES", Vector3(x, 3.0, -8), 80)
	_rope(r, "ClimbRope6", Vector3(x - 3, 7.0, -14), 6.5, 1)
	_rope(r, "ClimbRope10", Vector3(x, 11.0, -14), 10.5, 1)
	b._block(r, "RopeTop", Vector3(3, 0.3, 3), x - 1.5, -16.8, 7.0, b.grid_dark)
	b._marker("climb_rope", Vector3(x - 3, 0.1, -12.6), 0)
	# Rappel cliff: an 8 m wall with a rope over the edge.
	b._block(r, "Cliff", Vector3(6, 8.0, 5), x, -26, 8.0, b.grid)
	_rope(r, "RappelRope", Vector3(x, 8.2, -23.3), 8.0, 1)
	_ladder(r, "CliffLadder", Vector3(x + 2.0, 0, -23.45), 8.0)
	b._marker("cliff_top", Vector3(x, 8.05, -25.5), 180)
	# A climbable wall (handholds texture = accent colour).
	var cw := StaticBody3D.new()
	cw.name = "ClimbWall"
	cw.collision_layer = UltraLayers.CLIMBABLE | UltraLayers.WORLD_STATIC
	cw.position = Vector3(x + 7, 3.0, -26)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(4, 6, 1)
	mi.mesh = bm
	mi.material_override = b.grid_accent
	cw.add_child(mi)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = bm.size
	cs.shape = bs
	cw.add_child(cs)
	r.add_child(cw)
	b._own(cw)
	b._block(r, "ClimbWallTop", Vector3(4, 6.0, 3), x + 7, -28.5, 6.0, b.grid)
	b._label(r, "CLIMBABLE WALL\nwalk into it to climb", Vector3(x + 7, 6.5, -25.4), 48)
	b._marker("climb_wall", Vector3(x + 7, 0.1, -24.4), 0)


func _puzzles() -> void:
	var p: Node3D = b._node(b.scene_root, "RopePuzzles")
	var x := 150.0
	# Pulley lift: crates into the basket raise the platform to a 5 m ledge with a medkit.
	var lift := Node3D.new()
	lift.set_script(load("res://demo/puzzles/pulley_lift.gd"))
	lift.name = "PulleyLift"
	lift.position = Vector3(x, 0, -14)
	var plat := AnimatableBody3D.new()
	plat.name = "Platform"
	plat.sync_to_physics = false
	plat.collision_layer = UltraLayers.WORLD_STATIC
	var pm := MeshInstance3D.new()
	var pbm := BoxMesh.new()
	pbm.size = Vector3(2.5, 0.25, 2.5)
	pm.mesh = pbm
	pm.material_override = b.grid_accent
	pm.position.y = 0.125
	plat.add_child(pm)
	var pcs := CollisionShape3D.new()
	var pbs := BoxShape3D.new()
	pbs.size = pbm.size
	pcs.shape = pbs
	pcs.position.y = 0.125
	plat.add_child(pcs)
	var deck := Area3D.new()
	deck.name = "Deck"
	deck.collision_layer = 0
	deck.collision_mask = UltraLayers.CHARACTER
	var dcs := CollisionShape3D.new()
	var dbs := BoxShape3D.new()
	dbs.size = Vector3(2.4, 1.0, 2.4)
	dcs.shape = dbs
	dcs.position.y = 0.7
	deck.add_child(dcs)
	plat.add_child(deck)
	lift.add_child(plat)
	var basket := Area3D.new()
	basket.name = "Basket"
	basket.position = Vector3(4.0, 5.0, 0)
	basket.collision_layer = 0
	basket.collision_mask = UltraLayers.WORLD_DYNAMIC
	var bcs := CollisionShape3D.new()
	var bbs := BoxShape3D.new()
	bbs.size = Vector3(1.6, 1.0, 1.6)
	bcs.shape = bbs
	bcs.position.y = 0.5
	basket.add_child(bcs)
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = UltraLayers.WORLD_STATIC
	var fm := MeshInstance3D.new()
	var fbm := BoxMesh.new()
	fbm.size = Vector3(1.8, 0.1, 1.8)
	fm.mesh = fbm
	fm.material_override = b.grid_dark
	floor_body.add_child(fm)
	var fcs := CollisionShape3D.new()
	var fbs := BoxShape3D.new()
	fbs.size = fbm.size
	fcs.shape = fbs
	floor_body.add_child(fcs)
	basket.add_child(floor_body)
	lift.add_child(basket)
	p.add_child(lift)
	b._own(lift)
	b._block(p, "LiftLedge", Vector3(4, 5.0, 4), x - 3.3, -14, 5.0, b.grid)
	b._block(p, "BasketStair", Vector3(2, 4.5, 2), x + 6.2, -14, 4.5, b.grid_dark)
	_ladder(p, "BasketLadder", Vector3(x + 6.2, 0, -12.95), 4.5)
	b._label(p, "PULLEY LIFT — load the basket (45 kg) to raise the platform", Vector3(x, 6.5, -11.5), 44)
	for i in 3:
		(load("res://demo/maps/playground/zones_m5.gd") as Script).new(b).prop(p, "LiftCrate%d" % i, "box", Vector3(0.6, 0.6, 0.6), 18.0, Vector3(x + 6.2 + (i - 1) * 0.7, 4.85, -14), Color(0.8, 0.6, 0.3))
	b._marker("pulley", Vector3(x, 0.1, -9), 180)
	# Rope drawbridge over a pit: shoot the knot.
	b._block(p, "PitNear", Vector3(6, 2, 4), x, -30, 2.0, b.grid)
	b._block(p, "PitFar", Vector3(6, 2, 4), x, -40, 2.0, b.grid)
	var br := Node3D.new()
	br.set_script(load("res://demo/puzzles/rope_bridge.gd"))
	br.name = "RopeBridge"
	br.position = Vector3(x, 2.0, -32.0)
	var plank := RigidBody3D.new()
	plank.name = "Plank"
	plank.mass = 80.0
	plank.collision_layer = UltraLayers.WORLD_DYNAMIC
	plank.collision_mask = UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC | UltraLayers.CHARACTER
	plank.position = Vector3(0, 3.0, 0.15)
	var plm := MeshInstance3D.new()
	var plbm := BoxMesh.new()
	plbm.size = Vector3(2.5, 6.0, 0.2)
	plm.mesh = plbm
	plm.material_override = b.grid_accent
	plank.add_child(plm)
	var plcs := CollisionShape3D.new()
	var plbs := BoxShape3D.new()
	plbs.size = plbm.size
	plcs.shape = plbs
	plank.add_child(plcs)
	var no := NetObject.new()
	no.name = "NetObject"
	plank.add_child(no)
	br.add_child(plank)
	var hinge := HingeJoint3D.new()
	hinge.name = "Hinge"
	hinge.position = Vector3(0, 0.0, 0.15)
	hinge.rotation_degrees.y = 90
	hinge.node_a = NodePath("../Plank")
	br.add_child(hinge)
	var knot := StaticBody3D.new()
	knot.name = "Knot"
	knot.collision_layer = UltraLayers.WORLD_STATIC
	knot.position = Vector3(0, 6.3, 0.3)
	var km := MeshInstance3D.new()
	var ks := SphereMesh.new()
	ks.radius = 0.18
	ks.height = 0.36
	km.mesh = ks
	var kmat := StandardMaterial3D.new()
	kmat.albedo_color = Color(0.9, 0.75, 0.3)
	km.material_override = kmat
	knot.add_child(km)
	var kcs := CollisionShape3D.new()
	var kss := SphereShape3D.new()
	kss.radius = 0.25
	kcs.shape = kss
	knot.add_child(kcs)
	br.add_child(knot)
	var rv := MeshInstance3D.new()
	rv.name = "RopeVisual"
	var rcm := CylinderMesh.new()
	rcm.top_radius = 0.025
	rcm.bottom_radius = 0.025
	rcm.height = 2.0
	rv.mesh = rcm
	rv.position = Vector3(0, 7.3, 0.3)
	br.add_child(rv)
	b._block(p, "BridgePost", Vector3(0.4, 9.5, 0.4), x, -31.6, 9.5, b.grid_dark)
	p.add_child(br)
	b._own(br)
	b._label(p, "SHOOT THE KNOT", Vector3(x, 4.5, -27.8), 56)
	b._marker("rope_bridge", Vector3(x, 2.05, -29.0), 0)
