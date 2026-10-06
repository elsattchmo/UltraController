class_name UltraGuts
extends Node3D
## Intestine hanging out of a belly wound (presentation): a verlet chain whose first point rides
## the wound on the body (`anchor`, a node under a BoneAttachment3D) - a loop when the far end is
## held in the wound too (`anchor_b`) - swinging and settling under gravity, kept off the floor
## with a ray per point (round robin). Drawn as one smooth tube along the chain (Catmull-Rom),
## bulging and pinching in sections like gut, wet and pink-grey. Lives until the character
## respawns (UltraBodyFX clears it).

const RADIUS := 0.017
const SIDES := 8
const SUB := 3                      ## tube rings per chain segment

var anchor: Node3D
var anchor_b: Node3D
var segments := 12
var seg_len := 0.045
var exclude: Array[RID] = []

var _p := PackedVector3Array()
var _q := PackedVector3Array()      ## previous positions
var _floor := PackedFloat32Array()
var _ray_i := 0
var _mesh := ImmediateMesh.new()
var _mi := MeshInstance3D.new()
var _bump := 0.0

static var _mat: StandardMaterial3D


static func gut_mat() -> StandardMaterial3D:
	if _mat == null:
		_mat = StandardMaterial3D.new()
		var tex := NoiseTexture2D.new()
		tex.width = 64
		tex.height = 64
		tex.seamless = true
		var n := FastNoiseLite.new()
		n.frequency = 0.09
		n.fractal_octaves = 3
		tex.noise = n
		var g := Gradient.new()
		g.set_color(0, Color(0.62, 0.3, 0.33))
		g.set_color(1, Color(0.93, 0.68, 0.66))
		g.add_point(0.55, Color(0.82, 0.5, 0.5))
		tex.color_ramp = g
		_mat.albedo_texture = tex
		_mat.roughness = 0.25
		_mat.metallic_specular = 0.8
		_mat.clearcoat_enabled = true
		_mat.clearcoat = 1.0
		_mat.clearcoat_roughness = 0.1
		_mat.rim_enabled = true
		_mat.rim = 0.2
		_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return _mat


func _ready() -> void:
	top_level = true
	_bump = randf() * TAU
	_mi.mesh = _mesh
	_mi.material_override = gut_mat()
	_mi.top_level = true                 # (the tube is built in world space)
	add_child(_mi)
	_mi.global_transform = Transform3D.IDENTITY
	_mi.extra_cull_margin = 2.0
	var at := anchor.global_position if anchor else global_position
	for i in segments + 1:
		var drop := mini(i, segments - i) if anchor_b else i
		var p := at + Vector3(randf_range(-0.02, 0.02), -seg_len * drop * 0.55, randf_range(-0.02, 0.02))
		_p.append(p)
		_q.append(p)
		_floor.append(-INF)


## Thrown out of the wound along `v` (m/s) to start with.
func kick(v: Vector3, dt := 1.0 / 60.0) -> void:
	for i in range(1, _p.size()):
		_q[i] = _p[i] - v * dt * (0.6 + 0.4 * float(i) / segments)


