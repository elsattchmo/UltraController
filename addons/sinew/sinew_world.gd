class_name SinewWorld
extends Node
## The Sinew physics world for a scene: one per scene tree, shared by every Sinew body in it,
## made by the first body that asks (acquire) and freed with the last (release).
##
## It mirrors the level into Sinew (Box3D): static colliders once, moving ones (doors, lifts,
## props) as kinematic proxies that follow their Godot node every tick. Only the world layers
## (WORLD_STATIC | WORLD_DYNAMIC) are mirrored; characters, hit volumes and areas aren't.
## Then each tick, after the characters' motor ticks: bodies prepare (targets, tone, kinematic
## tracking), the world steps (8 substeps), bodies read their new pose.

const MIRROR_LAYERS := UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC

var physics: RefCounted                 ## SinewPhysics (the GDExtension)
var users := 0
var bodies: Array = []                  ## SinewRagdoll, stepped in this order
var _rigs := {}                         ## BodyProfile instance id -> rig id
var _static := {}                       ## mirrored collider instance id -> Sinew body
var _moving := {}                       ## collider instance id -> [node, Sinew body]
var _dirty := false


static func available() -> bool:
	return ClassDB.class_exists(&"SinewPhysics")


static var _by_tree := {}              ## SceneTree instance id -> its SinewWorld


## The world of `node`'s scene tree (made on first use). Pair with release().
## (Bodies ask while their character is being set up, when the root can't take a child: the
## world joins the tree deferred, and steps from then on.)
static func acquire(node: Node) -> SinewWorld:
	var tree := node.get_tree()
	var w: SinewWorld = _by_tree.get(tree.get_instance_id())
	if w == null or not is_instance_valid(w):
		w = SinewWorld.new()
		w.name = "SinewWorld"
		_by_tree[tree.get_instance_id()] = w
		tree.root.add_child.call_deferred(w)
	w.users += 1
	return w


func release() -> void:
	users -= 1
	if users > 0:
		return
	for k in _by_tree.keys():
		if _by_tree[k] == self:
			_by_tree.erase(k)
	if is_inside_tree():
		get_parent().remove_child(self)
	queue_free()


func _init() -> void:
	physics = ClassDB.instantiate(&"SinewPhysics")
	var g: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
	var gv: Vector3 = ProjectSettings.get_setting("physics/3d/default_gravity_vector", Vector3.DOWN)
	physics.call("setup", gv * g, 8)
	# After the characters (UltraNet ticks them at priority 0) and before the ropes / rounds.
	process_physics_priority = 120


func _ready() -> void:
	get_tree().node_added.connect(_on_node_changed)
	get_tree().node_removed.connect(_on_node_changed)
	_mirror_all()


func _on_node_changed(n: Node) -> void:
	if n is CollisionObject3D or n is CollisionShape3D:
		_dirty = true


func _physics_process(dt: float) -> void:
	if _dirty:
		_dirty = false
		_mirror_all()
	for id in _moving.keys():
		var e: Array = _moving[id]
		var n := e[0] as Node3D
		if is_instance_valid(n) and n.is_inside_tree():
			physics.call("move_kinematic", e[1], _rigid(n.global_transform), dt)
	for b in bodies:
		b.call("sinew_pre_step", dt)
	physics.call("step", dt)
	for b in bodies:
		b.call("sinew_post_step", dt)


## The rig for a model (built once per BodyProfile): rests in the skeleton's frame.
func rig_for(profile: BodyProfile, sk: Skeleton3D, mass: float) -> int:
	var key := profile.get_instance_id() if profile else sk.get_instance_id()
	if _rigs.has(key):
		return _rigs[key]
	var names := PackedStringArray()
	var parents := PackedInt32Array()
	var rests := []
	for i in sk.get_bone_count():
		names.append(sk.get_bone_name(i))
		parents.append(sk.get_bone_parent(i))
		rests.append(sk.get_bone_global_rest(i))
	var forward := Vector3(0, 0, 1) if profile == null or profile.model_faces_positive_z else Vector3(0, 0, -1)
	var rig: int = physics.call("build_humanoid_rig", names, parents, rests, Vector3.UP, forward, mass)
	_rigs[key] = rig
	return rig


# ------------------------------------------------------------------ the level, mirrored

func _mirror_all() -> void:
	var seen := {}
	_scan(get_tree().root, seen)
	for id in _static.keys():
		if not seen.has(id):
			physics.call("remove_body", _static[id])
			_static.erase(id)
	for id in _moving.keys():
		if not seen.has(id):
			physics.call("remove_body", _moving[id][1])
			_moving.erase(id)


func _scan(n: Node, seen: Dictionary) -> void:
	if n is CollisionObject3D:
		var co := n as CollisionObject3D
		if _mirrors(co):
			var id := co.get_instance_id()
			seen[id] = true
			if not _static.has(id) and not _moving.has(id):
				_add(co)
	for c in n.get_children():
		_scan(c, seen)


