class_name UltraScenario
extends Node
## A scripted stress test that runs inside a live (server-side) session: it spawns bots and
## props, drives them for `duration` seconds of physics, watches for trouble (NaN, falling
## through the world, stuck states, T-posing bodies), records metrics and gives a verdict.
## Run headless from the test runner (`--suite=stress`) or in game from the F5 menu.
## Subclasses override setup() / step() / finish().

signal done(ok: bool)

var title := "scenario"
var duration := 10.0
var map: Node3D                      ## the playground
var metrics := {}
var failures: Array[String] = []
var bots: Array[UltraCharacter] = []
var spawned: Array[Node] = []        ## props etc. to free afterwards
var t := 0.0
var running := false
var _phys_ms: Array[float] = []
var _flags := {}                     ## per-check "already reported"


func start(p_map: Node3D) -> void:
	map = p_map
	setup()
	running = true


func setup() -> void:
	pass


func step(_dt: float) -> void:
	pass


func finish() -> void:
	pass


func _physics_process(dt: float) -> void:
	if not running:
		return
	t += dt
	_phys_ms.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	step(dt)
	for c in bots:
		if is_instance_valid(c):
			check_sane(c)
	if t >= duration:
		running = false
		_phys_ms.sort()
		if not _phys_ms.is_empty():
			metrics["physics_ms_p50"] = snappedf(_phys_ms[_phys_ms.size() / 2], 0.01)
			metrics["physics_ms_p95"] = snappedf(_phys_ms[int(_phys_ms.size() * 0.95)], 0.01)
		finish()
		cleanup()
		done.emit(failures.is_empty())


func fail(msg: String) -> void:
	if not _flags.has(msg):
		_flags[msg] = true
		failures.append(msg)


func metric(k: String, v: Variant) -> void:
	metrics[k] = v


func marker(n: String) -> Marker3D:
	return map.call("marker", n) as Marker3D


## A server-side bot at `at`, driven by `steps` (BotInputSource format) or a driver callable.
func spawn_bot(bot_name: String, at: Transform3D, steps: Array = [], driver := Callable(), loop := true) -> UltraCharacter:
	var p := UltraNet.spawn_bot(bot_name, at)
	if p == null:
		fail("could not spawn a bot (not the server?)")
		return null
	var src := p.character.input_source as BotInputSource
	src.loop = loop
	if driver.is_valid():
		src.driver = driver
	else:
		src.set_steps(steps if not steps.is_empty() else [{"ticks": 60}])
	bots.append(p.character)
	return p.character


func cleanup() -> void:
	for c in bots:
		if is_instance_valid(c):
			UltraNet.despawn_bot(c.net_id)
	bots.clear()
	for n in spawned:
		if is_instance_valid(n):
			n.queue_free()
	spawned.clear()


## Trouble every scenario watches for.
func check_sane(c: UltraCharacter) -> void:
	var s := c.state
	if not s.pos.is_finite() or not s.vel.is_finite():
		fail("%s: NaN in position / velocity" % c.name)
	elif s.pos.y < -30.0:
		fail("%s: fell out of the world at %s" % [c.name, s.pos.snappedf(0.1)])
	var limit := 6.0
	match s.state:
		MotorState.Id.ROOT_MOTION, MotorState.Id.MANTLE, MotorState.Id.VAULT, MotorState.Id.LEDGE_CLIMB, MotorState.Id.LAND, MotorState.Id.GET_UP, MotorState.Id.SLIDE:
			if s.state_time > limit:
				fail("%s: stuck in %s for %.1f s" % [c.name, MotorState.Id.keys()[s.state], s.state_time])
	if c.skeleton and c.anim and Engine.get_physics_frames() % 30 == 0 and is_t_pose(c):
		fail("%s: T-pose (animation not applied)" % c.name)


## The pose equals the rest (bind) pose on both arms: nothing is animating the body.
static func is_t_pose(c: UltraCharacter) -> bool:
	var sk := c.skeleton
	for b: String in ["LeftUpperArm", "RightUpperArm", "LeftLowerArm", "RightLowerArm"]:
		var i := sk.find_bone(b)
		if i < 0:
			return false
		if sk.get_bone_pose_rotation(i).angle_to(sk.get_bone_rest(i).basis.get_rotation_quaternion()) > deg_to_rad(2.0):
			return false
	return true


func report() -> String:
	var keys := metrics.keys()
	keys.sort()
	var parts: Array[String] = []
	for k: String in keys:
		parts.append("%s=%s" % [k, metrics[k]])
	return "%s: %s%s" % [title, "PASS" if failures.is_empty() else "FAIL", ("  " + " ".join(parts)) if not parts.is_empty() else ""]
