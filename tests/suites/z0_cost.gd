extends UltraTestSuite
## Stage 0b: what does a character cost? N = 1 / 10 / 20 / 40 bots walking about on a flat floor, as
## server-only characters (no body) and as full-visual characters (the mannequin's whole stack:
## AnimationTree, modifiers, equipment, ragdoll, BodyFX). Headless numbers are the script / physics /
## animation cost (no rendering). Reported, not asserted - they set the zombie performance budgets
## (and, once the lite tier exists, prove it).

const COUNTS := [1, 10, 20, 40]


## Slow (minutes) and report-only: runs when asked for (`--suite=z0`), not as part of `--suite=all`.
func _wanted() -> bool:
	return OS.get_cmdline_user_args().has("--suite=z0")

var _floor: StaticBody3D


func before_each() -> void:
	_floor = StaticBody3D.new()
	_floor.collision_layer = UltraLayers.WORLD_STATIC
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(400, 1, 400)
	cs.shape = bs
	cs.position = Vector3(0, -0.5, 0)
	_floor.add_child(cs)
	add_child(_floor)
	UltraNet.world_root = self
	UltraNet.spawn_transform = func(_p: NetPlayer) -> Transform3D: return Transform3D(Basis(), Vector3(0, 0.05, 0))
	UltraNet.local_input_factory = func(_i: int) -> InputSource: return BotInputSource.new()
	_set_factory(false)
	UltraNet.start_offline(1)
	await ticks(3)


func after_each() -> void:
	UltraNet.stop()
	UltraNet.character_factory = Callable()
	UltraNet.local_input_factory = Callable()
	UltraNet.spawn_transform = Callable()
	if is_instance_valid(_floor):
		_floor.queue_free()
	await super.after_each()


func _set_factory(visuals: bool) -> void:
	UltraNet.character_factory = func(_p: NetPlayer) -> UltraCharacter:
		var ch := UltraCharacter.new()
		ch.profile = (load("res://addons/ultra_controller/profiles/fps.tres") as MovementProfile).duplicate(true)
		ch.body_profile = load("res://assets/characters/mannequin/mannequin_body_profile.tres")
		ch.build_visuals = visuals
		return ch


func _spawn(n: int, visuals: bool) -> Array[int]:
	_set_factory(visuals)
	var ids: Array[int] = []
	for i in n:
		var ang := TAU * float(i) / maxf(n, 1.0)
		var at := Vector3(cos(ang), 0.05, sin(ang)) * (3.0 + 0.4 * n)
		var p := UltraNet.spawn_bot("Z%d" % i, Transform3D(Basis(Vector3.UP, ang), at))
		# Everyone shambles along its own heading, slowly (walk gait, a bit under full deflection).
		(p.character.input_source as BotInputSource).set_steps([{"ticks": 100000, "move": Vector2(0, 0.6), "yaw": ang + PI}])
		ids.append(p.id)
	return ids


## Wall time per frame over `n` frames: [mean ms, p95 ms, worst ms]. (`--fixed-fps` runs frames back
## to back, so this is the real compute cost of a frame; the engine's TIME_PHYSICS_PROCESS monitor
## read nonsense here - 62 ms for an empty scene.)
func _frames(n: int) -> Array:
	var ts: Array[float] = []
	var last := Time.get_ticks_usec()
	for i in n:
		await get_tree().physics_frame
		var now := Time.get_ticks_usec()
		ts.append((now - last) / 1000.0)
		last = now
	var sum := 0.0
	for t in ts:
		sum += t
	ts.sort()
	return [sum / n, ts[int(n * 0.95)], ts[n - 1]]


func test_character_cost() -> void:
	if not _wanted():
		return
	await ticks(120)
	var base: Array = await _frames(120)
	var rows := ["%-14s %4s %9s %8s %9s %8s %9s" % ["config", "N", "mean ms", "p95 ms", "worst ms", "nodes", "spawn ms"]]
	rows.append("%-14s %4d %9.2f %8.2f %9.2f %8d %9s" % ["empty", 0, base[0], base[1], base[2], int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)), "-"])
	var per := {}
	for visuals: bool in [false, true]:
		var label := "full visuals" if visuals else "server only"
		for n: int in COUNTS:
			var t0 := Time.get_ticks_usec()
			var ids := _spawn(n, visuals)
			var spawn_ms := (Time.get_ticks_usec() - t0) / 1000.0
			await ticks(90)                                       # (get going; let the first-frame work settle)
			var m: Array = await _frames(240)
			var nodes := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
			rows.append("%-14s %4d %9.2f %8.2f %9.2f %8d %9.1f" % [label, n, m[0], m[1], m[2], nodes, spawn_ms])
			per["%s %d" % [label, n]] = [(m[0] - base[0]) / n, spawn_ms / n]
			for id in ids:
				UltraNet.despawn_bot(id)
			await ticks(30)
	info("per-character cost (wall ms per frame, headless: no rendering)
  " + "
  ".join(rows))
	var lines := []
	for k: String in per:
		lines.append("%s: %.3f ms per character per frame, %.1f ms to spawn each" % [k, per[k][0], per[k][1]])
	info("derived (over the empty baseline)
  " + "
  ".join(lines))
	check(true, "cost table recorded")


## Where a server-only character's ~0.3 ms goes: 40 of them with one cost driver switched off at a
## time (and all of them), to see what a zombie's lighter motor path should drop.
func test_sim_cost_breakdown() -> void:
	if not _wanted():
		return
	await ticks(120)
	var base: Array = await _frames(120)
	var variants := [
		["baseline", func(_c: UltraCharacter) -> void: pass],
		["no quantize", func(c: UltraCharacter) -> void: c.quantize_state = false],
		["no transition hooks", func(c: UltraCharacter) -> void: c.motor.transition_hooks.clear()],
		["no edge balance", func(c: UltraCharacter) -> void: c.profile.enable_balance = false],
		["no soft collision", func(c: UltraCharacter) -> void: c.profile.character_collision = MovementProfile.CharacterCollision.NONE],
		["all four off", func(c: UltraCharacter) -> void:
			c.quantize_state = false
			c.motor.transition_hooks.clear()
			c.profile.enable_balance = false
			c.profile.character_collision = MovementProfile.CharacterCollision.NONE],
	]
	var rows := []
	for v: Array in variants:
		var ids: Array[int] = []
		_set_factory(false)
		for i in 40:
			var ang := TAU * float(i) / 40.0
			var p := UltraNet.spawn_bot("Z%d" % i, Transform3D(Basis(Vector3.UP, ang), Vector3(cos(ang), 0.05, sin(ang)) * 20.0))
			(p.character.input_source as BotInputSource).set_steps([{"ticks": 100000, "move": Vector2(0, 0.6), "yaw": ang + PI}])
			(v[1] as Callable).call(p.character)
			ids.append(p.id)
		await ticks(90)
		var m: Array = await _frames(240)
		rows.append("%-22s %6.2f ms per frame, %.3f ms per character" % [v[0], m[0], (m[0] - base[0]) / 40.0])
		for id in ids:
			UltraNet.despawn_bot(id)
		await ticks(30)
	info("40 server-only characters, one cost driver off at a time\n  " + "\n  ".join(rows))
	check(true, "breakdown recorded")
