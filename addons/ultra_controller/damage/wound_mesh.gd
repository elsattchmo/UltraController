class_name UltraWoundMesh
extends RefCounted
## Gore meshes, built in code (presentation): the open end of a severed limb - on the body's
## stump and on the part that flew off - and a torso blast's crater. Each is an irregular domed
## slab of meat under a ring of skin and yellow fat, wet (procedural noise albedo + normal map),
## the bone(s) standing out of it with marrow in the end, a few torn flaps hanging off the rim.
## Local +Y points out of the wound; `radius` is the limb's.

static var _meat: StandardMaterial3D
static var _fat: StandardMaterial3D
static var _bone: StandardMaterial3D
static var _marrow: StandardMaterial3D


static func meat_mat() -> StandardMaterial3D:
	if _meat == null:
		_meat = StandardMaterial3D.new()
		var tex := NoiseTexture2D.new()
		tex.width = 128
		tex.height = 128
		tex.seamless = true
		var n := FastNoiseLite.new()
		n.noise_type = FastNoiseLite.TYPE_CELLULAR
		n.frequency = 0.06
		n.fractal_octaves = 3
		tex.noise = n
		var g := Gradient.new()
		g.set_color(0, Color(0.22, 0.01, 0.02))
		g.set_color(1, Color(0.78, 0.18, 0.17))
		g.add_point(0.45, Color(0.5, 0.04, 0.05))
		g.add_point(0.8, Color(0.85, 0.36, 0.32))
		tex.color_ramp = g
		_meat.albedo_texture = tex
		var nt := NoiseTexture2D.new()
		nt.width = 128
		nt.height = 128
		nt.seamless = true
		nt.as_normal_map = true
		nt.bump_strength = 6.0
		nt.noise = n
		_meat.normal_enabled = true
		_meat.normal_texture = nt
		_meat.roughness = 0.3
		_meat.metallic_specular = 0.7
		_meat.clearcoat_enabled = true              # (wet)
		_meat.clearcoat = 0.8
		_meat.clearcoat_roughness = 0.15
		_meat.uv1_scale = Vector3(3.0, 3.0, 1.0)
		_meat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_meat.vertex_color_use_as_albedo = true
	return _meat


static func fat_mat() -> StandardMaterial3D:
	if _fat == null:
		_fat = StandardMaterial3D.new()
		_fat.albedo_color = Color(0.86, 0.6, 0.42)             # (the fat under the skin, blood-stained)
		_fat.roughness = 0.6
		_fat.metallic_specular = 0.3
		_fat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return _fat


static func bone_mat() -> StandardMaterial3D:
	if _bone == null:
		_bone = StandardMaterial3D.new()
		_bone.albedo_color = Color(0.92, 0.88, 0.78)
		_bone.roughness = 0.55
	return _bone


static func marrow_mat() -> StandardMaterial3D:
	if _marrow == null:
		_marrow = StandardMaterial3D.new()
		_marrow.albedo_color = Color(0.35, 0.03, 0.03)
		_marrow.roughness = 0.3
	return _marrow


