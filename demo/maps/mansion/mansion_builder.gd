class_name MansionBuilder
extends RefCounted
## MansionLayout -> boxes (BoxList) + the facts built from it (doors with their rooms and nav link
## ends, lights). Pure data: no nodes, so tests and the navmesh bake can run anywhere.

const L := preload("res://demo/maps/mansion/mansion_layout.gd")

class Built:
	var boxes := BoxList.new()
	var doors: Array[Dictionary] = []    ## name, floor, axis, at, c, w, kind, state, key, center, normal, rooms, a, b (nav link ends)
	var lights: Array[Dictionary] = []   ## pos, color, energy, range, shadow
	var rails := 0
	var props := 0

	func door(door_name: String) -> Dictionary:
		for d in doors:
			if d.name == door_name:
				return d
		return {}


static func build() -> Built:
	var b := Built.new()
	_doors(b)
	_floors(b)
	_walls(b)
	_stairs(b)
	_rails(b)
	_roofs(b)
	_outside(b)
	_props(b)
	_lights(b)
	return b


# ------------------------------------------------------------------ doors (facts first: walls cut for them)

static func _doors(b: Built) -> void:
	for d: Array in L.DOORS:
		var f := int(d[1])
		var axis := String(d[2])
		var at := float(d[3])
		var c := float(d[4])
		var w := float(d[5])
		var fy := L.floor_y(f)
		var center := Vector3(at, fy, c) if axis == "x" else Vector3(c, fy, at)
		var normal := Vector3.RIGHT if axis == "x" else Vector3.BACK          # across the wall
		var t := _thickness(axis, at)
		var off := normal * (t * 0.5 + 0.55)
		var ra := L.room_at(Vector2((center - off).x, (center - off).z), f)
		var rb := L.room_at(Vector2((center + off).x, (center + off).z), f)
		var rec := {
			"name": String(d[0]), "floor": f, "axis": axis, "at": at, "c": c, "w": w, "kind": String(d[6]), "state": String(d[7]),
			"key": String(d[8]) if d.size() > 8 else "", "center": center, "normal": normal, "rooms": [ra, rb],
			"a": center - normal * (t * 0.5 + 0.7) + Vector3.UP * 0.05, "b": center + normal * (t * 0.5 + 0.7) + Vector3.UP * 0.05,
		}
		b.doors.append(rec)


## Wall thickness on a line: exterior on the footprint's edge.
static func _thickness(axis: String, at: float) -> float:
	var fp := L.FOOTPRINT
	if axis == "x":
		return L.W_OUT if (is_equal_approx(at, fp.position.x) or is_equal_approx(at, fp.end.x)) else L.W_IN
	return L.W_OUT if (is_equal_approx(at, fp.position.y) or is_equal_approx(at, fp.end.y)) else L.W_IN


# ------------------------------------------------------------------ floors, ceilings

static func _holes(f: int) -> Array:
	var out := []
	for s: Dictionary in L.STAIRS:
		if s.has("hole") and int((s.hole as Array)[0]) == f:
			var h: Array = s.hole
			out.append(Rect2(float(h[1]), float(h[2]), float(h[3]) - float(h[1]), float(h[4]) - float(h[2])))
	return out


static func _floors(b: Built) -> void:
	var bl := b.boxes
	for r: Array in L.ROOMS:
		var f := int(r[1])
		var fy := L.floor_y(f)
		var kind := String(r[6])
		var mat := StringName(L.FLOOR_MAT.get(kind, "floor_wood"))
		var rect := L.rect_of(r)
		for piece in L.subtract(rect, _holes(f)):
			bl.add_min_max(Vector3(piece.position.x, fy - L.SLAB, piece.position.y), Vector3(piece.end.x, fy, piece.end.y), BoxList.Kind.FLOOR, mat, &"floors")
		# A ceiling slab on the ground floor where no upstairs room sits on top of it (the upstairs
		# floor is the slab otherwise), never over the Great Hall (its void is open to the roof).
		if f == 0 and String(r[0]) != "hall" and not _covered_above(rect):
			bl.add_min_max(Vector3(rect.position.x, fy + L.HEIGHT, rect.position.y), Vector3(rect.end.x, fy + L.HEIGHT + L.SLAB, rect.end.y), BoxList.Kind.CEILING, &"ceiling", &"floors")
	# Landings that carry the grand flights onto the gallery.
	var f1 := L.floor_y(1)
	for lr: Array in L.LANDINGS:
		bl.add_min_max(Vector3(lr[0], f1 - L.SLAB, lr[1]), Vector3(lr[2], f1, lr[3]), BoxList.Kind.FLOOR, &"floor_wood", &"floors")


