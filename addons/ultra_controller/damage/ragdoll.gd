class_name UltraRagdoll
extends Node
## Physics ragdoll for the visible body (13 bodies, ~74 kg) built from the retargeted skeleton:
## capsules along each bone (+Y points down the bone), cone joints for spine, neck, shoulders
## and hips, hinges for elbows and knees. It's cosmetic and local: the simulated character is
## the deterministic knocked-down capsule (ragdoll_state.gd). When getting up, the ragdoll fades
## into the get-up clip from where the body actually lies.

enum J { CONE, HINGE }
## bone, end bone (or "" + length), radius, mass, joint, swing/limit (deg), twist (deg)
const BODIES := [
	["Hips", "Spine", 0.13, 11.0, J.CONE, 10.0, 10.0],
	["Spine", "Chest", 0.12, 8.0, J.CONE, 22.0, 15.0],
	["Chest", "Neck", 0.15, 13.0, J.CONE, 18.0, 12.0],
	["Head", "", 0.1, 5.0, J.CONE, 35.0, 30.0],
	["LeftUpperArm", "LeftLowerArm", 0.05, 2.5, J.CONE, 75.0, 40.0],
	["LeftLowerArm", "LeftHand", 0.045, 2.0, J.HINGE, 140.0, 0.0],
	["RightUpperArm", "RightLowerArm", 0.05, 2.5, J.CONE, 75.0, 40.0],
	["RightLowerArm", "RightHand", 0.045, 2.0, J.HINGE, 140.0, 0.0],
	["LeftUpperLeg", "LeftLowerLeg", 0.075, 9.0, J.CONE, 55.0, 20.0],
	["LeftLowerLeg", "LeftFoot", 0.055, 4.5, J.HINGE, 140.0, 0.0],
	["RightUpperLeg", "RightLowerLeg", 0.075, 9.0, J.CONE, 55.0, 20.0],
	["RightLowerLeg", "RightFoot", 0.055, 4.5, J.HINGE, 140.0, 0.0],
	["LeftFoot", "LeftToes", 0.045, 1.0, J.CONE, 25.0, 10.0],
]

var character: UltraCharacter
var sim: PhysicalBoneSimulator3D
var bones: Array[PhysicalBone3D] = []
var active := false
var _fade := 0.0                          ## 1 = ragdoll, 0 = animation
var _getting_up := false

## --- Active ragdoll ("muscle tone"), and joint limits enforced here: the Jolt integration
## ignores PhysicalBone3D joint limits, so the bones would otherwise fold any way at all.
## 0..1 how hard the body holds its pose when knocked down / once it's lying there.
@export_range(0, 1, 0.01) var tone_start := 1.0
@export_range(0, 1, 0.01) var tone_down := 0.18
@export_range(0, 1, 0.01) var tone_dead := 0.04
@export_range(1, 30, 0.5) var max_joint_speed := 7.0      ## rad/s, any bone vs. its parent
@export_range(1, 30, 0.5) var max_bone_speed := 12.0      ## m/s
const TONE_W := 13.0                       ## muscle natural frequency at full tone (rad/s)
const LIMIT_W := 30.0                      ## joint-limit stiffness (rad/s)
## Brace pose: arms out to break the fall (a falling-forward frame of Death_A).
const BRACE_CLIP := "Death_A"
const BRACE_TIME := 3.3

var _ctl: Array[Dictionary] = []          ## per controlled bone
var _t := 0.0                    ## since the body is down on the ground
var _t_limp := 0.0               ## since it went limp
var _airborne := false
var getup_front := false                  ## presentation: lying face down when getting up
var getup_yaw := NAN                      ## world yaw the get-up clip should start facing
var limit_violation := 0.0
## Steers the tumbling body toward the knocked-down capsule (so the get-up starts near it).
var pull_strength := 1.0
## Torso blown in two (UltraBodyFX halve): the Chest body has no joint to the Spine any more.
var split := false
var _split_dir := Vector3.INF             ## asked for before the ragdoll started


