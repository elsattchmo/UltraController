class_name UltraBodyFX
extends Node
## A character's injury presentation: hit reactions (clip + per-bone flinch), and what follows a
## limb coming off. With a cut set (BodyProfile.cut_scene, see UltraCutBody) the body switches to
## its pre-cut pieces: the severed pieces hide, the fitted stump shows, the pieces that came off
## fly as a gib (skinned on the CPU in the pose they had) with their own fitted end; the belly
## opens into a cavity, the head bursts into its chunks, the torso comes apart at the waist.
## Without one: the region collapses (DismemberModifier) under a cap built at runtime.
## Reads MotorState; never writes it. Gore follows the character's DamageProfile.

const R := UltraLimbs.Region
const PARENT_BONE := {
	R.HEAD: "Neck", R.ARM_L: "LeftShoulder", R.FOREARM_L: "LeftUpperArm", R.ARM_R: "RightShoulder",
	R.FOREARM_R: "RightUpperArm", R.THIGH_L: "Hips", R.SHIN_L: "LeftUpperLeg", R.THIGH_R: "Hips",
	R.SHIN_R: "RightUpperLeg", R.HAND_L: "LeftLowerArm", R.HAND_R: "RightLowerArm",
	R.FOOT_L: "LeftLowerLeg", R.FOOT_R: "RightLowerLeg",
}
const CAP_RADIUS := {
	R.HEAD: 0.065, R.ARM_L: 0.055, R.FOREARM_L: 0.045, R.ARM_R: 0.055, R.FOREARM_R: 0.045,
	R.THIGH_L: 0.08, R.SHIN_L: 0.058, R.THIGH_R: 0.08, R.SHIN_R: 0.058,
	R.HAND_L: 0.032, R.HAND_R: 0.032, R.FOOT_L: 0.04, R.FOOT_R: 0.04,
}
const MAX_GIBS := 32
## The region a cut through `r` leaves the stump on.
const PARENT_REGION := {
	R.HEAD: R.TORSO, R.ARM_L: R.TORSO, R.ARM_R: R.TORSO, R.THIGH_L: R.TORSO, R.THIGH_R: R.TORSO,
	R.FOREARM_L: R.ARM_L, R.FOREARM_R: R.ARM_R, R.HAND_L: R.FOREARM_L, R.HAND_R: R.FOREARM_R,
	R.SHIN_L: R.THIGH_L, R.SHIN_R: R.THIGH_R, R.FOOT_L: R.SHIN_L, R.FOOT_R: R.SHIN_R,
}
## Bones showing in a cut through the region (a forearm / shin has two).
const BONES_IN := {R.FOREARM_L: 2, R.FOREARM_R: 2, R.SHIN_L: 2, R.SHIN_R: 2}

static var _gibs: Array[Node3D] = []
static var _vertex_regions := {}          ## mesh RID -> Array[PackedByteArray] per surface
static var _flesh: StandardMaterial3D
static var _drip: StandardMaterial3D

var character: UltraCharacter
var dismember: DismemberModifier
var injury: InjuryModifier
var _shown := 0                            ## severed mask currently presented
var _caps := {}                            ## region -> Node3D (no cut set: runtime caps)
var cuts: UltraCutBody                     ## the pre-cut pieces (null: the model has none)


func setup(c: UltraCharacter) -> void:
	character = c
	var sk := c.skeleton
	injury = InjuryModifier.new()
	injury.name = "Injury"
	sk.add_child(injury)
	dismember = DismemberModifier.new()
	dismember.name = "Dismember"
	sk.add_child(dismember)                 # last: after IK, look and injuries
	if UltraCutBody.available(c):
		cuts = UltraCutBody.new(c)
		UltraCutBody.prewarm(c.body_profile.cut_scene)
	sk.skeleton_updated.connect(_capture_pose)
	UltraNet.world.on_event(&"sever", _on_sever)
	UltraNet.world.on_event(&"halve", _on_halve)
	UltraNet.world.on_event(&"hit", _on_hit_gore)
	UltraNet.world.on_event(&"heart", _on_heart)


func _exit_tree() -> void:
	UltraNet.world.off_event(&"sever", _on_sever)
	UltraNet.world.off_event(&"halve", _on_halve)
	UltraNet.world.off_event(&"hit", _on_hit_gore)
	UltraNet.world.off_event(&"heart", _on_heart)


func _process(delta: float) -> void:
	if character == null:
		return
	var s := character.state
	if s.severed != _shown:
		_apply_mask(s.severed)
	if cuts and cuts.active:
		cuts.sync_layers()
	var S := UltraLimbs.Status
	injury.dangle_l = 1.0 if UltraLimbs.status(s, R.ARM_L) == S.CRIPPLED or UltraLimbs.status(s, R.FOREARM_L) == S.CRIPPLED else 0.0
	injury.dangle_r = 1.0 if UltraLimbs.status(s, R.ARM_R) == S.CRIPPLED or UltraLimbs.status(s, R.FOREARM_R) == S.CRIPPLED else 0.0
	if s.state in [MotorState.Id.RAGDOLL, MotorState.Id.DEAD]:
		injury.dangle_l = 0.0
		injury.dangle_r = 0.0
	var vb := character.visual_root.global_basis
	injury.accel = (vb.inverse() * character.get_accel()) * Vector3(-1, 1, -1)   # world -> skeleton space
	_drive_blood(delta)
	# Respawned (back from dead, or health jumping back to full): the torso wounds and guts go.
	var dead_now := s.state == MotorState.Id.DEAD
	var respawned := (_gore_was_dead and not dead_now) or (s.hp >= 100.0 and _gore_hp < 60.0)
	_gore_was_dead = dead_now
	_gore_hp = s.hp
	if respawned and not _gore.is_empty():
		for n in _gore:
			if is_instance_valid(n):
				(n as Node).queue_free()
		_gore.clear()
		_guts = 0
	if respawned and cuts and cuts.torso != UltraCutBody.Torso.WHOLE:
		cuts.torso = UltraCutBody.Torso.WHOLE
		_apply_mask(s.severed)


# ---------------------------------------------------------------- the posed body

var _world: Array[Transform3D] = []        ## each bone's final pose (world), last skeleton update
var _caps_frame := -1
var _caps_list: Array = []


## The bones' final poses (after IK, the ragdoll...): only readable at skeleton_updated - read
## any other time, a ragdolling body's bones are where the animation would have them standing.
func _capture_pose() -> void:
	var sk := character.skeleton
	var n := sk.get_bone_count()
	if _world.size() != n:
		_world.resize(n)
	var g := sk.global_transform
	for b in n:
		_world[b] = g * sk.get_bone_global_pose(b)


