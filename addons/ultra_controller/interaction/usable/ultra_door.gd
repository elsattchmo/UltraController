@tool
class_name UltraDoor
extends Node3D
## A hinged door. The panel (an AnimatableBody3D child named "Panel", built automatically if
## missing) swings away from whoever opens it. Can be locked; a key item with a matching
## key_id unlocks it. Server-authoritative; open/locked/swing replicate as discrete state.

signal opened
signal closed
signal unlocked
## Battered by something (a zombie's blow): `hp` left. And broken for good.
signal bashed(hp_left: float)
signal broke
## Anything about it changed (open, locked, hp, broken...): AI navigation reprices the way through it.
signal state_changed

## Every door in the tree (AI: where the doors are, which are shut).
static var all: Array[UltraDoor] = []

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
@export var door_name: StringName
## Health against being bashed (zombies' blows, something thrown at it); 0 breaks it open for good.
@export var hp := 100.0
## Boarded up: it can't be opened (or unlocked), only broken.
@export var barricaded := false

var is_open := false
var broken := false
var swing := 1.0                       ## +1 / -1: which way it opens
## A double door's other leaf: they open and close together.
var partner: UltraDoor
var _angle := 0.0
var _wobble := 0.0                     ## 0..1: shaking from a blow
var _max_hp := 100.0
var _open_t := 0.0
var _panel: AnimatableBody3D


func _enter_tree() -> void:
	if not Engine.is_editor_hint():
		all.append(self)


func _exit_tree() -> void:
	all.erase(self)


## Shut and in the way: locked or barricaded (an AI has to break it).
func is_blocked() -> bool:
	return not broken and (locked or barricaded)


func _ready() -> void:
	_max_hp = hp
	_panel = get_node_or_null("Panel") as AnimatableBody3D
	if _panel == null:
		_build()
	if is_open:
		_angle = deg_to_rad(open_angle_deg) * swing           # (placed open: no swing at load)
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
	if broken:
		return ""
	if barricaded:
		return "Barricaded"
	if locked:
		var k := c.inventory.find_key(key_id) if c and c.inventory else -1
		return "Unlock with %s" % c.inventory.get_slot(k).def().display_name if k >= 0 else locked_text
	return prompt_close if is_open else prompt_open


## Server.
func interact(c: UltraCharacter) -> void:
	if broken:
		return
	if barricaded:
		UltraNet.world.broadcast(&"locked", [c.net_id, "Barricaded"], true)
		return
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
	UltraNoise.emit(global_position + Vector3.UP, 4.0, &"door", c.net_id)


## Server (or logic gates). `from` decides the swing direction (away from it).
func set_open(v: bool, from := Vector3.INF, _from_partner := false) -> void:
	if broken:
		return
	if v and from != Vector3.INF:
		var local := global_transform.affine_inverse() * from
		swing = 1.0 if local.z > 0.0 else -1.0       # (+angle turns the leaf's +X toward -Z: from the +Z side it swings away)
	is_open = v
	_open_t = 0.0
	(opened if v else closed).emit()
	_mark()
	if partner and not _from_partner and not partner.broken and partner.is_open != v:
		partner.set_open(v, from, true)


## Server, for the AI: open it if it can be (not locked / barricaded). True if it is open now.
func ai_open(from: Vector3) -> bool:
	if broken or is_open:
		return true
	if is_blocked():
		return false
	set_open(true, from)
	return true


## Server: a blow (a zombie's swing, a thrown prop). It shakes; at 0 it breaks open for good.
func bash(amount: float, from := Vector3.INF) -> void:
	if broken:
		return
	hp = maxf(hp - amount, 0.0)
	_wobble = 1.0
	_mark()
	bashed.emit(hp)
	UltraNoise.emit(global_position + Vector3.UP, 18.0, &"bash", 0)
	if hp <= 0.0:
		break_open(from)


## Server: splintered - it stays open, unlocked, nothing left to close.
func break_open(from := Vector3.INF) -> void:
	if broken:
		return
	hp = 0.0
	locked = false
	barricaded = false
	is_open = true
	_set_broken(from)
	UltraNoise.emit(global_position + Vector3.UP, 25.0, &"crash", 0)
	_mark()
	if partner and not partner.broken:
		partner.break_open(from)