func setup(c: UltraCharacter) -> void:
	character = c
	var sk := c.skeleton
	sim = PhysicalBoneSimulator3D.new()
	sim.name = "Ragdoll"
	# Even inactive, the simulator writes the pose back; zero influence keeps it out of the way.
	sim.active = false
	sim.influence = 0.0
	sk.add_child(sim)
	# Severed parts collapse after the ragdoll has posed the body.
	var dm := sk.get_node_or_null("Dismember")
	if dm:
		sk.move_child(dm, -1)
	_make_bodies(false)


## (Re)build the physical bodies and their muscles. `split`: the Chest body without a joint to
## the Spine (the torso in two). Bodies are always made fresh: Jolt keeps a PhysicalBone3D's
## joint as it was first made whatever joint_type is set to later - and a body swapped in by
## hand came back with no joint at all (every later death split the body at the waist).
func _make_bodies(split_chest: bool) -> void:
	var sk := character.skeleton
	if not bones.is_empty():
		# A new simulator too, in the old one's place: bodies added to one that has already
		# run never got their joints back.
		var at := sim.get_index()
		var old := sim
		sim = PhysicalBoneSimulator3D.new()
		sim.name = "Ragdoll"
		sim.active = old.active
		sim.influence = old.influence
		sk.remove_child(old)
		old.free()
		sk.add_child(sim)
		sk.move_child(sim, at)
	bones.clear()
	_ctl.clear()
	var specs := BODIES.duplicate()
	specs.append(["RightFoot", "RightToes", 0.045, 1.0, J.CONE, 25.0, 10.0])
	for spec: Array in specs:
		var b := sk.find_bone(spec[0])
		if b < 0:
			continue
		var end: String = spec[1]
		var length := 0.18
		if end != "":
			var e := sk.find_bone(end)
			if e >= 0:
				length = sk.get_bone_rest(e).origin.length()
		var pb := PhysicalBone3D.new()
		pb.name = "PB_" + spec[0]
		pb.bone_name = spec[0]
		pb.mass = spec[3]
		pb.friction = 0.8
		pb.bounce = 0.0
		pb.linear_damp = 0.1
		pb.angular_damp = 0.6
		pb.collision_layer = UltraLayers.RAGDOLL
		pb.collision_mask = UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC
		pb.body_offset = Transform3D(Basis(), Vector3(0, length * 0.5, 0))
		var r: float = spec[2]
		var cs := CollisionShape3D.new()
		var cap := CapsuleShape3D.new()
		cap.radius = r
		cap.height = maxf(length + r * 0.6, r * 2.0 + 0.01)
		cs.shape = cap
		pb.add_child(cs)
		if b == sk.find_bone("Hips") or (split_chest and spec[0] == "Chest"):
			pb.joint_type = PhysicalBone3D.JOINT_TYPE_NONE
		elif spec[4] == J.HINGE:
			pb.joint_type = PhysicalBone3D.JOINT_TYPE_HINGE
			# Hinge axis (joint Z) along the bone's X: the elbow / knee bend axis.
			pb.joint_offset = Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(0, -length * 0.5, 0))
			pb.set("joint_constraints/angular_limit_enabled", true)
			pb.set("joint_constraints/angular_limit_upper", 5.0)
			pb.set("joint_constraints/angular_limit_lower", -float(spec[5]))
		else:
			pb.joint_type = PhysicalBone3D.JOINT_TYPE_CONE
			# Cone twist axis (joint X) along the bone (+Y).
			pb.joint_offset = Transform3D(Basis(Vector3.BACK, PI * 0.5), Vector3(0, -length * 0.5, 0))
			pb.set("joint_constraints/swing_span", float(spec[5]))
			pb.set("joint_constraints/twist_span", float(spec[6]))
		sim.add_child(pb)
		bones.append(pb)
	_build_controllers(sk)
	if split_chest:
		var chest := _pb_for(sk, sk.find_bone("Chest"))
		_ctl = _ctl.filter(func(c: Dictionary) -> bool: return c.pb != chest)