func _bone_world(b: int) -> Transform3D:
	if b >= 0 and b < _world.size():
		return _world[b]
	var sk := character.skeleton
	return sk.global_transform * sk.get_bone_global_pose(maxi(b, 0))


## Capsules [a, b, radius] (world) round the body's pieces still on, for loose gore (guts) to
## lie against instead of through. A torso in two is two capsules, apart.
const BODY_CAPS := [
	[R.TORSO, "Hips", "Spine", 0.13], [R.TORSO, "Spine", "Chest", 0.12], [R.TORSO, "Chest", "Neck", 0.14],
	[R.HEAD, "Neck", "Head", 0.06], [R.HEAD, "Head", "", 0.1],
	[R.ARM_L, "LeftUpperArm", "LeftLowerArm", 0.05], [R.FOREARM_L, "LeftLowerArm", "LeftHand", 0.042],
	[R.ARM_R, "RightUpperArm", "RightLowerArm", 0.05], [R.FOREARM_R, "RightLowerArm", "RightHand", 0.042],
	[R.THIGH_L, "LeftUpperLeg", "LeftLowerLeg", 0.075], [R.SHIN_L, "LeftLowerLeg", "LeftFoot", 0.052],
	[R.THIGH_R, "RightUpperLeg", "RightLowerLeg", 0.075], [R.SHIN_R, "RightLowerLeg", "RightFoot", 0.052],
]


func body_capsules() -> Array:
	var f := Engine.get_physics_frames()
	if f == _caps_frame:
		return _caps_list
	_caps_frame = f
	_caps_list = []
	var sk := character.skeleton
	if sk == null:
		return _caps_list
	var halved := cuts != null and cuts.torso == UltraCutBody.Torso.HALVED
	for c: Array in BODY_CAPS:
		var r: int = c[0]
		if r != R.TORSO and ((cuts and cuts.active and cuts.gone(r)) or (cuts == null and (character.state.severed >> r) & 1)):
			continue
		var a := sk.find_bone(c[1])
		if a < 0:
			continue
		var pa := _bone_world(a)
		var pb: Vector3
		if c[2] == "":
			pb = pa.origin + pa.basis.y.normalized() * 0.12
		else:
			var b := sk.find_bone(c[2])
			if b < 0:
				continue
			pb = _bone_world(b).origin
		if halved and c[1] == "Spine":
			var ends := _waist_ends()
			if ends.size() == 2:
				_caps_list.append([pa.origin, ends[0][0], c[3]])
				_caps_list.append([ends[1][0], pb, c[3]])
				continue
		_caps_list.append([pa.origin, pb, c[3]])
	return _caps_list


# ---------------------------------------------------------------- bleeding

var _beat := 0.0
var _heart_t := 0.0
var _drip_t := 0.0
var _seep_t := 0.0
var _pool_t := 0.0
var _dead_t := 0.0


## Open stumps pump blood with the heart (weaker as the blood runs out; a dribble once dead);
## anyone lying in it grows a pool, and a body that's been shot dead bleeds out under itself.
func _drive_blood(delta: float) -> void:
	var fx := UltraEffects.instance()
	if fx == null or fx.blood_fx == null or not character.damage_profile.blood_on():
		return
	var s := character.state
	var Id := MotorState.Id
	var dead := s.state == Id.DEAD
	_dead_t = _dead_t + delta if dead else 0.0
	var lying := s.state in [Id.RAGDOLL, Id.DEAD, Id.GET_UP]
	var life := clampf(s.hp / 100.0, 0.0, 1.0)
	var flow := 0.0 if dead and _dead_t > 12.0 else (0.25 if dead else 0.4 + 0.6 * life)
	_beat -= delta
	_drip_t -= delta
	_pool_t -= delta
	var beat := false
	if _beat <= 0.0:
		_beat = 0.75 if not dead else 1.4
		beat = true
	for st: Array in _stumps():
		var at: Vector3 = st[0]
		var out: Vector3 = st[1]
		if flow <= 0.0:
			continue
		if beat:
			fx.blood_fx.spray(at, out + Vector3.UP * 0.15, int(4 + 8 * flow), 1.2 + 2.2 * flow, 22.0, 0.007, character)
		if _drip_t <= 0.0:
			fx.blood_fx.spray(at, Vector3.DOWN, 1, 0.3, 30.0, 0.006, character)
		if lying and _pool_t <= 0.0:
			fx.blood_fx.pool(at, 0.12 + 0.1 * flow)
	# Through the heart: the chest pumps hard and fast (and runs out fast).
	if s.has(MotorState.F_HEART) and flow > 0.0 and character.skeleton:
		_heart_t -= delta
		if _heart_t <= 0.0:
			_heart_t = 0.42 if not dead else 1.1
			var sk2 := character.skeleton
			var ch2 := sk2.find_bone("UpperChest")
			if ch2 >= 0:
				var g := _bone_world(ch2)
				var front := -character.visual_root.global_basis.z
				if lying:
					front = Vector3.DOWN
				var at2 := g.origin + front * 0.12 + Vector3.UP * -0.05
				fx.blood_fx.spray(at2, front + Vector3.UP * 0.25, int(10 + 14 * flow), 1.6 + 2.6 * flow, 20.0, 0.008, character)
				if lying:
					fx.blood_fx.pool(at2, 0.2 + 0.15 * flow)
	# Crippled limbs seep: a drop now and then off the wound.
	_seep_t -= delta
	if _seep_t <= 0.0 and not dead and character.skeleton:
		_seep_t = randf_range(0.35, 0.7)
		var sk := character.skeleton
		for r in UltraLimbs.COUNT:
			if r == R.HEAD or UltraLimbs.status(s, r) != UltraLimbs.Status.CRIPPLED:
				continue
			var bones: Array = UltraLimbs.BONES[r]
			var b := sk.find_bone(bones[0] if r != R.TORSO else "Chest")
			if b < 0:
				continue
			var bp := _bone_world(b).origin
			fx.blood_fx.spray(bp + Vector3(randf_range(-0.04, 0.04), 0.0, randf_range(-0.04, 0.04)), Vector3.DOWN, 1, 0.4, 25.0, 0.006, character)
	if _drip_t <= 0.0:
		_drip_t = 0.09
	# Shot dead: a pool spreads from under the chest for a while.
	if dead and _dead_t < 10.0 and _pool_t <= 0.0 and character.skeleton:
		var sk := character.skeleton
		var ch := sk.find_bone("Chest")
		if ch >= 0:
			fx.blood_fx.pool(_bone_world(ch).origin, 0.16)
	if _pool_t <= 0.0:
		_pool_t = 0.45


