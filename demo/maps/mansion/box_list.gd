class_name BoxList
extends RefCounted
## Axis-aligned boxes: the one source of truth for a map built from code. The same list makes the
## collision (one StaticBody3D per group, a BoxShape3D per box), the render meshes (one merged
## ArrayMesh per material) and the navigation source geometry, so what you see, what you bump into
## and where zombies can walk can't disagree.
##
## A box's `kind` decides where it goes:
##   FLOOR, WALL, CEILING, SOLID (furniture, cover)   collision + render + navigation
##   STAIR   collision + render; the navmesh gets a smooth wedge instead (add_nav_wedge: a staircase's
##           0.174 m steps trip Recast's ledge filter - two steps' climb is nearly its 0.35 limit)
##   PLUG    a doorway filled for the navmesh only (a door's NavigationLink3D crosses it instead)
##   TRIM    render only (skirting, glass panes you may walk through, light fittings)
##   ROOF    collision + render, left out of the navigation geometry (nobody walks up there)

enum Kind { FLOOR, WALL, CEILING, STAIR, SOLID, PLUG, TRIM, ROOF }

class Box:
	var min := Vector3.ZERO
	var max := Vector3.ZERO
	var kind := Kind.WALL
	var mat := &"plaster"
	var group := &"world"

	func size() -> Vector3:
		return max - min

	func center() -> Vector3:
		return (min + max) * 0.5

	func key() -> String:
		return "%d|%s|%s|%s|%s" % [kind, mat, group, str(min.snapped(Vector3.ONE * 0.001)), str(max.snapped(Vector3.ONE * 0.001))]


var boxes: Array[Box] = []
var nav_extra := PackedVector3Array()        ## extra navigation triangles (stair wedges)
var _seen := {}


## A box from its corners. Identical boxes (same corners, kind, material, group) are kept once.
func add_min_max(lo: Vector3, hi: Vector3, kind: Kind, mat: StringName, group: StringName = &"world") -> Box:
	var b := Box.new()
	b.min = Vector3(minf(lo.x, hi.x), minf(lo.y, hi.y), minf(lo.z, hi.z))
	b.max = Vector3(maxf(lo.x, hi.x), maxf(lo.y, hi.y), maxf(lo.z, hi.z))
	b.kind = kind
	b.mat = mat
	b.group = group
	var k := b.key()
	if _seen.has(k):
		return _seen[k]
	_seen[k] = b
	boxes.append(b)
	return b


func add(center: Vector3, size: Vector3, kind: Kind, mat: StringName, group: StringName = &"world") -> Box:
	return add_min_max(center - size * 0.5, center + size * 0.5, kind, mat, group)


## Where does the list reach (all collision-bearing boxes)?
func bounds() -> AABB:
	var out := AABB()
	var first := true
	for b in boxes:
		var bb := AABB(b.min, b.size())
		out = bb if first else out.merge(bb)
		first = false
	return out


func count(kind: Kind) -> int:
	var n := 0
	for b in boxes:
		if b.kind == kind:
			n += 1
	return n


static func has_collision(k: Kind) -> bool:
	return k != Kind.PLUG and k != Kind.TRIM


static func has_mesh(k: Kind) -> bool:
	return k != Kind.PLUG


static func in_nav(k: Kind) -> bool:
	return k != Kind.TRIM and k != Kind.ROOF and k != Kind.STAIR


## One StaticBody3D per group under `parent`, a BoxShape3D per collision box. Returns group -> body.
func build_collision(parent: Node3D, layer: int, mask := 0) -> Dictionary:
	var bodies := {}
	var shapes := {}
	for b in boxes:
		if not has_collision(b.kind):
			continue
		var body: StaticBody3D = bodies.get(b.group)
		if body == null:
			body = StaticBody3D.new()
			body.name = "Col_" + String(b.group)
			body.collision_layer = layer
			body.collision_mask = mask
			parent.add_child(body)
			bodies[b.group] = body
		var sz := b.size()
		var shape: BoxShape3D = shapes.get(sz.snapped(Vector3.ONE * 0.001))
		if shape == null:
			shape = BoxShape3D.new()
			shape.size = sz
			shapes[sz.snapped(Vector3.ONE * 0.001)] = shape
		var cs := CollisionShape3D.new()
		cs.shape = shape
		cs.position = b.center()
		body.add_child(cs)
	return bodies


## One MeshInstance3D per material, every box of it merged. `materials`: name -> Material
## (a box with an unknown material gets `fallback`).
func build_meshes(parent: Node3D, materials: Dictionary, fallback: Material = null) -> Array[MeshInstance3D]:
	var by_mat := {}
	for b in boxes:
		if has_mesh(b.kind):
			(by_mat.get_or_add(b.mat, []) as Array).append(b)
	var out: Array[MeshInstance3D] = []
	for mat_name: StringName in by_mat:
		var verts := PackedVector3Array()
		var norms := PackedVector3Array()
		var uvs := PackedVector2Array()
		var idx := PackedInt32Array()
		for b: Box in by_mat[mat_name]:
			_append_box(b, verts, norms, uvs, idx)
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = norms
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		arrays[Mesh.ARRAY_INDEX] = idx
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mi := MeshInstance3D.new()
		mi.name = "Mesh_" + String(mat_name)
		mi.mesh = mesh
		mi.material_override = materials.get(mat_name, fallback)
		parent.add_child(mi)
		out.append(mi)
	return out