func _physics_process(delta: float) -> void:
	if anchor == null or not is_instance_valid(anchor):
		queue_free()
		return
	var last := _p.size() - 1
	_p[0] = anchor.global_position
	_q[0] = _p[0]
	var pinned_b := anchor_b != null and is_instance_valid(anchor_b)
	if pinned_b:
		_p[last] = anchor_b.global_position
		_q[last] = _p[last]
	var g := Vector3.DOWN * 9.8 * delta * delta
	var free_end := _p.size() - (1 if pinned_b else 0)
	for i in range(1, free_end):
		var cur := _p[i]
		var v := (cur - _q[i]) * 0.96
		_q[i] = cur
		_p[i] = cur + v + g
	for it in 5:
		for i in range(_p.size() - 1):
			var a := _p[i]
			var b := _p[i + 1]
			var d := b - a
			var l := d.length()
			if l < 1e-5:
				continue
			var corr := d * ((l - seg_len) / l)
			var a_fixed := i == 0
			var b_fixed := pinned_b and i + 1 == last
			if a_fixed and not b_fixed:
				_p[i + 1] = b - corr
			elif b_fixed and not a_fixed:
				_p[i] = a + corr
			elif not a_fixed and not b_fixed:
				_p[i] = a + corr * 0.5
				_p[i + 1] = b - corr * 0.5
	# The floor: a ray under one point per tick (round robin), a clamp for all of them.
	var space := get_world_3d().direct_space_state
	_ray_i = (_ray_i + 1) % _p.size()
	var q := PhysicsRayQueryParameters3D.create(_p[_ray_i] + Vector3.UP * 0.4, _p[_ray_i] + Vector3.DOWN * 1.5, UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC, exclude)
	var hit := space.intersect_ray(q)
	_floor[_ray_i] = (hit.position as Vector3).y if not hit.is_empty() else -INF
	for i in range(1, free_end):
		var fy := _floor[i] + RADIUS
		if _p[i].y < fy:
			_p[i].y = fy
			_q[i] = _q[i].lerp(_p[i], 0.5)          # (friction on the ground)


func _process(_delta: float) -> void:
	if _p.size() < 2:
		return
	# The chain smoothed into a curve, then a tube round it.
	var pts := PackedVector3Array()
	var n := _p.size()
	for i in n - 1:
		var p0 := _p[maxi(i - 1, 0)]
		var p1 := _p[i]
		var p2 := _p[i + 1]
		var p3 := _p[mini(i + 2, n - 1)]
		for k in SUB:
			var t := float(k) / SUB
			var t2 := t * t
			var t3 := t2 * t
			pts.append(0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3))
	pts.append(_p[n - 1])
	_mesh.clear_surfaces()
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	var normal := Vector3.UP
	var prev_ring: Array[Vector3] = []
	var prev_n: Array[Vector3] = []
	var prev_v := 0.0
	for i in pts.size():
		var tan := (pts[mini(i + 1, pts.size() - 1)] - pts[maxi(i - 1, 0)]).normalized()
		if tan.length() < 0.5:
			tan = Vector3.DOWN
		# (Parallel transport: the ring doesn't twist along the tube.)
		normal = (normal - tan * normal.dot(tan))
		if normal.length() < 1e-3:
			normal = tan.cross(Vector3.RIGHT if absf(tan.x) < 0.9 else Vector3.FORWARD)
		normal = normal.normalized()
		var bin := tan.cross(normal)
		# Sections: swollen and pinched along the length; the ends taper into the wound.
		var u := float(i) / (pts.size() - 1)
		var r := RADIUS * (1.0 + 0.22 * sin(i * 1.3 + _bump)) * clampf(minf(u, 1.0 - u) * 12.0 + 0.55, 0.55, 1.0)
		var ring: Array[Vector3] = []
		var norms: Array[Vector3] = []
		for s in SIDES:
			var a := TAU * s / SIDES
			var dn := normal * cos(a) + bin * sin(a)
			ring.append(pts[i] + dn * r)
			norms.append(dn)
		var v := u * 6.0
		if not prev_ring.is_empty():
			for s in SIDES:
				var s2 := (s + 1) % SIDES
				var quad := [[prev_ring[s], prev_n[s], Vector2(float(s) / SIDES, prev_v)],
					[ring[s], norms[s], Vector2(float(s) / SIDES, v)],
					[ring[s2], norms[s2], Vector2(float(s + 1) / SIDES, v)],
					[prev_ring[s2], prev_n[s2], Vector2(float(s + 1) / SIDES, prev_v)]]
				for idx in [0, 1, 2, 0, 2, 3]:
					var vtx: Array = quad[idx]
					_mesh.surface_set_normal(vtx[1])
					_mesh.surface_set_uv(vtx[2])
					_mesh.surface_add_vertex(vtx[0])
		prev_ring = ring
		prev_n = norms
		prev_v = v
	_mesh.surface_end()