static func _covered_above(rect: Rect2) -> bool:
	var c := rect.get_center()
	for r: Array in L.ROOMS:
		if int(r[1]) == 1 and L.rect_of(r).has_point(c):
			return true
	return false


static func _roofs(b: Built) -> void:
	var y := L.floor_y(1) + L.HEIGHT
	for r: Array in L.ROOMS:
		if int(r[1]) != 1:
			continue
		var rect := L.rect_of(r)
		b.boxes.add_min_max(Vector3(rect.position.x, y, rect.position.y), Vector3(rect.end.x, y + L.SLAB, rect.end.y), BoxList.Kind.ROOF, &"ceiling", &"roof")
	b.boxes.add_min_max(Vector3(L.VOID.position.x, y, L.VOID.position.y), Vector3(L.VOID.end.x, y + L.SLAB, L.VOID.end.y), BoxList.Kind.ROOF, &"ceiling", &"roof")


# ------------------------------------------------------------------ walls

## An interval [a, b] of height h along a line (key = the line's coordinate).
static func _edge(lines: Dictionary, key: float, a: float, c: float, h: float) -> void:
	(lines.get_or_add(snappedf(key, 0.001), []) as Array).append([minf(a, c), maxf(a, c), h])


## Overlapping intervals -> disjoint ones (the tallest wins), equal neighbours merged.
static func _resolve(iv: Array) -> Array:
	var pts := []
	for i: Array in iv:
		pts.append(i[0])
		pts.append(i[1])
	pts.sort()
	var uniq := []
	for p in pts:
		if uniq.is_empty() or absf(float(p) - float(uniq[-1])) > 1e-6:
			uniq.append(p)
	var out := []
	for k in uniq.size() - 1:
		var lo: float = uniq[k]
		var hi: float = uniq[k + 1]
		var mid := (lo + hi) * 0.5
		var h := 0.0
		for i: Array in iv:
			if float(i[0]) <= mid and mid <= float(i[1]):
				h = maxf(h, float(i[2]))
		if h <= 0.0:
			continue
		if not out.is_empty() and absf(float((out[-1] as Array)[1]) - lo) < 1e-6 and is_equal_approx(float((out[-1] as Array)[2]), h):
			(out[-1] as Array)[1] = hi
		else:
			out.append([lo, hi, h])
	return out


static func _walls(b: Built) -> void:
	for f in [-1, 0, 1]:
		var hl := {}                       # z -> intervals along x   (walls running east-west)
		var vl := {}                       # x -> intervals along z   (walls running north-south)
		for r: Array in L.ROOMS:
			if int(r[1]) != f or String(r[0]).begins_with("gallery"):
				continue                     # (the gallery ring has no walls: its neighbours' are its walls)
			var rect := L.rect_of(r)
			var h: float = L.HEIGHT_OF[f]
			_edge(hl, rect.position.y, rect.position.x, rect.end.x, h)
			_edge(hl, rect.end.y, rect.position.x, rect.end.x, h)
			_edge(vl, rect.position.x, rect.position.y, rect.end.y, h)
			_edge(vl, rect.end.x, rect.position.y, rect.end.y, h)
		for z: float in hl:
			_wall_line(b, f, "z", z, _resolve(hl[z]))
		for x: float in vl:
			_wall_line(b, f, "x", x, _resolve(vl[x]))


