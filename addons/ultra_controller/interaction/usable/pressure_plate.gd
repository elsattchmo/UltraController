@tool
class_name UltraPressurePlate
extends Node3D
## Activates while at least `threshold_kg` rests on it: rigid bodies count their mass, and
## characters count their MovementProfile.mass (plus what they carry). Server-side; the active
## state replicates. Visual plate sinks a little when pressed.

signal activated
signal deactivated

@export var size := Vector2(2.0, 2.0)
@export var threshold_kg := 40.0
@export var label := ""

var active := false
var load_kg := 0.0
var _area: Area3D
var _plate: MeshInstance3D


func _ready() -> void:
	_area = get_node_or_null("Area") as Area3D
	if _area == null:
		_build()
	if Engine.is_editor_hint():
		return
	if find_child("NetObject", false, false) == null:
		var o := NetObject.new()
		o.name = "NetObject"
		add_child(o)


func _build() -> void:
	_plate = MeshInstance3D.new()
	_plate.name = "Plate"
	var bm := BoxMesh.new()
	bm.size = Vector3(size.x, 0.08, size.y)
	_plate.mesh = bm
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.75, 0.55, 0.2)
	_plate.material_override = m
	_plate.position.y = 0.04
	add_child(_plate)
	_area = Area3D.new()
	_area.name = "Area"
	_area.collision_layer = 0
	_area.collision_mask = UltraLayers.WORLD_DYNAMIC | UltraLayers.CHARACTER
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(size.x, 0.5, size.y)
	cs.shape = bs
	cs.position.y = 0.3
	_area.add_child(cs)
	add_child(_area)
	var l := Label3D.new()
	l.text = label if label != "" else "%d kg" % int(threshold_kg)
	l.position = Vector3(0, 0.12, size.y * 0.5 + 0.02)
	l.rotation_degrees.x = -60
	l.font_size = 48
	l.pixel_size = 0.004
	add_child(l)


func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint() or _area == null:
		return
	if _plate:
		_plate.position.y = 0.01 if active else 0.04
	if not UltraNet.is_server():
		return
	var kg := 0.0
	for b in _area.get_overlapping_bodies():
		if b is RigidBody3D:
			kg += (b as RigidBody3D).mass
		elif b is UltraCharacter:
			var c := b as UltraCharacter
			kg += c.profile.mass + c.state.held_mass
	load_kg = kg
	var now := kg >= threshold_kg
	if now != active:
		active = now
		(activated if active else deactivated).emit()
		var o := find_child("NetObject", false, false) as NetObject
		if o:
			o.mark_dirty()


func get_net_state() -> Dictionary:
	return {"active": active}


func set_net_state(d: Dictionary) -> void:
	var a := bool(d.get("active", active))
	if a != active:
		active = a
		(activated if active else deactivated).emit()
