extends UltraTestSuite
## Marksman stage V7: every motor state shows its own node, as the UltraController shows it - scripted courses on the
## playground (mantle, ledge hang + shimmy, vault, ladder, rope, running leap, fall, drop to hang, slide, roll, swim,
## dive). Per course: the loco nodes the driver went through (the expected ones must be among them), no NaN in the
## shown skeleton and no bone faster than SPEED_MAX.

const Id := MotorState.Id
const FPS := "res://addons/ultra_controller/profiles/fps.tres"
const SPEED_MAX := 25.0
## A strike's hands are fast for real (the clip time-scaled so contact lands on the sim's): 26-29 m/s through the swing.
const SWING_MAX := 40.0


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


func _report(name: String, r: Dictionary, want: Array, limit := SPEED_MAX) -> Array:
	info("%-16s nodes %s | states %s | fastest %s %.1f m/s" % [name, " ".join(r.nodes), " ".join(r.states), r.fast_bone, r.fast])
	var bad := []
	for w: String in want:
		if not w in r.nodes:
			bad.append("%s: no %s (%s)" % [name, w, " ".join(r.nodes)])
	if r.nan:
		bad.append("%s: NaN" % name)
	if float(r.fast) > limit:
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
		bad += _report("ledge %.1f m" % top, r, ["climb_up"] if h == 100 else ["catch", "climb_up"])
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
	bad += _report("standing jump", rj, ["hop"])
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
	# Melee: a bat swing standing (whole body) and walking (upper body), a gun-butt with the rifle up.
	for spec: Array in [[&"bat", InputFrame.B_PRIMARY, Vector2.ZERO], [&"bat", InputFrame.B_PRIMARY, Vector2(0, 1)], [&"rifle", InputFrame.B_MELEE, Vector2.ZERO],
			[&"rifle", InputFrame.B_MELEE, Vector2(0, 1)], [&"pistol", InputFrame.B_MELEE, Vector2.ZERO]]:
		var item: StringName = spec[0]
		UltraItems.give(cg, item)
		var msl := 0
		for i in cg.inventory.size():
			var it := cg.inventory.get_slot(i)
			if it and it.def_id == item:
				msl = i + 1
		bot(cg).set_steps([{"ticks": 70, "slot": msl}])
		await ticks(70)
		var swung := [0]
		var off := [0.0]
		var blow := [INF, INF]
		var gp := (cg.ragdoll as MarksmanRagdoll).gun_pass
		var rm: Dictionary = await _course(cg, 90, func(k: int, ch: MarksmanCharacter) -> InputFrame:
			if bool(ch.anim.tree.get("parameters/swing/active")):
				swung[0] += 1
			if gp.strike_w > 0.99:
				off[0] = maxf(off[0], gp.support_error)
			# At the blow (the sim's hit window): the stock leads (ahead of the muzzle along the facing) and the gun's top is up.
			var eqp := ch.get_node("Equipment") as UltraEquipmentVisual
			if spec[0] != &"bat" and ch.state.action == UltraActionLayer.Action.MELEE and absf(ch.state.action_t - 0.45) < 0.02 and eqp.held_node:
				var g := eqp.held_node.global_transform
				var fwd := Vector3(-sin(ch.state.body_yaw), 0, -cos(ch.state.body_yaw))
				var st_w := g * gp._stock_local.origin if gp._has_stock else g.origin
				var mz_w := g * gp._muzzle_local.origin
				blow[0] = (st_w - mz_w).dot(fwd)
				blow[1] = g.basis.y.normalized().y
			var f := frame(spec[2], int(spec[1]) if k >= 10 and k < 14 else 0)
			f.want_slot = msl
			return f, never)
		var name := "melee %s%s" % [item, " walking" if spec[2] != Vector2.ZERO else ""]
		bad += _report(name, rm, [], SWING_MAX)
		info("%s: swing one-shot active %d frames, support hand up to %.1f cm off the gun mid-strike; at the blow stock %+.2f m ahead of the muzzle, gun top up %.2f" % [name, swung[0], off[0] * 100.0, blow[0], blow[1]])
		if item == &"rifle" and off[0] > 0.03:
			bad.append("%s: the support hand left the gun (%.1f cm)" % [name, off[0] * 100.0])
		if item == &"rifle" and (blow[0] < 0.2 or blow[1] < 0.5):
			bad.append("%s: at the blow the stock must lead, the gun upright (stock %+.2f m, top up %.2f)" % [name, blow[0], blow[1]])
		if swung[0] < 10:
			bad.append("%s: no swing played (%d frames)" % [name, swung[0]])
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
