@tool
class_name UltraShootingTarget
extends Node3D
## A pop-up target: falls back when shot, counts hits, stands up again after `reset_time`.
## Optional sideways swing. Server decides hits; the down/up state replicates.

signal hit(points: int)

@export var reset_time := 2.5
@export var swing := 0.0                 ## metres of side-to-side travel (0 = static)
@export var swing_period := 3.0
@export var label := ""

var down := false
var hits := 0
var _t := 0.0
var _vis := 0.0
var _pivot: Node3D
var _body: StaticBody3D
var _origin := Vector3.ZERO


func _ready() -> void:
	_pivot = Node3D.new()
	add_child(_pivot)
	_body = StaticBody3D.new()
	_body.collision_layer = UltraLayers.WORLD_STATIC
	_body.set_script(null)
	_pivot.add_child(_body)
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.3
	cyl.bottom_radius = 0.3
	cyl.height = 0.04
	mi.mesh = cyl
	mi.rotation_degrees.x = 90
	mi.position.y = 1.2
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.95, 0.95, 0.95)
	mi.material_override = m
	_body.add_child(mi)
	var bull := MeshInstance3D.new()
	var bc := CylinderMesh.new()
	bc.top_radius = 0.1
	bc.bottom_radius = 0.1
	bc.height = 0.045
	bull.mesh = bc
	bull.rotation_degrees.x = 90
	bull.position.y = 1.2
	var bm := StandardMaterial3D.new()
	bm.albedo_color = Color(0.85, 0.1, 0.1)
	bull.material_override = bm
	_body.add_child(bull)
	var post := MeshInstance3D.new()
	var pm := BoxMesh.new()
	pm.size = Vector3(0.05, 0.9, 0.05)
	post.mesh = pm
	post.position.y = 0.45
	_body.add_child(post)
	var cs := CollisionShape3D.new()
	var cshape := CylinderShape3D.new()
	cshape.radius = 0.3
	cshape.height = 0.05
	cs.shape = cshape
	cs.rotation_degrees.x = 90
	cs.position.y = 1.2
	_body.add_child(cs)
	_origin = position
	if label != "":
		var l := Label3D.new()
		l.text = label
		l.position.y = 1.7
		l.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
		l.font_size = 48
		l.pixel_size = 0.004
		add_child(l)
	if Engine.is_editor_hint():
		return
	# Damage on the collider forwards here.
	_body.set_meta("damage_target", self)
	var o := NetObject.new()
	o.name = "NetObject"
	add_child(o)


## Server (via UltraCombat.apply: the StaticBody's parent chain reaches us).
func take_damage(info: UltraCombat.DamageInfo) -> void:
	if down:
		return
	var local := _body.global_transform.affine_inverse() * info.point
	var bull := Vector2(local.x, local.y - 1.2).length() < 0.1
	hits += 1
	down = true
	_t = 0.0
	hit.emit(2 if bull else 1)
	UltraNet.world.broadcast(&"target_hit", [String(name), bull], true)
	(find_child("NetObject", false, false) as NetObject).mark_dirty()


func get_net_state() -> Dictionary:
	return {"down": down, "hits": hits}


func set_net_state(d: Dictionary) -> void:
	down = bool(d.get("down", down))
	hits = int(d.get("hits", hits))


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if down and UltraNet.is_server():
		_t += delta
		if _t >= reset_time:
			down = false
			(find_child("NetObject", false, false) as NetObject).mark_dirty()
	_vis = move_toward(_vis, 1.0 if down else 0.0, delta * 6.0)
	_pivot.rotation.x = -_vis * 1.45
	if swing > 0.0:
		var tick := UltraNet.server_tick if UltraNet.is_server() else int(UltraNet.server_tick_est)
		position = _origin + Vector3.RIGHT * sin(float(tick) / 60.0 * TAU / swing_period) * swing