## The open end of a limb cut through: `bones` 1 (upper arm, thigh, neck, hand, foot) or 2
## (forearm, shin), `rng_seed` makes each one its own.
static func stump(radius: float, rng_seed: int, bones := 1) -> Node3D:
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	var root := Node3D.new()
	root.name = "Stump"
	# The meat: a ragged domed disc filling the cross-section.
	var segs := 16
	var rim := PackedFloat32Array()
	for i in segs:
		rim.append(radius * rng.randf_range(0.88, 1.12))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var centre := Vector3(0, radius * 0.45, 0)
	for i in segs:
		var a0 := TAU * i / segs
		var a1 := TAU * (i + 1) / segs
		var r0 := rim[i]
		var r1 := rim[(i + 1) % segs]
		var mid0 := Vector3(cos(a0) * r0 * 0.55, radius * rng.randf_range(0.12, 0.26), sin(a0) * r0 * 0.55)
		var mid1 := Vector3(cos(a1) * r1 * 0.55, radius * 0.18, sin(a1) * r1 * 0.55)
		var e0 := Vector3(cos(a0) * r0, rng.randf_range(-0.01, 0.015), sin(a0) * r0)
		var e1 := Vector3(cos(a1) * r1, 0.0, sin(a1) * r1)
		for tri: Array in [[centre, mid1, mid0], [mid0, mid1, e1], [mid0, e1, e0]]:
			for v: Vector3 in tri:
				st.set_uv(Vector2(v.x, v.z) / (radius * 2.0) + Vector2(0.5, 0.5))
				st.add_vertex(v)
	st.generate_normals()
	var meat := MeshInstance3D.new()
	meat.mesh = st.commit()
	meat.material_override = meat_mat()
	root.add_child(meat)
	# Skin and fat round the rim.
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = radius * 0.93
	tm.outer_radius = radius * 1.04
	tm.rings = 18
	tm.ring_segments = 6
	ring.mesh = tm
	ring.material_override = fat_mat()
	ring.scale = Vector3(1.0, 0.3, 1.0)
	root.add_child(ring)
	# The bone(s) standing out of it, marrow at the end.
	for b in bones:
		var off := Vector3.ZERO if bones == 1 else Vector3((b - 0.5) * radius * 0.7, 0, rng.randf_range(-0.1, 0.1) * radius)
		var br := radius * (0.26 if bones == 1 else 0.17)
		var len := radius * rng.randf_range(0.5, 0.95)
		var cyl := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = br * 0.9
		cm.bottom_radius = br
		cm.height = len
		cm.radial_segments = 8
		cm.rings = 1
		cyl.mesh = cm
		cyl.material_override = bone_mat()
		cyl.position = off + Vector3(0, len * 0.5 + radius * 0.05, 0)
		cyl.rotation = Vector3(rng.randf_range(-0.2, 0.2), 0, rng.randf_range(-0.2, 0.2))
		root.add_child(cyl)
		var mar := MeshInstance3D.new()
		var mc := CylinderMesh.new()
		mc.top_radius = br * 0.55
		mc.bottom_radius = br * 0.55
		mc.height = 0.004
		mc.radial_segments = 8
		mar.mesh = mc
		mar.material_override = marrow_mat()
		mar.position = Vector3(0, len * 0.5 + 0.001, 0)
		cyl.add_child(mar)
	# Torn flaps of skin and muscle off the rim, hanging out.
	for i in rng.randi_range(2, 4):
		var a := rng.randf() * TAU
		var flap := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(radius * rng.randf_range(0.35, 0.6), radius * rng.randf_range(0.5, 1.0), radius * 0.08)
		flap.mesh = bm
		flap.material_override = meat_mat() if rng.randf() < 0.6 else fat_mat()
		var at := Vector3(cos(a), 0, sin(a)) * radius * 0.95
		flap.position = at + Vector3(0, bm.size.y * 0.3, 0)
		flap.rotation = Vector3(0, -a + PI * 0.5, rng.randf_range(0.3, 0.9) * (1 if rng.randf() < 0.5 else -1))
		root.add_child(flap)
	return root


