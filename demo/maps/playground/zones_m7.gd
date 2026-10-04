extends RefCounted
## M7 playground: the water zone. A pool (1 m shallow end with steps, 4 m deep end, diving
## tower, ladder), an underwater L-tunnel (breath test) to a sealed grotto holding the blue key
## for the boathouse, floating / sinking props, a river with a current, and a cistern whose
## valve floods it so you can swim to the supplies on its pillar. Holes in the ground slab are
## cut by build_playground.gd (GROUND_HOLES).

var b: Node
var m4: RefCounted
var m5: RefCounted
var m6: RefCounted

const SURFACE := -0.3          ## rest water level (30 cm below the deck)
const BOTTOM := -5.0           ## everything sunken is built down to here


func _init(builder: Node) -> void:
	b = builder
	m4 = (load("res://demo/maps/playground/zones_m4.gd") as Script).new(builder)
	m5 = (load("res://demo/maps/playground/zones_m5.gd") as Script).new(builder)
	m6 = (load("res://demo/maps/playground/zones_m6.gd") as Script).new(builder)


func build() -> void:
	var w: Node3D = b._node(b.scene_root, "WaterZone")
	b._label(w, "WATER ZONE   (dive: C or look down · surface: Space · grotto via the deep-end tunnel)", Vector3(56, 4.0, 62), 60, 180)
	_pool(w)
	_grotto(w)
	_props(w)
	_river(w)
	_cistern(w)


## Walls under the ground slab around a sunken hole (the slab itself is only 1 m thick).
func _liner(parent: Node, x0: float, x1: float, z0: float, z1: float) -> void:
	_slab(parent, "LinerW", x0 - 1, x0, z0 - 1, z1 + 1, BOTTOM, -0.5, b.grid_dark)
	_slab(parent, "LinerE", x1, x1 + 1, z0 - 1, z1 + 1, BOTTOM, -0.5, b.grid_dark)
	_slab(parent, "LinerS", x0, x1, z0 - 1, z0, BOTTOM, -0.5, b.grid_dark)
	_slab(parent, "LinerN", x0, x1, z1, z1 + 1, BOTTOM, -0.5, b.grid_dark)


## Solid box from (x0, y0, z0) to (x1, y1, z1).
func _slab(parent: Node, n: String, x0: float, x1: float, z0: float, z1: float, y0: float, y1: float, mat: Material = null) -> void:
	b._block(parent, n, Vector3(x1 - x0, y1 - y0, z1 - z0), (x0 + x1) * 0.5, (z0 + z1) * 0.5, y1, mat if mat else b.grid)


func _water(parent: Node, n: String, center: Vector3, size: Vector2, depth: float, props := {}) -> Node3D:
	var wv := Node3D.new()
	wv.set_script(load("res://addons/ultra_controller/water/ultra_water.gd"))
	wv.name = n
	wv.position = center
	wv.set("size", size)
	wv.set("depth", depth)
	for k: String in props:
		wv.set(k, props[k])
	parent.add_child(wv)
	wv.owner = b.scene_root
	return wv


func _light(parent: Node, n: String, pos: Vector3, energy := 1.0, rng := 8.0, color := Color(0.7, 0.9, 1.0)) -> void:
	var l := OmniLight3D.new()
	l.name = n
	l.position = pos
	l.light_energy = energy
	l.omni_range = rng
	l.light_color = color
	parent.add_child(l)
	l.owner = b.scene_root