## Open cut ends on the body: [world point, out of the wound].
func _stumps() -> Array:
	var out := []
	if cuts and cuts.active:
		var sk := character.skeleton
		for r: int in PARENT_BONE:
			if not cuts.gone(r) or cuts.gone(PARENT_REGION[r]):
				continue
			var j := sk.find_bone(UltraLimbs.BONES[r][0])
			var p := sk.find_bone(PARENT_BONE[r])
			if j < 0 or p < 0:
				continue
			var jp := _bone_world(j).origin
			var pp := _bone_world(p).origin
			out.append([jp, (jp - pp).normalized() if jp.distance_to(pp) > 0.01 else Vector3.UP])
		if cuts.torso == UltraCutBody.Torso.HALVED:
			for w: Array in _waist_ends():
				out.append(w)
		return out
	for r: int in _caps:
		var att := _caps[r] as Node3D
		if not is_instance_valid(att) or att.get_child_count() == 0:
			continue
		var cap := att.get_child(0) as Node3D
		out.append([cap.global_position, cap.global_basis.y.normalized()])
	return out


## The two ends of a torso in two (posed): [point, out] for the lower half (on Spine) and the
## upper half (on Chest) - they part once the ragdoll's halves fly apart.
func _waist_ends() -> Array:
	var sk := character.skeleton
	var sp := sk.find_bone("Spine")
	var ch := sk.find_bone("Chest")
	if sp < 0 or ch < 0:
		return []
	var half := sk.get_bone_rest(ch).origin.length() * 0.5
	var a := _bone_world(sp)
	var b := _bone_world(ch)
	var ay := a.basis.y.normalized()
	var by := b.basis.y.normalized()
	return [[a.origin + ay * half, ay], [b.origin - by * half, -by]]


## Hit reaction: the matching clip on the upper body, and a kick on the bone that was hit.
func react(region: int, dir: Vector3, amount: float, kind := &"bullet") -> void:
	if character.anim:
		character.anim.play_hit(region == R.HEAD, kind == &"blocked")
	if region < 0 or injury == null or kind == &"blocked":
		return
	var bone: String = UltraLimbs.BONES[region][0]
	if region == R.TORSO:
		bone = "Chest"
	var skel_dir := (character.visual_root.global_basis.inverse() * dir) * Vector3(-1, 1, -1)
	injury.flinch(bone, skel_dir, clampf(amount * 0.12, 1.5, 7.0))


func _apply_mask(mask: int) -> void:
	_shown = mask
	if cuts:
		# The pieces: nothing collapses (the skin round a cut stays exactly where it is).
		dismember.severed = 0
		cuts.severed = mask
		if mask != 0 or cuts.torso != UltraCutBody.Torso.WHOLE:
			cuts.activate()
			cuts.update()
		else:
			cuts.deactivate()
		return
	dismember.severed = mask
	for r: int in PARENT_BONE:
		var cut := (mask >> r) & 1 == 1
		# Only the top of a cut chain gets a cap (no cap on a forearm whose arm is gone).
		var top := cut
		for up: int in UltraLimbs.BELOW:
			if r in UltraLimbs.BELOW[up] and (mask >> up) & 1:
				top = false
		if top and not _caps.has(r):
			_caps[r] = _make_cap(r)
		elif not top and _caps.has(r):
			(_caps[r] as Node).queue_free()
			_caps.erase(r)


func _make_cap(r: int) -> Node3D:
	var sk := character.skeleton
	var att := BoneAttachment3D.new()
	att.bone_name = PARENT_BONE[r]
	sk.add_child(att)
	var child := sk.find_bone(UltraLimbs.BONES[r][0])
	var at := sk.get_bone_rest(child).origin
	var rad: float = CAP_RADIUS[r]
	var bones: int = BONES_IN[r] if BONES_IN.has(r) else 1
	# The open end of the limb, fitted to its cross-section at the joint (the posed skin of the
	# limb it was cut from, within a couple of cm of the cut): fat, meat, bone, torn strands.
	# (From the bone's posed transform: a new attachment only takes it next update.)
	var parent_xf := _bone_world(sk.find_bone(PARENT_BONE[r]))
	var joint := _bone_world(child).origin
	var axis := (joint - parent_xf.origin).normalized() if joint.distance_to(parent_xf.origin) > 0.01 else parent_xf.basis.y.normalized()
	var ring := PackedVector3Array()
	var bm := character.body_mesh()
	if PARENT_REGION.has(r) and bm and bm.mesh and bm.skin:
		var tris: Array = []
		_collect_tris(bm, 1 << int(PARENT_REGION[r]), tris, joint, rad * 2.2)
		var pts := PackedVector3Array()
		for t: Array in tris:
			for j in 3:
				var v: Vector3 = t[j]
				if absf((v - joint).dot(axis)) < 0.03:
					pts.append(v)
		if pts.size() >= 8:
			ring = UltraWoundMesh.outline(pts, joint - axis * 0.012, axis, 18, 0.93)     # (sunk inside the skin's edge)
	if ring.is_empty():
		var u := axis.cross(Vector3.UP if absf(axis.y) < 0.9 else Vector3.RIGHT).normalized()
		var w := axis.cross(u)
		for k in 16:
			var a := TAU * k / 16.0
			ring.append(joint + (u * cos(a) + w * sin(a)) * rad * 1.1)
	var inv := parent_xf.affine_inverse()
	var local := PackedVector3Array()
	for v in ring:
		local.append(inv * v)
	var cap := UltraWoundMesh.cap(local, (inv.basis * axis).normalized(), bones, randi())
	att.add_child(cap)
	return att


func _bleed(on: Node3D) -> void:
	var p := CPUParticles3D.new()
	p.amount = 24
	p.lifetime = 0.9
	p.direction = Vector3.UP
	p.spread = 30.0
	p.initial_velocity_min = 0.3
	p.initial_velocity_max = 1.0
	p.gravity = Vector3(0, -9.8, 0)
	var m := SphereMesh.new()
	m.radius = 0.008
	m.height = 0.016
	m.radial_segments = 4
	m.rings = 2
	p.mesh = m
	p.material_override = _drip_mat()
	p.local_coords = false
	on.add_child(p)
	p.emitting = true
	var tm := Timer.new()
	tm.one_shot = true
	tm.wait_time = 8.0
	tm.autostart = true
	tm.timeout.connect(func() -> void: p.emitting = false)
	p.add_child(tm)


