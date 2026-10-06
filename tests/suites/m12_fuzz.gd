extends UltraTestSuite
## Input hammering: a bot mashes the controls the way a play-tester does - mouse flicks, ADS /
## crouch / sprint / prone toggled a few frames apart, jump taps, fire, reloads, gun-butts,
## weapon switches, first <-> third person - while the body and the camera are watched every
## frame (at skeleton_updated, in the body's own frame):
##   * pops: a jump in a core bone's acceleration (head / chest / hips) beyond what a body part
##     does on its own,
##   * the camera: its turn not explained by the aim it's given, its eye jerking about, roll,
##   * NaNs anywhere.
## Seeded: a reported seed replays exactly (`-- --seed=N --fuzz-ticks=M`).

const POINTS := ["Head", "UpperChest", "Hips", "LeftHand", "RightHand"]
const CORE := 3
## m/s^2 (second difference x 3600) of a core point in a frame. Steady gaits sit at 5-30, the
## transitions course allows 60 (gentle) / 200 (anything). Hammering inputs, a quick but smooth
## move reaches 200-250 (reported); a pop you see is > SEVERE (before this pass: 1000-2300).
const POP := 200.0
const SEVERE := 350.0
## The clips' own fast motion is real: a jump's take-off (from a crouch with a gun shouldered
## the body whips up after the camera-placed gun, ~390; the running leap's take-off ~480),
## dropping prone / getting up.
const POP_CLIP := {"air": 420.0, "air_run": 520.0, "prone_down": 360.0, "prone_up": 360.0}


func before_each() -> void:
	load_playground()
	await ticks(2)


class Fuzz:
	var rng := RandomNumberGenerator.new()
	var move := Vector2.ZERO
	var held := 0                         ## held buttons
	var tap := 0                          ## buttons for one tick
	var slot := 0
	var yaw := 0.0
	var yaw_to := 0.0
	var yaw_step := 0.0
	var pitch := 0.0
	var next := 0
	var log: Array[String] = []           ## recent changes (tick: what)
	var tp := false

	func frame(t: int) -> InputFrame:
		if t >= next:
			_change(t)
			next = t + rng.randi_range(2, 18)
		if absf(angle_difference(yaw, yaw_to)) > 1e-4:
			yaw = yaw + clampf(angle_difference(yaw, yaw_to), -yaw_step, yaw_step)
		var f := InputFrame.new()
		f.move = move
		f.yaw = yaw
		f.pitch = pitch
		f.buttons = held | tap | (InputFrame.B_VIEW_TP if tp else 0)
		f.want_slot = slot
		tap = 0
		return f

	func _change(t: int) -> void:
		var F := InputFrame
		var what := ""
		match rng.randi_range(0, 12):
			0, 1:
				var dirs := [Vector2.ZERO, Vector2(0, 1), Vector2(0, -1), Vector2(1, 0), Vector2(-1, 0),
					Vector2(0.7, 0.7), Vector2(-0.7, 0.7), Vector2(0.7, -0.7), Vector2(-0.7, -0.7)]
				move = dirs[rng.randi_range(0, dirs.size() - 1)]
				what = "move %s" % move
			2:
				held ^= F.B_SPRINT
				what = "sprint %s" % bool(held & F.B_SPRINT)
			3:
				held ^= F.B_CROUCH
				what = "crouch %s" % bool(held & F.B_CROUCH)
			4:
				held ^= F.B_SECONDARY
				what = "ads %s" % bool(held & F.B_SECONDARY)
			5:
				held ^= F.B_PRIMARY
				what = "fire %s" % bool(held & F.B_PRIMARY)
			6:
				tap |= F.B_JUMP
				what = "jump"
			7:
				var b: int = [F.B_RELOAD, F.B_MELEE, F.B_RELOAD][rng.randi_range(0, 2)]
				tap |= b
				what = "reload" if b == F.B_RELOAD else "melee"
			8:
				slot = rng.randi_range(0, 2)
				what = "slot %d" % slot
			9, 10:
				# A mouse flick: up to 180 deg, swept over 0-8 ticks.
				yaw_to = yaw + rng.randf_range(-PI, PI)
				var n := rng.randi_range(0, 8)
				yaw_step = absf(angle_difference(yaw, yaw_to)) / maxf(n, 1)
				pitch = rng.randf_range(-0.9, 0.7)
				what = "flick %.0f deg / %d ticks, pitch %.0f" % [rad_to_deg(angle_difference(yaw, yaw_to)), n, rad_to_deg(pitch)]
			11:
				# (Prone is rarer: getting down is slow, and it would soak up the run.)
				if held & F.B_CRAWL or rng.randf() < 0.35:
					held ^= F.B_CRAWL
				what = "prone %s" % bool(held & F.B_CRAWL)
			12:
				tp = not tp
				what = "view %s" % ("TP" if tp else "FP")
		log.append("%d: %s" % [t, what])
		if log.size() > 6:
			log.remove_at(0)