func _pb_for(sk: Skeleton3D, b: int) -> PhysicalBone3D:
	for pb in bones:
		if sk.find_bone(pb.bone_name) == b:
			return pb
	return null


func _build_controllers(sk: Skeleton3D) -> void:
	var specs := BODIES.duplicate()
	specs.append(["RightFoot", "RightToes", 0.045, 1.0, J.CONE, 25.0, 10.0])
	var brace := _clip_globals(sk, BRACE_CLIP, BRACE_TIME)
	for spec: Array in specs:
		var b := sk.find_bone(spec[0])
		var pb := _pb_for(sk, b)
		if pb == null or spec[0] == "Hips":
			continue
		var par := sk.get_bone_parent(b)
		var ppb: PhysicalBone3D = null
		while par >= 0 and ppb == null:
			ppb = _pb_for(sk, par)
			if ppb == null:
				par = sk.get_bone_parent(par)
		if ppb == null:
			continue
		var rest_rel := (sk.get_bone_global_rest(par).basis.orthonormalized().inverse() * sk.get_bone_global_rest(b).basis.orthonormalized()).get_rotation_quaternion()
		var brace_rel := rest_rel
		if not brace.is_empty():
			brace_rel = ((brace[par] as Basis).inverse() * (brace[b] as Basis)).get_rotation_quaternion()
		_ctl.append({"pb": pb, "parent": ppb, "bone": b, "pbone": par, "rest_rel": rest_rel,
			"kind": spec[4], "lim": deg_to_rad(float(spec[5])), "snap": rest_rel, "brace": brace_rel})


## Global (skeleton-space) bone bases of a clip frame, composed from its rotation tracks.
func _clip_globals(sk: Skeleton3D, clip: String, t: float) -> Array:
	var lib: AnimationLibrary = character.body_profile.library if character.body_profile else null
	if lib == null or not lib.has_animation(clip):
		return []
	var a := lib.get_animation(clip)
	var local := {}
	for tr in a.get_track_count():
		if a.track_get_type(tr) == Animation.TYPE_ROTATION_3D:
			local[String(a.track_get_path(tr).get_concatenated_subnames())] = a.rotation_track_interpolate(tr, t)
	var g: Array = []
	g.resize(sk.get_bone_count())
	for b in sk.get_bone_count():
		var q: Quaternion = local.get(sk.get_bone_name(b), sk.get_bone_rest(b).basis.get_rotation_quaternion())
		var p := sk.get_bone_parent(b)
		g[b] = (g[p] as Basis) * Basis(q) if p >= 0 else Basis(q)
	return g


## Bone world basis from its physical body (body_offset only translates).
static func _wb(pb: PhysicalBone3D) -> Basis:
	return pb.global_basis.orthonormalized()


func _snapshot_pose() -> void:
	for c in _ctl:
		var pr: PhysicalBone3D = c.parent
		var ch: PhysicalBone3D = c.pb
		c.snap = (_wb(pr).inverse() * _wb(ch)).get_rotation_quaternion()