## One line of wall on floor `f`: axis "z" = a wall at z = at running along x, "x" = at x running along z.
static func _wall_line(b: Built, f: int, axis: String, at: float, pieces: Array) -> void:
	var fy := L.floor_y(f)
	var t := _thickness(axis, at)
	var exterior := t == L.W_OUT
	var mat: StringName = &"brick" if exterior else (&"stone_wall" if f < 0 else &"plaster")
	# The doors on this line.
	var cuts := []
	for d in b.doors:
		if int(d.floor) == f and String(d.axis) == axis and absf(float(d.at) - at) < 0.001:
			var open_h := L.ARCH_H if d.kind == "arch" else L.DOOR_H
			cuts.append([float(d.c) - float(d.w) * 0.5, float(d.c) + float(d.w) * 0.5, open_h])
	for p: Array in pieces:
		var lo: float = float(p[0]) - t * 0.5            # (ends run on half a wall: the corners close)
		var hi: float = float(p[1]) + t * 0.5
		var h: float = p[2]
		# Subtract the openings; a lintel closes each above its door.
		var spans := [[lo, hi]]
		for c: Array in cuts:
			var next := []
			for s: Array in spans:
				if c[1] <= s[0] or c[0] >= s[1]:
					next.append(s)
					continue
				if c[0] > s[0]:
					next.append([s[0], c[0]])
				if c[1] < s[1]:
					next.append([c[1], s[1]])
				_wall_box(b, axis, at, t, maxf(c[0], s[0]), minf(c[1], s[1]), fy + float(c[2]), fy + h, mat)
			spans = next
		for s: Array in spans:
			if float(s[1]) - float(s[0]) > 0.01:
				_wall_box(b, axis, at, t, s[0], s[1], fy, fy + h, mat)
	# The doors' navigation plugs (not arches: they stay open ground).
	for d in b.doors:
		if int(d.floor) == f and String(d.axis) == axis and absf(float(d.at) - at) < 0.001 and d.kind != "arch":
			var c0: float = float(d.c) - float(d.w) * 0.5
			var c1: float = float(d.c) + float(d.w) * 0.5
			if axis == "z":
				b.boxes.add_min_max(Vector3(c0, fy, at - t * 0.5 - 0.05), Vector3(c1, fy + L.DOOR_H, at + t * 0.5 + 0.05), BoxList.Kind.PLUG, &"plug", &"plugs")
			else:
				b.boxes.add_min_max(Vector3(at - t * 0.5 - 0.05, fy, c0), Vector3(at + t * 0.5 + 0.05, fy + L.DOOR_H, c1), BoxList.Kind.PLUG, &"plug", &"plugs")


static func _wall_box(b: Built, axis: String, at: float, t: float, lo: float, hi: float, y0: float, y1: float, mat: StringName) -> void:
	if axis == "z":
		b.boxes.add_min_max(Vector3(lo, y0, at - t * 0.5), Vector3(hi, y1, at + t * 0.5), BoxList.Kind.WALL, mat, &"walls")
	else:
		b.boxes.add_min_max(Vector3(at - t * 0.5, y0, lo), Vector3(at + t * 0.5, y1, hi), BoxList.Kind.WALL, mat, &"walls")


# ------------------------------------------------------------------ stairs, rails

static func _stairs(b: Built) -> void:
	for s: Dictionary in L.STAIRS:
		var from := Vector2(float((s.from as Array)[0]), float((s.from as Array)[1]))
		var d := Vector2(float((s.dir as Array)[0]), float((s.dir as Array)[1]))
		var w: float = s.w
		var n: int = s.steps
		var y0: float = s.y0
		var rise := (float(s.y1) - y0) / n
		for i in n:
			var s0 := i * L.RUN
			var s1 := (i + 1) * L.RUN
			var top := y0 + (i + 1) * rise
			# Axis-aligned flight: along d from s0 to s1, across +-w/2 (solid from the lower floor up).
			var a := from + d * s0
			var c := from + d * s1
			var x0 := minf(a.x, c.x) - (w * 0.5 if absf(d.x) < 0.5 else 0.0)
			var x1 := maxf(a.x, c.x) + (w * 0.5 if absf(d.x) < 0.5 else 0.0)
			var z0 := minf(a.y, c.y) - (w * 0.5 if absf(d.y) < 0.5 else 0.0)
			var z1 := maxf(a.y, c.y) + (w * 0.5 if absf(d.y) < 0.5 else 0.0)
			b.boxes.add_min_max(Vector3(x0, y0 - 0.02, z0), Vector3(x1, top, z1), BoxList.Kind.STAIR, &"stair_wood", &"stairs")
		# The navmesh gets the flight as a smooth ramp through the tread rears (floor to floor).
		var run_end := from + d * (n * L.RUN)
		var half := Vector2(-d.y, d.x) * (w * 0.5)
		b.boxes.add_nav_wedge(Vector3(from.x + half.x, y0, from.y + half.y), Vector3(from.x - half.x, y0, from.y - half.y), Vector3(run_end.x + half.x, float(s.y1), run_end.y + half.y), Vector3(run_end.x - half.x, float(s.y1), run_end.y - half.y), minf(y0, float(s.y1)) - 0.05)


const RAIL_H := 1.0
const RAIL_T := 0.07


