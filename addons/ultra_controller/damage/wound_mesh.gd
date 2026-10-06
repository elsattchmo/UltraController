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
		_meat.roughness = 0.22
		_meat.metallic_specular = 0.8
		_meat.uv1_scale = Vector3(2.0, 2.0, 1.0)
	return _meat


static func fat_mat() -> StandardMaterial3D:
	if _fat == null:
		_fat = StandardMaterial3D.new()
		_fat.albedo_color = Color(0.86, 0.62, 0.48)            # (skin edge and fat, blood-stained)
		_fat.roughness = 0.35
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


## A crater blown into the body (a torso hit by a blast): meat sunk into the surface, ragged
## skin and fat round it, a rib or two showing. +Y out of the body.
static func crater(radius: float, rng_seed: int) -> Node3D:
	var root := stump(radius, rng_seed, 0)
	(root.get_child(0) as Node3D).scale = Vector3(1.0, -0.7, 1.0)    # (dished in, not domed out)
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed + 17
	for i in rng.randi_range(1, 2):
		var rib := MeshInstance3D.new()
		var cm := CapsuleMesh.new()
		cm.radius = radius * 0.07
		cm.height = radius * 1.4
		cm.radial_segments = 6
		cm.rings = 1
		rib.mesh = cm
		rib.material_override = bone_mat()
		rib.position = Vector3(rng.randf_range(-0.3, 0.3) * radius, -radius * 0.12, (i - 0.5) * radius * 0.6)
		rib.rotation = Vector3(0, 0, PI * 0.5)
		root.add_child(rib)
	return root
