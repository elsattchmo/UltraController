extends UltraTestSuite
## Marksman stage V7: every motor state shows its own node, as the UltraController shows it - scripted courses on the
## playground (mantle, ledge hang + shimmy, vault, ladder, rope, running leap, fall, drop to hang, slide, roll, swim,
## dive). Per course: the loco nodes the driver went through (the expected ones must be among them), no NaN in the
## shown skeleton and no bone faster than SPEED_MAX.

const Id := MotorState.Id
const FPS := "res://addons/ultra_controller/profiles/fps.tres"
const SPEED_MAX := 25.0


func _marksman(at: Vector3, yaw: float) -> MarksmanCharacter:
	var c := MarksmanCharacter.new()
	c.motion_matching = true
	c.profile = (load(FPS) as MovementProfile).duplicate(true)
	c.body_profile = CharacterModels.body_profile("mannequin")
	c.build_visuals = true
	var b := BotInputSource.new()
	b.name = "InputSource"
	c.add_child(b)
	c.input_source = b
	c.position = at
	c.rotation.y = yaw
	add_child(c)
	b.body = c
	chars.append(c)
	return c


static func frame(move: Vector2, buttons := 0, yaw := 0.0, pitch := 0.0) -> InputFrame:
	var f := InputFrame.new()
	f.move = move
	f.buttons = buttons
	f.yaw = yaw
	f.pitch = pitch
	return f