static func _rail(b: Built, y: float, x0: float, z0: float, x1: float, z1: float) -> void:
	b.boxes.add_min_max(Vector3(minf(x0, x1) - RAIL_T * 0.5, y, minf(z0, z1) - RAIL_T * 0.5), Vector3(maxf(x0, x1) + RAIL_T * 0.5, y + RAIL_H, maxf(z0, z1) + RAIL_T * 0.5), BoxList.Kind.SOLID, &"rail", &"rails")
	b.rails += 1


static func _rails(b: Built) -> void:
	var y := L.floor_y(1)
	var v := L.VOID
	# Round the Great Hall's void; the landings that continue the grand flights are gaps in the west and
	# east runs.
	var gaps := [[15.0, 18.4]]
	for x in [v.position.x, v.end.x]:
		var z := v.position.y
		for g: Array in gaps:
			if g[0] > z:
				_rail(b, y, x, z, x, g[0])
			z = g[1]
		_rail(b, y, x, z, x, v.end.y)
	_rail(b, y, v.position.x, v.position.y, v.end.x, v.position.y)
	_rail(b, y, v.position.x, v.end.y, v.end.x, v.end.y)
	# The landings' open sides (north and the side facing the middle).
	_rail(b, y, 19.0, 15.0, 21.6, 15.0)
	_rail(b, y, 21.6, 15.0, 21.6, 18.4)
	_rail(b, y, 34.4, 15.0, 37.0, 15.0)
	_rail(b, y, 34.4, 15.0, 34.4, 18.4)
	# Stairwell holes: guarded on every side but the one you step on from - the north edge (back_w rises
	# north out of its hole; the cellar flight starts at its north edge going down).
	for s: Dictionary in L.STAIRS:
		if not s.has("hole"):
			continue
		var h: Array = s.hole
		var fy := L.floor_y(int(h[0]))
		var x0 := float(h[1])
		var z0 := float(h[2])
		var x1 := float(h[3])
		var z1 := float(h[4])
		_rail(b, fy, x0, z1, x1, z1)
		_rail(b, fy, x0, z0 + 0.4, x0, z1)
		_rail(b, fy, x1, z0 + 0.4, x1, z1)


# ------------------------------------------------------------------ the grounds

static func _outside(b: Built) -> void:
	var fp := L.FOOTPRINT
	var lo := Vector2(-30.0, -20.0)
	var hi := Vector2(86.0, 80.0)
	var bl := b.boxes
	# Lawn around the building (none under it: the basement is hollow).
	bl.add_min_max(Vector3(lo.x, -0.5, lo.y), Vector3(hi.x, 0.0, fp.position.y), BoxList.Kind.FLOOR, &"grass", &"ground")
	bl.add_min_max(Vector3(lo.x, -0.5, fp.end.y), Vector3(hi.x, 0.0, hi.y), BoxList.Kind.FLOOR, &"grass", &"ground")
	bl.add_min_max(Vector3(lo.x, -0.5, fp.position.y), Vector3(fp.position.x, 0.0, fp.end.y), BoxList.Kind.FLOOR, &"grass", &"ground")
	bl.add_min_max(Vector3(fp.end.x, -0.5, fp.position.y), Vector3(hi.x, 0.0, fp.end.y), BoxList.Kind.FLOOR, &"grass", &"ground")
	# A paved path from the gate to the front doors.
	bl.add_min_max(Vector3(26.0, 0.0, 40.15), Vector3(30.0, 0.04, 72.0), BoxList.Kind.TRIM, &"path", &"ground")
	# The estate wall (2.4 m): nothing gets in or out.
	var t := 0.5
	bl.add_min_max(Vector3(lo.x, 0.0, lo.y - t), Vector3(hi.x, 2.4, lo.y), BoxList.Kind.WALL, &"stone_wall", &"walls")
	bl.add_min_max(Vector3(lo.x, 0.0, hi.y), Vector3(hi.x, 2.4, hi.y + t), BoxList.Kind.WALL, &"stone_wall", &"walls")
	bl.add_min_max(Vector3(lo.x - t, 0.0, lo.y - t), Vector3(lo.x, 2.4, hi.y + t), BoxList.Kind.WALL, &"stone_wall", &"walls")
	bl.add_min_max(Vector3(hi.x, 0.0, lo.y - t), Vector3(hi.x + t, 2.4, hi.y + t), BoxList.Kind.WALL, &"stone_wall", &"walls")


# ------------------------------------------------------------------ furniture

static var _rects: Array = []        # placed prop rects per floor, to keep them apart