## The cut end fitted to the real cut: `ring` (points round the edge of the cut, in order, in
## the parent's space), `out` pointing out of the wound. A thin band of yellow fat just inside
## the skin, the meat raised in a ragged dome, darker and wetter in the middle, the bone(s)
## broken off standing out of it with marrow in the end, a few torn muscle strands hanging out.
static func cap(ring: PackedVector3Array, out: Vector3, bones: int, rng_seed: int, dome := 1.0, strands := true) -> Node3D:
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	var root := Node3D.new()
	root.name = "Stump"
	var n := ring.size()
	if n < 3:
		return root
	out = out.normalized()
	var c := Vector3.ZERO
	for v in ring:
		c += v
	c /= n
	var rad := 0.0
	for v in ring:
		rad += (v - c).length()
	rad /= n
	# Fat band (rim -> 88 % in), then meat: a middle ring raised and jittered, the centre higher.
	var inner := PackedVector3Array()
	var mid := PackedVector3Array()
	for v in ring:
		var d := v - c
		inner.append(c + d * 0.88 + out * rad * 0.04)
		mid.append(c + d * rng.randf_range(0.5, 0.6) + out * rad * rng.randf_range(0.14, 0.22) * dome)
	var top := c + out * rad * 0.3 * dome
	var fat := SurfaceTool.new()
	fat.begin(Mesh.PRIMITIVE_TRIANGLES)
	var meat := SurfaceTool.new()
	meat.begin(Mesh.PRIMITIVE_TRIANGLES)
	var col_edge := Color(0.8, 0.26, 0.24)
	var col_mid := Color(0.7, 0.18, 0.17)
	var col_top := Color(0.45, 0.06, 0.07)
	var tri := func(st: SurfaceTool, a: Vector3, b: Vector3, d: Vector3, ca: Color, cb: Color, cd: Color) -> void:
		# Wound facing out of the cut.
		if (b - a).cross(d - a).dot(out) < 0.0:
			var t := b
			b = d
			d = t
			var tc := cb
			cb = cd
			cd = tc
		for pair: Array in [[a, ca], [b, cb], [d, cd]]:
			var p: Vector3 = pair[0]
			st.set_color(pair[1])
			st.set_uv(Vector2((p - c).dot(out.cross(Vector3.UP if absf(out.y) < 0.9 else Vector3.RIGHT).normalized()), (p - c).dot(out.cross(out.cross(Vector3.UP if absf(out.y) < 0.9 else Vector3.RIGHT)).normalized())) / (rad * 2.0) + Vector2(0.5, 0.5))
			st.add_vertex(p)
	for i in n:
		var j := (i + 1) % n
		tri.call(fat, ring[i] + out * 0.001, ring[j] + out * 0.001, inner[j], col_edge, col_edge, col_edge)
		tri.call(fat, ring[i] + out * 0.001, inner[j], inner[i], col_edge, col_edge, col_edge)
		tri.call(meat, inner[i], inner[j], mid[j], col_edge, col_edge, col_mid)
		tri.call(meat, inner[i], mid[j], mid[i], col_edge, col_mid, col_mid)
		tri.call(meat, mid[i], mid[j], top, col_mid, col_mid, col_top)
	fat.generate_normals()
	meat.generate_normals()
	var fm := MeshInstance3D.new()
	fm.mesh = fat.commit()
	fm.material_override = fat_mat()
	root.add_child(fm)
	var mm := MeshInstance3D.new()
	mm.mesh = meat.commit()
	mm.material_override = meat_mat()
	root.add_child(mm)
	# The bone(s), snapped off: a shaft out of the meat, a sharp shard on one side, marrow.
	var side := out.cross(Vector3.UP if absf(out.y) < 0.9 else Vector3.RIGHT).normalized()
	for b in bones:
		var off := Vector3.ZERO if bones == 1 else side * (b - 0.5) * rad * 0.75
		var br := rad * (0.24 if bones == 1 else 0.15)
		var len := rad * rng.randf_range(0.25, 0.45)
		var axis := (out + side * rng.randf_range(-0.15, 0.15)).normalized()
		var bone := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = br * 0.85
		cm.bottom_radius = br
		cm.height = len
		cm.radial_segments = 8
		cm.rings = 1
		bone.mesh = cm
		bone.material_override = bone_mat()
		bone.transform = Transform3D(Basis(Quaternion(Vector3.UP, axis)), c + off + axis * len * 0.5)
		root.add_child(bone)
		var shard := MeshInstance3D.new()
		var sh := CylinderMesh.new()
		sh.top_radius = 0.0
		sh.bottom_radius = br * 0.5
		sh.height = len * 0.45
		sh.radial_segments = 5
		sh.rings = 1
		shard.mesh = sh
		shard.material_override = bone_mat()
		shard.position = Vector3(br * 0.5, len * 0.5 + sh.height * 0.4, 0)
		bone.add_child(shard)
		var mar := MeshInstance3D.new()
		var mc := CylinderMesh.new()
		mc.top_radius = br * 0.5
		mc.bottom_radius = br * 0.5
		mc.height = 0.003
		mc.radial_segments = 8
		mar.mesh = mc
		mar.material_override = marrow_mat()
		mar.position = Vector3(0, len * 0.5 + 0.0015, 0)
		bone.add_child(mar)
	# Torn shreds of muscle drooping out of the meat (rounded, not spikes).
	for k in (rng.randi_range(1, 3) if strands else 0):
		var i := rng.randi() % n
		var from := c.lerp(mid[i], rng.randf_range(0.5, 0.9)) + out * rad * 0.05
		var dir := (out * rng.randf_range(0.3, 0.6) + Vector3.DOWN * rng.randf_range(0.7, 1.0) + side * rng.randf_range(-0.3, 0.3)).normalized()
		var len := rad * rng.randf_range(0.35, 0.6)
		var strand := MeshInstance3D.new()
		var sm := CapsuleMesh.new()
		sm.radius = rad * rng.randf_range(0.07, 0.11)
		sm.height = len
		sm.radial_segments = 6
		sm.rings = 2
		strand.mesh = sm
		strand.material_override = meat_mat()
		strand.transform = Transform3D(Basis(Quaternion(Vector3.UP, dir)), from + dir * len * 0.4)
		strand.scale = Vector3(1.0, 1.0, 0.6)
		root.add_child(strand)
	return root


