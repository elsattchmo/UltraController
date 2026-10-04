@tool
class_name UltraSwitch
extends Node3D
## Levers (toggle), buttons (momentary) and drawers (slide open/closed) in one class.
## A visual "Handle" moves to show the state; `changed(on)` drives puzzles (UltraLogicGate).

signal changed(on: bool)

enum Kind { LEVER, BUTTON, DRAWER }

@export var kind := Kind.LEVER
@export var on := false
## BUTTON: seconds it stays pressed.
@export var hold_time := 0.6
@export var prompt := ""
@export var label := ""
@export var material: Material

var _t := 0.0
var _vis := 0.0
var _handle: Node3D


func _ready() -> void:
	_handle = get_node_or_null("Handle") as Node3D
	if _handle == null:
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
		it.max_distance = 2.0
		add_child(it)


func _build() -> void:
	var base := StaticBody3D.new()
	base.collision_layer = UltraLayers.WORLD_STATIC | UltraLayers.INTERACTABLE
	add_child(base)
	var bm := BoxMesh.new()
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	match kind:
		Kind.LEVER:
			bm.size = Vector3(0.25, 0.35, 0.12)
		Kind.BUTTON:
			bm.size = Vector3(0.22, 0.22, 0.08)
		Kind.DRAWER:
			bm.size = Vector3(0.7, 0.5, 0.55)
	var mi := MeshInstance3D.new()
	mi.mesh = bm
	if material:
		mi.material_override = material
	base.add_child(mi)
	bs.size = bm.size
	cs.shape = bs
	base.add_child(cs)
	_handle = Node3D.new()
	_handle.name = "Handle"
	add_child(_handle)
	var hm := MeshInstance3D.new()
	match kind:
		Kind.LEVER:
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.025
			cyl.bottom_radius = 0.025
			cyl.height = 0.4
			hm.mesh = cyl
			hm.position = Vector3(0, 0.2, 0)
			_handle.position = Vector3(0, 0, 0.08)
		Kind.BUTTON:
			var sph := CylinderMesh.new()
			sph.top_radius = 0.07
			sph.bottom_radius = 0.07
			sph.height = 0.05
			hm.mesh = sph
			hm.rotation_degrees.x = 90
			_handle.position = Vector3(0, 0, 0.06)
		Kind.DRAWER:
			var b := BoxMesh.new()
			b.size = Vector3(0.6, 0.35, 0.5)
			hm.mesh = b
			_handle.position = Vector3(0, 0, 0.04)
	var hmat := StandardMaterial3D.new()
	hmat.albedo_color = Color(0.85, 0.2, 0.15) if kind != Kind.DRAWER else Color(0.5, 0.4, 0.3)
	hm.material_override = hmat
	_handle.add_child(hm)
	if label != "":
		var l := Label3D.new()
		l.text = label
		l.position = Vector3(0, 0.45, 0.1)
		l.font_size = 48
		l.pixel_size = 0.004
		l.outline_size = 8
		add_child(l)


func interaction_prompt(_c: UltraCharacter) -> String:
	if prompt != "":
		return prompt
	match kind:
		Kind.LEVER: return "Pull lever"
		Kind.BUTTON: return "Press"
	return "Close drawer" if on else "Open drawer"


## Server.
func interact(_c: UltraCharacter) -> void:
	if kind == Kind.BUTTON:
		_t = 0.0
		set_on(true)
	else:
		set_on(not on)


func set_on(v: bool) -> void:
	if v == on and kind != Kind.BUTTON:
		return
	on = v
	changed.emit(on)
	var o := find_child("NetObject", false, false) as NetObject
	if o:
		o.mark_dirty()


func get_net_state() -> Dictionary:
	return {"on": on}


func set_net_state(d: Dictionary) -> void:
	var v := bool(d.get("on", on))
	if v != on:
		on = v
		changed.emit(on)


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if kind == Kind.BUTTON and on and UltraNet.is_server():
		_t += delta
		if _t >= hold_time:
			set_on(false)
	_vis = move_toward(_vis, 1.0 if on else 0.0, delta * 5.0)
	if _handle:
		match kind:
			Kind.LEVER:
				_handle.rotation.x = lerpf(-0.7, 0.7, _vis)
			Kind.BUTTON:
				_handle.position.z = lerpf(0.06, 0.02, _vis)
			Kind.DRAWER:
				_handle.position.z = lerpf(0.04, 0.45, _vis)
