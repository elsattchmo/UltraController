@tool
class_name UltraRope
extends Node3D
## A hanging rope. Origin = anchor point. Gameplay treats it as a pendulum in the motor
## (deterministic, predicted); this node draws a cosmetic rope that follows whoever holds it
## and reacts to the world around it.
## Every rope swings and climbs: looking level, forward/back pumps the swing; looking up or
## down (> 25 deg), forward/back climbs toward where you look. Jump lets go carrying the
## swing's speed; reaching the ground at the bottom puts you on your feet.
##
## The cosmetic rope is a verlet chain (presentation only, never affects gameplay):
##   - held: taut and straight from the anchor to the hands, the tail below hangs free;
##   - lies on and slides along the ground and walls (ray-swept per particle);
##   - characters walking into it push it and set it swinging; flying props knock it about;
##   - keeps its momentum when let go; sleeps when nothing moves it.

enum Kind { SWING, CLIMB }   ## (kept for older scenes; both behave the same)

static var all: Array[UltraRope] = []
static var _next_id := 1

@export var kind := Kind.SWING
@export_range(1, 30, 0.1) var length := 6.0
@export_range(0.01, 0.1, 0.005) var thickness := 0.03
## Minimum chain particles; long ropes get one every ~0.15 m.
@export var segments := 16

const SUBSTEP := 1.0 / 120.0
const ITERATIONS := 10
const DAMP := 0.996                 ## per substep: air drag on the free rope
const FRICTION := 0.6               ## sliding along a surface keeps this much tangential speed
const SIDES := 6

var rope_id := 0
var _pts: PackedVector3Array = []
var _prev: PackedVector3Array = []
var _seg := 0.1
var _acc := 0.0
var _still := 0.0                    ## seconds nothing has moved (sleeps after a while)
var _last_hands := Vector3.INF
var _bodies: Array = []              ## this frame's pushers: [a, b, radius, velocity]
var _ground := PackedFloat32Array()  ## per particle: floor height under it (-INF: none)
var _mi: MeshInstance3D
var _im: ImmediateMesh
var _mat: StandardMaterial3D


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	rope_id = _next_id
	_next_id += 1
	all.append(self)
	process_priority = 150               # after characters place their bodies (the hands)
	var n := maxi(segments, int(ceil(length / 0.15))) + 1
	_seg = length / (n - 1)
	_pts.resize(n)
	_prev.resize(n)
	for k in n:
		_pts[k] = global_position + Vector3.DOWN * _seg * k
		_prev[k] = _pts[k]
	_im = ImmediateMesh.new()
	_mi = MeshInstance3D.new()
	_mi.mesh = _im
	_mi.top_level = true
	_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_mat = StandardMaterial3D.new()
	_mat.albedo_color = Color(0.72, 0.6, 0.4)
	_mat.roughness = 0.9
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	add_child(_mi)
	_draw()
	_settle_on_world.call_deferred()


func _exit_tree() -> void:
	all.erase(self)


func anchor() -> Vector3:
	return global_position


static func find(id: int) -> UltraRope:
	for r in all:
		if r.rope_id == id:
			return r
	return null


## Climbing input on a rope, -1 (down) .. 1 (up): forward / back while looking up or down
## moves along the rope toward where you look (looking level, forward / back pumps the swing).
const CLIMB_LOOK := 25.0            ## degrees of look up / down that turn forward into climbing
static func climb_input(rope: UltraRope, i: InputFrame) -> float:
	if rope == null or absf(i.move.y) < 0.3 or absf(i.pitch) < deg_to_rad(CLIMB_LOOK):
		return 0.0
	return clampf(signf(i.pitch) * i.move.y, -1.0, 1.0)


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


## Where the rope is at distance `s` from the anchor (cosmetic chain; for effects / tests).
func point_at(s: float) -> Vector3:
	var f := clampf(s / _seg, 0.0, _pts.size() - 1.0)
	var k := mini(int(f), _pts.size() - 2)
	return _pts[k].lerp(_pts[k + 1], f - k)