## A ring of `segs` points round a cross-section: from points `pts` (any order) near a plane
## through `c` with normal `axis`, the farthest out in each angular slice (an irregular outline
## that fits the limb), pulled out a little so it covers the skin.
static func outline(pts: PackedVector3Array, c: Vector3, axis: Vector3, segs := 18, grow := 1.06) -> PackedVector3Array:
	axis = axis.normalized()
	var u := axis.cross(Vector3.UP if absf(axis.y) < 0.9 else Vector3.RIGHT).normalized()
	var w := axis.cross(u)
	var best := PackedFloat32Array()
	best.resize(segs)
	best.fill(0.0)
	for p in pts:
		var d := p - c
		d -= axis * d.dot(axis)
		var a := atan2(d.dot(w), d.dot(u))
		var k := int(floor((a + PI) / TAU * segs)) % segs
		best[k] = maxf(best[k], d.length())
	# Sparse points made spikes: each slice is held near the median radius (empty slices take
	# it), then smoothed with its neighbours - a limb's outline, not a star.
	var vals: Array[float] = []
	for k in segs:
		if best[k] > 0.0:
			vals.append(best[k])
	vals.sort()
	var med: float = vals[vals.size() / 2] if not vals.is_empty() else 0.04
	var held := PackedFloat32Array()
	for k in segs:
		held.append(clampf(best[k], med * 0.8, med * 1.15) if best[k] > 0.0 else med)
	var out := PackedVector3Array()
	for k in segs:
		var r := (held[(k + segs - 1) % segs] + held[k] * 2.0 + held[(k + 1) % segs]) * 0.25
		var a := (float(k) + 0.5) / segs * TAU - PI
		out.append(c + (u * cos(a) + w * sin(a)) * r * grow)
	return out


## A crater blown into the body (a blast into the torso): `radius` round the middle, in a plane
## facing +Y, the meat dished in under a ragged edge - a fitted cap turned inside out.
static func crater(radius: float, rng_seed: int) -> Node3D:
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	var ring := PackedVector3Array()
	for k in 16:
		var a := TAU * k / 16.0
		var r := radius * rng.randf_range(0.8, 1.15)
		ring.append(Vector3(cos(a) * r, rng.randf_range(-0.004, 0.004), sin(a) * r))
	var root := cap(ring, Vector3.UP, 0, rng_seed, -0.9, false)
	# Torn strands of muscle round the edge, hanging down out of it.
	return root