## Runs one hammering session; returns its worst moments.
func _hammer(seed: int, n: int) -> Dictionary:
	var c := spawn("speed_start", "res://addons/ultra_controller/profiles/fps.tres", true)
	await ticks(3)
	UltraItems.give(c, &"pistol")
	UltraItems.give(c, &"rifle")
	UltraItems.give(c, &"ammo_9mm", 300)
	UltraItems.give(c, &"ammo_556", 300)
	var rig := UltraCameraRig.new()
	add_child(rig)
	rig.attach(c)
	rig.camera.current = true
	await ticks(10)
	var fz := Fuzz.new()
	fz.rng.seed = seed
	var tick := [0]
	bot(c).driver = func(_t: int, _src: BotInputSource) -> InputFrame:
		tick[0] += 1
		var f := fz.frame(tick[0])
		return f
	var sk := c.skeleton
	var bones := []
	for nm: String in POINTS:
		bones.append(sk.find_bone(nm))
	# A probe before each modifier (and one after the last): which stage a pop comes from.
	var stages: Array[_Stage] = []
	var names: Array[String] = []
	var mods := []
	for ch in sk.get_children():
		if ch is SkeletonModifier3D:
			mods.append(ch)
	for m: Node in mods:
		var st := _Stage.new()
		st.bones = bones.slice(0, CORE)
		sk.add_child(st)
		sk.move_child(st, m.get_index())
		stages.append(st)
		names.append("before " + String(m.name))
	var last := _Stage.new()
	last.bones = bones.slice(0, CORE)
	sk.add_child(last)
	stages.append(last)
	names.append("final")
	var frames := []
	var info_rows := []
	var stage_at := []
	var guns := []
	var on_pose := func() -> void:
		var inv := c.visual_root.global_transform.affine_inverse()
		var ps := []
		for b: int in bones:
			ps.append(inv * (sk.global_transform * sk.get_bone_global_pose(b).origin))
		frames.append(ps)
		# The gun in the camera's frame as it will be drawn this frame (the hand's final pose -
		# the attachment node itself still holds last frame's): what a first-person player sees.
		var eq := c.get_node_or_null("Equipment") as UltraEquipmentVisual
		var gun := Vector3.INF
		if eq and eq.held_node and eq.held_def and eq.held_def.kind == ItemDefinition.Kind.FIREARM and rig.tp_blend < 0.05:
			var att := eq.held_node.get_parent() as BoneAttachment3D
			if att:
				var g := sk.global_transform * sk.get_bone_global_pose(att.bone_idx) * eq.held_node.transform
				gun = (rig.camera.global_transform.affine_inverse() * g).origin
		guns.append([gun, eq.ads if eq else 0.0])
		var idx := []
		for st: _Stage in stages:
			idx.append(st.rows.size() - 1)
		stage_at.append(idx)
		info_rows.append([tick[0], MotorState.Id.keys()[c.state.state], c.anim._cur_loco, " | ".join(fz.log)])
		var dbg := OS.get_environment("FUZZ_DBG")
		if dbg != "" and absi(tick[0] - int(dbg)) <= 14:
			var wp := c.anim.weapon_pose
			var eqd := c.get_node_or_null("Equipment") as UltraEquipmentVisual
			print("DBG t%d head %s w %.3f body %s blade %.1f gap %.3f fp_w %.3f carry %.3f item %.2f pose %.2f state %s" % [tick[0], (frames[frames.size() - 1][0] as Vector3).snappedf(0.001), wp.weight, wp.from_body, wp.last_blade, wp.last_gap, eqd._fp_w if eqd else -1.0, c.anim.sprint_carry, c.anim._item_w, c.anim._pose_w, MotorState.Id.keys()[c.state.state]])
	sk.skeleton_updated.connect(on_pose)
	# The camera: sampled after everything else this frame.
	var cams := []
	var probe := _Probe.new()
	probe.process_priority = 100000
	probe.cb = func() -> void:
		var src := c.input_source
		var want := Basis(Vector3.UP, src.live_yaw) * Basis(Vector3.RIGHT, src.live_pitch)
		var cam := rig.camera.global_transform
		var off := (want.inverse() * cam.basis.orthonormalized()).get_rotation_quaternion()
		# (The eye off the body, in world axes: everything that moves the camera but the body's
		# own travel - the head, the eye's place round the neck, crouching, the guards.)
		var eye := cam.origin - c.visual_root.global_position
		cams.append([off, eye, c.state.state, rig.tp_blend])
	add_child(probe)
	var nan := 0
	for i in n:
		await get_tree().process_frame
		if not c.state.pos.is_finite() or not rig.camera.global_position.is_finite():
			nan += 1
	sk.skeleton_updated.disconnect(on_pose)

	probe.queue_free()
	rig.queue_free()
	c.queue_free()
	chars.erase(c)
	# Pops: core accel per frame (skipping frames right after a big root jump - a teleport).
	var pops := []
	var worst := 0.0
	for i in range(1, frames.size() - 1):
		var acc := 0.0
		var who := ""
		for k in CORE:
			var a := ((frames[i + 1][k] as Vector3) - 2.0 * (frames[i][k] as Vector3) + (frames[i - 1][k] as Vector3)).length() * 3600.0
			if a > acc:
				acc = a
				who = POINTS[k]
		worst = maxf(worst, acc)
		if acc > POP:
			# The first stage at which this frame's core acceleration shows up: the tree (the
			# blended clips) or the modifier just before that stage.
			var src := "?"
			for si in stages.size():
				var rows: Array = stages[si].rows
				var j: int = stage_at[i][si]
				if j < 1 or j + 1 >= rows.size():
					continue
				var sa := 0.0
				for k in CORE:
					sa = maxf(sa, ((rows[j + 1][k] as Vector3) - 2.0 * (rows[j][k] as Vector3) + (rows[j - 1][k] as Vector3)).length() * 3600.0)
				if sa > acc * 0.5:
					src = "the tree" if si == 0 else names[si - 1].substr(7)
					break
			pops.append([acc, who, info_rows[i], src, acc > float(POP_CLIP.get(info_rows[i][2], SEVERE))])
	pops.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	# Per state / loco node: frames, pops, worst core accel, worst eye jerk.
	var by := {}
	for i in range(1, frames.size() - 1):
		var row: Array = info_rows[i]
		var key := "%s/%s" % [row[1], row[2]]
		var st: Array = by.get(key, [0, 0, 0.0, 0.0])
		st[0] += 1
		var acc := 0.0
		for k in CORE:
			acc = maxf(acc, ((frames[i + 1][k] as Vector3) - 2.0 * (frames[i][k] as Vector3) + (frames[i - 1][k] as Vector3)).length() * 3600.0)
		if acc > POP:
			st[1] += 1
		st[2] = maxf(st[2], acc)
		by[key] = st
	# Camera: how far the view turns away from the aim it was given (recoil kicks and the
	# down-view are expected - reported separately), how fast that offset changes, the roll,
	# and the eye's jerk in the body's frame.
	var cam_off := 0.0
	var cam_rate := 0.0
	var eye_jerk := 0.0
	var cam_rows := []
	var Id := MotorState.Id
	for i in range(2, cams.size()):
		var down: bool = cams[i][2] in [Id.RAGDOLL, Id.DEAD, Id.GET_UP]
		var off_a := rad_to_deg((cams[i][0] as Quaternion).get_angle())
		var rate := rad_to_deg((cams[i][0] as Quaternion).angle_to(cams[i - 1][0])) * 60.0
		var jerk := ((cams[i][1] as Vector3) - 2.0 * (cams[i - 1][1] as Vector3) + (cams[i - 2][1] as Vector3)).length() * 3600.0
		if not down:
			cam_off = maxf(cam_off, off_a)
			cam_rate = maxf(cam_rate, rate)
			if rate > 200.0 or off_a > 25.0:
				cam_rows.append([rate, off_a, info_rows[mini(i, info_rows.size() - 1)]])
		if (cams[i][3] as float) < 0.05 and (cams[i - 2][3] as float) < 0.05:
			eye_jerk = maxf(eye_jerk, jerk)
	cam_rows.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	var eye_top := []
	var eye_by := {}
	for i in range(2, mini(cams.size(), info_rows.size())):
		if (cams[i][3] as float) >= 0.05 or (cams[i - 2][3] as float) >= 0.05:
			continue
		var jerk := ((cams[i][1] as Vector3) - 2.0 * (cams[i - 1][1] as Vector3) + (cams[i - 2][1] as Vector3)).length() * 3600.0
		var row: Array = info_rows[i]
		var key := "%s/%s" % [row[1], row[2]]
		eye_by[key] = maxf(float(eye_by.get(key, 0.0)), jerk)
		if jerk > 600.0:
			eye_top.append([jerk, row])
	for key: String in by:
		(by[key] as Array)[3] = float(eye_by.get(key, 0.0))
	eye_top.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	# Gun in view (first person, a firearm held three frames running): jerk of its place.
	var gun_top := []
	var gun_worst := 0.0
	for i in range(2, guns.size()):
		if guns[i][0] == Vector3.INF or guns[i - 1][0] == Vector3.INF or guns[i - 2][0] == Vector3.INF:
			continue
		var gj := ((guns[i][0] as Vector3) - 2.0 * (guns[i - 1][0] as Vector3) + (guns[i - 2][0] as Vector3)).length() * 3600.0
		gun_worst = maxf(gun_worst, gj)
		if gj > 150.0:
			gun_top.append([gj, info_rows[i], guns[i][1]])
	gun_top.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	return {"gun_top": gun_top, "gun_worst": gun_worst, "eye_top": eye_top, "by": by, "pops": pops, "worst": worst, "nan": nan, "cam_off": cam_off, "cam_rate": cam_rate, "eye_jerk": eye_jerk, "cam_rows": cam_rows, "frames": frames.size()}


