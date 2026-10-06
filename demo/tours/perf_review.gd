extends UltraTour
## Frame-time experiments in the mansion sandbox (windowed): the camera sits in the Great Hall, all the
## zombies are in, standing; each step switches one thing off and prints the frame time over the next
## seconds, so the cost of rendering features and zombie parts shows in numbers.
##   godot --path . --resolution 1280x720 -- --map=mansion --tour=perf_review

var _cam: Camera3D
var _ft: Array[float] = []
var _label := ""
var _env: Environment


func _build() -> void:
	steps = [
		{"teleport": "spawn", "t": 5.0, "yaw": 0, "pitch": 0, "view_tp": true},
		{"call": _setup, "t": 22.0},
		{"call": _measure.bind("warm-up"), "t": 3.0},
		{"call": _measure.bind("baseline (all on)"), "t": 3.0},
		{"call": _measure.bind("SSAO off"), "t": 3.0},
		{"call": _measure.bind("glow off"), "t": 3.0},
		{"call": _measure.bind("fog off"), "t": 3.0},
		{"call": _measure.bind("moon shadow off"), "t": 3.0},
		{"call": _measure.bind("omni shadows off"), "t": 3.0},
		{"call": _measure.bind("all zombie casters off (no zombie shadows)"), "t": 3.0},
		{"call": _measure.bind("all lights off"), "t": 3.0},
		{"call": _measure.bind("zombie meshes hidden"), "t": 3.0},
		{"call": _measure.bind("+ characters' _process off"), "t": 3.0},
		{"call": _measure.bind("+ BodyFX / ragdoll / anim driver off"), "t": 3.0},
		{"call": _measure.bind("+ AnimationTrees off"), "t": 3.0},
		{"call": _measure.bind("+ skeleton modifiers off"), "t": 3.0},
		{"call": _measure.bind("+ visual roots hidden"), "t": 3.0},
		{"call": _measure.bind("+ brains / director off"), "t": 3.0},
		{"call": _measure.bind("+ characters' physics off"), "t": 3.0},
		{"call": _measure.bind("done"), "t": 0.5},
	]


func _setup() -> void:
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	print("PERF adapter: ", RenderingServer.get_video_adapter_name(), " | ", Engine.get_physics_ticks_per_second(), " Hz physics, max steps ", Engine.max_physics_steps_per_frame)
	_cam = Camera3D.new()
	main.add_child(_cam)
	_cam.fov = 70.0
	_cam.far = 300.0
	_cam.current = true
	_cam.global_position = Vector3(28, 2.4, 27.0)
	_cam.look_at(Vector3(28, 1.2, 16.0))
	# The player somewhere out of the way, the sandbox's zombies standing.
	var p: UltraCharacter = main.player
	p.teleport(Vector3(28, 0.05, 20.0), 0.0)
	for b in main.sandbox.director.brains:
		b.reset(ZombieBrain.Mode.CHASE, p)
	var we := main.map.get_node("WorldEnvironment") as WorldEnvironment
	_env = we.environment


func now_far() -> float:
	return main.sandbox.director.now + 1e6


func _measure(next: String) -> void:
	if not _ft.is_empty():
		var sum := 0.0
		var worst := 0.0
		for d in _ft:
			sum += d
			worst = maxf(worst, d)
		var vp := get_viewport().get_viewport_rid()
		print("PERF %-44s %5.1f ms avg (%3.0f fps), worst %5.1f ms, %d primitives, %d draw calls | process %.1f physics %.1f ms | render cpu %.1f gpu %.1f ms" % [_label, sum / _ft.size() * 1000.0, _ft.size() / sum, worst * 1000.0, int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)), int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)), Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0, RenderingServer.viewport_get_measured_render_time_cpu(vp), RenderingServer.viewport_get_measured_render_time_gpu(vp)])
	_ft.clear()
	_label = next
	match next:
		"SSAO off":
			_env.ssao_enabled = false
		"glow off":
			_env.glow_enabled = false
		"fog off":
			_env.fog_enabled = false
		"moon shadow off":
			(main.map.get_node("Moon") as DirectionalLight3D).shadow_enabled = false
		"omni shadows off":
			for l in main.map.get_node("Lights").get_children():
				(l as Light3D).shadow_enabled = false
		"all zombie casters off (no zombie shadows)":
			for b in main.sandbox.director.brains:
				if b.c.body_mesh():
					b.c.body_mesh().cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		"all lights off":
			for l in main.map.get_node("Lights").get_children():
				(l as Light3D).visible = false
		"zombie meshes hidden":
			for b in main.sandbox.director.brains:
				if b.c.body_mesh():
					b.c.body_mesh().visible = false
		"+ characters' _process off":
			for b in main.sandbox.director.brains:
				b.c.set_process(false)
		"+ BodyFX / ragdoll / anim driver off":
			for b in main.sandbox.director.brains:
				b.c.body_fx.set_process(false)
				b.c.body_fx.set_physics_process(false)
				b.c.ragdoll.set_process(false)
				b.c.ragdoll.set_physics_process(false)
				b.c.anim.set_process(false)
		"+ AnimationTrees off":
			for b in main.sandbox.director.brains:
				b.c.anim.tree.active = false
		"+ skeleton modifiers off":
			for b in main.sandbox.director.brains:
				for ch in b.c.skeleton.get_children():
					if ch is SkeletonModifier3D:
						(ch as SkeletonModifier3D).active = false
		"+ visual roots hidden":
			for b in main.sandbox.director.brains:
				b.c.visual_root.visible = false
		"+ brains / director off":
			main.sandbox.director.set_physics_process(false)
		"+ characters' physics off":
			for b in main.sandbox.director.brains:
				b.c.set_physics_process(false)
				b.c.process_mode = Node.PROCESS_MODE_DISABLED


func _process(delta: float) -> void:
	super(delta)
	_ft.append(delta)
	if _cam:
		_cam.current = true
	if main.player:
		main.player.state.hp = 100.0
