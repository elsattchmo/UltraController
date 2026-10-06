extends UltraTour
## Review tour: zombies' minds in the mansion (debug overlay on). Scene 1: a pistol shot in the Great
## Hall, a zombie in the kitchen hears it, comes through the service corridor and finds the player.
## Scene 2: a zombie shut in the study batters the locked door down. Scene 3: a runner chases up the grand stairs.
##   godot --path . --resolution 1280x720 -- --map=mansion --tour=zombie_review --out=C:/Dev/verify/ultra/review/zombie_review

var _cam: Camera3D
var _dir: ZombieDirector
var _dbg: ZombieDebug
var _focus: Node3D
var _focus_off := Vector3(0, 1.0, 0)
var _from := Vector3(2.0, 1.2, 3.0)
var _static := false
var _at := Vector3.ZERO
var _look := Vector3.ZERO
var _a: ZombieBrain
var _b: ZombieBrain
var _c: ZombieBrain
var _all: Array[ZombieBrain] = []


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/zombie_review")
	var F := InputFrame
	steps = [
		{"teleport": "spawn", "t": 0.6, "yaw": 0, "pitch": 0, "view_tp": true, "slot": 0},
		{"call": _setup, "t": 0.5, "slot": 0},
		# --- scene 1: the shot
		{"call": _scene1, "t": 1.6, "slot": 1, "buttons": F.B_SECONDARY, "shot": "s1_idle"},
		{"call": _fire_from, "t": 0.25, "slot": 1, "buttons": F.B_SECONDARY, "tap": F.B_PRIMARY, "shot": "s1_shot"},
		{"call": _follow_a, "t": 1.5, "slot": 1, "shot": "s1_heard"},
		{"t": 20.0, "slot": 1, "until": func() -> bool: return _a.c.state.pos.x < 41.0, "after": 0.3, "shot": "s1_corridor"},
		{"t": 20.0, "slot": 1, "until": func() -> bool: return _a.c.state.pos.x < 33.0, "after": 0.2, "shot": "s1_door"},
		{"t": 25.0, "slot": 1, "until": func() -> bool: return _a.mode == ZombieBrain.Mode.CHASE, "after": 0.5, "shot": "s1_sees"},
		{"t": 25.0, "slot": 1, "until": func() -> bool: return _a.mode == ZombieBrain.Mode.ATTACK, "after": 0.3, "shot": "s1_attack_0"},
		{"t": 0.35, "slot": 1, "shot": "s1_attack_1"},
		{"t": 0.35, "slot": 1, "shot": "s1_attack_2"},
		# --- scene 2: the locked study door
		{"call": _scene2, "t": 2.0, "slot": 0, "shot": "s2_start"},
		{"t": 30.0, "until": func() -> bool: return _b.mode == ZombieBrain.Mode.BASH_DOOR, "after": 0.2, "shot": "s2_bash_0"},
		{"t": 0.7, "shot": "s2_bash_1"},
		{"t": 0.7, "shot": "s2_bash_2"},
		{"t": 30.0, "until": func() -> bool: return _study_door().broken, "after": 0.15, "shot": "s2_broken"},
		{"t": 0.6, "shot": "s2_through"},
		{"t": 1.2, "shot": "s2_after"},
		# --- scene 3: up the stairs
		{"call": _scene3, "t": 1.0, "slot": 0, "shot": "s3_start"},
		{"t": 20.0, "until": func() -> bool: return _c.c.state.pos.y > 1.5, "after": 0.2, "shot": "s3_climb"},
		{"t": 20.0, "until": func() -> bool: return _c.c.state.pos.y > 3.4, "after": 0.4, "shot": "s3_top"},
		{"t": 2.0, "shot": "s3_end"},
	]


func _setup() -> void:
	_cam = Camera3D.new()
	main.add_child(_cam)
	_cam.fov = 62.0
	_cam.far = 300.0
	_cam.current = true
	_dir = ZombieDirector.new()
	main.add_child(_dir)
	_dbg = ZombieDebug.new()
	_dbg.director = _dir
	_dbg.enabled = true
	main.add_child(_dbg)


func _zombie(arch: StringName, pos: Vector3, yaw: float, mode: int) -> ZombieBrain:
	var p := UltraNet.spawn_bot(ZombieFactory.name_for(arch, _all.size()), Transform3D(Basis(Vector3.UP, deg_to_rad(yaw)), pos))
	var b := _dir.add(p.character)
	b.mode = mode
	_all.append(b)
	return b


func _clear() -> void:
	for b in _all:
		UltraNet.despawn_bot(b.c.net_id)
		_dir.remove(b)
	_all.clear()


func _follow(n: Node3D, from: Vector3, off := Vector3(0, 1.0, 0)) -> void:
	_static = false
	_focus = n
	_from = from
	_focus_off = off


func _fixed(at: Vector3, look: Vector3) -> void:
	_static = true
	_at = at
	_look = look


func _scene1() -> void:
	var p: UltraCharacter = main.player
	p.teleport(Vector3(28, 0.05, 22.5), 0.0)
	(p.input_source as BotInputSource).live_yaw = 0.0
	_a = _zombie(&"walker", Vector3(46, 0.05, 21), 90.0, ZombieBrain.Mode.IDLE)
	_follow(_a.c.visual_root, Vector3(-2.6, 1.6, -2.6), Vector3(0, 1.0, 0))


func _fire_from() -> void:
	_fixed(Vector3(24.0, 2.4, 10.0), Vector3(28, 1.2, 21))


func _follow_a() -> void:
	_follow(_a.c.visual_root, Vector3(-2.8, 1.5, -2.8), Vector3(0, 1.0, 0))


func _scene2() -> void:
	_clear()
	var p: UltraCharacter = main.player
	p.teleport(Vector3(9, 0.05, 26.5), 0.0)
	_b = _zombie(&"walker", Vector3(4, 0.05, 36), 0.0, ZombieBrain.Mode.CHASE)
	_b.target = p
	_b.last_seen = p.state.pos
	_fixed(Vector3(9.4, 1.8, 31.2), Vector3(7.6, 1.2, 35.0))


func _study_door() -> UltraDoor:
	return main.map.door("d_study_corr")


func _scene3() -> void:
	_clear()
	var p: UltraCharacter = main.player
	p.teleport(Vector3(28, 3.7, 26.5), 0.0)
	_c = _zombie(&"runner", Vector3(28, 0.05, 19), 0.0, ZombieBrain.Mode.CHASE)
	_c.target = p
	_c.last_seen = p.state.pos
	_fixed(Vector3(26.5, 2.4, 22.8), Vector3(20.2, 2.2, 21.0))


func _process(delta: float) -> void:
	super(delta)
	# Keep the chasers on the scent: they can't see through walls and the tour wants the whole trip.
	if _b != null and _b.mode == ZombieBrain.Mode.CHASE:
		_b.last_seen_t = _dir.now
		_b.last_seen = main.player.state.pos
	if _c != null:
		_c.last_seen_t = _dir.now
		_c.last_seen = main.player.state.pos
	if _cam == null:
		return
	_cam.current = true
	if _static:
		_cam.global_position = _at
		_cam.look_at(_look)
	elif _focus != null and is_instance_valid(_focus):
		var f := _focus.global_position + _focus_off
		_cam.global_position = f + _from
		_cam.look_at(f)
