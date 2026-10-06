extends UltraTour
## Review tour: the zombies' bodies - the row of archetypes standing, each walking (side on), the
## crawler, a claw swing, a hit flinch, and a knock-down and get-up.
##   godot --path . --resolution 1280x720 -- --tour=zombie_look --out=C:/Dev/verify/ultra/review/zombie_look

const ARCH := [&"walker", &"shambler", &"limper", &"runner", &"brute", &"crawler"]

var _cam: Camera3D
var _z: Array[UltraCharacter] = []
var _focus := Vector3.ZERO
var _from := Vector3.ZERO
var _follow := -1


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/zombie_look")
	steps = [
		{"teleport": "speed_start", "t": 0.6, "yaw": 0, "pitch": -4, "view_tp": true, "slot": 0},
		{"call": _setup, "t": 2.5, "slot": 0},
		{"call": _wide, "t": 0.3, "shot": "idle_row"},
	]
	for k in ARCH.size():
		steps.append({"call": _walk_one.bind(k), "t": 1.6 if k != 3 else 1.2})
		steps.append({"call": _side.bind(k), "t": 0.3, "shot": "gait_%d_%s_a" % [k, ARCH[k]]})
		steps.append({"t": 0.35, "shot": "gait_%d_%s_b" % [k, ARCH[k]]})
		steps.append({"call": _front.bind(k), "t": 0.3, "shot": "gait_%d_%s_front" % [k, ARCH[k]]})
		steps.append({"call": _stop.bind(k), "t": 0.2})
	steps += [
		{"call": _attack.bind(0, &"atk_swipe"), "t": 0.0},
		{"call": _angle.bind(0, Vector3(1.6, 0.4, -2.2)), "t": 0.3, "shot": "swipe_0"},
		{"t": 0.3, "shot": "swipe_1"},
		{"t": 0.3, "shot": "swipe_2"},
		{"t": 0.3, "shot": "swipe_3"},
		{"t": 0.6},
		{"call": _attack.bind(4, &"atk_overhead"), "t": 0.0},
		{"call": _angle.bind(4, Vector3(1.8, 0.4, -2.4)), "t": 0.4, "shot": "overhead_0"},
		{"t": 0.35, "shot": "overhead_1"},
		{"t": 0.35, "shot": "overhead_2"},
		{"t": 0.35, "shot": "overhead_3"},
		{"t": 0.8},
		{"call": _attack.bind(5, &"atk_swipe"), "t": 0.0},
		{"call": _angle.bind(5, Vector3(1.4, 0.7, -1.8)), "t": 0.3, "shot": "crawl_swipe_0"},
		{"t": 0.3, "shot": "crawl_swipe_1"},
		{"t": 0.3, "shot": "crawl_swipe_2"},
		{"t": 0.8},
		{"call": _hurt.bind(1), "t": 0.0},
		{"call": _wide, "t": 0.5, "shot": "bars_row"},
		{"call": _hit.bind(1), "t": 0.0},
		{"call": _angle.bind(1, Vector3(2.6, 1.1, -4.2)), "t": 0.25, "shot": "hit_0"},
		{"t": 0.3, "shot": "hit_1"},
		{"t": 0.8},
		{"call": _knock.bind(2), "t": 0.0},
		{"call": _angle.bind(2, Vector3(2.2, 1.0, -2.6)), "t": 0.6, "shot": "down_0"},
		{"t": 2.6, "shot": "down_1"},
		{"t": 1.2, "shot": "getup_0"},
		{"t": 1.0, "shot": "getup_1"},
		{"t": 1.0, "shot": "getup_2"},
		{"t": 1.2, "shot": "getup_3"},
		{"t": 1.0, "shot": "after"},
	]


func _setup() -> void:
	var c: UltraCharacter = main.player
	for k in ARCH.size():
		var at := c.state.pos + Vector3(-5.0 + k * 2.0, 0.05, -9.0)
		var p := UltraNet.spawn_bot(ZombieFactory.name_for(ARCH[k], k), Transform3D(Basis(Vector3.UP, 0.0), at))
		(p.character.input_source as BotInputSource).set_steps([{"ticks": 100000, "yaw": 0.0}])
		_z.append(p.character)
	_cam = Camera3D.new()
	main.add_child(_cam)
	_cam.fov = 40.0
	_cam.current = true
	_wide()






func _wide() -> void:
	_follow = -1
	_focus = main.player.state.pos + Vector3(0, 1.0, -9.0)
	_from = Vector3(0, 0.6, -7.5)


func _side(k: int) -> void:
	_follow = k
	_from = Vector3(3.4, 0.2, 0.0)


func _front(k: int) -> void:
	_follow = k
	_from = Vector3(0.0, 0.3, -3.6)


func _angle(k: int, from: Vector3) -> void:
	_follow = k
	_from = from


func _walk_one(k: int) -> void:
	var z := _z[k]
	var b := z.input_source as BotInputSource
	b.set_steps([{"ticks": 100000, "move": Vector2(0, 1), "yaw": z.state.body_yaw, "buttons": InputFrame.B_SPRINT if ARCH[k] == &"runner" else 0}])


func _stop(k: int) -> void:
	var z := _z[k]
	(z.input_source as BotInputSource).set_steps([{"ticks": 100000, "yaw": z.state.body_yaw}])


func _attack(k: int, role: StringName) -> void:
	var z := _z[k]
	var spec: Dictionary = ZombieArchetype.CLIPS[role]
	(z.anim as UltraLiteAnimDriver).play_attack(role, spec.seg, spec.contact, 0.45, z.state.state == MotorState.Id.CRAWL)


func _hit(k: int) -> void:
	(_z[k].anim as UltraLiteAnimDriver).play_hit(false)


## Shots into the row so their health bars show (the later ones hurt worse).
func _hurt(_k: int) -> void:
	for j in _z.size():
		var d := UltraCombat.DamageInfo.new()
		d.amount = 34.0 * float(j + 1) * 0.5
		d.region = UltraLimbs.Region.TORSO
		d.kind = &"bullet"
		d.dir = Vector3(0, 0, 1)
		d.point = _z[j].state.pos + Vector3.UP * 1.2
		d.attacker_id = main.player.net_id
		_z[j].apply_damage(d)


func _knock(k: int) -> void:
	_z[k].knock_down(Vector3(0, 0, -3.0) + Vector3.UP * 1.5)


func _process(delta: float) -> void:
	super(delta)
	if _cam == null:
		return
	_cam.current = true
	if _follow >= 0:
		var z := _z[_follow]
		_focus = z.visual_root.global_position + Vector3(0, 0.9 if z.state.state != MotorState.Id.CRAWL else 0.4, 0)
	_cam.global_position = _focus + _from
	_cam.look_at(_focus)
