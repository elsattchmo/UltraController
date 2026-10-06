class_name UltraGuts
extends Node3D
## Intestine hanging out of a belly wound (presentation): a verlet chain whose first point rides
## the wound on the body (`anchor`, a node under a BoneAttachment3D) - a loop when the far end is
## held in the wound too (`anchor_b`) - swinging and settling under gravity, kept off the floor
## with a ray per point (round robin), and off the body: every point outside the body's
## capsules (`colliders`, UltraBodyFX.body_capsules - the posed torso, limbs, head) but the
## few next to the wound it comes out of. Drawn as one smooth tube along the chain (Catmull-Rom),
## bulging and pinching in sections like gut, wet and pink-grey. Lives until the character
## respawns (UltraBodyFX clears it).

const RADIUS := 0.017
const SIDES := 8
const SUB := 2                      ## tube rings per chain segment

var anchor: Node3D
var anchor_b: Node3D
var segments := 12
var seg_len := 0.045
var exclude: Array[RID] = []
## () -> Array of [a, b, radius] capsules (world) the gut lies against.
var colliders: Callable
## Points this close (in links) to an anchor may stay inside the body: they come out of it.
var free_links := 3

var _p := PackedVector3Array()
var _q := PackedVector3Array()      ## previous positions
var _floor := PackedFloat32Array()
var _ray_i := 0
var _mesh := ArrayMesh.new()
var _dirty := true
var _still := 0                     ## ticks it hasn't moved
var _asleep := false
var _sleep_at := Vector3.ZERO       ## anchors where it fell asleep (moving them wakes it)
var _sleep_b := Vector3.ZERO
var _age := 0.0
var _mi := MeshInstance3D.new()
var _bump := 0.0

static var _mat: StandardMaterial3D
var cost_us := 0                       ## (time spent in this gut's updates, for perf tests)


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
	var t0 := Time.get_ticks_usec()
	_physics_step(delta)
	cost_us += Time.get_ticks_usec() - t0


func _physics_step(delta: float) -> void:
	if anchor == null or not is_instance_valid(anchor):
		queue_free()
		return
	var last := _p.size() - 1
	var pinned_b := anchor_b != null and is_instance_valid(anchor_b)
	# Asleep (lying still): nothing to do until the body it hangs from moves.
	var ab_pos := anchor_b.global_position if pinned_b else Vector3.ZERO
	if _asleep:
		# (3 mm, 1 cm once it's been out a while: a settled ragdoll still shivers.)
		var wake := 9e-6 if _age < 2.0 else 1e-4
		if anchor.global_position.distance_squared_to(_sleep_at) < wake and ab_pos.distance_squared_to(_sleep_b) < wake:
			return
		_asleep = false
		_still = 0
	_age += delta
	_p[0] = anchor.global_position
	_q[0] = _p[0]
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
	# The body: pushed out of its capsules (sliding, a little friction), no clipping through.
	# (Only the capsules within reach of the chain's bounding sphere.)
	if colliders.is_valid():
		var mid := Vector3.ZERO
		for i in _p.size():
			mid += _p[i]
		mid /= _p.size()
		var reach := 0.0
		for i in _p.size():
			reach = maxf(reach, mid.distance_squared_to(_p[i]))
		reach = sqrt(reach) + RADIUS * 1.2
		var near: Array = []
		for c: Array in colliders.call():
			var a0: Vector3 = c[0]
			var ab0: Vector3 = (c[1] as Vector3) - a0
			var l20 := ab0.length_squared()
			var t0 := clampf((mid - a0).dot(ab0) / l20, 0.0, 1.0) if l20 > 1e-8 else 0.0
			if mid.distance_to(a0 + ab0 * t0) < reach + float(c[2]):
				near.append(c)
		var hi := free_end - (free_links if pinned_b else 0)
		for i in range(free_links, hi):
			var p := _p[i]
			for c: Array in near:
				var a: Vector3 = c[0]
				var ab: Vector3 = (c[1] as Vector3) - a
				var l2 := ab.length_squared()
				var t := clampf((p - a).dot(ab) / l2, 0.0, 1.0) if l2 > 1e-8 else 0.0
				var d := p - (a + ab * t)
				var rr: float = c[2] + RADIUS * 1.1
				var dl := d.length()
				if dl < rr:
					var n := d / dl if dl > 1e-5 else Vector3.UP
					# Back out the side it was on last tick: a body bending fast over a gut
					# carries the point past its axis, and the near side is then the far one.
					var q := _q[i]
					var tq := clampf((q - a).dot(ab) / l2, 0.0, 1.0) if l2 > 1e-8 else 0.0
					var dq := q - (a + ab * tq)
					if dq.length() > 1e-4 and dq.dot(d) < 0.0:
						n = dq.normalized()
					p = a + ab * t + n * rr
			if p != _p[i]:
				_p[i] = p
				_q[i] = _q[i].lerp(p, 0.3)
	# The floor: a ray under one point per tick (round robin), a clamp for all of them.
	var space := get_world_3d().direct_space_state
	_ray_i = (_ray_i + 1) % _p.size()
	var q := PhysicsRayQueryParameters3D.create(_p[_ray_i] + Vector3.UP * 0.4, _p[_ray_i] + Vector3.DOWN * 1.5, UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC, exclude)
	var hit := space.intersect_ray(q)
	_floor[_ray_i] = (hit.position as Vector3).y if not hit.is_empty() else -INF
	var moved := 0.0
	for i in range(1, free_end):
		var fy := _floor[i] + RADIUS
		if _p[i].y < fy:
			_p[i].y = fy
			_q[i] = _q[i].lerp(_p[i], 0.5)          # (friction on the ground)
		moved = maxf(moved, _p[i].distance_squared_to(_q[i]))
	_dirty = true
	# Lying still for half a second: sleep (it costs nothing until the body moves).
	var calm := 0.0008 if _age < 2.0 else 0.002
	_still = _still + 1 if moved < calm * calm else 0
	if _still > 20:
		_asleep = true
		_sleep_at = _p[0]
		_sleep_b = ab_pos


