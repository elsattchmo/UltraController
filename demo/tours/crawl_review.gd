extends UltraTour
## Review tour: a zombie cut in half. A walker takes a point-blank blast through the waist (slow
## motion: the lower half flies off, the upper falls), lies, drags itself up on its arms and crawls,
## swings a claw lying down, then a headshot ends it. A legless crawler beside it for comparison.
##   godot --path . --resolution 1280x720 -- --tour=crawl_review --out=C:/Dev/verify/ultra/review/crawl_review

const SLOW := 0.25

var _cam: Camera3D
var _z: UltraCharacter
var _c: UltraCharacter
var _focus := Vector3.ZERO
var _from := Vector3(2.4, 0.6, -2.0)
var _follow := true


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/crawl_review")
	steps = [
		{"teleport": "speed_start", "t": 0.6, "yaw": 0, "pitch": -4, "view_tp": true, "slot": 0},
		{"call": _setup, "t": 2.2, "slot": 0, "shot": "before"},
		{"call": _slow.bind(true), "t": 0.0},
		{"call": _blast, "t": 0.12, "slot": 0, "shot": "halve_0"},
	]
	for k in 5:
		steps.append({"t": 0.22, "slot": 0, "shot": "halve_%d" % (k + 1)})
	steps += [
		{"call": _slow.bind(false), "t": 2.5, "shot": "down_0"},
		{"t": 2.0, "shot": "down_1"},
		{"t": 20.0, "until": _crawling, "after": 0.3, "shot": "up_0"},
		{"call": _walk, "t": 1.2, "shot": "crawl_0"},
		{"t": 0.45, "shot": "crawl_1"},
		{"t": 0.45, "shot": "crawl_2"},
		{"t": 0.45, "shot": "crawl_3"},
		{"call": _front, "t": 0.9, "shot": "crawl_front"},
		{"call": _stop, "t": 0.5},
		{"call": _slow.bind(true), "t": 0.0},
		{"call": _claw, "t": 0.2, "shot": "claw_0"},
		{"t": 0.25, "shot": "claw_1"},
		{"t": 0.25, "shot": "claw_2"},
		{"t": 0.25, "shot": "claw_3"},
		{"call": _slow.bind(false), "t": 1.0},
		{"call": _head, "t": 0.1, "shot": "head_0"},
		{"t": 0.8, "shot": "head_1"},
		{"t": 1.5, "shot": "dead"},
	]


func _setup() -> void:
	_c = main.player
	var at := _c.state.pos + Vector3(0, 0.05, -6.0)
	var p := UltraNet.spawn_bot(ZombieFactory.name_for(&"walker", 0), Transform3D(Basis(Vector3.UP, 0.0), at))
	_z = p.character
	(_z.input_source as BotInputSource).set_steps([{"ticks": 100000, "yaw": 0.0}])
	_cam = Camera3D.new()
	main.add_child(_cam)
	_cam.fov = 40.0
	_cam.current = true
	_from = Vector3(2.6, 0.5, -2.2)


func _slow(on: bool) -> void:
	Engine.time_scale = SLOW if on else 1.0


func _waist() -> Vector3:
	for cp: Dictionary in UltraHitboxes.capsules(_z, _z.state.pos):
		if cp.region == UltraLimbs.Region.TORSO:
			return (cp.a as Vector3).lerp(cp.b as Vector3, 0.72)
	return _z.state.pos + Vector3.UP


func _blast() -> void:
	var at := _waist()
	var from := at + Vector3(0, 0, -1.0)
	var dirs := []
	for i in 9:
		dirs.append(((at - from).normalized() + Vector3(randf_range(-0.01, 0.01), randf_range(-0.01, 0.01), 0)).normalized())
	UltraCombat.hitscan_pellets(_c, from, dirs, ItemDB.get_def(&"shotgun"))


func _crawling() -> bool:
	return _z.state.state == MotorState.Id.CRAWL


func _walk() -> void:
	(_z.input_source as BotInputSource).set_steps([{"ticks": 100000, "move": Vector2(0, 1), "yaw": _z.state.body_yaw}])
	_from = Vector3(2.4, 0.45, 0.0)


func _front() -> void:
	_from = Vector3(0.3, 0.5, -2.4)


func _stop() -> void:
	(_z.input_source as BotInputSource).set_steps([{"ticks": 100000, "yaw": _z.state.body_yaw}])
	_from = Vector3(2.0, 0.8, -1.6)


func _claw() -> void:
	var spec: Dictionary = ZombieArchetype.CLIPS[&"atk_swipe"]
	(_z.anim as UltraLiteAnimDriver).play_attack(&"atk_swipe", spec.seg, spec.contact, 0.45, true)


func _head() -> void:
	var d := UltraCombat.DamageInfo.new()
	d.amount = 80.0
	d.region = UltraLimbs.Region.HEAD
	d.kind = &"bullet"
	d.dir = Vector3(0, 0, 1)
	d.point = _z.state.pos + Vector3.UP * 0.5
	d.attacker_id = _c.net_id
	_z.apply_damage(d)


func _process(delta: float) -> void:
	super(delta)
	if _cam == null or _z == null:
		return
	_cam.current = true
	var base := _z.visual_root.global_position
	var h := 0.9 if _z.state.state in [MotorState.Id.IDLE, MotorState.Id.MOVE] else 0.4
	if _z.skeleton and _z.body_fx and not _z.body_fx._world.is_empty():
		var b := _z.skeleton.find_bone("Chest")
		if b >= 0 and _z.state.state in [MotorState.Id.RAGDOLL, MotorState.Id.DEAD, MotorState.Id.GET_UP]:
			base = _z.body_fx._bone_world(b).origin
			h = 0.0
	_focus = _focus.lerp(base + Vector3(0, h, 0), 1.0 - exp(-8.0 * delta / maxf(Engine.time_scale, 0.1)))
	_cam.global_position = _focus + _from
	_cam.look_at(_focus)