## Is the cosmetic rope resting (asleep)?
func is_still() -> bool:
	return _still > 0.5


## Give the rope a shove at a point (e.g. a shot or an explosion near it).
func push(at: Vector3, velocity: Vector3, radius := 0.4) -> void:
	for k in range(1, _pts.size()):
		var w := 1.0 - clampf(_pts[k].distance_to(at) / radius, 0.0, 1.0)
		if w > 0.0:
			_prev[k] -= velocity * SUBSTEP * w
	_still = 0.0


# ---------------------------------------------------------------- simulation

func _process(delta: float) -> void:
	if Engine.is_editor_hint() or _pts.is_empty():
		return
	var hold := _holder()
	_gather_bodies(hold)
	if hold.is_empty() and _bodies.is_empty() and _still > 1.0:
		_last_hands = Vector3.INF
		return                                         # asleep: nothing to do, nothing to draw
	_probe_ground()
	var hands_from := _last_hands
	var hands_to: Vector3 = hold.get("hands", Vector3.INF)
	_acc = minf(_acc + delta, SUBSTEP * 6.0)
	var n := int(_acc / SUBSTEP)
	_acc -= n * SUBSTEP
	var moved := 0.0
	for j in n:
		var hands := hands_to
		if hands_to != Vector3.INF and hands_from != Vector3.INF:
			hands = hands_from.lerp(hands_to, float(j + 1) / n)
		moved = maxf(moved, _step(hands, float(hold.get("grip", -1.0))))
	_last_hands = hands_to
	_still = 0.0 if (moved > 0.0004 or not hold.is_empty()) else _still + delta
	_draw()


## Who's holding this rope: {hands, grip} (visual hand point, distance along the rope).
func _holder() -> Dictionary:
	for n in get_tree().get_nodes_in_group(&"ultra_character"):
		var c := n as UltraCharacter
		if c and c.state.state == MotorState.Id.ROPE and c.state.trav_id == rope_id:
			return {"hands": UltraTraversalVisual.rope_grip(c), "grip": c.state.trav_s, "who": c}
	return {}


## Characters and loose props near the rope push it this frame.
func _gather_bodies(hold: Dictionary) -> void:
	_bodies.clear()
	var lo := _pts[0]
	var hi := _pts[0]
	for p in _pts:
		lo = lo.min(p)
		hi = hi.max(p)
	var box := AABB(lo, hi - lo).grow(0.8)
	for n in get_tree().get_nodes_in_group(&"ultra_character"):
		var c := n as UltraCharacter
		if c == null or not box.has_point(c.state.pos + Vector3.UP * 0.9):
			continue
		var r := c.profile.radius if c.profile else 0.3
		if hold.get("who") == c:
			# The one holding it: only their body (a slim capsule along the body, which hangs
			# along the rope a little behind it), so the tail hangs in front instead of
			# bulging round the movement capsule.
			if c.visual_root == null:
				continue
			var vx := c.visual_root.global_transform
			_bodies.append([vx * Vector3(0, 0.35, 0.05), vx * Vector3(0, 1.45, 0.05), 0.13, c.state.vel])
		else:
			_bodies.append([c.state.pos + Vector3.UP * r, c.state.pos + Vector3.UP * maxf(c.state.height - r, r), r, c.state.vel])
	var space := get_world_3d().direct_space_state if is_inside_tree() else null
	if space == null:
		return
	var q := PhysicsShapeQueryParameters3D.new()
	var bs := BoxShape3D.new()
	bs.size = box.size
	q.shape = bs
	q.transform = Transform3D(Basis(), box.get_center())
	q.collision_mask = UltraLayers.WORLD_DYNAMIC | UltraLayers.HELD_PROP
	for hit in space.intersect_shape(q, 8):
		var rb := hit.collider as RigidBody3D
		if rb == null or rb.sleeping or rb.linear_velocity.length() < 0.05:
			continue
		var rad := UltraGrab._size(rb) * 0.8
		_bodies.append([rb.global_position, rb.global_position, rad, rb.linear_velocity])


