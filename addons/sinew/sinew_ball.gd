class_name SinewBall
extends Node3D
## A test ball (the "Ball launcher" item, demo/items/ball_launcher_item.tres): a real body in Sinew's
## physics world (Box3D, continuous collision) - it hits the body parts themselves, and what that does
## is simulated: the momentum goes into the part it strikes and on through the joints. A body is only
## physical where something is happening, so a ball about to reach a Sinew character wakes it first
## (SinewRagdoll.brace: the whole body physical, the balancer on - as a stagger): then an arm is knocked
## back by its own mass, a chest hit rocks the body onto its heels and it steps, a leg can be swept.
## No damage. Gone after `life` s (it shrinks away over the last 0.4).

const MAX_BALLS := 30
const LOOK_AHEAD := 0.15          ## s of flight swept for a body to wake
const WAKE_RADIUS := 0.35         ## a part this close to the ball's path (plus its radius) wakes
static var _live: Array[SinewBall] = []

var physics: RefCounted
var body := 0
var radius := 0.11
var life := 2.5
var _age := 0.0
var _mesh: MeshInstance3D
var _prev := Transform3D()
var _now := Transform3D()


## Fire a ball from `origin` along `dir` (world) for `by`, with the item's stats. Null without Sinew.
static func launch(by: UltraCharacter, origin: Vector3, dir: Vector3, def: ItemDefinition) -> SinewBall:
	var r := by.ragdoll as SinewRagdoll
	if r == null or r.world == null:
		return null
	var b := SinewBall.new()
	b.physics = r.world.physics
	b.radius = float(def.stat("ball_radius", 0.11))
	b.life = float(def.stat("ball_life", 2.5))
	var v := dir.normalized() * float(def.stat("ball_speed", 20.0)) + Vector3(by.state.vel.x, 0.0, by.state.vel.z)
	b.body = int(b.physics.call("add_ball", origin, v, b.radius, float(def.stat("ball_mass", 2.0)), 0.35))
	b._mesh = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = b.radius
	sm.height = b.radius * 2.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.45, 0.1)
	sm.material = mat
	b._mesh.mesh = sm
	b._mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	b.add_child(b._mesh)
	b.top_level = true
	by.get_tree().current_scene.add_child(b)
	b._now = Transform3D(Basis(), origin)
	b._prev = b._now
	b.global_transform = b._now
	_live.append(b)
	while _live.size() > MAX_BALLS:
		var old: SinewBall = _live.pop_front()
		if is_instance_valid(old):
			old.queue_free()
	return b


func _physics_process(delta: float) -> void:
	_age += delta
	if _age >= life:
		queue_free()
		return
	_prev = _now
	_now = physics.call("body_transform", body)
	# Bodies about to be struck turn physical before the contact (an animated part can't be moved).
	var v: Vector3 = physics.call("linear_velocity", body)
	if v.length() > 3.0:
		_wake_ahead(_now.origin, v * LOOK_AHEAD)


func _process(_delta: float) -> void:
	global_transform = _prev.interpolate_with(_now, Engine.get_physics_interpolation_fraction())
	if _mesh:
		_mesh.scale = Vector3.ONE * clampf((life - _age) / 0.4, 0.05, 1.0)


func _wake_ahead(from: Vector3, travel: Vector3) -> void:
	for r: SinewRagdoll in SinewRagdoll.all:
		if not is_instance_valid(r):
			continue
		for xf: Transform3D in r.pose_now:
			var q := Geometry3D.get_closest_point_to_segment(xf.origin, from, from + travel)
			if q.distance_to(xf.origin) < WAKE_RADIUS + radius:
				r.brace()
				break


func _exit_tree() -> void:
	_live.erase(self)
	if physics and body != 0:
		physics.call("remove_body", body)
		body = 0