## Drive `c` with fn(tick, c) -> InputFrame until done(c) or `limit` ticks: the loco nodes and motor states seen,
## the fastest shown bone (m/s), NaN.
func _course(c: MarksmanCharacter, limit: int, fn: Callable, done: Callable) -> Dictionary:
	var out := {"nodes": [], "states": [], "fast": 0.0, "fast_bone": "", "nan": false}
	var sk := c.skeleton
	var last := {}
	var probe := func() -> void:
		var dt := 1.0 / 60.0
		if OS.get_environment("G9_TRACE") != "":
			var hb := sk.find_bone("Hips")
			var r := c.ragdoll as SinewRagdoll
			var cp: Array = r.modifier.clip_pose if r and r.modifier else []
			var rb := sk.find_bone("Root")
			print("YAW f%d sk %.1f body %.1f node %s" % [Engine.get_physics_frames(), rad_to_deg(sk.global_basis.get_euler().y), rad_to_deg(c.state.body_yaw), c.anim._cur_loco])
			print("LP f%d root %s %s hips %s %s" % [Engine.get_physics_frames(), sk.get_bone_pose_position(rb).snappedf(0.01) if rb >= 0 else Vector3.ZERO, sk.get_bone_pose_rotation(rb).get_euler().snappedf(0.01) if rb >= 0 else Vector3.ZERO, sk.get_bone_pose_position(hb).snappedf(0.01), sk.get_bone_pose_rotation(hb).get_euler().snappedf(0.01)])
			var inn: InertialBlendModifier = c.anim.inertial
			if inn:
				print("IN f%d active %s t %.3f jumps %d idx %d infl %.2f act %s" % [Engine.get_physics_frames(), inn._active, inn._t, inn.jumps, inn.get_index(), inn.influence, inn.active])
			print("TR f%d clip-hips %s node %s st %s root %s hips %s lhand %s pos %s blend %.2f" % [Engine.get_physics_frames(), (sk.global_transform * (cp[0] as Transform3D).origin).snappedf(0.01) if not cp.is_empty() else Vector3.ZERO, c.anim._cur_loco, Id.keys()[c.state.state],
					sk.global_position.snappedf(0.01), (sk.global_transform * sk.get_bone_global_pose(hb).origin).snappedf(0.01),
					(sk.global_transform * sk.get_bone_global_pose(sk.find_bone("LeftHand")).origin).snappedf(0.01), c.state.pos.snappedf(0.01),
					r.modifier.blend if r and r.modifier else -1.0])
		for b in sk.get_bone_count():
			if sk.get_bone_name(b).contains("leaf") or sk.get_bone_name(b) == "Root":
				continue          # (end markers of the rig, no pose of their own; the root bone is the capsule's floor)
			var p := sk.global_transform * sk.get_bone_global_pose(b).origin
			if not p.is_finite():
				out.nan = true
				continue
			if last.has(b):
				var v: float = p.distance_to(last[b]) / dt
				if v > SPEED_MAX and OS.get_environment("G9_DBG") != "":
					print("G9 f%d %s %.1f m/s node %s state %s" % [Engine.get_physics_frames(), sk.get_bone_name(b), v, c.anim._cur_loco, Id.keys()[c.state.state]])
				if v > float(out.fast):
					out.fast = v
					out.fast_bone = sk.get_bone_name(b)
			last[b] = p
	if OS.get_environment("G9_TRACE") != "" and out.nodes.is_empty():
		var lp := (c.anim.tree.tree_root as AnimationNodeBlendTree).get_node("loco") as AnimationNodeStateMachine
		for nn in ["drop_hang", "air_run", "land_heavy", "hang", "ladder", "prone_down"]:
			if lp.has_node(nn):
				var nd := lp.get_node(nn)
				var an := ""
				if nd is AnimationNodeBlendTree and (nd as AnimationNodeBlendTree).has_node("clip"):
					an = String(((nd as AnimationNodeBlendTree).get_node("clip") as AnimationNodeAnimation).animation)
				elif nd is AnimationNodeAnimation:
					an = String((nd as AnimationNodeAnimation).animation)
				print("NODE %s anim '%s' in player %s" % [nn, an, c.anim.player.has_animation(an) if an != "" else false])
				if an != "" and c.anim.player.has_animation(an):
					var A := c.anim.player.get_animation(an)
					for ti in A.get_track_count():
						var tp := String(A.track_get_path(ti))
						if tp.ends_with(":Hips") or tp.ends_with(":Root"):
							print("   track %s type %d keys %d first %s last %s len %.2f" % [tp, A.track_get_type(ti), A.track_get_key_count(ti), A.track_get_key_value(ti, 0), A.track_get_key_value(ti, A.track_get_key_count(ti) - 1), A.length])
	# (A teleport or respawn moves everything at once: the probe starts after the first frames.)
	await ticks(4)
	sk.skeleton_updated.connect(probe)
	var src := c.input_source as BotInputSource
	var k := [0]
	src.driver = func(_t: int, _s: BotInputSource) -> InputFrame: return fn.call(k[0], c)
	for i in limit:
		await ticks(1)
		k[0] = i
		var n: String = c.anim._cur_loco
		if out.nodes.is_empty() or out.nodes[-1] != n:
			out.nodes.append(n)
		var st: String = Id.keys()[c.state.state]
		if out.states.is_empty() or out.states[-1] != st:
			out.states.append(st)
		if done.call(c):
			break
	src.driver = Callable()
	sk.skeleton_updated.disconnect(probe)
	return out


func _report(name: String, r: Dictionary, want: Array) -> Array:
	info("%-16s nodes %s | states %s | fastest %s %.1f m/s" % [name, " ".join(r.nodes), " ".join(r.states), r.fast_bone, r.fast])
	var bad := []
	for w: String in want:
		if not w in r.nodes:
			bad.append("%s: no %s (%s)" % [name, w, " ".join(r.nodes)])
	if r.nan:
		bad.append("%s: NaN" % name)
	if float(r.fast) > SPEED_MAX:
		bad.append("%s: %s at %.1f m/s" % [name, r.fast_bone, r.fast])
	return bad


func _done(c: MarksmanCharacter) -> void:
	chars.erase(c)
	c.queue_free()
	await ticks(3)


func _at(m: String) -> Array:
	var n := marker(m)
	return [n.global_position, n.global_rotation.y] if n else [Vector3.ZERO, 0.0]