## A prop box (SOLID: collision, render, in the navmesh as an obstacle) unless it would stand in front of
## a door or on another prop.
static func _prop(b: Built, f: int, c: Vector2, size: Vector2, height: float, mat: StringName, capped := true) -> bool:
	var rect := Rect2(c - size * 0.5, size)
	for d in b.doors:
		if int(d.floor) != f:
			continue
		var cx := Vector2((d.center as Vector3).x, (d.center as Vector3).z)
		var clear := Rect2(cx - Vector2(float(d.w) * 0.5 + 0.7, float(d.w) * 0.5 + 0.7), Vector2(float(d.w) + 1.4, float(d.w) + 1.4))
		if rect.intersects(clear):
			return false
	for r: Array in _rects:
		if int(r[0]) == f and (r[1] as Rect2).grow(0.35).intersects(rect):
			return false
	_rects.append([f, rect])
	var fy := L.floor_y(f)
	b.boxes.add_min_max(Vector3(rect.position.x, fy, rect.position.y), Vector3(rect.end.x, fy + height, rect.end.y), BoxList.Kind.SOLID, mat, &"props")
	# (Nav only: the space above it filled up to the ceiling, so its top is no walkable island. Not in the
	# Great Hall: its void has no ceiling to cap against - a table top there stays an island nobody can
	# climb onto.)
	# (A box taller than the agent leaves its hollow inside walkable - only the surfaces are rasterised:
	# a thin nav-only slab at 0.9 m shuts the floor under it.)
	if height > 1.7:
		b.boxes.add_min_max(Vector3(rect.position.x, fy + 0.9, rect.position.y), Vector3(rect.end.x, fy + 0.95, rect.end.y), BoxList.Kind.PLUG, &"plug", &"plugs")
	if capped and height < L.HEIGHT - 0.1:
		b.boxes.add_min_max(Vector3(rect.position.x, fy + height, rect.position.y), Vector3(rect.end.x, fy + L.HEIGHT, rect.end.y), BoxList.Kind.PLUG, &"plug", &"plugs")
	b.props += 1
	return true


