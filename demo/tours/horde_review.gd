extends UltraTour
## Review tour: the zombie sandbox. The gate, the foyer with its buttons, the Great Hall; then the wave
## button: the horde converges on the player (kept alive, shotgun in hand, sweeping the hall).
##   godot --path . --resolution 1280x720 -- --map=mansion --tour=horde_review --out=C:/Dev/verify/ultra/review/horde_review

var _cam: Camera3D
var _free := false
var _at := Vector3.ZERO
var _look := Vector3.ZERO


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/horde_review")
	var F := InputFrame
	steps = [
		{"teleport": "spawn", "t": 4.0, "yaw": 0, "pitch": 0, "view_tp": true, "slot": 0, "shot": "gate"},
		{"call": _setup_cam, "t": 0.2},
		{"call": _free_cam.bind(Vector3(21.0, 1.7, 26.0), Vector3(16.3, 1.3, 32.0)), "t": 0.8, "shot": "buttons"},
		{"call": _free_cam.bind(Vector3(28, 2.2, 28.5), Vector3(28, 2.4, 9.0)), "t": 0.8, "shot": "hall"},
		{"call": _to_hall, "t": 1.5, "slot": 3, "yaw": 0, "pitch": 0, "view_tp": true, "buttons": F.B_SECONDARY, "shot": "hall_ready"},
		{"call": _wave, "t": 2.0, "slot": 3, "buttons": F.B_SECONDARY, "yaw_rate": -18, "shot": "wave_0"},
	]
	for k in 8:
		steps.append({"t": 0.1, "slot": 3, "buttons": F.B_SECONDARY | F.B_PRIMARY, "tap": F.B_PRIMARY, "yaw_rate": 22 if k % 2 == 0 else -22})
		steps.append({"t": 2.3, "slot": 3, "buttons": F.B_SECONDARY, "yaw_rate": 22 if k % 2 == 0 else -22, "shot": "wave_%d" % (k + 1)})
	steps.append({"call": _free_cam.bind(Vector3(28, 6.0, 30.5), Vector3(28, 0.8, 18.0)), "t": 1.0, "slot": 3, "shot": "overview"})


func _setup_cam() -> void:
	_cam = Camera3D.new()
	main.add_child(_cam)
	_cam.fov = 70.0
	_cam.far = 300.0


func _free_cam(at: Vector3, look: Vector3) -> void:
	_free = true
	_at = at
	_look = look


func _to_hall() -> void:
	_free = false
	var p: UltraCharacter = main.player
	p.teleport(Vector3(28, 0.05, 25.0), 0.0)
	(p.input_source as BotInputSource).live_yaw = 0.0


func _wave() -> void:
	main.sandbox.trigger_wave(12)


var _ft: Array[float] = []
var _ft_t := 0.0


func _process(delta: float) -> void:
	super(delta)
	_ft.append(delta)
	_ft_t += delta
	if _ft_t >= 3.0:
		_ft_t = 0.0
		var sum := 0.0
		var worst := 0.0
		for d in _ft:
			sum += d
			worst = maxf(worst, d)
		var alive: int = main.sandbox.alive() if main.sandbox and main.sandbox.director else 0
		print("PERF primitives %d draw calls %d objects %d process %.1f ms physics %.1f ms nodes %d phys objects %d" % [int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)), int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)), int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)), Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0, int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)), int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS))])
		print("FRAMES %d frames, avg %.1f ms (%.0f fps), worst %.1f ms; %d zombies alive, %d hunting" % [_ft.size(), sum / _ft.size() * 1000.0, _ft.size() / sum, worst * 1000.0, alive, main.sandbox.hunting() if main.sandbox and main.sandbox.director else 0])
		_ft.clear()
	if main.player:
		main.player.state.hp = 100.0                 # (the tour wants to film the whole fight)
	if _cam == null:
		return
	if _free:
		_cam.current = true
		_cam.global_position = _at
		_cam.look_at(_look)
	else:
		_cam.current = false
		var rigs := main.get_tree().root.find_children("*", "UltraCameraRig", true, false)
		if not rigs.is_empty():
			((rigs[0] as UltraCameraRig).camera as Camera3D).current = true