## Muscles + joint limits + speed limits, as velocity changes (stable at 60 Hz).
func _drive(delta: float) -> void:
	# Two clocks: since going limp, and since the body hit the ground (it can go limp well before
	# - a fall known to be too hard - and must not stiffen, settle or let go of the capsule in
	# mid-air: that all starts at the impact).
	_t_limp += delta
	if _airborne and character.state.is_grounded():
		_airborne = false
	if not _airborne:
		_t += delta
	# Out cold goes as limp as dead.
	var dead := character.state.state == MotorState.Id.DEAD or character.state.has(MotorState.F_UNCONSCIOUS)
	var tone := lerpf(tone_start, tone_down, smoothstep(0.0, 1.2, _t))
	if dead:
		tone = lerpf(tone, tone_dead, smoothstep(0.3, 2.0, _t))
	# Arms come out to break the fall, then relax once down.
	var brace_w := smoothstep(0.12, 0.55, _t_limp) * lerpf(1.0, 0.35, smoothstep(0.9, 1.6, _t)) * (0.5 if dead else 1.0)
	# Once down, the body loses energy fast (it lies still instead of twitching).
	var settle := smoothstep(0.8, 1.6, _t)
	for pb in bones:
		pb.linear_damp = lerpf(0.1, 2.5, settle)
		pb.angular_damp = lerpf(1.5, 6.0, settle)
	var kt := pow(TONE_W, 2.0) * tone
	var ct := 2.0 * 0.9 * TONE_W * sqrt(tone)
	var kl := LIMIT_W * LIMIT_W
	var cl := 2.0 * LIMIT_W
	for c in _ctl:
		var pr: PhysicalBone3D = c.parent
		var ch: PhysicalBone3D = c.pb
		var pw := _wb(pr)
		var cw := _wb(ch)
		var q := (pw.inverse() * cw).get_rotation_quaternion()
		var rest_rel: Quaternion = c.rest_rel
		var goal: Quaternion = (c.snap as Quaternion).slerp(c.brace, brace_w)
		# Joint limit: the nearest allowed relative rotation.
		var d := rest_rel.inverse() * q
		if d.w < 0.0:
			d = -d
		var allowed := q
		var over := 0.0
		if c.kind == J.HINGE:
			# Knees / elbows: never bend the wrong way (backwards about the bone's +X); the rest
			# (twist, the bend itself up to its limit) is left to the muscles.
			var ang := wrapf(2.0 * atan2(d.x, d.w), -PI, PI)
			if ang < deg_to_rad(-4.0):
				allowed = q * Quaternion(Vector3.RIGHT, deg_to_rad(-4.0) - ang)
				over = rad_to_deg(deg_to_rad(-4.0) - ang)
			elif d.get_angle() > c.lim:
				allowed = rest_rel * Quaternion.IDENTITY.slerp(d, c.lim / d.get_angle())
				over = rad_to_deg(d.get_angle() - c.lim)
		elif d.get_angle() > c.lim:
			allowed = rest_rel * Quaternion.IDENTITY.slerp(d, c.lim / d.get_angle())
			over = rad_to_deg(d.get_angle() - c.lim)
		if _t > 0.25:
			limit_violation = maxf(limit_violation, over)
		var w_rel := ch.angular_velocity - pr.angular_velocity
		var dv := Vector3.ZERO
		if kt > 0.0:
			dv += _rot_err(pw, cw, goal) * kt - w_rel * ct
		var lim_err := _rot_err(pw, cw, allowed)
		if lim_err.length() > 0.002:
			dv += lim_err * kl - w_rel * cl * 0.5
		dv *= delta
		var mc := ch.mass
		var mp := pr.mass
		ch.angular_velocity += dv * (mp / (mc + mp))
		pr.angular_velocity -= dv * (mc / (mc + mp))
		# Max joint speed.
		var wr := ch.angular_velocity - pr.angular_velocity
		if wr.length() > max_joint_speed:
			ch.angular_velocity = pr.angular_velocity + wr.normalized() * max_joint_speed
	# Keep the body near the (deterministic) knocked-down capsule, so getting up starts close
	# to where it lies: a soft horizontal pull on the hips.
	var hips := bones[0] if not bones.is_empty() else null
	# Only while falling / tumbling: once down, the body lies where it is (dragging it along
	# the floor would keep it twitching).
	var pull_w := (1.0 - smoothstep(1.0, 1.5, _t)) * pull_strength
	if hips and hips.bone_name == "Hips" and pull_w > 0.0:
		var off := character.state.pos - hips.global_position
		off.y = 0.0
		var cv := character.state.vel
		# Only beyond a dead zone (the hips needn't sit exactly over the capsule), so the body can
		# come to rest.
		var excess := off.normalized() * maxf(off.length() - 0.6, 0.0) if off.length() > 0.001 else Vector3.ZERO
		var want := Vector3(cv.x, 0, cv.z) + excess.limit_length(1.5) * 3.0
		var hv := Vector3(hips.linear_velocity.x, 0, hips.linear_velocity.z)
		var dv := (want - hv) * minf(5.0 * delta, 1.0) * pull_w
		for pb in bones:                   # the whole body, so it doesn't stretch from the hips
			pb.linear_velocity += dv * (1.0 if pb == hips else 0.6)
	for pb in bones:
		if pb.linear_velocity.length() > max_bone_speed:
			pb.linear_velocity = pb.linear_velocity.normalized() * max_bone_speed
		if pb.angular_velocity.length() > max_joint_speed * 2.0:
			pb.angular_velocity = pb.angular_velocity.normalized() * max_joint_speed * 2.0