## The navigation source geometry: every box that takes part (not TRIM / ROOF), as triangles.
func nav_source() -> NavigationMeshSourceGeometryData3D:
	var src := NavigationMeshSourceGeometryData3D.new()
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for b in boxes:
		if in_nav(b.kind):
			_append_box(b, verts, norms, uvs, idx)
	var faces := PackedVector3Array()
	for i in idx:
		faces.append(verts[i])
	faces.append_array(nav_extra)
	src.add_faces(faces, Transform3D.IDENTITY)
	return src


## A solid ramp for the navmesh only: the sloped top from the low edge (`lo_a` - `lo_b`, across the
## flight) to the high edge (`hi_a` - `hi_b`), filled down to `base_y`.
func add_nav_wedge(lo_a: Vector3, lo_b: Vector3, hi_a: Vector3, hi_b: Vector3, base_y: float) -> void:
	var t: Array[Vector3] = [lo_a, lo_b, hi_b, hi_a]
	var b: Array[Vector3] = []
	for p: Vector3 in t:
		b.append(Vector3(p.x, base_y, p.z))
	var centre := Vector3.ZERO
	for p: Vector3 in t:
		centre += p
	for p: Vector3 in b:
		centre += p
	centre /= 8.0
	var quads := [[t[0], t[1], t[2], t[3]], [b[0], b[1], b[2], b[3]], [t[0], t[1], b[1], b[0]], [t[1], t[2], b[2], b[1]], [t[2], t[3], b[3], b[2]], [t[3], t[0], b[0], b[3]]]
	for q: Array in quads:
		var mid: Vector3 = ((q[0] as Vector3) + (q[1] as Vector3) + (q[2] as Vector3) + (q[3] as Vector3)) * 0.25
		for tri: Array in [[q[0], q[1], q[2]], [q[0], q[2], q[3]]]:
			var tn: Vector3 = ((tri[1] as Vector3) - (tri[0] as Vector3)).cross((tri[2] as Vector3) - (tri[0] as Vector3))
			# Godot's front face is clockwise seen from outside: a triangle whose cross product points
			# outward (counter-clockwise) is flipped.
			if tn.dot(mid - centre) >= 0.0:
				nav_extra.append_array(PackedVector3Array([tri[0], tri[2], tri[1]]))
			else:
				nav_extra.append_array(PackedVector3Array([tri[0], tri[1], tri[2]]))


## 24 vertices (flat normals, UVs in metres so a tiling material scales with the world), 12 triangles.
static func _append_box(b: Box, verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, idx: PackedInt32Array) -> void:
	var lo := b.min
	var hi := b.max
	var faces := [
		[Vector3.UP, Vector3(lo.x, hi.y, hi.z), Vector3(hi.x, hi.y, hi.z), Vector3(hi.x, hi.y, lo.z), Vector3(lo.x, hi.y, lo.z)],
		[Vector3.DOWN, Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, lo.y, hi.z), Vector3(lo.x, lo.y, hi.z)],
		[Vector3.BACK, Vector3(lo.x, lo.y, hi.z), Vector3(hi.x, lo.y, hi.z), Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z)],
		[Vector3.FORWARD, Vector3(hi.x, lo.y, lo.z), Vector3(lo.x, lo.y, lo.z), Vector3(lo.x, hi.y, lo.z), Vector3(hi.x, hi.y, lo.z)],
		[Vector3.RIGHT, Vector3(hi.x, lo.y, hi.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(hi.x, hi.y, hi.z)],
		[Vector3.LEFT, Vector3(lo.x, lo.y, lo.z), Vector3(lo.x, lo.y, hi.z), Vector3(lo.x, hi.y, hi.z), Vector3(lo.x, hi.y, lo.z)],
	]
	for f: Array in faces:
		var n: Vector3 = f[0]
		var base := verts.size()
		for k in 4:
			var v: Vector3 = f[1 + k]
			verts.append(v)
			norms.append(n)
			# Planar UVs in metres: the two axes across the face.
			if absf(n.y) > 0.5:
				uvs.append(Vector2(v.x, v.z))
			elif absf(n.x) > 0.5:
				uvs.append(Vector2(v.z, -v.y))
			else:
				uvs.append(Vector2(v.x, -v.y))
		# Winding: clockwise seen from outside - Godot's front face (BoxMesh.get_faces() has its cross
		# products pointing inward). Checked, not assumed.
		var a: Vector3 = f[1]
		var bb: Vector3 = f[2]
		var c: Vector3 = f[3]
		if (bb - a).cross(c - a).dot(n) < 0.0:
			idx.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
		else:
			idx.append_array([base, base + 2, base + 1, base, base + 3, base + 2])