func _process(_delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_draw_tube()
	cost_us += Time.get_ticks_usec() - t0


func _draw_tube() -> void:
	if _p.size() < 2 or not _dirty:
		return
	_dirty = false
	# The chain smoothed into a curve, then a tube round it (built as arrays: per-vertex
	# ImmediateMesh calls cost ~0.7 ms a gut every frame).
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
	var m := pts.size()
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	verts.resize(m * (SIDES + 1))
	norms.resize(m * (SIDES + 1))
	uvs.resize(m * (SIDES + 1))
	var normal := Vector3.UP
	var w := 0
	for i in m:
		var tan := (pts[mini(i + 1, m - 1)] - pts[maxi(i - 1, 0)]).normalized()
		if tan.length() < 0.5:
			tan = Vector3.DOWN
		# (Parallel transport: the ring doesn't twist along the tube.)
		normal = (normal - tan * normal.dot(tan))
		if normal.length() < 1e-3:
			normal = tan.cross(Vector3.RIGHT if absf(tan.x) < 0.9 else Vector3.FORWARD)
		normal = normal.normalized()
		var bin := tan.cross(normal)
		# Sections: swollen and pinched along the length; the ends taper into the wound.
		var u := float(i) / (m - 1)
		var r := RADIUS * (1.0 + 0.22 * sin(i * 1.3 + _bump)) * clampf(minf(u, 1.0 - u) * 12.0 + 0.55, 0.55, 1.0)
		for s2 in SIDES + 1:
			var a := TAU * s2 / SIDES
			var dn := normal * cos(a) + bin * sin(a)
			verts[w] = pts[i] + dn * r
			norms[w] = dn
			uvs[w] = Vector2(float(s2) / SIDES, u * 6.0)
			w += 1
	var idx := PackedInt32Array()
	idx.resize((m - 1) * SIDES * 6)
	var k2 := 0
	var row := SIDES + 1
	for i in m - 1:
		for s2 in SIDES:
			var a0 := i * row + s2
			var b0 := a0 + row
			idx[k2] = a0
			idx[k2 + 1] = b0
			idx[k2 + 2] = b0 + 1
			idx[k2 + 3] = a0
			idx[k2 + 4] = b0 + 1
			idx[k2 + 5] = a0 + 1
			k2 += 6
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	_mesh.clear_surfaces()
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