func _step(hands: Vector3, grip: float) -> float:
	var n := _pts.size()
	var dt := SUBSTEP
	var g := Vector3.DOWN * 9.8 * dt * dt
	var pin := clampi(int(round(grip / _seg)), 1, n - 1) if grip >= 0.0 and hands != Vector3.INF else -1
	var start := _pts.duplicate()
	for k in range(1, n):
		var cur := _pts[k]
		_pts[k] = cur + (cur - _prev[k]) * DAMP + g
		_prev[k] = cur
	var a := anchor()
	for _it in ITERATIONS:
		_pts[0] = a
		if pin > 0:
			# Under the climber's weight the rope is straight from the anchor to the hands.
			for k in range(1, pin + 1):
				_pts[k] = a.lerp(hands, float(k) / pin)
		for k in range(maxi(pin, 0), n - 1):
			var p0 := _pts[k]
			var p1 := _pts[k + 1]
			var d := p1 - p0
			var l := d.length()
			if l < 0.00001:
				continue
			var fixed0 := k == 0 or k <= pin
			var corr := d * (1.0 - _seg / l)
			if fixed0:
				_pts[k + 1] = p1 - corr
			else:
				_pts[k] = p0 + corr * 0.5
				_pts[k + 1] = p1 - corr * 0.5
		# Floors are part of the solve (fighting the length constraint after it jitters).
		for k in range(maxi(pin, 0) + 1, n):
			if _pts[k].y < _ground[k]:
				_pts[k].y = _ground[k]
	_collide(maxi(pin, 0) + 1, dt)
	_ground_friction(maxi(pin, 0) + 1)
	var moved := 0.0
	for k in n:
		moved = maxf(moved, _pts[k].distance_squared_to(start[k]))
	return sqrt(moved)


## Free particles against pushers (characters, props: they hand over some of their speed) and
## the world (ray swept from where each particle was: rests on the floor, slides off walls).
func _collide(first: int, dt: float) -> void:
	var rad := thickness + 0.01
	for k in range(first, _pts.size()):
		var p := _pts[k]
		for b: Array in _bodies:
			var q := Geometry3D.get_closest_point_to_segment(p, b[0], b[1])
			var d := p - q
			var r: float = float(b[2]) + rad
			var dl := d.length()
			if dl < r:
				var nrm := d / dl if dl > 0.0001 else Vector3.RIGHT
				p = q + nrm * r
				# Carried along by the pusher: its velocity, minus any part pulling away.
				var vb: Vector3 = b[3]
				var vp := (p - _prev[k]) / dt
				var rel := vp - vb
				var vn := rel.dot(nrm)
				var vt := rel - nrm * vn
				_prev[k] = p - (vb + nrm * maxf(vn, 0.0) + vt * 0.5) * dt
		_pts[k] = p
	var space := get_world_3d().direct_space_state if is_inside_tree() else null
	if space == null:
		return
	for k in range(first, _pts.size()):
		var from := _prev[k]
		var to := _pts[k]
		if from.distance_squared_to(to) < 0.0000001:
			continue
		var dir := (to - from).normalized()
		var ray := PhysicsRayQueryParameters3D.create(from - dir * rad, to + dir * rad, UltraLayers.WORLD_STATIC)
		var hit := space.intersect_ray(ray)
		if hit.is_empty():
			continue
		var nrm: Vector3 = hit.normal
		if nrm.y > 0.6 and _ground.size() == _pts.size() and _ground[k] > -INF:
			continue                     # a floor: the ground clamp has it
		var at: Vector3 = hit.position + nrm * rad
		var v := (to - from) / dt
		var vt := (v - nrm * v.dot(nrm)) * FRICTION
		_pts[k] = at
		_prev[k] = at - vt * dt