func test_every_state_shows_its_node() -> void:
	load_playground()
	await ticks(2)
	var bad := []
	var never := func(_c: MarksmanCharacter) -> bool: return false
	# Mantle onto 1 m, hang from 2.5 m and climb up.
	for h: int in [100, 250]:
		var a := _at("ledge_%d" % h)
		var c := _marksman(a[0], a[1])
		await ticks(20)
		var top := h / 100.0
		var r: Dictionary = await _course(c, 400, func(_k: int, ch: MarksmanCharacter) -> InputFrame:
			var up := ch.state.is_grounded() and ch.state.pos.y > top - 0.2
			return frame(Vector2(0, 1) if not up else Vector2.ZERO, InputFrame.B_JUMP if ch.state.pos.z < -27.3 else 0),
			func(ch: MarksmanCharacter) -> bool: return ch.state.is_grounded() and ch.state.pos.y > top - 0.15 and ch.state.state in [Id.IDLE, Id.MOVE] and ch.state.state_time > 0.3)
		bad += _report("ledge %.1f m" % top, r, ["climb_up"] if h == 100 else ["hang", "climb_up"])
		await _done(c)
	# Vault at a sprint.
	var av := _at("parkour_start")
	var cv := _marksman(av[0], av[1])
	await ticks(20)
	var rv: Dictionary = await _course(cv, 240, func(_k: int, ch: MarksmanCharacter) -> InputFrame:
		return frame(Vector2(0, 1), InputFrame.B_SPRINT | (InputFrame.B_JUMP if ch.state.pos.z < -14.4 else 0)),
		func(ch: MarksmanCharacter) -> bool: return ch.state.pos.z < -17.5 and ch.state.is_grounded())
	bad += _report("vault", rv, ["vault"])
	await _done(cv)
	# Ladder up.
	var al := _at("parkour_ladder")
	var cl := _marksman(al[0], al[1])
	await ticks(20)
	var rl: Dictionary = await _course(cl, 600, func(_k: int, _ch: MarksmanCharacter) -> InputFrame: return frame(Vector2(0, 1)),
		func(ch: MarksmanCharacter) -> bool: return ch.state.pos.y > 5.9 and ch.state.is_grounded())
	bad += _report("ladder", rl, ["ladder"])
	await _done(cl)
	# Ledge hang under the overhang and shimmy right.
	var ash := _at("parkour_shimmy")
	var csh := _marksman(ash[0], ash[1])
	await ticks(20)
	var shim := [0.0]
	var rsh: Dictionary = await _course(csh, 420, func(k: int, ch: MarksmanCharacter) -> InputFrame:
		if ch.state.state == Id.LEDGE_HANG and ch.state.state_time > 0.4:
			shim[0] = maxf(shim[0], float(ch.anim._hang_dir))
			return frame(Vector2(1, 0))
		return frame(Vector2(0, 1), InputFrame.B_JUMP if ch.state.pos.z < -44.9 else 0),
		func(ch: MarksmanCharacter) -> bool: return ch.state.trav_s > 0.5)
	bad += _report("shimmy", rsh, ["hang"])
	info("shimmy blend reached %.2f" % shim[0])
	if shim[0] < 0.5:
		bad.append("shimmy: the hang never blended to the shimmy (%.2f)" % shim[0])
	await _done(csh)
	# Rope: run, jump, catch it, pump, let go.
	var ar := _at("parkour_rope")
	var cr := _marksman(ar[0], ar[1])
	await ticks(20)
	var rr: Dictionary = await _course(cr, 420, func(k: int, ch: MarksmanCharacter) -> InputFrame:
		if ch.state.state == Id.ROPE:
			return frame(Vector2(0, 1.0 if ch.state.vel.z < 0.0 else -1.0), InputFrame.B_JUMP if ch.state.state_time > 3.0 else 0)
		return frame(Vector2(0, 1), InputFrame.B_SPRINT | (InputFrame.B_JUMP if ch.state.pos.z < -55.4 and ch.state.is_grounded() else 0)),
		never)
	bad += _report("rope", rr, ["rope"])
	await _done(cr)
	# Open ground: a running leap, a standing jump, a slide, a roll.
	var ag := _at("spawn")
	var cg := _marksman(ag[0] + Vector3(-16, 0, -3), 0.0)
	await ticks(30)
	var rg: Dictionary = await _course(cg, 110, func(k: int, _ch: MarksmanCharacter) -> InputFrame:
		return frame(Vector2(0, 1), InputFrame.B_SPRINT | (InputFrame.B_JUMP if k == 70 else 0)), never)
	bad += _report("running leap", rg, ["air_run"])
	var rj: Dictionary = await _course(cg, 90, func(k: int, _ch: MarksmanCharacter) -> InputFrame:
		return frame(Vector2.ZERO, InputFrame.B_JUMP if k == 30 else 0), never)
	bad += _report("standing jump", rj, ["air"])
	var rs: Dictionary = await _course(cg, 150, func(k: int, _ch: MarksmanCharacter) -> InputFrame:
		return frame(Vector2(0, 1), InputFrame.B_SPRINT | (InputFrame.B_CROUCH if k >= 70 and k < 74 else 0)), never)
	bad += _report("slide", rs, ["slide"])
	# Down to prone and back up (unarmed, then with the rifle).
	for item: StringName in [&"", &"rifle"]:
		var sl := 0
		if item != &"":
			UltraItems.give(cg, item)
			for i in cg.inventory.size():
				var it := cg.inventory.get_slot(i)
				if it and it.def_id == item:
					sl = i + 1
		var bits := InputFrame.B_CRAWL | InputFrame.B_CROUCH
		bot(cg).set_steps([{"ticks": 60, "slot": sl}])
		await ticks(60)
		var rpd: Dictionary = await _course(cg, 220, func(k: int, _ch: MarksmanCharacter) -> InputFrame:
			var f := frame(Vector2.ZERO, bits if k < 110 else 0)
			f.want_slot = sl
			return f, never)
		bad += _report("prone %s" % ("rifle" if item != &"" else "unarmed"), rpd, ["prone_down", "prone", "prone_up"])
	await _done(cg)
	# Off the cliff top: crouched lowers into a hang (drop_hang), standing walks off and falls.
	var cc := _marksman(Vector3(128.5, 8.05, -24.6), PI)
	await ticks(30)
	var rd: Dictionary = await _course(cc, 300, func(_k: int, _ch: MarksmanCharacter) -> InputFrame:
		return frame(Vector2(0, 1), InputFrame.B_CROUCH, PI),
		func(ch: MarksmanCharacter) -> bool: return ch.state.state == Id.LEDGE_HANG and ch.state.state_time > 0.5)
	bad += _report("drop to hang", rd, ["drop_hang", "hang"])
	await _done(cc)
	var cf := _marksman(Vector3(128.5, 8.05, -24.6), PI)
	await ticks(30)
	var rf: Dictionary = await _course(cf, 200, func(_k: int, _ch: MarksmanCharacter) -> InputFrame:
		return frame(Vector2(0, 1), 0, PI), func(ch: MarksmanCharacter) -> bool: return ch.state.pos.y < 1.0)
	bad += _report("walk off a cliff", rf, ["fall"])
	await _done(cf)
	# Water: swim, then look down and dive.
	var ap := _at("pool_deep_side")
	var cp := _marksman(ap[0], ap[1])
	await ticks(20)
	var yaw := -PI * 0.5
	var rp: Dictionary = await _course(cp, 600, func(_k: int, ch: MarksmanCharacter) -> InputFrame:
		if ch.state.state in [Id.SWIM, Id.DIVE] and ch.state.state_time > 1.5 or ch.state.state == Id.DIVE:
			return frame(Vector2(0, 1), 0, yaw, -0.9)
		return frame(Vector2(0, 1) if ch.state.state != Id.SWIM else Vector2.ZERO, 0, yaw),
		func(ch: MarksmanCharacter) -> bool: return ch.state.state == Id.DIVE and ch.state.state_time > 1.0)
	bad += _report("swim + dive", rp, ["swim", "dive"])
	await _done(cp)
	check(bad.is_empty(), "every state shows its node, no NaN, nothing faster than %.0f m/s (%s)" % [SPEED_MAX, "; ".join(bad)])
