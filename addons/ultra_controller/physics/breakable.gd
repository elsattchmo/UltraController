class_name UltraBreakable
extends Node
## Something that smashes: a crate, a barrel, a bottle, a pane of glass. A child (named
## "Breakable") of the body it breaks - a RigidBody3D prop or a StaticBody3D pane. It takes
## damage from shots and blows (UltraCombat.apply forwards them) and from hard knocks: a prop
## that hits something (dropped from a height, struck by a thrown crate) feels the change in
## its own momentum; a pane feels whatever comes through it fast. The server decides it breaks
## and replicates `broken` (the body's NetObject carries it); everyone then hides the body and
## throws local debris made from its own mesh, and the server spills any `drops`.

enum Kind { WOOD, GLASS, CERAMIC }

@export var kind := Kind.WOOD
@export var health := 30.0
## A knock harder than this (kg*m/s) hurts it; each kg*m/s over takes `impact_scale` health.
@export var impact_min := 20.0
@export var impact_scale := 0.7
## Fragile things (glass) care about the jolt, not the momentum: a change in velocity over this
## (m/s) in one tick breaks it outright (0 = off). A bottle knocked or falling off a table.
@export var impact_dv := 0.0
## Debris pieces it breaks into.
@export var pieces := 8
## What spills out: [item_id, count, item_id, count, ...].
@export var drops: Array = []

var broken := false
var _hp := 0.0
var _prev_vel := Vector3.ZERO
var _armed := 0.0                    ## s before it can be knocked (level start settles props)

static var _debris: Array[Node3D] = []
const MAX_DEBRIS := 140
const DEBRIS_LIFE := 9.0


func _ready() -> void:
	name = "Breakable"
	_hp = health
	_armed = 1.0
	var body := get_parent()
	if body is RigidBody3D:
		_prev_vel = (body as RigidBody3D).linear_velocity
	elif body is StaticBody3D and kind == Kind.GLASS:
		_add_sensor.call_deferred(body as StaticBody3D)


## The breakable on `o` (the body itself or one of its ancestors), if any.
static func find_on(o: Object) -> UltraBreakable:
	var n := o as Node
	for k in 3:
		if n == null:
			return null
		var br := n.get_node_or_null("Breakable") as UltraBreakable
		if br:
			return br
		n = n.get_parent()
	return null


func _authority() -> bool:
	return UltraNet.mode != UltraNet.Mode.CLIENT


# ---------------------------------------------------------------- damage

## Shots, blows (UltraCombat.apply).
func take_damage(info: UltraCombat.DamageInfo) -> void:
	if broken or not _authority():
		return
	var k := 1.0
	match kind:
		Kind.GLASS:
			k = 4.0
		Kind.CERAMIC:
			k = 3.0
	if info.kind == &"blunt" or info.kind == &"impact":
		k *= 1.4                      # a club smashes better than a bullet holes
	hurt(info.amount * k, info.point, info.dir)


func hurt(amount: float, point: Vector3, dir: Vector3) -> void:
	if broken or not _authority():
		return
	_hp -= amount
	if _hp <= 0.0:
		break_apart(point, dir)


## Hard knocks on a prop: the change in its own momentum this tick, beyond what gravity did.
func _physics_process(delta: float) -> void:
	_armed = maxf(_armed - delta, 0.0)
	var rb := get_parent() as RigidBody3D
	if rb == null or broken:
		return
	var v := rb.linear_velocity
	var dv := v - _prev_vel - rb.get_gravity() * delta * rb.gravity_scale
	_prev_vel = v
	if not _authority() or _armed > 0.0 or rb.freeze:
		return
	# (Being held, or just thrown: the hold spring / the throw set its velocity on purpose.)
	if rb.has_meta("held_for") or float(rb.get_meta("thrown_left", 0.0)) > UltraGrab.THROWN_TIME - 0.12:
		return
	var mom := dv.length() * rb.mass
	if mom > impact_min:
		hurt((mom - impact_min) * impact_scale, rb.global_position, -dv.normalized())


## A pane: whatever comes through it fast (a thrown prop, a running body) breaks it.
func _add_sensor(pane: StaticBody3D) -> void:
	var cs := pane.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if cs == null:
		for ch in pane.get_children():
			if ch is CollisionShape3D:
				cs = ch
	if cs == null or not (cs.shape is BoxShape3D):
		return
	var area := Area3D.new()
	area.name = "BreakSensor"
	area.collision_layer = 0
	area.collision_mask = UltraLayers.WORLD_DYNAMIC | UltraLayers.CHARACTER
	var acs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	# Deep enough on the thin axis that a body stopped by the pane is inside it.
	var size := (cs.shape as BoxShape3D).size
	var thin := 0 if size.x <= minf(size.y, size.z) else (1 if size.y <= size.z else 2)
	var grow := Vector3(0.12, 0.12, 0.12)
	grow[thin] = 1.0
	bs.size = size + grow
	acs.shape = bs
	acs.transform = cs.transform
	area.add_child(acs)
	pane.add_child(area)
	area.body_entered.connect(func(b: Node3D) -> void:
		if broken or not _authority() or _armed > 0.0:
			return
		var v := Vector3.ZERO
		var m := 0.0
		if b is RigidBody3D:
			v = (b as RigidBody3D).linear_velocity
			m = (b as RigidBody3D).mass
		elif b is UltraCharacter:
			v = (b as UltraCharacter).state.vel
			m = (b as UltraCharacter).profile.mass
		if v.length() > 2.5 and v.length() * m > 6.0:
			break_apart(b.global_position, v.normalized()))