## In the water the limp body floats: each bone under the surface is pushed up (more than its
## weight once it's well under) and drags in the water.
func _buoy(delta: float) -> void:
	if UltraWater.all.is_empty():
		return
	for pb in bones:
		var d := UltraWater.depth_at(pb.global_position, TickPlatform.current_tick)
		if d <= 0.0:
			continue
		pb.linear_velocity += Vector3.UP * minf(d * 28.0, 15.0) * delta
		pb.linear_velocity *= exp(-2.2 * delta)
		pb.angular_velocity *= exp(-1.8 * delta)


## World axis * angle that turns the child onto `goal` (relative to the parent).
static func _rot_err(pw: Basis, cw: Basis, goal: Quaternion) -> Vector3:
	var want := pw * Basis(goal)
	var e := (want * cw.inverse()).get_rotation_quaternion()
	if e.w < 0.0:
		e = -e
	var ang := e.get_angle()
	return e.get_axis() * ang if ang > 0.0001 else Vector3.ZERO


## Which way the body lies, and the yaw the get-up clip should start from.
func _decide_getup() -> void:
	var sk := character.skeleton
	var chest := _pb_for(sk, sk.find_bone("Chest"))
	var hips := _pb_for(sk, sk.find_bone("Hips"))
	var head := _pb_for(sk, sk.find_bone("Head"))
	if chest == null or hips == null or head == null:
		getup_front = false
		getup_yaw = NAN
		return
	var fwd_local := sk.get_bone_global_rest(sk.find_bone("Chest")).basis.orthonormalized().inverse() * Vector3(0, 0, 1)
	var front := _wb(chest) * fwd_local
	getup_front = front.y < -0.2
	var h := head.global_position - hips.global_position
	h.y = 0.0
	if h.length() < 0.05:
		getup_yaw = NAN
		return
	h = h.normalized()
	# Face-down clip: head ahead of the character. Face-up (LayToIdle): head behind.
	getup_yaw = atan2(-h.x, -h.z) if getup_front else atan2(h.x, h.z)


func _physics_process(delta: float) -> void:
	if character == null or sim == null:
		return
	var st := character.state.state
	var down := st == MotorState.Id.RAGDOLL or st == MotorState.Id.DEAD
	if down and not active:
		start()
	elif st == MotorState.Id.GET_UP and active and not _getting_up:
		_getting_up = true
		_decide_getup()
		character.ragdoll_offset = hips_offset()
		if not is_nan(getup_yaw):
			character.ragdoll_yaw = angle_difference(character.state.body_yaw, getup_yaw)
	elif (st == MotorState.Id.SWIM or st == MotorState.Id.DIVE) and active and not _getting_up:
		_getting_up = true                 # came round in the water: fade into swimming
	elif not down and st != MotorState.Id.GET_UP and active:
		stop()
	if active and not _getting_up:
		_drive(delta)
	if active:
		_buoy(delta)
	if _getting_up:
		_fade = maxf(_fade - delta / 0.6, 0.0)
		sim.influence = _fade
		if _fade <= 0.0:
			stop()