# ---------------------------------------------------------------- torso gore

## Buckshot this heavy into the torso tears it open: chunks of it fly, a raw wound stays, and
## (heavier, or a kill) guts spill out and hang.
const GORE_MIN := 30.0
const GUTS_MIN := 45.0
const MAX_GUTS := 2
var _gore: Array[Node] = []
var _gore_was_dead := false
var _gore_hp := 100.0
var _cap_at := Vector3.INF            ## (spawn_gib -> _make_gib: where the cut end is)
var _cap_r := 0.0
var _cap_bones := 1
var _guts := 0


func _on_heart(net_id: int, point := Vector3.ZERO, dir := Vector3.ZERO) -> void:
	if character == null or net_id != character.net_id or not character.damage_profile.blood_on():
		return
	var fx := UltraEffects.instance()
	if fx and fx.blood_fx:
		# Through the heart: a burst out of the exit and the entry both.
		fx.blood_fx.spray(point + dir * 0.25, dir + Vector3.UP * 0.2, 70, 5.5, 30.0, 0.009, character)
		fx.blood_fx.spray(point, -dir + Vector3.UP * 0.3, 35, 2.5, 40.0, 0.008, character)
		for i in 5:
			fx.blood_fx.splat_body(character, point + Vector3(randf_range(-0.12, 0.12), randf_range(-0.3, 0.05), randf_range(-0.12, 0.12)), randf_range(0.1, 0.18))
	_heart_t = 0.15


func _on_hit_gore(target_id: int, pos: Vector3, dir: Vector3, amount: float, _attacker_id: int, region := -1, kind := &"bullet") -> void:
	if character == null or target_id != character.net_id or region != R.TORSO:
		return
	if kind != &"buckshot" and kind != &"blast":
		return
	var dp := character.damage_profile
	if not dp.gore_on() or amount < GORE_MIN:
		return
	# (At the end of the frame: the same blast may halve the body - its `halve` event comes
	# after the hit - and then the halves are the wound: no skin chunks, no crater as well.)
	_blast_unless_halved.call_deferred(pos, dir.normalized(), amount)


func _blast_unless_halved(pos: Vector3, dir: Vector3, amount: float) -> void:
	if cuts and cuts.torso == UltraCutBody.Torso.HALVED:
		return
	torso_blast(pos, dir, amount)


## A torso blown open at `point` (world) by a blast travelling `dir`.
func torso_blast(point: Vector3, dir: Vector3, amount: float) -> void:
	var sk := character.skeleton
	var fx := UltraEffects.instance()
	# Which torso bone it's on (the wound rides it).
	var best := ""
	var bd := INF
	for b in ["Hips", "Spine", "Chest", "UpperChest"]:
		var i := sk.find_bone(b)
		if i < 0:
			continue
		var d := (_bone_world(i).origin).distance_to(point)
		if d < bd:
			bd = d
			best = b
	var att := BoneAttachment3D.new()
	att.bone_name = best
	sk.add_child(att)
	_gore.append(att)
	# (The attachment only takes its bone's pose on the next skeleton update: work from the bone.)
	var bone_xf := _bone_world(sk.find_bone(best))
	var at_local := bone_xf.affine_inverse() * (point + dir * 0.03)
	var front := -character.visual_root.global_basis.z
	var into_front := dir.dot(front) < -0.2
	if cuts and into_front:
		# From the front: the belly blown open (the cut set's cavity).
		if cuts.torso == UltraCutBody.Torso.WHOLE:
			cuts.torso = UltraCutBody.Torso.OPEN
			_apply_mask(character.state.severed)
	elif cuts == null or cuts.torso != UltraCutBody.Torso.HALVED:
		# The wound: a ragged crater blown into the torso (meat, fat, a rib showing), facing
		# out toward where the blast came from.
		var r := clampf(0.04 + amount * 0.0008, 0.05, 0.08)
		var w := UltraWoundMesh.crater(r, randi())
		var out_l := (bone_xf.basis.inverse() * -dir).normalized()
		w.transform = Transform3D(Basis(Quaternion(Vector3.UP, out_l)), at_local - out_l * 0.05)
		att.add_child(w)
	# Chunks of the torso torn off (its own skin round the hit) and some flesh with them.
	var tris: Array = []
	var bm := character.body_mesh()
	if bm and bm.mesh and bm.skin:
		_collect_tris(bm, 1 << R.TORSO, tris, point, 0.11)
	if not tris.is_empty():
		var dirs := _sphere_dirs(3)
		var groups: Array = [[], [], []]
		for k in tris.size():
			var t: Array = tris[k]
			var v: Vector3 = ((t[0] + t[1] + t[2]) / 3.0 - point).normalized()
			var bi := 0
			for q in 3:
				if dirs[q].dot(v) > dirs[bi].dot(v):
					bi = q
			(groups[bi] as Array).append(k)
		for g: Array in groups:
			if g.is_empty():
				continue
			var gc := Vector3.ZERO
			for k: int in g:
				var t2: Array = tris[k]
				gc += (t2[0] + t2[1] + t2[2]) / 3.0
			gc /= g.size()
			_make_gib(tris, g, gc, character.state.vel + dir * randf_range(3.0, 6.0) + Vector3.UP * randf_range(0.5, 2.0), true)
	for i in 3:
		_flesh_blob(point, dir * randf_range(2.0, 5.0) + Vector3(randf_range(-1, 1), randf_range(0.5, 2.0), randf_range(-1, 1)))
	# Lots of blood: out the back with the shot, a spray off the front, the body splashed.
	if fx and fx.blood_fx and character.damage_profile.blood_on():
		fx.blood_fx.spray(point + dir * 0.2, dir + Vector3.UP * 0.15, 110, 6.5, 32.0, 0.009, character)
		fx.blood_fx.spray(point, -dir + Vector3.UP * 0.4, 45, 2.8, 50.0, 0.008, character)
		for i in 8:
			fx.blood_fx.splat_body(character, point + Vector3(randf_range(-0.2, 0.2), randf_range(-0.4, 0.1), randf_range(-0.2, 0.2)), randf_range(0.1, 0.2))
	# Guts: a blast into the front of the torso spills them out of the stomach - a loop of
	# intestine sagging out of the belly (both ends still inside) and a loose length hanging.
	if into_front and _guts < MAX_GUTS:
		_spill_guts(dir)