# Hole A (x 40..72, z 64..96): pool x 42..56 z 68..92, tunnel T1 x 56..67 z 85..87,
# T2 x 65..67 z 74..85, grotto x 63..70 z 67..74 (shelf x 68..70).
func _pool(w: Node3D) -> void:
	var p: Node3D = b._node(w, "Pool")
	# Deck fills (solid to the bottom, top flush with the ground).
	_slab(p, "DeckW", 40, 42, 64, 96, BOTTOM, 0)
	_slab(p, "DeckS", 42, 63, 64, 68, BOTTOM, 0)
	_slab(p, "DeckSE", 63, 72, 64, 67, BOTTOM, 0)
	_slab(p, "DeckN", 42, 72, 92, 96, BOTTOM, 0)
	_slab(p, "FillMid", 56, 63, 68, 85, BOTTOM, 0)
	_slab(p, "FillNE", 56, 72, 87, 92, BOTTOM, 0)
	_slab(p, "FillT2W", 63, 65, 74, 85, BOTTOM, 0)
	_slab(p, "FillT2E", 67, 72, 74, 87, BOTTOM, 0)
	_slab(p, "FillGE", 70, 72, 67, 74, BOTTOM, 0)
	# Pool floor: shallow 1 m, a slope, deep 4 m.
	_slab(p, "FloorShallow", 42, 56, 68, 76, BOTTOM, SURFACE - 1.0, b.grid_ice)
	_slab(p, "FloorDeep", 42, 56, 76, 92, BOTTOM, SURFACE - 4.0, b.grid_ice)
	var a := atan2(3.0, 6.0)
	var t := 0.6
	var n := Vector3(0, cos(a), sin(a))
	b._box(p, "Slope", Vector3(14, t, sqrt(45.0)), Vector3(49, SURFACE - 2.5, 79) - n * t * 0.5, Vector3(rad_to_deg(a), 0, 0), b.grid_ice)
	# Steps down into the shallow end.
	for i in 3:
		_slab(p, "Step%d" % i, 43, 47, 68 + i * 0.4, 68.4 + i * 0.4, BOTTOM, -0.325 * (i + 1), b.grid_accent)
	m6._ladder(p, "PoolLadder", Vector3(42.05, SURFACE - 4.0, 88), 4.3, 90)
	_water(p, "PoolWater", Vector3(49, SURFACE, 80), Vector2(14, 24), 4.0)
	_light(p, "PoolLight", Vector3(49, SURFACE - 3.0, 84), 0.6, 9.0)
	# Diving tower on the north deck, board over the deep end.
	_slab(p, "Tower", 47, 51, 93.5, 96, 0, 5.0, b.grid_dark)
	_slab(p, "Board", 48.5, 49.5, 90.0, 93.5, 4.85, 5.0, b.grid_accent)
	m6._ladder(p, "TowerLadder", Vector3(51.05, 0, 94.75), 5.0, 90)
	b._label(p, "POOL  1 m → 4 m", Vector3(45, 1.6, 67.6), 48, 180)
	b._label(p, "5 m board", Vector3(49, 6.2, 94), 40)
	# Boathouse: locked with the blue key from the grotto.
	var door_at: Vector3 = m4._room(p, "Boathouse", Vector3(60, 0, 100), Vector2(6, 5))
	m4._door(p, "BoathouseDoor", door_at, {"locked": true, "key_id": &"blue", "locked_text": "Locked. The blue key is in the grotto (deep-end tunnel).", "consume_key": false})
	b._label(p, "BOATHOUSE (blue key)", door_at + Vector3(0, 2.7, -0.2), 52)
	m4._world_item(p, "res://assets/items/ammo/ammo_9mm_world.tscn", Vector3(59, 0.3, 101), 48)
	m4._world_item(p, "res://assets/items/medkit/medkit_world.tscn", Vector3(61, 0.3, 101), 2)
	b._marker("pool", Vector3(49, 0.1, 65.5), 180)
	b._marker("pool_deep_side", Vector3(41, 0.1, 86), -90)
	b._marker("dive_tower", Vector3(49, 5.05, 94.6), 0)
	b._marker("boathouse", door_at + Vector3(0, 0.1, -2.5), 180)


func _grotto(w: Node3D) -> void:
	var g: Node3D = b._node(w, "Grotto")
	# Tunnel: 2 m high, its ceiling solid up to the deck; ~20 m of breath-holding.
	_slab(g, "T1Floor", 56, 67, 85, 87, BOTTOM, SURFACE - 4.0, b.grid_ice)
	_slab(g, "T1Ceil", 56, 67, 85, 87, SURFACE - 2.0, 0)
	_slab(g, "T2Floor", 65, 67, 74, 85, BOTTOM, SURFACE - 4.0, b.grid_ice)
	_slab(g, "T2Ceil", 65, 67, 74, 85, SURFACE - 2.0, 0)
	_water(g, "T1Water", Vector3(61.5, SURFACE, 86), Vector2(11, 2), 4.0, {"show_surface": false})
	_water(g, "T2Water", Vector3(66, SURFACE, 79.5), Vector2(2, 11), 4.0, {"show_surface": false})
	_light(g, "T1Light", Vector3(61.5, SURFACE - 3.0, 86), 0.5, 6.0)
	_light(g, "T2Light", Vector3(66, SURFACE - 3.0, 79.5), 0.5, 6.0)
	# The grotto: sealed room with an air pocket, a shelf to climb onto.
	_slab(g, "GFloor", 63, 68, 67, 74, BOTTOM, SURFACE - 4.0, b.grid_ice)
	_slab(g, "Shelf", 68, 70, 67, 74, BOTTOM, 0)
	_water(g, "GrottoWater", Vector3(65.5, SURFACE, 70.5), Vector2(5, 7), 4.0)
	_slab(g, "WallS", 62.75, 70.25, 66.75, 67, 0, 2.6, b.grid_dark)
	_slab(g, "WallN", 62.75, 70.25, 74, 74.25, 0, 2.6, b.grid_dark)
	_slab(g, "WallW", 62.75, 63, 67, 74, 0, 2.6, b.grid_dark)
	_slab(g, "WallE", 70, 70.25, 67, 74, 0, 2.6, b.grid_dark)
	_slab(g, "Roof", 62.75, 70.25, 66.75, 74.25, 2.6, 2.8, b.grid_dark)
	_light(g, "GrottoLight", Vector3(66, 2.0, 70.5), 1.2, 9.0, Color(0.6, 0.85, 1.0))
	m4._world_item(g, "res://assets/items/keys/key_blue_world.tscn", Vector3(69, 0.15, 70.5))
	b._label(g, "blue key", Vector3(69, 1.0, 70.5), 40, -90)
	b._marker("tunnel", Vector3(55.0, SURFACE - 3.4, 86), -90)
	b._marker("grotto", Vector3(65.5, SURFACE - 1.0, 72.0), 180)