# ---------------------------------------------------------------- breaking

## Server: it breaks. Everyone else hears through the NetObject (`broken` in its state).
func break_apart(point: Vector3, dir: Vector3) -> void:
	if broken:
		return
	broken = true
	var o := get_parent().get_node_or_null("NetObject") as NetObject
	if o:
		o.mark_dirty()
	_spill()
	_shatter(point, dir)


## From the NetObject (a joining client, or the server's update).
func apply_broken(b: bool) -> void:
	if b and not broken:
		broken = true
		var body := get_parent() as Node3D
		_shatter(body.global_position if body else Vector3.ZERO, Vector3.ZERO)


func _spill() -> void:
	var body := get_parent() as Node3D
	if body == null or drops.is_empty():
		return
	for k in range(0, drops.size() - 1, 2):
		var id := StringName(drops[k])
		var def := ItemDB.get_def(id)
		if def == null or def.world_scene == null:
			continue
		var at := Transform3D(Basis(), body.global_position + Vector3(randf_range(-0.15, 0.15), 0.15, randf_range(-0.15, 0.15)))
		UltraNet.world.spawn(def.world_scene.resource_path, at, {"item_id": id, "count": int(drops[k + 1])})


## Gone: the body disappears (no collision) and its pieces fly - local debris cut from its
## own mesh (a box into blocks, glass into thin shards), thrown out from the blow.
func _shatter(point: Vector3, dir: Vector3) -> void:
	var body := get_parent() as Node3D
	if body == null:
		return
	var mi: MeshInstance3D = null
	for ch in body.get_children():
		if ch is MeshInstance3D:
			mi = ch
			break
	var vel := (body as RigidBody3D).linear_velocity if body is RigidBody3D else Vector3.ZERO
	var co := body as CollisionObject3D
	if co:
		co.collision_layer = 0
		co.collision_mask = 0
	if body is RigidBody3D and _authority():
		(body as RigidBody3D).freeze = true
	body.visible = false
	if mi == null or mi.mesh == null:
		return
	var aabb := mi.mesh.get_aabb()
	var mat := mi.get_active_material(0)
	var xf := mi.global_transform
	var root := get_tree().current_scene if get_tree().current_scene else body.get_parent()
	var n := pieces
	var grid := Vector3i(2, 2, 2)
	if kind == Kind.GLASS:
		# A pane: a grid of thin shards across its two big sides.
		var s := aabb.size
		var thin := 0 if s.x <= minf(s.y, s.z) else (1 if s.y <= s.z else 2)
		grid = Vector3i(4, 3, 4)
		grid[thin] = 1
	elif n <= 4:
		grid = Vector3i(2, 2, 1)
	var cell := aabb.size / Vector3(grid)
	var from := point if point != Vector3.ZERO else xf.origin
	for ix in grid.x:
		for iy in grid.y:
			for iz in grid.z:
				var c := aabb.position + cell * (Vector3(ix, iy, iz) + Vector3(0.5, 0.5, 0.5))
				var size := cell * randf_range(0.7, 1.0)
				if kind == Kind.GLASS:
					size *= Vector3(randf_range(0.6, 1.2), randf_range(0.6, 1.2), randf_range(0.6, 1.2))
				var piece := RigidBody3D.new()
				piece.collision_layer = 0
				piece.collision_mask = UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC
				piece.mass = 0.2
				var m := MeshInstance3D.new()
				var bm := BoxMesh.new()
				bm.size = size.max(Vector3.ONE * 0.004)
				m.mesh = bm
				m.material_override = mat
				piece.add_child(m)
				var cs := CollisionShape3D.new()
				var bs := BoxShape3D.new()
				bs.size = bm.size.max(Vector3.ONE * 0.02)
				cs.shape = bs
				piece.add_child(cs)
				root.add_child(piece)
				var wp := xf * c
				piece.global_transform = Transform3D(xf.basis.orthonormalized().rotated(Vector3(randf(), randf(), randf()).normalized(), randf_range(-0.4, 0.4)), wp)
				var out := (wp - from).normalized() if wp.distance_to(from) > 0.01 else Vector3.UP
				var push := (out * randf_range(1.0, 2.6) + dir * randf_range(0.5, 2.0)) * (1.6 if kind == Kind.GLASS else 1.0)
				piece.linear_velocity = vel + push + Vector3.UP * randf_range(0.3, 1.4)
				piece.angular_velocity = Vector3(randf_range(-8, 8), randf_range(-8, 8), randf_range(-8, 8))
				piece.add_to_group(&"ultra_debris")
				_debris.append(piece)
				get_tree().create_timer(DEBRIS_LIFE + randf()).timeout.connect(piece.queue_free)
	for k in range(_debris.size() - 1, -1, -1):
		if not is_instance_valid(_debris[k]) or _debris[k].is_queued_for_deletion():
			_debris.remove_at(k)
	while _debris.size() > MAX_DEBRIS:
		var old := _debris.pop_front() as Node
		if is_instance_valid(old):
			old.queue_free()
	# Wood splinters, glass glitters: a puff of fine bits too.
	var fx := UltraEffects.instance()
	if fx:
		if kind == Kind.WOOD:
			fx.dust(from, aabb.size.length())
		else:
			fx.sparks(from, Vector3.UP)