## Intestines out of the belly (front of the abdomen, on the Spine bone): a sagging loop and a
## dangling strand, verlet chains (UltraGuts) that swing with the body and lie on the floor.
func _spill_guts(dir: Vector3) -> void:
	var sk := character.skeleton
	var sp := sk.find_bone("Spine")
	if sp < 0:
		return
	_guts += 1
	var att := BoneAttachment3D.new()
	att.bone_name = "Spine"
	sk.add_child(att)
	_gore.append(att)
	var bone_xf := _bone_world(sp)
	var front := -character.visual_root.global_basis.z
	var belly := bone_xf.origin + front * 0.13 + Vector3.DOWN * 0.02
	var side := character.visual_root.global_basis.x
	var root := character.get_tree().current_scene if character.get_tree().current_scene else character.get_parent()
	var inv := bone_xf.affine_inverse()
	if cuts and cuts.active and cuts.torso == UltraCutBody.Torso.OPEN:
		# Out of the cavity (between Spine and Chest, a little inside the skin).
		var ch := sk.find_bone("Chest")
		if ch >= 0:
			belly = bone_xf.origin.lerp(_bone_world(ch).origin, 0.55) + front * 0.085
	else:
		# The belly wound itself.
		var w := UltraWoundMesh.crater(0.055, randi())
		var out_l := (bone_xf.basis.inverse() * front).normalized()
		w.transform = Transform3D(Basis(Quaternion(Vector3.UP, out_l)), inv * belly - out_l * 0.055)    # (sunk: the skin covers its rim)
		att.add_child(w)
	# Two loops sagging out of the belly (both ends inside) and a loose length hanging below.
	var specs := [[side * 0.035, -side * 0.04 + Vector3.UP * 0.025, 13], [-side * 0.01 + Vector3.DOWN * 0.02, side * 0.045 + Vector3.DOWN * 0.01, 9], [-side * 0.03, Vector3.INF, 10]]
	for spec: Array in specs:
		var a := Node3D.new()
		a.position = inv * (belly + (spec[0] as Vector3))
		att.add_child(a)
		var guts := UltraGuts.new()
		guts.anchor = a
		guts.segments = int(spec[2])
		if spec[1] != Vector3.INF:
			var b := Node3D.new()
			b.position = inv * (belly + (spec[1] as Vector3))
			att.add_child(b)
			guts.anchor_b = b
		guts.exclude = [character.get_rid()]
		guts.colliders = body_capsules
		root.add_child(guts)
		guts.global_position = belly
		guts.kick(front * 1.5 - dir * 0.0 + Vector3.DOWN * 0.5)
		_gore.append(guts)


## The torso blown in two at the waist (a close blast through the middle that kills): the
## pieces switch to the two halves, the ragdoll's spine lets go between them (each half
## flops on its own), the blast throws the upper half, guts hang out of both, lots of blood.
func _on_halve(net_id: int, dir := Vector3.ZERO, point := Vector3.ZERO) -> void:
	if character == null or net_id != character.net_id or cuts == null:
		return
	if cuts.torso == UltraCutBody.Torso.HALVED:
		return
	cuts.torso = UltraCutBody.Torso.HALVED
	_apply_mask(character.state.severed)
	if character.ragdoll:
		character.ragdoll.split_waist(dir)
	var fx := UltraEffects.instance()
	if fx and fx.blood_fx and character.damage_profile.blood_on():
		fx.blood_fx.spray(point + dir * 0.2, dir + Vector3.UP * 0.2, 140, 7.0, 35.0, 0.009, character)
		fx.blood_fx.spray(point, Vector3.UP, 60, 3.5, 50.0, 0.008, character)
		fx.blood_fx.spray(point, -dir + Vector3.UP * 0.4, 40, 2.5, 50.0, 0.008, character)
		for i in 10:
			fx.blood_fx.splat_body(character, point + Vector3(randf_range(-0.25, 0.25), randf_range(-0.4, 0.3), randf_range(-0.25, 0.25)), randf_range(0.12, 0.22))
	for i in 5:
		_flesh_blob(point, dir * randf_range(2.0, 5.0) + Vector3(randf_range(-1.5, 1.5), randf_range(0.5, 2.5), randf_range(-1.5, 1.5)))
	# Guts out of both ends: loops and loose lengths, hanging from the halves as they part.
	var ends := _waist_ends()
	if ends.size() == 2:
		var side := character.visual_root.global_basis.x
		# Lots of it: long loose ropes and sagging loops out of each open end.
		var fwd := -character.visual_root.global_basis.z
		var lower := []
		var upper := []
		for k in 6:
			var a := side * randf_range(-0.07, 0.07) + fwd * randf_range(-0.02, 0.06)
			var loop := k % 3 == 1
			var e: Vector3 = side * randf_range(-0.07, 0.07) + fwd * 0.03 if loop else Vector3.INF
			lower.append([a, e, randi_range(16, 24) if not loop else randi_range(12, 18)])
			var a2 := side * randf_range(-0.07, 0.07) + fwd * randf_range(-0.02, 0.06)
			var e2: Vector3 = side * randf_range(-0.07, 0.07) + fwd * 0.03 if loop else Vector3.INF
			upper.append([a2, e2, randi_range(14, 22) if not loop else randi_range(12, 16)])
		_hang_guts("Spine", ends[0][0], lower, dir * 0.5 + Vector3.UP * 1.2)
		_hang_guts("Chest", ends[1][0], upper, dir * 2.0 + Vector3.DOWN * 0.5)


## Lengths of gut hanging out of `at` (world), riding `bone`: specs [[start offset, end offset
## (Vector3.INF: loose), segments]], thrown out at `kick` m/s.
func _hang_guts(bone: String, at: Vector3, specs: Array, kick: Vector3) -> void:
	var sk := character.skeleton
	var b := sk.find_bone(bone)
	if b < 0:
		return
	var att := BoneAttachment3D.new()
	att.bone_name = bone
	sk.add_child(att)
	_gore.append(att)
	var inv := (_bone_world(b)).affine_inverse()
	var root := character.get_tree().current_scene if character.get_tree().current_scene else character.get_parent()
	for spec: Array in specs:
		var a := Node3D.new()
		a.position = inv * (at + (spec[0] as Vector3))
		att.add_child(a)
		var guts := UltraGuts.new()
		guts.anchor = a
		guts.segments = int(spec[2])
		if spec[1] != Vector3.INF:
			var e := Node3D.new()
			e.position = inv * (at + (spec[1] as Vector3))
			att.add_child(e)
			guts.anchor_b = e
		guts.exclude = [character.get_rid()]
		guts.colliders = body_capsules
		root.add_child(guts)
		guts.global_position = at
		guts.kick(kick + Vector3(randf_range(-0.5, 0.5), 0.0, randf_range(-0.5, 0.5)))
		_gore.append(guts)