func _props(w: Node3D) -> void:
	var f: Node3D = b._node(w, "Floaters")
	# "buoyancy" tunes how deep a (hollow, light) prop sits: about half under for crates.
	m5.prop(f, "WoodCrate", "box", Vector3(0.8, 0.8, 0.8), 30.0, Vector3(45, 0.8, 85), Color(0.72, 0.5, 0.28)).set_meta("buoyancy", 0.12)
	m5.prop(f, "MetalCrate", "box", Vector3(0.5, 0.5, 0.5), 300.0, Vector3(53, 0.8, 87), Color(0.45, 0.47, 0.5))
	m5.prop(f, "Barrel", "cylinder", Vector3(0.35, 1.0, 0.35), 40.0, Vector3(53, 0.8, 72), Color(0.7, 0.25, 0.2)).set_meta("buoyancy", 0.22)
	m5.prop(f, "BeachBall", "sphere", Vector3(0.3, 0.3, 0.3), 2.0, Vector3(45, 0.8, 72), Color(0.95, 0.85, 0.2))
	b._label(f, "wood floats · metal sinks", Vector3(49, 1.4, 67.6), 40, 180)


# Hole C (x 96..100, z 60..100): river, 1.7 m deep, current toward +Z.
func _river(w: Node3D) -> void:
	var r: Node3D = b._node(w, "River")
	_liner(r, 96, 100, 60, 100)
	_slab(r, "Bed", 96, 100, 60, 100, BOTTOM, SURFACE - 1.7, b.grid_ice)
	_water(r, "RiverWater", Vector3(98, SURFACE, 80), Vector2(4, 40), 1.7, {"current": Vector3(0, 0, 1.4)})
	m6._ladder(r, "RiverLadder", Vector3(96.05, SURFACE - 1.7, 98.5), 2.0, 90)
	for i in 3:
		m5.prop(r, "DriftCrate%d" % i, "box", Vector3(0.6, 0.6, 0.6), 15.0, Vector3(98, 0.6, 76.0 + i * 3.0), Color(0.7, 0.52, 0.3)).set_meta("buoyancy", 0.15)
	b._label(r, "RIVER  →  current 1.4 m/s", Vector3(98, 1.6, 59), 44, 180)
	b._marker("river", Vector3(98, 0.1, 58), 180)


# Hole B (x 78..90, z 64..76): a 3.5 m pit with 0.5 m of water; the valve floods it.
func _cistern(w: Node3D) -> void:
	var c: Node3D = b._node(w, "Cistern")
	_liner(c, 78, 90, 64, 76)
	_slab(c, "Floor", 78, 90, 64, 76, BOTTOM, -3.5, b.grid_dark)
	_slab(c, "Pillar", 83, 85, 69, 71, BOTTOM, 0, b.grid_accent)
	var wv: Node3D = _water(c, "CisternWater", Vector3(84, -3.0, 70), Vector2(12, 12), 0.5, {"raised_offset": 2.7, "raise_time": 8.0})
	m6._ladder(c, "CisternLadder", Vector3(78.05, -3.5, 65.5), 3.5, 90)
	_slab(c, "ValvePost", 76.2, 76.6, 67.8, 68.2, 0, 1.4, b.grid_dark)
	var valve: Node3D = m4._scripted(c, "res://addons/ultra_controller/interaction/usable/ultra_switch.gd", "Valve", Vector3(76.75, 1.1, 68.0), {"kind": 0, "label": "valve"}, -90)
	var vin: Array[NodePath] = [NodePath("../" + String(valve.name))]
	var vt: Array[NodePath] = [NodePath("../" + String(wv.name))]
	m4._gate(c, "ValveGate", 0, vin, vt)
	m4._world_item(c, "res://assets/items/medkit/medkit_world.tscn", Vector3(83.6, 0.3, 70), 2)
	m4._world_item(c, "res://assets/items/ammo/ammo_9mm_world.tscn", Vector3(84.4, 0.3, 70), 36)
	b._label(c, "CISTERN  open the valve, swim to the pillar", Vector3(84, 2.2, 63.6), 44, 180)
	b._marker("cistern", Vector3(76.0, 0.1, 70.0), -90)
