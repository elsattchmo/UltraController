@tool
class_name UltraLadder
extends Node3D
## A ladder (or a pipe to shin up). Origin = bottom centre, +Y = up the ladder, -Z = the side
## you climb from (it faces you along its local +Z). Pure data for the motor (deterministic,
## no Area signals); builds simple visuals if it has no children.

enum Kind { LADDER, PIPE }

static var all: Array[UltraLadder] = []
static var _next_id := 1

@export var kind := Kind.LADDER
@export_range(0.5, 30, 0.1) var height := 4.0
@export_range(0.2, 1.5, 0.05) var width := 0.6
@export var climb_speed := 1.25

var ladder_id := 0


func _ready() -> void:
	if get_child_count() == 0:
		_build()
	if Engine.is_editor_hint():
		return
	ladder_id = _next_id
	_next_id += 1
	all.append(self)


func _exit_tree() -> void:
	all.erase(self)


func normal() -> Vector3:
	var z := global_basis.z
	return Vector3(z.x, 0, z.z).normalized()


func height_of(p: Vector3) -> float:
	return (p - global_position).dot(Vector3.UP)


## Standing position on the ladder at height `h` (capsule centre-bottom).
func stand_point(h: float) -> Vector3:
	return global_position + Vector3.UP * h + normal() * (0.36 if kind == Kind.LADDER else 0.3)


static func find(id: int) -> UltraLadder:
	for l in all:
		if l.ladder_id == id:
			return l
	return null


## A ladder in front of `pos`, within reach, that the player is moving into.
static func find_enterable(pos: Vector3, dir: Vector3, push: float) -> UltraLadder:
	for l in all:
		var rel := pos - l.global_position
		var h := rel.y
		if h < -0.3 or h > l.height - 0.5:
			continue
		var n := l.normal()
		var out := Vector3(rel.x, 0, rel.z).dot(n)
		var side := absf(Vector3(rel.x, 0, rel.z).dot(n.cross(Vector3.UP)))
		if out < 0.1 or out > 0.85 or side > l.width * 0.5 + 0.25:
			continue
		if dir.dot(-n) > 0.6 and push > 0.3:
			return l
	return null


func _build() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.4, 0.25) if kind == Kind.LADDER else Color(0.45, 0.47, 0.5)
	mat.metallic = 0.0 if kind == Kind.LADDER else 0.8
	if kind == Kind.PIPE:
		var p := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.07
		cm.bottom_radius = 0.07
		cm.height = height
		p.mesh = cm
		p.position = Vector3(0, height * 0.5, 0)
		p.material_override = mat
		add_child(p)
		return
	for side in [-1, 1]:
		var rail := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.06, height, 0.06)
		rail.mesh = bm
		rail.position = Vector3(side * width * 0.5, height * 0.5, 0)
		rail.material_override = mat
		add_child(rail)
	var n := int(height / 0.3)
	for i in n:
		var rung := MeshInstance3D.new()
		var cm2 := CylinderMesh.new()
		cm2.top_radius = 0.02
		cm2.bottom_radius = 0.02
		cm2.height = width
		rung.mesh = cm2
		rung.rotation_degrees.z = 90
		rung.position = Vector3(0, 0.25 + i * 0.3, 0)
		rung.material_override = mat
		add_child(rung)
