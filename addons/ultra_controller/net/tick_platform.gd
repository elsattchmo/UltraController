@tool
class_name TickPlatform
extends AnimatableBody3D
## A moving platform whose pose is a pure function of the simulation tick. Clients can put
## it exactly where it was for any tick they predict or replay, so riding it never causes a
## misprediction. The motor carries riders by the platform's own tick-to-tick delta.

enum Mode { LINEAR, ROTATE, ELEVATOR }

static var all: Array[TickPlatform] = []
static var _next_id := 1

@export var mode := Mode.LINEAR
## LINEAR / ELEVATOR: travel offset from the start pose (ping-pong).
@export var travel := Vector3(0, 0, -8)
## Seconds for one leg of the trip.
@export_range(0.5, 60, 0.1) var leg_time := 4.0
## Seconds to wait at each end.
@export_range(0, 10, 0.1) var pause := 1.0
## ROTATE: degrees per second about Y.
@export_range(-360, 360, 1) var spin_deg := 30.0

var platform_id := 0
var _origin := Transform3D()


func _ready() -> void:
	sync_to_physics = false
	_origin = global_transform
	if Engine.is_editor_hint():
		return
	platform_id = _next_id
	_next_id += 1
	all.append(self)


func _exit_tree() -> void:
	all.erase(self)


func pose_at(tick: int) -> Transform3D:
	var t := float(tick) / Engine.physics_ticks_per_second
	match mode:
		Mode.ROTATE:
			return Transform3D(Basis(Vector3.UP, deg_to_rad(spin_deg) * t) * _origin.basis, _origin.origin)
		_:
			var cycle := 2.0 * (leg_time + pause)
			var u := fposmod(t, cycle)
			var k := 0.0
			if u < leg_time:
				k = u / leg_time
			elif u < leg_time + pause:
				k = 1.0
			elif u < 2.0 * leg_time + pause:
				k = 1.0 - (u - leg_time - pause) / leg_time
			k = smoothstep(0.0, 1.0, k)
			return Transform3D(_origin.basis, _origin.origin + travel * k)


func apply_tick(tick: int) -> void:
	var xf := pose_at(tick)
	global_transform = xf
	PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, xf)


## Put every platform where it is at `tick` (start of a simulated tick, or before a replay).
## The world tick last applied (presentation of other tick-driven things, e.g. water level).
static var current_tick := 0


static func set_all(tick: int) -> void:
	current_tick = tick
	for p in all:
		p.apply_tick(tick)


static func find(id: int) -> TickPlatform:
	for p in all:
		if p.platform_id == id:
			return p
	return null