## Records the core points' skeleton-space positions as the pose passes through the stack.
class _Stage:
	extends SkeletonModifier3D
	var bones: Array = []
	var rows: Array = []

	func _process_modification_with_delta(_d: float) -> void:
		var sk := get_skeleton()
		var ps := []
		for b: int in bones:
			ps.append(sk.get_bone_global_pose(b).origin)
		rows.append(ps)


class _Probe:
	extends Node
	var cb: Callable

	func _process(_d: float) -> void:
		if cb.is_valid():
			cb.call()


func test_hammer_inputs() -> void:
	var seeds := [11, 22, 55, 66, 88]
	var n := 1800
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			seeds = [int(a.get_slice("=", 1))]
		if a.begins_with("--fuzz-ticks="):
			n = int(a.get_slice("=", 1))
	for s: int in seeds:
		var r: Dictionary = await _hammer(s, n)
		var pops: Array = r.pops
		info("seed %d: %d frames, core worst %.0f m/s^2, %d pops > %.0f; camera off-aim max %.1f deg, off-aim rate max %.0f deg/s, eye jerk max %.0f m/s^2, NaN %d" % [s, r.frames, r.worst, pops.size(), POP, r.cam_off, r.cam_rate, r.eye_jerk, r.nan])
		var keys: Array = (r.by as Dictionary).keys()
		keys.sort_custom(func(a: String, b: String) -> bool: return r.by[a][2] > r.by[b][2])
		for key: String in keys:
			var st: Array = r.by[key]
			info("  %-26s %4d frames  %3d pops  core max %5.0f  eye jerk max %5.0f" % [key, st[0], st[1], st[2], st[3]])
		for p: Array in pops.slice(0, int(OS.get_environment("FUZZ_SHOW")) if OS.get_environment("FUZZ_SHOW") != "" else 6):
			var row: Array = p[2]
			info("  pop %.0f (%s, from %s) tick %d %s/%s  after: %s" % [p[0], p[1], p[3], row[0], row[1], row[2], row[3]])
		info("  gun in view: worst jerk %.0f m/s^2, %d frames > 150" % [r.gun_worst, (r.gun_top as Array).size()])
		for p: Array in (r.gun_top as Array).slice(0, 6):
			var row: Array = p[1]
			info("  gun jerk %.0f (ads %.2f) tick %d %s/%s  after: %s" % [p[0], p[2], row[0], row[1], row[2], row[3]])
		for p: Array in (r.eye_top as Array).slice(0, 5):
			var row: Array = p[1]
			info("  eye jerk %.0f tick %d %s/%s  after: %s" % [p[0], row[0], row[1], row[2], row[3]])
		for p: Array in (r.cam_rows as Array).slice(0, 4):
			var row: Array = p[2]
			info("  camera %.0f deg/s, %.1f deg off aim, tick %d %s/%s  after: %s" % [p[0], p[1], row[0], row[1], row[2], row[3]])
		check(r.nan == 0, "seed %d: no NaNs" % s)
		var severe := pops.filter(func(p: Array) -> bool: return p[4])
		check(severe.is_empty(), "seed %d: no pops past %.0f m/s^2 (%d; %d quick moves > %.0f, worst %.0f)" % [s, SEVERE, severe.size(), pops.size(), POP, r.worst])


