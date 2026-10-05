@tool
class_name UltraRope
extends Node3D
## A hanging rope. Origin = anchor point. Gameplay treats it as a pendulum in the motor
## (deterministic, predicted); this node draws a cosmetic verlet rope that follows whoever
## holds it and sways when nobody does.
##   SWING: forward/back pumps the swing, jump lets go carrying the swing's speed
##   CLIMB: forward/back climbs up/down

enum Kind { SWING, CLIMB }

static var all: Array[UltraRope] = []
static var _next_id := 1

@export var kind := Kind.SWING
@export_range(1, 30, 0.1) var length := 6.0
@export_range(0.01, 0.1, 0.005) var thickness := 0.03
@export var segments := 16

var rope_id := 0
var _pts: PackedVector3Array = []
var _prev: PackedVector3Array = []
var _mm: MultiMeshInstance3D


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	rope_id = _next_id
	_next_id += 1
	all.append(self)
	_pts.resize(segments + 1)
	_prev.resize(segments + 1)
	for k in segments + 1:
		_pts[k] = global_position + Vector3.DOWN * length * k / segments
		_prev[k] = _pts[k]
	_mm = MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var cyl := CylinderMesh.new()
	cyl.top_radius = thickness
	cyl.bottom_radius = thickness
	cyl.height = 1.0
	cyl.radial_segments = 6
	cyl.rings = 1
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.72, 0.6, 0.4)
	cyl.material = m
	mm.mesh = cyl
	mm.instance_count = segments
	_mm.multimesh = mm
	_mm.top_level = true
	add_child(_mm)


func _exit_tree() -> void:
	all.erase(self)


func anchor() -> Vector3:
	return global_position


static func find(id: int) -> UltraRope:
	for r in all:
		if r.rope_id == id:
			return r
	return null


## Climbing input on this rope, -1 (down) .. 1 (up). Climb ropes: forward / back. Swing
## ropes: forward while looking up climbs, forward while looking down slides down (looking
## level, forward / back pumps the swing).
static func climb_input(rope: UltraRope, i: InputFrame) -> float:
	if rope == null:
		return 0.0
	if rope.kind == Kind.CLIMB:
		return clampf(i.move.y, -1.0, 1.0)
	if i.move.y > 0.3 and absf(i.pitch) > deg_to_rad(28.0):
		return signf(i.pitch) * i.move.y
	return 0.0


## A rope the character's hands can catch (hands ~2 m above the feet).
static func find_catch(feet: Vector3) -> UltraRope:
	var hands := feet + Vector3.UP * 2.0
	for r in all:
		var a := r.anchor()
		if hands.y > a.y - 0.3 or hands.y < a.y - r.length:
			continue
		if Vector2(hands.x - a.x, hands.z - a.z).length() < 0.55:
			return r
	return null


## Cosmetic verlet, pinned at the anchor and (if held) at the holder's hands.
func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or _pts.is_empty():
		return
	var holder_hands := Vector3.INF
	var grip := -1.0
	for n in get_tree().get_nodes_in_group(&"ultra_character"):
		var c := n as UltraCharacter
		if c and c.state.state == MotorState.Id.ROPE and c.state.trav_id == rope_id:
			holder_hands = UltraTraversalVisual.rope_grip(c)
			grip = c.state.trav_s
	var g := Vector3.DOWN * 9.8 * delta * delta
	for k in range(1, _pts.size()):
		var cur := _pts[k]
		_pts[k] = cur + (cur - _prev[k]) * 0.985 + g
		_prev[k] = cur
	var seg := length / segments
	for _it in 8:
		_pts[0] = anchor()
		for k in range(_pts.size() - 1):
			var a := _pts[k]
			var b := _pts[k + 1]
			var d := b - a
			var l := d.length()
			if l < 0.0001:
				continue
			var corr := d * (1.0 - seg / l) * 0.5
			if k > 0:
				_pts[k] = a + corr
				_pts[k + 1] = b - corr
			else:
				_pts[k + 1] = b - corr * 2.0
		if grip >= 0.0:
			var gi := clampi(int(round(grip / seg)), 1, segments)
			_pts[gi] = holder_hands
	var mm := _mm.multimesh
	for k in segments:
		var a := _pts[k]
		var b := _pts[k + 1]
		var mid := (a + b) * 0.5
		var dir := (b - a)
		var l := maxf(dir.length(), 0.001)
		var y := dir / l
		var x := y.cross(Vector3.FORWARD if absf(y.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT).normalized()
		var z := x.cross(y)
		mm.set_instance_transform(k, Transform3D(Basis(x, y * l, z), mid))