## The torso in two at the waist: the Chest body lets go of the Spine (each half its own
## ragdoll, no muscle across the cut, no pull toward the capsule) and the blast throws the upper
## half along `dir`. Put back when the ragdoll stops (respawn).
func split_waist(dir: Vector3) -> void:
	if split:
		return
	if not active:
		_split_dir = dir
		return
	var sk := character.skeleton
	var cb := sk.find_bone("Chest")
	var chest := _pb_for(sk, cb)
	if chest == null:
		return
	split = true
	# Rebuilt with the Chest body free, the simulation restarted round it: every body kept
	# where it is and moving as it was (the bodies are made in the same order every time).
	var keep := []
	for pb in bones:
		keep.append([pb.global_transform, pb.linear_velocity, pb.angular_velocity])
	sim.physical_bones_stop_simulation()
	_make_bodies(true)
	sim.active = true
	sim.influence = 1.0
	sim.physical_bones_start_simulation()
	for i in mini(bones.size(), keep.size()):
		var pb := bones[i]
		pb.global_transform = keep[i][0]
		pb.linear_velocity = keep[i][1]
		pb.angular_velocity = keep[i][2]
	_snapshot_pose()
	pull_strength = 0.0
	for pb in bones:
		var b := sk.find_bone(pb.bone_name)
		var upper := false
		while b >= 0:
			if b == cb:
				upper = true
				break
			b = sk.get_bone_parent(b)
		# The blast carries the upper half off; the legs and hips mostly drop where they stood.
		# (The body already carries the death push - up to 10 m/s point blank: the half it
		# carries off gets a part of it, ~3 m of flight.)
		if upper:
			pb.linear_velocity = pb.linear_velocity * 0.45 + dir * 1.0 + Vector3.UP * 1.2
		else:
			pb.linear_velocity = pb.linear_velocity * 0.15 + Vector3.UP * 0.3


func _rejoin() -> void:
	var was := split
	split = false
	_split_dir = Vector3.INF
	pull_strength = 1.0
	if was:
		sim.physical_bones_stop_simulation()
		sim.active = false
		sim.influence = 0.0
		_make_bodies(false)


func start() -> void:
	active = true
	_getting_up = false
	_fade = 1.0
	sim.active = true
	sim.influence = 1.0
	sim.physical_bones_start_simulation()
	var v := character.state.vel             # already carries the knock-down push
	for pb in bones:
		pb.linear_velocity = v
		pb.angular_velocity = Vector3.ZERO
		pb.angular_damp = 1.5
	_t = 0.0
	_t_limp = 0.0
	_airborne = not character.state.is_grounded()
	limit_violation = 0.0
	_snapshot_pose()
	if _split_dir != Vector3.INF:
		var d := _split_dir
		_split_dir = Vector3.INF
		split_waist(d)


func stop() -> void:
	if split or _split_dir != Vector3.INF:
		_rejoin()
	active = false
	_getting_up = false
	sim.physical_bones_stop_simulation()
	sim.active = false
	sim.influence = 0.0
	_fade = 0.0


## Where the ragdoll's hips lie relative to the capsule (on the ground plane).
func hips_offset() -> Vector3:
	for pb in bones:
		if pb.bone_name == "Hips":
			var d := pb.global_position - character.state.pos
			return Vector3(d.x, 0, d.z)
	return Vector3.ZERO


func hips_position() -> Vector3:
	for pb in bones:
		if pb.bone_name == "Hips":
			return pb.global_position
	return character.state.pos


func max_speed() -> float:
	var m := 0.0
	for pb in bones:
		m = maxf(m, pb.linear_velocity.length())
	return m