## Holding the trigger with the carbine (first person, aimed and from the hip): the eye (the
## camera's place, off the body) stays steady - every round restarted the shot clip on the
## upper body, head included.
func test_auto_fire_keeps_the_eye_steady() -> void:
	var c := spawn("speed_start", "res://addons/ultra_controller/profiles/fps.tres", true)
	await ticks(3)
	UltraItems.give(c, &"rifle")
	UltraItems.give(c, &"ammo_556", 300)
	var rig := UltraCameraRig.new()
	add_child(rig)
	rig.attach(c)
	rig.camera.current = true
	var F := InputFrame
	var res := []
	for spec: Array in [["hip", 0], ["aimed", F.B_SECONDARY]]:
		bot(c).set_steps([{"ticks": 100000, "slot": 1, "buttons": spec[1], "yaw": 0.0, "pitch": 0.0}])
		await ticks(90)
		var still := await _eye_path(c, rig, 60)
		bot(c).set_steps([{"ticks": 100000, "slot": 1, "buttons": spec[1] | F.B_PRIMARY, "yaw": 0.0, "pitch": 0.0}])
		await ticks(10)
		var firing := await _eye_path(c, rig, 60)
		res.append("%s: eye wander still %.1f mm, firing %.1f mm (jerk max %.0f / %.0f m/s^2)" % [spec[0], still[0] * 1000.0, firing[0] * 1000.0, still[1], firing[1]])
		check(firing[0] < 0.02, "%s: auto fire moves the eye < 2 cm (%.1f mm)" % [spec[0], firing[0] * 1000.0])
	info("; ".join(res))


## The eye off the body (world axes) over `n` frames: [largest distance from its mean, worst jerk].
func _eye_path(c: UltraCharacter, rig: UltraCameraRig, n: int) -> Array:
	var ps: Array[Vector3] = []
	for i in n:
		await get_tree().process_frame
		ps.append(rig.camera.global_position - c.visual_root.global_position)
	var mean := Vector3.ZERO
	for p in ps:
		mean += p
	mean /= ps.size()
	var wander := 0.0
	var jerk := 0.0
	for i in ps.size():
		wander = maxf(wander, ps[i].distance_to(mean))
		if i >= 2:
			jerk = maxf(jerk, (ps[i] - 2.0 * ps[i - 1] + ps[i - 2]).length() * 3600.0)
	return [wander, jerk]
