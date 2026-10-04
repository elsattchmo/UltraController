extends RefCounted
## M4 playground zones: shooting range and puzzle yard (locked vault + key tower, lever
## sequence, pressure plate, timed button door). Called by build_playground.gd.

var b: Node          ## the builder (helpers: _node, _block, _box, _label, _marker, _own...)


func _init(builder: Node) -> void:
	b = builder


func build() -> void:
	_shooting_range()
	_puzzles()


func _scripted(parent: Node, script_path: String, n: String, pos: Vector3, props := {}, yaw := 0.0) -> Node3D:
	var x := Node3D.new()
	x.set_script(load(script_path))
	x.name = n
	x.position = pos
	x.rotation_degrees.y = yaw
	for k: String in props:
		x.set(k, props[k])
	parent.add_child(x)
	x.owner = b.scene_root
	return x


func _gate(parent: Node, n: String, mode: int, inputs: Array[NodePath], targets: Array[NodePath], latch := false) -> void:
	var g := Node.new()
	g.set_script(load("res://addons/ultra_controller/interaction/usable/ultra_logic.gd"))
	g.name = n
	g.set("mode", mode)
	g.set("inputs", inputs)
	g.set("targets", targets)
	g.set("latch", latch)
	parent.add_child(g)
	g.owner = b.scene_root


func _world_item(parent: Node, scene_path: String, pos: Vector3, count := 1) -> void:
	var it := (load(scene_path) as PackedScene).instantiate() as Node3D
	it.position = pos
	it.set("count", count)
	parent.add_child(it)
	it.owner = b.scene_root


func _crate(parent: Node, n: String, mass: float, pos: Vector3) -> void:
	var rb := RigidBody3D.new()
	rb.name = n
	rb.mass = mass
	rb.collision_layer = UltraLayers.WORLD_DYNAMIC
	rb.collision_mask = UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC | UltraLayers.CHARACTER
	var sz := 0.45 + pow(mass, 1.0 / 3.0) * 0.08
	rb.position = pos + Vector3(0, sz * 0.5 + 0.01, 0)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3.ONE * sz
	mi.mesh = bm
	mi.material_override = b.grid_accent
	rb.add_child(mi)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3.ONE * sz
	cs.shape = bs
	rb.add_child(cs)
	var no := NetObject.new()
	no.name = "NetObject"
	rb.add_child(no)
	parent.add_child(rb)
	b._own(rb)
	b._label(parent, "%d kg" % int(mass), rb.position + Vector3(0, sz * 0.5 + 0.3, 0), 40)


func _shooting_range() -> void:
	var r: Node3D = b._node(b.scene_root, "ShootingRange")
	r.position = Vector3(0, 0, 30)
	b._block(r, "Floor", Vector3(22, 0.05, 40), 0, 18, 0.05, b.grid)
	b._block(r, "Bench", Vector3(20, 1.0, 0.6), 0, 1.0, 1.0, b.grid_dark)
	b._label(r, "SHOOTING RANGE", Vector3(0, 2.6, 0.5), 80, 180)
	for i in 4:
		b._block(r, "LaneWall%d" % i, Vector3(0.2, 1.4, 34), -9.0 + i * 6.0, 19, 1.4, b.grid_dark)
	var lanes := [[-6.0, [5.0, 15.0, 28.0]], [0.0, [8.0, 18.0]], [6.0, [10.0, 22.0]]]
	var n := 0
	for lane: Array in lanes:
		for d: float in lane[1]:
			var swing := 1.6 if lane[0] == 0.0 and d > 10.0 else 0.0
			_scripted(r, "res://addons/ultra_controller/combat/shooting_target.gd", "Target%d" % n, Vector3(lane[0], 0, 2.0 + d), {"label": "%d m" % int(d), "swing": swing}, 180)
			n += 1
	b._block(r, "Backstop", Vector3(22, 5, 1), 0, 38, 5, b.grid_dark)
	_world_item(r, "res://assets/items/ammo/ammo_9mm_world.tscn", Vector3(-3, 1.1, 1.0), 48)
	_world_item(r, "res://assets/items/ammo/ammo_9mm_world.tscn", Vector3(3, 1.1, 1.0), 48)
	_world_item(r, "res://assets/items/pistol/pistol_world.tscn", Vector3(0, 1.1, 1.0))
	b._marker("range", Vector3(0, 0.1, 28.5), 180)


## Four walls with a doorway centred in the -Z wall. Returns the doorway's world position.
func _room(parent: Node, n: String, center: Vector3, size: Vector2, h := 3.0) -> Vector3:
	var room: Node3D = b._node(parent, n)
	room.position = center
	var t := 0.25
	var door_w := 1.2
	b._block(room, "WallBack", Vector3(size.x, h, t), 0, size.y * 0.5, h, b.grid)
	b._block(room, "WallL", Vector3(t, h, size.y), -size.x * 0.5, 0, h, b.grid)
	b._block(room, "WallR", Vector3(t, h, size.y), size.x * 0.5, 0, h, b.grid)
	var side := (size.x - door_w) * 0.5
	b._block(room, "WallFrontL", Vector3(side, h, t), -(door_w + side) * 0.5, -size.y * 0.5, h, b.grid)
	b._block(room, "WallFrontR", Vector3(side, h, t), (door_w + side) * 0.5, -size.y * 0.5, h, b.grid)
	b._block(room, "Lintel", Vector3(door_w, h - 2.2, t), 0, -size.y * 0.5, h, b.grid)
	b._block(room, "Roof", Vector3(size.x + t, 0.2, size.y + t), 0, 0, h + 0.2, b.grid_dark)
	return center + Vector3(0, 0, -size.y * 0.5)