## Server: back to a starting state (a scenario reset): intact, with `new_hp`, shut or open, locked / barricaded as given.
func reset(open: bool, p_locked: bool, p_barricaded: bool, new_hp: float) -> void:
	broken = false
	hp = new_hp
	locked = p_locked
	barricaded = p_barricaded
	is_open = open
	_angle = deg_to_rad(open_angle_deg) * swing if open else 0.0
	_wobble = 0.0
	if _panel:
		_panel.collision_layer = UltraLayers.WORLD_STATIC | UltraLayers.INTERACTABLE
		_panel.visible = true
		_panel.transform = Transform3D(Basis(Vector3.UP, _angle), Vector3.ZERO)
	_mark()


func _set_broken(from := Vector3.INF) -> void:
	if broken:
		return
	broken = true
	broke.emit()
	if _panel:
		_panel.collision_layer = 0
		_panel.visible = false
	_debris(from)


## Planks flying off a broken door (presentation: every machine makes its own).
func _debris(from: Vector3) -> void:
	if Engine.is_editor_hint() or not is_inside_tree():
		return
	var root := get_tree().current_scene if get_tree().current_scene else get_parent()
	var away := Vector3.ZERO
	if from != Vector3.INF:
		away = (global_position - from)
		away.y = 0.0
		away = away.normalized()
	var hinge := global_transform
	for k in 7:
		var body := RigidBody3D.new()
		body.collision_layer = 0
		body.collision_mask = UltraLayers.WORLD_STATIC
		body.mass = 1.0
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(randf_range(0.12, 0.3), randf_range(0.25, 0.6), 0.035)
		mi.mesh = bm
		if material:
			mi.material_override = material
		body.add_child(mi)
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = bm.size
		cs.shape = bs
		body.add_child(cs)
		root.add_child(body)
		body.global_position = hinge * Vector3(randf_range(0.1, size.x - 0.1), randf_range(0.2, size.y - 0.2), 0.0)
		body.linear_velocity = away * randf_range(1.0, 3.5) + Vector3(randf_range(-1, 1), randf_range(0.5, 2.5), randf_range(-1, 1))
		body.angular_velocity = Vector3(randf_range(-6, 6), randf_range(-6, 6), randf_range(-6, 6))
		get_tree().create_timer(8.0).timeout.connect(body.queue_free)


func set_locked(v: bool) -> void:
	locked = v
	_mark()


func _mark() -> void:
	var o := find_child("NetObject", false, false) as NetObject
	if o:
		o.mark_dirty()
	state_changed.emit()


func get_net_state() -> Dictionary:
	return {"open": is_open, "locked": locked, "swing": swing, "broken": broken, "hp": hp, "barricaded": barricaded}


func set_net_state(d: Dictionary) -> void:
	locked = bool(d.get("locked", locked))
	barricaded = bool(d.get("barricaded", barricaded))
	swing = float(d.get("swing", swing))
	var new_hp := float(d.get("hp", hp))
	if new_hp < hp - 0.01:
		_wobble = 1.0
	hp = new_hp
	if bool(d.get("broken", broken)) and not broken:
		is_open = true
		_set_broken()
		return
	var o := bool(d.get("open", is_open))
	if o != is_open:
		is_open = o
		(opened if o else closed).emit()
	state_changed.emit()


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or _panel == null:
		return
	if is_open and auto_close > 0.0 and UltraNet.is_server():
		_open_t += delta
		if _open_t >= auto_close:
			set_open(false)
	if broken:
		return
	var target := deg_to_rad(open_angle_deg) * swing if is_open else 0.0
	_angle = move_toward(_angle, target, delta * deg_to_rad(open_angle_deg) / open_time)
	# A blow shakes a shut door in its frame (a few degrees, dying away).
	var shake := 0.0
	if _wobble > 0.0:
		_wobble = maxf(_wobble - delta * 3.0, 0.0)
		shake = sin(_wobble * 38.0) * _wobble * 0.045
	_panel.transform = Transform3D(Basis(Vector3.UP, _angle + shake), Vector3.ZERO)