func _mirrors(co: CollisionObject3D) -> bool:
	if co is CharacterBody3D or co is PhysicalBone3D or co is Area3D:
		return false
	return (co.collision_layer & MIRROR_LAYERS) != 0 and co.is_inside_tree()


## Things that never move by construction mirror as static; anything that can (rigid bodies,
## animatable bodies, scripted bodies such as doors) as a kinematic proxy.
func _moves(co: CollisionObject3D) -> bool:
	if co is RigidBody3D or co is AnimatableBody3D:
		return true
	if co.get_script() != null:
		return true
	var p := co.get_parent()
	return p != null and p.get_script() != null and p is Node3D and not (p is CollisionObject3D)


func _add(co: CollisionObject3D) -> void:
	var moving := _moves(co)
	var xf := co.global_transform
	var scale := xf.basis.get_scale()
	var body: int = physics.call("add_body", 1 if moving else 0, _rigid(xf))
	var shapes := 0
	for owner in co.get_shape_owners():
		if co.is_shape_owner_disabled(owner):
			continue
		var local: Transform3D = co.shape_owner_get_transform(owner)
		for k in co.shape_owner_get_shape_count(owner):
			if _add_shape(body, co.shape_owner_get_shape(owner, k), local, scale):
				shapes += 1
	if shapes == 0:
		physics.call("remove_body", body)
		return
	if moving:
		_moving[co.get_instance_id()] = [co, body]
	else:
		_static[co.get_instance_id()] = body


## A shape in the body's (unscaled) frame: the node's scale is baked into the shape.
func _add_shape(body: int, shape: Shape3D, local: Transform3D, scale: Vector3) -> bool:
	var s := Transform3D(Basis.from_scale(scale), Vector3.ZERO) * local
	if shape is BoxShape3D:
		var hull := PackedVector3Array()
		var h := (shape as BoxShape3D).size * 0.5
		for x in [-1, 1]:
			for y in [-1, 1]:
				for z in [-1, 1]:
					hull.append(s * Vector3(h.x * x, h.y * y, h.z * z))
		return physics.call("add_hull_shape", body, hull)
	if shape is SphereShape3D:
		var r := (shape as SphereShape3D).radius * maxf(scale.x, maxf(scale.y, scale.z))
		physics.call("add_sphere_shape", body, s.origin, r)
		return true
	if shape is CapsuleShape3D:
		var cs := shape as CapsuleShape3D
		var half := maxf(cs.height * 0.5 - cs.radius, 0.0)
		var r := cs.radius * maxf(scale.x, scale.z)
		physics.call("add_capsule_shape", body, s * Vector3(0, -half, 0), s * Vector3(0, half, 0), r)
		return true
	if shape is CylinderShape3D:
		var cy := shape as CylinderShape3D
		var pts := PackedVector3Array()
		for i in 16:
			var a := TAU * i / 16.0
			for y in [-0.5, 0.5]:
				pts.append(s * Vector3(cos(a) * cy.radius, y * cy.height, sin(a) * cy.radius))
		return physics.call("add_hull_shape", body, pts)
	if shape is ConvexPolygonShape3D:
		var pts := PackedVector3Array()
		for p in (shape as ConvexPolygonShape3D).points:
			pts.append(s * p)
		return pts.size() >= 4 and physics.call("add_hull_shape", body, pts)
	if shape is ConcavePolygonShape3D:
		var faces := (shape as ConcavePolygonShape3D).get_faces()
		var verts := PackedVector3Array()
		var idx := PackedInt32Array()
		for i in faces.size():
			verts.append(s * faces[i])
			idx.append(i)
		return physics.call("add_mesh_shape", body, verts, idx, true)
	if shape is HeightMapShape3D:
		var hm := shape as HeightMapShape3D
		var verts := PackedVector3Array()
		var idx := PackedInt32Array()
		var w := hm.map_width
		var d := hm.map_depth
		for z in d:
			for x in w:
				verts.append(s * Vector3(x - (w - 1) * 0.5, hm.map_data[z * w + x], z - (d - 1) * 0.5))
		for z in d - 1:
			for x in w - 1:
				var i := z * w + x
				idx.append_array([i, i + 1, i + w, i + 1, i + w + 1, i + w])
		return physics.call("add_mesh_shape", body, verts, idx, true)
	if shape is WorldBoundaryShape3D:
		var plane := (shape as WorldBoundaryShape3D).plane
		var xf := Transform3D(Basis(Quaternion(Vector3.UP, plane.normal)), plane.normal * (plane.d - 50.0))
		physics.call("add_box_shape", body, s * xf, Vector3(1000, 50, 1000))
		return true
	return false


static func _rigid(xf: Transform3D) -> Transform3D:
	return Transform3D(xf.basis.orthonormalized(), xf.origin)
