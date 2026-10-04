extends UltraTestSuite
## In-process netcode checks. Real multi-process runs (server + clients over ENet with
## simulated lag) are in `tools/verify.sh m2` (net_case).


func before_each() -> void:
	load_playground()
	await ticks(2)


func after_each() -> void:
	UltraNet.stop()
	UltraNet.character_factory = Callable()
	UltraNet.local_input_factory = Callable()
	UltraNet.spawn_transform = Callable()
	await super.after_each()


func _course() -> Array:
	return UltraBotCourses.get_course("course_full")


## Single-player runs through the session loop; it must produce exactly what the bare motor
## produces with the same inputs (same code path, no hidden latency or buffering).
func test_offline_session_equals_direct_sim() -> void:
	var finals := []
	# 1) bare character, stepped directly
	var c := spawn("speed_start", "res://addons/ultra_controller/profiles/fps.tres", false)
	c.self_simulate = false
	c.quantize_state = true
	c.state.quantize()
	await ticks(1)
	var b := bot(c)
	b.set_steps(_course())
	var t := 0
	while not b.is_done():
		c.simulate(b.sample(t), 1.0 / 60.0)
		t += 1
	finals.append(c.state.copy())
	var n_ticks := t
	c.queue_free()
	chars.erase(c)
	await ticks(2)
	# 2) the same through UltraNet offline
	UltraNet.world_root = self
	UltraNet.spawn_transform = func(_p: NetPlayer) -> Transform3D: return marker("speed_start").global_transform
	UltraNet.character_factory = func(_p: NetPlayer) -> UltraCharacter:
		var ch := UltraCharacter.new()
		ch.profile = (load("res://addons/ultra_controller/profiles/fps.tres") as MovementProfile).duplicate(true)
		ch.body_profile = load("res://assets/characters/mannequin/mannequin_body_profile.tres")
		ch.build_visuals = false
		return ch
	UltraNet.local_input_factory = func(_i: int) -> InputSource:
		var bi := BotInputSource.new()
		bi.set_steps(_course())
		return bi
	UltraNet.start_offline(1)
	var p: NetPlayer = UltraNet.local_players[0]
	check(p.role == NetPlayer.Role.AUTHORITY_LOCAL, "offline player is local authority")
	await ticks(n_ticks)
	finals.append(p.character.state.copy())
	var a: MotorState = finals[0]
	var z: MotorState = finals[1]
	info("direct %s  session %s" % [a.pos, z.pos])
	check(a.pos.distance_to(z.pos) < 1e-4, "offline session == direct simulation")


func test_quantize_is_idempotent() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 50:
		var s := MotorState.new()
		s.pos = Vector3(rng.randf_range(-500, 500), rng.randf_range(-50, 50), rng.randf_range(-500, 500))
		s.vel = Vector3(rng.randf_range(-30, 30), rng.randf_range(-30, 30), rng.randf_range(-30, 30))
		s.body_yaw = rng.randf_range(-10, 10)
		s.state = rng.randi_range(0, 10)
		s.height = rng.randf_range(0.6, 1.8)
		s.coyote_t = rng.randf_range(0, 0.12)
		s.quantize()
		var q := s.copy().quantize()
		if not check(s.diff(q) < 1e-6 and s.vel.is_equal_approx(q.vel), "quantize(quantize(s)) == quantize(s)"):
			return
	var fast := MotorState.new()
	fast.vel = Vector3(0, -40, 25)
	fast.quantize()
	near(fast.vel.y, -40.0, 0.01, "falling speed survives the codec")
	near(fast.vel.z, 25.0, 0.01, "sprint speed survives the codec")


func test_lagsim_orders_reliable_and_drops_only_unreliable() -> void:
	var sim := UltraLagSim.new()
	sim.configure(60, 40, 50)
	var got: Array[int] = []
	for i in 40:
		var k := i
		sim.send(func() -> void: got.append(k), true)
	var dropped := [0]
	for i in 200:
		sim.send(func() -> void: dropped[0] += 1, false)
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 200:
		sim.flush()
		await get_tree().process_frame
	check(got.size() == 40, "no reliable packet lost (%d/40)" % got.size())
	var sorted := got.duplicate()
	sorted.sort()
	check(got == sorted, "reliable packets keep their order")
	check(dropped[0] < 160 and dropped[0] > 40, "unreliable packets are dropped at ~50%% (%d/200 arrived)" % dropped[0])


func test_split_screen_two_local_players() -> void:
	UltraNet.world_root = self
	UltraNet.spawn_transform = func(np: NetPlayer) -> Transform3D:
		return marker("spawn" if np.id == 1 else "spawn_2").global_transform
	UltraNet.character_factory = func(_p: NetPlayer) -> UltraCharacter:
		var ch := UltraCharacter.new()
		ch.profile = (load("res://addons/ultra_controller/profiles/fps.tres") as MovementProfile).duplicate(true)
		ch.body_profile = load("res://assets/characters/mannequin/mannequin_body_profile.tres")
		return ch
	var lp := UltraLocalPlayers.new()
	add_child(lp)
	lp.reserve([["kbm"], ["joy0"]])
	UltraNet.start_offline(2)
	await ticks(3)
	check(UltraNet.local_players.size() == 2, "two local players")
	check(lp.local_count() == 2, "two panes")
	var a := UltraNet.local_players[0].character
	var b2 := UltraNet.local_players[1].character
	check(a.head_mesh.layers != b2.head_mesh.layers, "each player's head is on its own render layer")
	var src0 := a.input_source as LocalInputSource
	var src1 := b2.input_source as LocalInputSource
	check(src0.claimed_devices == PackedStringArray(["kbm"]) and src1.claimed_devices == PackedStringArray(["joy0"]), "devices claimed per player")
	var rigs := lp.find_children("CameraRig_*", "Node3D", true, false)
	check(rigs.size() == 2, "a camera rig per player (%d)" % rigs.size())
	for r: UltraCameraRig in rigs:
		var own := r.character.head_mesh.layers
		check((r.camera.cull_mask & own) == 0, "pane %d hides only its own head" % r.view_index)
	lp.queue_free()


func test_launcher_starts_and_kills_instances() -> void:
	var p := UltraLaunchPreset.new()
	p.instances = PackedStringArray(["headless|--offline --quit-after=20", "headless|--offline --quit-after=20"])
	var pids := UltraLauncher.launch(p)
	check(pids.size() == 2, "two instances started")
	await get_tree().create_timer(1.5).timeout
	var running := 0
	for pid in pids:
		if OS.is_process_running(pid):
			running += 1
	check(running == 2, "both instances running (%d)" % running)
	var killed := UltraLauncher.kill_all()
	check(killed >= 2, "kill_all stopped them (%d)" % killed)
	await get_tree().create_timer(0.5).timeout
	for pid in pids:
		check(not OS.is_process_running(pid), "instance %d stopped" % pid)
	var presets := UltraLauncher.presets()
	check(presets.size() >= 8, "launch presets available (%d)" % presets.size())