## A loose lump of flesh / gut thrown out of a wound (a small rigid body that lies where it lands).
func _flesh_blob(at: Vector3, vel: Vector3) -> void:
	var body := RigidBody3D.new()
	body.collision_layer = 0
	body.collision_mask = UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC
	body.mass = 0.15
	var m := MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = randf_range(0.018, 0.03)
	cm.height = randf_range(0.07, 0.14)
	cm.radial_segments = 8
	cm.rings = 2
	m.mesh = cm
	m.material_override = UltraGuts.gut_mat() if randf() < 0.6 else _flesh_mat()
	body.add_child(m)
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = cm.radius
	cap.height = cm.height
	cs.shape = cap
	body.add_child(cs)
	var root := character.get_tree().current_scene if character.get_tree().current_scene else character.get_parent()
	root.add_child(body)
	body.global_position = at
	body.linear_velocity = vel
	body.angular_velocity = Vector3(randf_range(-8, 8), randf_range(-8, 8), randf_range(-8, 8))
	body.add_to_group(&"ultra_gib")
	for k in range(_gibs.size() - 1, -1, -1):
		if not is_instance_valid(_gibs[k]):
			_gibs.remove_at(k)
	_gibs.append(body)
	while _gibs.size() > MAX_GIBS:
		var old: Variant = _gibs.pop_front()
		if is_instance_valid(old):
			(old as Node).queue_free()
	character.get_tree().create_timer(30.0).timeout.connect(body.queue_free)


# ---------------------------------------------------------------- severing

func _on_sever(net_id: int, cut: int, dir: Vector3, point: Vector3, kind := &"bullet") -> void:
	if character == null or net_id != character.net_id:
		return
	_apply_mask(character.state.severed | cut)
	# Buckshot / a blast through the head: it bursts - chunks of it fly, a red mist.
	var head := 1 << R.HEAD
	if cut & head and (kind == &"buckshot" or kind == &"blast"):
		var fx2 := UltraEffects.instance()
		if fx2 and fx2.blood_fx and character.damage_profile.blood_on():
			fx2.blood_fx.spray(point, dir + Vector3.UP * 0.3, 90, 7.0, 35.0, 0.008, character)
			fx2.blood_fx.spray(point, Vector3.UP, 40, 3.5, 45.0, 0.007, character)
			for i in 8:
				fx2.blood_fx.splat_body(character, point + Vector3(randf_range(-0.2, 0.2), randf_range(-0.45, -0.05), randf_range(-0.2, 0.2)), randf_range(0.1, 0.18))
		spawn_gib(head, dir, 9, 7.0)
		cut &= ~head
		if cut == 0:
			return
	var fx := UltraEffects.instance()
	if fx and character.damage_profile.blood_on():
		if fx.blood_fx:
			# The limb tears off: a gush along the hit, a fountain up, the body splashed.
			fx.blood_fx.spray(point, dir + Vector3.UP * 0.2, 45, 4.5, 30.0, 0.008, character)
			fx.blood_fx.spray(point, Vector3.UP, 25, 2.8, 35.0, 0.007, character)
			for i in 6:
				fx.blood_fx.splat_body(character, point + Vector3(randf_range(-0.15, 0.15), randf_range(-0.25, 0.1), randf_range(-0.15, 0.15)), randf_range(0.08, 0.16))
		else:
			fx.blood(point, -dir)
	spawn_gib(cut, dir)


## Throw the cut-off part as rigid bodies made from its own triangles (body and head meshes)
## in their current pose. `pieces` > 1 breaks it into that many chunks round its middle, each
## with a bit of flesh in it, blown out at `burst` m/s (a head blown off by buckshot).
func spawn_gib(cut: int, dir: Vector3, pieces := 1, burst := 0.0) -> void:
	if cuts and cuts.active:
		_spawn_cut_gib(cut, dir, pieces, burst)
		return
	var tris: Array = []            # [Vector3 a, b, c, normals..., uvs..., material]
	for mi: MeshInstance3D in [character.body_mesh(), character.head_mesh]:
		if mi != null and mi.mesh != null and mi.skin != null:
			_collect_tris(mi, cut, tris)
	if tris.is_empty():
		return
	var center := Vector3.ZERO
	for t: Array in tris:
		center += (t[0] + t[1] + t[2]) / 3.0
	center /= tris.size()
	# The cut: the joint at the top of the chain that came off (its root bone, posed).
	_cap_at = Vector3.INF
	_cap_r = 0.0
	_cap_bones = 1
	if pieces <= 1:
		var sk := character.skeleton
		for r in UltraLimbs.COUNT:
			if not (cut >> r) & 1 or not CAP_RADIUS.has(r):
				continue
			var top := true
			for up: int in UltraLimbs.BELOW:
				if r in UltraLimbs.BELOW[up] and (cut >> up) & 1:
					top = false
			if top:
				var b := sk.find_bone(UltraLimbs.BONES[r][0])
				if b >= 0:
					_cap_at = _bone_world(b).origin
					_cap_r = CAP_RADIUS[r]
					_cap_bones = BONES_IN[r] if BONES_IN.has(r) else 1
				break
	var groups: Array = []
	if pieces <= 1:
		var all := []
		for k in tris.size():
			all.append(k)
		groups.append(all)
	else:
		# Chunks: each triangle goes to the nearest of `pieces` directions round the middle.
		var dirs := _sphere_dirs(pieces)
		for d in dirs:
			groups.append([])
		for k in tris.size():
			var t: Array = tris[k]
			var mid: Vector3 = (t[0] + t[1] + t[2]) / 3.0
			var v := (mid - center).normalized()
			var best := 0
			for q in dirs.size():
				if dirs[q].dot(v) > dirs[best].dot(v):
					best = q
			(groups[best] as Array).append(k)
	for g: Array in groups:
		if g.is_empty():
			continue
		var gc := Vector3.ZERO
		for k: int in g:
			var t: Array = tris[k]
			gc += (t[0] + t[1] + t[2]) / 3.0
		gc /= g.size()
		var out := (gc - center).normalized() if pieces > 1 and gc.distance_to(center) > 0.001 else Vector3.ZERO
		var vel := character.state.vel + dir * 3.5 + Vector3.UP * 2.0
		if burst > 0.0:
			vel = character.state.vel + dir * burst * randf_range(0.5, 1.1) + out * burst * randf_range(0.4, 0.8) + Vector3.UP * randf_range(1.0, 3.0)
		_make_gib(tris, g, gc, vel, pieces > 1)