static func _props(b: Built) -> void:
	_rects = []
	# Furniture clear of every doorway; a seeded RNG: the same house every run.
	var rng := RandomNumberGenerator.new()
	rng.seed = 41
	for r: Array in L.ROOMS:
		var f := int(r[1])
		var rect := L.rect_of(r).grow(-0.45)
		if rect.size.x < 1.6 or rect.size.y < 1.6:
			continue
		var kind := String(r[6])
		match kind:
			"hall":
				for x in [23.5, 32.5]:
					for z in [13.0, 21.0]:
						_prop(b, f, Vector2(x, z), Vector2(0.9, 0.9), 3.4, &"pillar", false)
				_prop(b, f, Vector2(28.0, 17.0), Vector2(2.4, 2.4), 0.8, &"wood_dark", false)
				_prop(b, f, Vector2(18.2, 8.5), Vector2(1.4, 0.9), 0.9, &"wood_dark", false)
				_prop(b, f, Vector2(37.8, 8.5), Vector2(1.4, 0.9), 0.9, &"wood_dark", false)
			"dining":
				_prop(b, f, rect.get_center(), Vector2(6.0, 1.7), 0.8, &"wood_dark")
				for k in 4:
					var x := rect.get_center().x - 2.2 + k * 1.45
					_prop(b, f, Vector2(x, rect.get_center().y - 1.35), Vector2(0.5, 0.5), 0.9, &"wood")
					_prop(b, f, Vector2(x, rect.get_center().y + 1.35), Vector2(0.5, 0.5), 0.9, &"wood")
				_prop(b, f, Vector2(rect.position.x + 0.5, rect.get_center().y), Vector2(0.6, 3.0), 1.0, &"wood_dark")
			"kitchen":
				_prop(b, f, Vector2(rect.get_center().x, rect.get_center().y), Vector2(2.6, 1.1), 0.9, &"counter")
				_prop(b, f, Vector2(rect.position.x + 0.4, rect.get_center().y - 2.0), Vector2(0.7, 4.5), 0.9, &"counter")
				_prop(b, f, Vector2(rect.get_center().x, rect.position.y + 0.4), Vector2(4.0, 0.7), 0.9, &"counter")
			"library", "study", "music":
				_prop(b, f, Vector2(rect.position.x + 0.35, rect.get_center().y), Vector2(0.55, minf(rect.size.y, 7.0) * 0.8), 2.3, &"wood_dark")
				_prop(b, f, Vector2(rect.get_center().x, rect.get_center().y), Vector2(1.6, 0.9), 0.78, &"wood")
				if rect.size.y > 7.0:
					_prop(b, f, Vector2(rect.get_center().x + 0.4, rect.position.y + 2.2), Vector2(0.5, 2.6), 2.3, &"wood_dark")
					_prop(b, f, Vector2(rect.get_center().x + 0.4, rect.end.y - 2.2), Vector2(0.5, 2.6), 2.3, &"wood_dark")
			"bedroom":
				_prop(b, f, Vector2(rect.get_center().x, rect.position.y + 1.1), Vector2(1.7, 2.1), 0.6, &"bed")
				_prop(b, f, Vector2(rect.end.x - 0.35, rect.get_center().y + 0.4), Vector2(0.5, 1.4), 1.0, &"wood")
			"parlor":
				_prop(b, f, rect.get_center(), Vector2(1.8, 1.0), 0.45, &"wood")
				_prop(b, f, Vector2(rect.position.x + 0.5, rect.get_center().y - 1.2), Vector2(0.9, 1.8), 0.8, &"sofa")
			"lobby", "foyer":
				if rect.size.x > 5.0:
					_prop(b, f, Vector2(rect.position.x + 1.0, rect.get_center().y), Vector2(1.2, 0.5), 0.9, &"wood_dark")
			"store":
				for k in 2:
					_prop(b, f, Vector2(rect.position.x + 0.45 + k * 1.1, rect.position.y + 0.45 + rng.randf() * 0.5), Vector2(0.7, 0.7), 0.7 + rng.randf() * 0.5, &"crate")
			"conservatory":
				for k in 3:
					_prop(b, f, Vector2(rect.position.x + 2.0 + k * 4.5, rect.get_center().y), Vector2(1.0, 1.0), 1.1, &"planter")
			"boiler":
				_prop(b, f, rect.get_center(), Vector2(2.0, 2.0), 2.2, &"metal")
				_prop(b, f, Vector2(rect.position.x + 0.8, rect.position.y + 0.8), Vector2(1.2, 1.2), 1.2, &"metal")
				_prop(b, f, Vector2(rect.end.x - 1.4, rect.end.y - 0.9), Vector2(1.6, 0.9), 1.0, &"crate")
			"cellar":
				for k in 3:
					_prop(b, f, Vector2(rect.position.x + 0.45, rect.position.y + 1.4 + k * 3.8), Vector2(0.6, 2.4), 1.8, &"wood_dark")
			"bath":
				_prop(b, f, Vector2(rect.end.x - 0.6, rect.get_center().y), Vector2(0.8, 1.7), 0.55, &"tile_white")


# ------------------------------------------------------------------ lights

const KIND_LIGHT := {
	"boiler": [Color(0.6, 0.75, 0.55), 1.1], "cellar": [Color(0.7, 0.6, 0.45), 0.9], "corridor": [Color(1.0, 0.8, 0.55), 0.9],
	"hall": [Color(1.0, 0.82, 0.58), 1.4], "conservatory": [Color(0.7, 0.8, 1.0), 1.0],
}


static func _lights(b: Built) -> void:
	for r: Array in L.ROOMS:
		var f := int(r[1])
		var kind := String(r[6])
		var rect := L.rect_of(r)
		var fy := L.floor_y(f)
		var spec: Array = KIND_LIGHT.get(kind, [Color(1.0, 0.78, 0.55), 1.2])
		var h := float(L.HEIGHT_OF[f])
		if String(r[0]) == "hall":
			# The chandeliers: two big warm lights over the void.
			for x in [24.0, 32.0]:
				b.lights.append({"pos": Vector3(x, fy + 6.2, 17.0), "color": spec[0], "energy": 3.2, "range": 18.0, "shadow": true})
			continue
		if String(r[0]).begins_with("gallery"):
			continue
		var long := maxf(rect.size.x, rect.size.y)
		var n := clampi(int(ceil(long / 9.0)), 1, 4)
		for k in n:
			var t := (k + 0.5) / n
			var p := rect.get_center()
			if rect.size.x >= rect.size.y:
				p.x = rect.position.x + rect.size.x * t
			else:
				p.y = rect.position.y + rect.size.y * t
			var area := rect.size.x * rect.size.y / n
			b.lights.append({"pos": Vector3(p.x, fy + h - 0.5, p.y), "color": spec[0], "energy": clampf(sqrt(area) * 0.35, 0.7, 2.2) * float(spec[1]), "range": clampf(sqrt(area) * 1.5, 5.0, 11.0), "shadow": false})