func _door(parent: Node, n: String, at: Vector3, props := {}) -> Node3D:
	# Hinge on the left edge of the doorway; the panel spans the opening.
	var d := _scripted(parent, "res://addons/ultra_controller/interaction/usable/ultra_door.gd", n, at + Vector3(-0.58, 0, 0), props)
	d.set("size", Vector3(1.16, 2.18, 0.08))
	d.set("material", b.grid_accent)
	return d


func _puzzles() -> void:
	var p: Node3D = b._node(b.scene_root, "PuzzleYard")
	b._label(p, "PUZZLE YARD", Vector3(-24, 3.5, 22), 80)
	# 1) The vault, locked with the red key that sits on top of the key tower.
	var vault_door := _room(p, "Vault", Vector3(-26, 0, 48), Vector2(8, 8))
	_door(p, "VaultDoor", vault_door, {"locked": true, "key_id": &"red", "locked_text": "Locked. The red key is on the tower.", "consume_key": false})
	b._label(p, "VAULT (red key)", vault_door + Vector3(0, 2.7, -0.2), 56)
	_world_item(p, "res://assets/items/medkit/medkit_world.tscn", Vector3(-27, 0.3, 50), 2)
	_world_item(p, "res://assets/items/ammo/ammo_9mm_world.tscn", Vector3(-25, 0.3, 50), 60)
	var tower: Node3D = b._node(p, "KeyTower")
	b._block(tower, "Top", Vector3(4, 4, 4), -12, 30, 4.0, b.grid_accent)
	var rise := 4.0
	var run := rise / tan(deg_to_rad(28.0))
	var slope_len := sqrt(rise * rise + run * run)
	var a := deg_to_rad(28.0)
	var t := 0.4
	var mid := Vector3(-12, rise * 0.5 - cos(a) * t * 0.5, 28.0 - run * 0.5 + sin(a) * t * 0.5)
	b._box(tower, "Ramp", Vector3(3, t, slope_len), mid, Vector3(-28, 0, 0), b.grid)
	_world_item(tower, "res://assets/items/keys/key_red_world.tscn", Vector3(-12, 4.15, 30.5))
	b._label(tower, "red key", Vector3(-12, 5.0, 29), 48)
	b._marker("puzzles", Vector3(-20, 0.1, 22), 180)
	b._marker("vault_door", vault_door + Vector3(0, 0.1, -2.0), 180)
	b._marker("key_tower", Vector3(-12, 0.1, 28.0 - run - 1.5), 180)
	# 2) Lever sequence: II, III, I opens the store room.
	var store_door := _room(p, "LeverStore", Vector3(-38, 0, 34), Vector2(5, 5))
	_door(p, "LeverDoor", store_door, {"locked": true, "locked_text": "Sealed. Try the levers."})
	var levers: Array[NodePath] = []
	var names := ["I", "II", "III"]
	for i in 3:
		var lv := _scripted(p, "res://addons/ultra_controller/interaction/usable/ultra_switch.gd", "Lever%d" % (i + 1), Vector3(-36.0 + i * 1.0, 1.1, 30.9), {"kind": 0, "label": names[i]}, 180)
		levers.append(NodePath("../" + String(lv.name)))
	b._label(p, "Pull in order:  II · III · I", Vector3(-35, 2.3, 30.7), 44, 180)
	var order: Array[NodePath] = [levers[1], levers[2], levers[0]]
	var lt: Array[NodePath] = [NodePath("../LeverDoor")]
	_gate(p, "LeverSequence", 2, order, lt, true)
	_world_item(p, "res://assets/items/ammo/ammo_9mm_world.tscn", Vector3(-38, 0.3, 35), 24)
	b._marker("levers", Vector3(-35, 0.1, 29.0), 0)
	# 3) Pressure plate: 40 kg holds the door open. Two crates to push onto it.
	var plate_room := _room(p, "PlateRoom", Vector3(-12, 0, 60), Vector2(5, 5))
	_door(p, "PlateDoor", plate_room, {"locked": true, "locked_text": "Held shut. Put 40 kg on the plate."})
	_scripted(p, "res://addons/ultra_controller/interaction/usable/pressure_plate.gd", "Plate", Vector3(-12, 0, 52.5), {"threshold_kg": 40.0})
	var pin: Array[NodePath] = [NodePath("../Plate")]
	var pt: Array[NodePath] = [NodePath("../PlateDoor")]
	_gate(p, "PlateGate", 0, pin, pt)
	_crate(p, "PlateCrateA", 20.0, Vector3(-15.5, 0, 50.5))
	_crate(p, "PlateCrateB", 45.0, Vector3(-8.5, 0, 50.5))
	_world_item(p, "res://assets/items/medkit/medkit_world.tscn", Vector3(-12, 0.3, 62))
	b._marker("pressure_plate", Vector3(-12, 0.1, 49.0), 180)
	# 4) Button door: open for 5 s.
	var btn_room := _room(p, "ButtonRoom", Vector3(2, 0, 64), Vector2(5, 5))
	_door(p, "ButtonDoor", btn_room, {"auto_close": 5.0, "locked": true, "locked_text": "Use the button."})
	_scripted(p, "res://addons/ultra_controller/interaction/usable/ultra_switch.gd", "DoorButton", btn_room + Vector3(1.3, 1.2, -0.15), {"kind": 1, "label": "5 s"}, 180)
	var bin: Array[NodePath] = [NodePath("../DoorButton")]
	var bt: Array[NodePath] = [NodePath("../ButtonDoor")]
	_gate(p, "ButtonGate", 1, bin, bt)
	b._marker("button_door", btn_room + Vector3(0, 0.1, -2.5), 180)