## The cut set's pieces of a severed chain as one gib (with the fitted end of its cut), or a head
## blown apart as its chunks (each closed: skin, skull, meat).
func _spawn_cut_gib(cut: int, dir: Vector3, pieces: int, burst: float) -> void:
	var head := 1 << R.HEAD
	var sources: Array = []
	if pieces > 1 and cut == head:
		for mi in cuts.head_chunks():
			sources.append([mi])
	else:
		sources.append(cuts.gib_parts(cut))
	var all_c := Vector3.ZERO
	var sets: Array = []
	for src: Array in sources:
		var tris: Array = []
		for mi: MeshInstance3D in src:
			_collect_tris(mi, -1, tris)
		if tris.is_empty():
			continue
		var c := Vector3.ZERO
		for t: Array in tris:
			c += (t[0] + t[1] + t[2]) / 3.0
		c /= tris.size()
		all_c += c
		sets.append([tris, c])
	if sets.is_empty():
		return
	all_c /= sets.size()
	_cap_r = 0.0                         # (the ends are in the pieces)
	for st: Array in sets:
		var tris: Array = st[0]
		var c: Vector3 = st[1]
		var group := range(tris.size())
		var vel := character.state.vel + dir * 3.5 + Vector3.UP * 2.0
		if burst > 0.0:
			var out := (c - all_c).normalized() if c.distance_to(all_c) > 0.001 else Vector3.UP
			vel = character.state.vel + dir * burst * randf_range(0.5, 1.1) + out * burst * randf_range(0.4, 0.8) + Vector3.UP * randf_range(1.0, 3.0)
		_make_gib(tris, group, c, vel, pieces > 1, true)


