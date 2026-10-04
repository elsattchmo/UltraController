class_name UltraMeshCap
extends RefCounted
## Closes the holes in a skinned mesh: every open boundary loop (e.g. the neck opening left
## when the head was split into its own mesh for first person) gets a fan of triangles to its
## centre, both windings, skinned like the loop. Results are cached per source mesh.

static var _cache := {}


static func capped(src: ArrayMesh) -> ArrayMesh:
	if src == null:
		return null
	var key := src.get_rid()
	if _cache.has(key):
		return _cache[key]
	var out := src.duplicate() as ArrayMesh
	for s in src.get_surface_count():
		if src.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arr := src.surface_get_arrays(s)
		var cap := _cap_surface(arr)
		if cap.is_empty():
			continue
		var flags := src.surface_get_format(s) & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, cap, [], {}, flags)
		out.surface_set_material(out.get_surface_count() - 1, src.surface_get_material(s))
	_cache[key] = out
	return out


static func _cap_surface(arr: Array) -> Array:
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	if idx.is_empty():
		idx.resize(verts.size())
		for i in verts.size():
			idx[i] = i
	# Weld by position (UV / normal seams split vertices that are really the same point).
	var weld := PackedInt32Array()
	weld.resize(verts.size())
	var by_pos := {}
	for i in verts.size():
		var k := verts[i].snappedf(0.0001)
		if not by_pos.has(k):
			by_pos[k] = i
		weld[i] = by_pos[k]
	# Edges used by exactly one triangle are on a boundary (keep their winding).
	var count := {}
	var dir_edge := {}
	for t in range(0, idx.size(), 3):
		for e in 3:
			var a := weld[idx[t + e]]
			var b := weld[idx[t + (e + 1) % 3]]
			var k := Vector2i(mini(a, b), maxi(a, b))
			count[k] = int(count.get(k, 0)) + 1
			dir_edge[k] = Vector2i(a, b)
	var boundary: Array[Vector2i] = []
	for k: Vector2i in count:
		if count[k] == 1:
			boundary.append(dir_edge[k])
	if boundary.is_empty():
		return []
	# Loops = connected groups of boundary edges.
	var parent := {}
	var find := func(x: int, f: Callable) -> int:
		while parent.get(x, x) != x:
			x = parent[x]
		return x
	for e in boundary:
		var ra: int = find.call(e.x, find)
		var rb: int = find.call(e.y, find)
		if ra != rb:
			parent[ra] = rb
	var loops := {}
	for e in boundary:
		var r: int = find.call(e.x, find)
		if not loops.has(r):
			loops[r] = []
		(loops[r] as Array).append(e)
	var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV] if arr[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
	var bones: PackedInt32Array = arr[Mesh.ARRAY_BONES] if arr[Mesh.ARRAY_BONES] != null else PackedInt32Array()
	var weights: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS] if arr[Mesh.ARRAY_WEIGHTS] != null else PackedFloat32Array()
	var per := bones.size() / maxi(verts.size(), 1)
	# The cap takes the mesh's most common colour (the skin of a palette-textured body).
	var skin_uv := Vector2.ZERO
	if not uvs.is_empty():
		var counts := {}
		var best := 0
		for uv in uvs:
			var k := uv.snappedf(0.01)
			counts[k] = int(counts.get(k, 0)) + 1
			if counts[k] > best:
				best = counts[k]
				skin_uv = uv
	var o_v := PackedVector3Array()
	var o_n := PackedVector3Array()
	var o_uv := PackedVector2Array()
	var o_b := PackedInt32Array()
	var o_w := PackedFloat32Array()
	var add := func(p: Vector3, n: Vector3, src: int) -> void:
		o_v.append(p)
		o_n.append(n)
		o_uv.append(skin_uv)
		for j in per:
			o_b.append(bones[src * per + j])
			o_w.append(weights[src * per + j])
	for r: int in loops:
		var edges: Array = loops[r]
		if edges.size() < 3 or edges.size() > 400:
			continue
		var c := Vector3.ZERO
		for e: Vector2i in edges:
			c += verts[e.x]
		c /= edges.size()
		# The centre takes the skinning of the loop vertex nearest to it.
		var src0: int = (edges[0] as Vector2i).x
		for e: Vector2i in edges:
			if verts[e.x].distance_to(c) < verts[src0].distance_to(c):
				src0 = e.x
		for e: Vector2i in edges:
			var a := verts[e.x]
			var b := verts[e.y]
			var n := (b - a).cross(c - a).normalized()
			# Boundary edges run opposite to the hole's own winding: (b, a, c) faces outward.
			add.call(b, n, e.y); add.call(a, n, e.x); add.call(c, n, src0)
			add.call(a, -n, e.x); add.call(b, -n, e.y); add.call(c, -n, src0)
	if o_v.is_empty():
		return []
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = o_v
	out[Mesh.ARRAY_NORMAL] = o_n
	out[Mesh.ARRAY_TEX_UV] = o_uv
	var ix := PackedInt32Array()
	ix.resize(o_v.size())
	for i in o_v.size():
		ix[i] = i
	out[Mesh.ARRAY_INDEX] = ix
	if per > 0:
		out[Mesh.ARRAY_BONES] = o_b
		out[Mesh.ARRAY_WEIGHTS] = o_w
	return out