## The floor under each particle (one ray each per frame, not per substep).
func _probe_ground() -> void:
	var n := _pts.size()
	if _ground.size() != n:
		_ground.resize(n)
	var space := get_world_3d().direct_space_state if is_inside_tree() else null
	var rad := thickness + 0.01
	for k in n:
		_ground[k] = -INF
		if space == null or k == 0:
			continue
		var p := _pts[k]
		var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 0.3, p + Vector3.DOWN * 0.6, UltraLayers.WORLD_STATIC)
		var hit := space.intersect_ray(q)
		if not hit.is_empty() and (hit.normal as Vector3).y > 0.6:
			_ground[k] = (hit.position as Vector3).y + rad


## Lying on the floor: no bounce, and it grips (static friction) unless dragged hard enough.
func _ground_friction(first: int) -> void:
	for k in range(first, _pts.size()):
		if _pts[k].y > _ground[k] + 0.002:
			continue
		var v := _pts[k] - _prev[k]
		var vh := Vector3(v.x, 0.0, v.z)
		_prev[k].y = _pts[k].y
		if vh.length() < 0.0015:
			_prev[k].x = _pts[k].x
			_prev[k].z = _pts[k].z
		else:
			_prev[k].x = _pts[k].x - vh.x * FRICTION
			_prev[k].z = _pts[k].z - vh.z * FRICTION


## On spawn: let a rope that's longer than the drop under it lie on the ground.
func _settle_on_world() -> void:
	if not is_inside_tree():
		return
	# Hang it from where the anchor is now; whatever's longer than the drop under the anchor
	# lies out along the floor (not heaped in one spot).
	var space := get_world_3d().direct_space_state
	var down := PhysicsRayQueryParameters3D.create(anchor(), anchor() + Vector3.DOWN * length, UltraLayers.WORLD_STATIC)
	var hit := space.intersect_ray(down)
	var drop := anchor().distance_to(hit.position) - (thickness + 0.01) if not hit.is_empty() else length
	var along := global_basis.x.normalized()
	along.y = 0.0
	along = along.normalized() if along.length() > 0.1 else Vector3.RIGHT
	for k in _pts.size():
		var d := _seg * k
		_pts[k] = anchor() + Vector3.DOWN * minf(d, drop) + along * maxf(d - drop, 0.0)
		_prev[k] = _pts[k]
	for i in 240:
		_bodies.clear()
		if i % 4 == 0:
			_probe_ground()
		_step(Vector3.INF, -1.0)
	_draw()


# ---------------------------------------------------------------- drawing

## A continuous tube through the chain (parallel-transported frame, smooth normals).
func _draw() -> void:
	_im.clear_surfaces()
	var n := _pts.size()
	if n < 2:
		return
	_im.surface_begin(Mesh.PRIMITIVE_TRIANGLES, _mat)
	var rings: Array = []
	var t0 := (_pts[1] - _pts[0]).normalized()
	var ref := Vector3.FORWARD if absf(t0.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT
	var nrm := t0.cross(ref).normalized()
	for k in n:
		var t := ((_pts[mini(k + 1, n - 1)] - _pts[maxi(k - 1, 0)])).normalized()
		if t == Vector3.ZERO:
			t = t0
		nrm = (nrm - t * nrm.dot(t)).normalized()          # carry the frame along the rope
		if nrm == Vector3.ZERO:
			nrm = t.cross(ref).normalized()
		var bin := t.cross(nrm)
		var ring := []
		for j in SIDES:
			var a := TAU * j / SIDES
			ring.append(cos(a) * nrm + sin(a) * bin)
		rings.append(ring)
	for k in n - 1:
		var r0: Array = rings[k]
		var r1: Array = rings[k + 1]
		for j in SIDES:
			var j1 := (j + 1) % SIDES
			var quad := [[k, j], [k + 1, j], [k + 1, j1], [k, j], [k + 1, j1], [k, j1]]
			for v: Array in quad:
				var ring: Array = r0 if v[0] == k else r1
				var dirv: Vector3 = ring[v[1]]
				_im.surface_set_normal(dirv)
				_im.surface_add_vertex(_pts[v[0]] + dirv * thickness)
	_im.surface_end()