## The cut region's triangles from one skinned mesh, posed (world space). `cut` -1: all of them.
## (`near` / `radius`: only the triangles whose middle is within `radius` of `near`.)
func _collect_tris(mi: MeshInstance3D, cut: int, out: Array, near := Vector3.INF, radius := 0.0) -> void:
	var sk := character.skeleton
	var every := cut < 0
	var regions := [] if every else _regions_for(mi, sk)
	var mesh := mi.mesh as ArrayMesh
	var bind_xf: Array[Transform3D] = []
	for i in mi.skin.get_bind_count():
		var b := mi.skin.get_bind_bone(i)
		if b < 0:
			b = sk.find_bone(mi.skin.get_bind_name(i))
		bind_xf.append(_bone_world(maxi(b, 0)) * mi.skin.get_bind_pose(i))
	for surf in mesh.get_surface_count():
		var arr := mesh.surface_get_arrays(surf)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		var uvs: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV] if arr[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
		var bones: PackedInt32Array = arr[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		var vr: PackedByteArray = PackedByteArray() if every else regions[surf]
		var per := bones.size() / maxi(verts.size(), 1)
		var mat := mi.get_active_material(surf)
		for t in range(0, idx.size(), 3):
			var tri: Array[int] = [idx[t], idx[t + 1], idx[t + 2]]
			if not every and not ((cut >> vr[tri[0]]) & 1 and (cut >> vr[tri[1]]) & 1 and (cut >> vr[tri[2]]) & 1):
				continue
			var p: Array = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, mat]
			for j in 3:
				var v: int = tri[j]
				var acc := Vector3.ZERO
				var nacc := Vector3.ZERO
				for k in per:
					var w := weights[v * per + k]
					if w <= 0.0:
						continue
					var bx := bind_xf[bones[v * per + k]]
					acc += (bx * verts[v]) * w
					nacc += (bx.basis * norms[v]) * w
				p[j] = acc
				p[3 + j] = nacc.normalized()
				p[6 + j] = uvs[v] if uvs.size() > v else Vector2.ZERO
			if near != Vector3.INF and ((p[0] + p[1] + p[2]) / 3.0).distance_to(near) > radius:
				continue
			out.append(p)


func _make_gib(tris: Array, group: Array, center: Vector3, vel: Vector3, chunk: bool, solid := false) -> void:
	# One surface per material (skin, fat, meat, bone...).
	var by_mat := {}
	var aabb := AABB()
	var first := true
	for k: int in group:
		var t: Array = tris[k]
		var mat: Variant = t[9]
		if not by_mat.has(mat):
			var st0 := SurfaceTool.new()
			st0.begin(Mesh.PRIMITIVE_TRIANGLES)
			if mat != null:
				st0.set_material(mat)
			by_mat[mat] = st0
		var st: SurfaceTool = by_mat[mat]
		for j in 3:
			st.set_uv(t[6 + j])
			st.set_normal(t[3 + j])
			st.add_vertex(t[j] - center)
			if first:
				aabb = AABB(t[j] - center, Vector3.ZERO)
				first = false
			else:
				aabb = aabb.expand(t[j] - center)
	var mesh := ArrayMesh.new()
	for mat: Variant in by_mat:
		(by_mat[mat] as SurfaceTool).commit(mesh)
	var body := RigidBody3D.new()
	body.collision_layer = 0
	body.collision_mask = UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC
	var m := MeshInstance3D.new()
	m.mesh = mesh
	body.add_child(m)
	if chunk and not solid:
		# Torn flesh in the broken piece (the skin alone is a hollow shell).
		var f := MeshInstance3D.new()
		var sm := SphereMesh.new()
		var r := clampf(aabb.size.length() * 0.22, 0.012, 0.05)
		sm.radius = r
		sm.height = r * 1.6
		sm.radial_segments = 6
		sm.rings = 3
		f.mesh = sm
		f.material_override = _flesh_mat()
		f.position = aabb.get_center() * 0.6
		body.add_child(f)
	if not chunk and _cap_r > 0.0 and _cap_at != Vector3.INF:
		# The part that came off is open at the cut: fill its real open edge (the loop of
		# triangle edges used once, nearest the joint) - a hollow shell showed inside otherwise.
		var loop := _open_loop(tris, group, _cap_at, _cap_r * 3.0)
		var out := (_cap_at - center).normalized() if _cap_at.distance_to(center) > 0.001 else Vector3.UP
		var ring := PackedVector3Array()
		if loop.size() >= 3:
			for v in loop:
				ring.append(v - center)
		else:
			var u := out.cross(Vector3.UP if absf(out.y) < 0.9 else Vector3.RIGHT).normalized()
			var w := out.cross(u)
			for k in 16:
				var a := TAU * k / 16.0
				ring.append(_cap_at - center + (u * cos(a) + w * sin(a)) * _cap_r * 1.1)
		var cap := UltraWoundMesh.cap(ring, out, _cap_bones, randi())
		body.add_child(cap)
	var cs := CollisionShape3D.new()
	var bx := BoxShape3D.new()
	bx.size = aabb.size.clamp(Vector3.ONE * (0.025 if chunk else 0.06), Vector3.ONE * 2.0) * 0.85
	cs.shape = bx
	cs.position = aabb.get_center()
	body.add_child(cs)
	body.mass = clampf(aabb.size.x * aabb.size.y * aabb.size.z * 900.0, 0.05 if chunk else 1.0, 9.0)
	var root := character.get_tree().current_scene if character.get_tree().current_scene else character.get_parent()
	root.add_child(body)
	body.global_position = center
	body.linear_velocity = vel
	body.angular_velocity = Vector3(randf_range(-6, 6), randf_range(-6, 6), randf_range(-6, 6)) * (2.5 if chunk else 1.0)
	body.add_to_group(&"ultra_gib")
	# (Gibs free themselves after 30 s: drop the freed ones before counting - casting a freed
	# object raised an error once the oldest had expired.)
	for k in range(_gibs.size() - 1, -1, -1):
		if not is_instance_valid(_gibs[k]):
			_gibs.remove_at(k)
	_gibs.append(body)
	while _gibs.size() > MAX_GIBS:
		var old: Variant = _gibs.pop_front()
		if is_instance_valid(old):
			(old as Node).queue_free()
	var life := Timer.new()
	life.one_shot = true
	life.wait_time = 30.0
	life.autostart = true
	life.timeout.connect(body.queue_free)
	body.add_child(life)
	# Chunks bleed where they fly.
	var fx := UltraEffects.instance()
	if chunk and fx and fx.blood_fx and character.damage_profile.blood_on():
		fx.blood_fx.spray(center, vel, 3, vel.length() * 0.8, 15.0, 0.007)


## The open edge of a set of triangles (edges used by only one of them), chained into loops;
## the loop whose middle is nearest `near` (within `max_d`), in order. Empty if none.
static func _open_loop(tris: Array, group: Array, near: Vector3, max_d: float) -> PackedVector3Array:
	var key := func(v: Vector3) -> Vector3i: return Vector3i(roundi(v.x * 4000.0), roundi(v.y * 4000.0), roundi(v.z * 4000.0))
	var count := {}
	var pos := {}
	for k: int in group:
		var t: Array = tris[k]
		for j in 3:
			var a: Vector3 = t[j]
			var b: Vector3 = t[(j + 1) % 3]
			var ka: Vector3i = key.call(a)
			var kb: Vector3i = key.call(b)
			if ka == kb:
				continue
			pos[ka] = a
			pos[kb] = b
			var e := [ka, kb] if str(ka) < str(kb) else [kb, ka]
			var ek := "%s|%s" % e
			count[ek] = int(count.get(ek, 0)) + 1
			if not count.has(ek + "#"):
				count[ek + "#"] = e
	var nbr := {}
	for ek: String in count:
		if ek.ends_with("#") or int(count[ek]) != 1:
			continue
		var e: Array = count[ek + "#"]
		(nbr.get_or_add(e[0], []) as Array).append(e[1])
		(nbr.get_or_add(e[1], []) as Array).append(e[0])
	var seen := {}
	var best := PackedVector3Array()
	var best_d := max_d
	for start: Vector3i in nbr:
		if seen.has(start):
			continue
		var loop := PackedVector3Array()
		var prev: Variant = null
		var cur: Vector3i = start
		for guard in 4000:
			seen[cur] = true
			loop.append(pos[cur])
			var nx: Variant = null
			for m: Vector3i in nbr[cur]:
				if m != prev and not seen.has(m):
					nx = m
					break
			if nx == null:
				break
			prev = cur
			cur = nx
		if loop.size() < 3:
			continue
		var c := Vector3.ZERO
		for v in loop:
			c += v
		c /= loop.size()
		if c.distance_to(near) < best_d:
			best_d = c.distance_to(near)
			best = loop
	return best


## `n` directions spread evenly over a sphere (Fibonacci).
static func _sphere_dirs(n: int) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var golden := PI * (3.0 - sqrt(5.0))
	for i in n:
		var y := 1.0 - (float(i) + 0.5) / n * 2.0
		var r := sqrt(maxf(1.0 - y * y, 0.0))
		out.append(Vector3(cos(golden * i) * r, y, sin(golden * i) * r))
	return out


## Which region each vertex belongs to (by its strongest bone), cached per mesh.
static func _regions_for(mi: MeshInstance3D, sk: Skeleton3D) -> Array:
	var key := mi.mesh.get_rid()
	if _vertex_regions.has(key):
		return _vertex_regions[key]
	var bone_region := PackedByteArray()
	bone_region.resize(sk.get_bone_count())
	for b in sk.get_bone_count():
		bone_region[b] = _region_of_bone(sk, b)
	var out: Array = []
	var mesh := mi.mesh as ArrayMesh
	for surf in mesh.get_surface_count():
		var arr := mesh.surface_get_arrays(surf)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = arr[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
		var per := bones.size() / maxi(verts.size(), 1)
		var vr := PackedByteArray()
		vr.resize(verts.size())
		for v in verts.size():
			var best := 0
			for k in per:
				if weights[v * per + k] > weights[v * per + best]:
					best = k
			var bind := bones[v * per + best]
			var b := mi.skin.get_bind_bone(bind)
			if b < 0:
				b = sk.find_bone(mi.skin.get_bind_name(bind))
			vr[v] = bone_region[maxi(b, 0)]
		out.append(vr)
	_vertex_regions[key] = out
	return out


static func _region_of_bone(sk: Skeleton3D, b: int) -> int:
	while b >= 0:
		var n := sk.get_bone_name(b)
		for r: int in UltraLimbs.BONES:
			if n in UltraLimbs.BONES[r]:
				return r
		b = sk.get_bone_parent(b)
	return R.TORSO


static func _flesh_mat() -> StandardMaterial3D:
	if _flesh == null:
		_flesh = StandardMaterial3D.new()
		_flesh.albedo_color = Color(0.55, 0.08, 0.07)
		_flesh.roughness = 0.35
	return _flesh


static func _drip_mat() -> StandardMaterial3D:
	if _drip == null:
		_drip = StandardMaterial3D.new()
		_drip.albedo_color = Color(0.45, 0.02, 0.02)
		_drip.roughness = 0.2
	return _drip
