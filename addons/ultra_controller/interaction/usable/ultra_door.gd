@tool
class_name UltraDoor
extends Node3D
## A hinged door. The panel (an AnimatableBody3D child named "Panel", built automatically if
## missing) swings away from whoever opens it. Can be locked; a key item with a matching
## key_id unlocks it. Server-authoritative; open/locked/swing replicate as discrete state.

signal opened
signal closed
signal unlocked

@export var size := Vector3(1.1, 2.15, 0.08)
@export_range(30, 175) var open_angle_deg := 100.0
@export_range(0.1, 5.0) var open_time := 0.7
@export var locked := false
@export var key_id: StringName
@export var consume_key := false
## Seconds before closing by itself (0 = stays open).
@export var auto_close := 0.0
@export var prompt_open := "Open door"
@export var prompt_close := "Close door"
@export var locked_text := "Locked"
@export var material: Material

var is_open := false
var swing := 1.0                       ## +1 / -1: which way it opens
var _angle := 0.0
var _open_t := 0.0
var _panel: AnimatableBody3D


func _ready() -> void:
	_panel = get_node_or_null("Panel") as AnimatableBody3D
	if _panel == null:
		_build()
	if Engine.is_editor_hint():
		return
	if find_child("NetObject", false, false) == null:
		var o := NetObject.new()
		o.name = "NetObject"
		add_child(o)
	if find_child("Interactable", false, false) == null:
		var it := Interactable.new()
		it.name = "Interactable"
		it.max_distance = 2.2
		add_child(it)


func _build() -> void:
	_panel = AnimatableBody3D.new()
	_panel.name = "Panel"
	_panel.sync_to_physics = false
	_panel.collision_layer = UltraLayers.WORLD_STATIC | UltraLayers.INTERACTABLE
	_panel.collision_mask = 0
	add_child(_panel)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = Vector3(size.x * 0.5, size.y * 0.5, 0)
	if material:
		mi.material_override = material
	_panel.add_child(mi)
	var knob := MeshInstance3D.new()
	var km := SphereMesh.new()
	km.radius = 0.04
	km.height = 0.08
	knob.mesh = km
	knob.position = Vector3(size.x - 0.12, 1.0, size.z * 0.5 + 0.03)
	_panel.add_child(knob)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	cs.position = mi.position
	_panel.add_child(cs)


func interaction_prompt(c: UltraCharacter) -> String:
	if locked:
		var k := c.inventory.find_key(key_id) if c and c.inventory else -1
		return "Unlock with %s" % c.inventory.get_slot(k).def().display_name if k >= 0 else locked_text
	return prompt_close if is_open else prompt_open


## Server.
func interact(c: UltraCharacter) -> void:
	if locked:
		var k := c.inventory.find_key(key_id)
		if k < 0:
			UltraNet.world.broadcast(&"locked", [c.net_id, locked_text], true)
			return
		locked = false
		if consume_key:
			c.inventory.remove_slot(k, 1)
			c.inventory_changed_by_server()
		unlocked.emit()
		UltraNet.world.broadcast(&"unlocked", [c.net_id, String(key_id)], true)
	set_open(not is_open, c.global_position)


## Server (or logic gates). `from` decides the swing direction (away from it).
func set_open(v: bool, from := Vector3.INF) -> void:
	if v and from != Vector3.INF:
		var local := global_transform.affine_inverse() * from
		swing = -1.0 if local.z > 0.0 else 1.0
	is_open = v
	_open_t = 0.0
	(opened if v else closed).emit()
	_mark()


func set_locked(v: bool) -> void:
	locked = v
	_mark()


func _mark() -> void:
	var o := find_child("NetObject", false, false) as NetObject
	if o:
		o.mark_dirty()


func get_net_state() -> Dictionary:
	return {"open": is_open, "locked": locked, "swing": swing}


func set_net_state(d: Dictionary) -> void:
	locked = bool(d.get("locked", locked))
	swing = float(d.get("swing", swing))
	var o := bool(d.get("open", is_open))
	if o != is_open:
		is_open = o
		(opened if o else closed).emit()


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or _panel == null:
		return
	if is_open and auto_close > 0.0 and UltraNet.is_server():
		_open_t += delta
		if _open_t >= auto_close:
			set_open(false)
	var target := deg_to_rad(open_angle_deg) * swing if is_open else 0.0
	_angle = move_toward(_angle, target, delta * deg_to_rad(open_angle_deg) / open_time)
	_panel.transform = Transform3D(Basis(Vector3.UP, _angle), Vector3.ZERO)
