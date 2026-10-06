class_name UltraGuts
extends Node3D
## A loop of gut hanging out of a torso wound (presentation): a verlet chain whose first point
## rides the wound on the body (a BoneAttachment3D parent), the rest swinging and settling under
## gravity, kept off the floor with a ray per point every few frames. Drawn as capsules between
## the points. Lives until the character respawns (UltraBodyFX clears it).

const SEGMENTS := 9
const SEG_LEN := 0.07
const RADIUS := 0.022

var anchor: Node3D                  ## follows the wound
var _p := PackedVector3Array()
var _q := PackedVector3Array()      ## previous positions
var _parts: Array[MeshInstance3D] = []
var _floor := PackedFloat32Array()
var _ray_i := 0
var exclude: Array[RID] = []


static var _mat: StandardMaterial3D
static var _mesh: CapsuleMesh


static func gut_mat() -> StandardMaterial3D:
	if _mat == null:
		_mat = StandardMaterial3D.new()
		_mat.albedo_color = Color(0.62, 0.24, 0.24)
		_mat.roughness = 0.18
		_mat.metallic_specular = 0.7
	return _mat


func _ready() -> void:
	top_level = true
	if _mesh == null:
		_mesh = CapsuleMesh.new()
		_mesh.radius = RADIUS
		_mesh.height = SEG_LEN + RADIUS * 2.0
		_mesh.radial_segments = 8
		_mesh.rings = 2
	var at := anchor.global_position if anchor else global_position
	for i in SEGMENTS + 1:
		var p := at + Vector3(randf_range(-0.01, 0.01), -SEG_LEN * i * 0.6, randf_range(-0.01, 0.01))
		_p.append(p)
		_q.append(p)
		_floor.append(-INF)
	for i in SEGMENTS:
		var mi := MeshInstance3D.new()
		mi.mesh = _mesh
		mi.material_override = gut_mat()
		add_child(mi)
		_parts.append(mi)


## Thrown out of the wound along `v` (m/s) to start with.
func kick(v: Vector3, dt := 1.0 / 60.0) -> void:
	for i in range(1, _p.size()):
		_q[i] = _p[i] - v * dt * (0.6 + 0.4 * float(i) / SEGMENTS)


func _physics_process(delta: float) -> void:
	if anchor == null or not is_instance_valid(anchor):
		queue_free()
		return
	_p[0] = anchor.global_position
	_q[0] = _p[0]
	var g := Vector3.DOWN * 9.8 * delta * delta
	for i in range(1, _p.size()):
		var cur := _p[i]
		var v := (cur - _q[i]) * 0.97
		_q[i] = cur
		_p[i] = cur + v + g
	for it in 4:
		for i in range(_p.size() - 1):
			var a := _p[i]
			var b := _p[i + 1]
			var d := b - a
			var l := d.length()
			if l < 1e-5:
				continue
			var corr := d * ((l - SEG_LEN) / l)
			if i == 0:
				_p[i + 1] = b - corr
			else:
				_p[i] = a + corr * 0.5
				_p[i + 1] = b - corr * 0.5
	# The floor: a ray under one point per frame (round robin), a clamp for all of them.
	var space := get_world_3d().direct_space_state
	_ray_i = (_ray_i + 1) % _p.size()
	var q := PhysicsRayQueryParameters3D.create(_p[_ray_i] + Vector3.UP * 0.4, _p[_ray_i] + Vector3.DOWN * 1.5, UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC, exclude)
	var hit := space.intersect_ray(q)
	_floor[_ray_i] = (hit.position as Vector3).y if not hit.is_empty() else -INF
	for i in range(1, _p.size()):
		var fy := _floor[i] + RADIUS
		if _p[i].y < fy:
			_p[i].y = fy
			_q[i] = _q[i].lerp(_p[i], 0.5)          # (friction on the ground)


func _process(_delta: float) -> void:
	for i in _parts.size():
		var a := _p[i]
		var b := _p[i + 1]
		var mid := (a + b) * 0.5
		var d := b - a
		var up := d.normalized() if d.length() > 1e-5 else Vector3.UP
		var side := up.cross(Vector3.FORWARD if absf(up.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT).normalized()
		_parts[i].global_transform = Transform3D(Basis(side, up, side.cross(up)), mid)
