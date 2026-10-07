class_name SinewRagdoll
extends UltraRagdoll
## The UltraRagdoll's job done by a Sinew body. UltraCharacter, BodyFX and the camera keep
## talking to it as before (active, getup_front / getup_yaw, split_waist, hips_offset...), and
## the deterministic capsule (RAGDOLL / GET_UP / DEAD states) stays in charge of gameplay:
## this is the body you see.
##
## Standing (`powered`, the default), the upper body is physical: spine, head and arms are
## dynamic bodies whose muscles track the animated pose (gravity compensated, leading it by their
## own lag), hanging off a pelvis and legs that follow the animation kinematically - the
## animation walks (physical legs scraped the floor; they come with the balance controller).
## The skeleton shows the physics. A shot or a blow pushes the part it hit and the body flinches
## for real, then recovers. With `powered` off every part is kinematic. Down, they're dynamic: muscles hold the pose
## of the moment it went over, their tone fading as it settles (a knock-out or death goes limp),
## and for the first ~1.2 s a pull keeps the body near the capsule. Getting up, it lets go into
## the get-up clip over 0.6 s.

## Limbs, as the Sinew core numbers them (limb awareness and effectors).
enum Limb { ARM_L, ARM_R, LEG_L, LEG_R, SPINE, NECK }

## Per part: {name, bone, parent, region, rest}
var parts: Array = []
var world: SinewWorld
var modifier: SinewPoseModifier
var pose_prev: Array[Transform3D] = []      ## the parts, world space, at the last two ticks
var pose_now: Array[Transform3D] = []
var _rig := -1
var _id := 0                                 ## the Sinew character
var _severed := 0                            ## regions already cut off in Sinew
var _part_of_region := {}                    ## region -> the top part of it

## Muscle tone while down (Sinew's tone: 1 = the rig's full muscles).
@export_range(0, 1, 0.01) var down_tone_start := 0.35
@export_range(0, 1, 0.01) var down_tone := 0.1
## Going down, the legs give way at once (a knocked-down body that kept its leg tone stood
## there like a statue and toppled over stiffly): per-part share of the tone above.
@export_range(0, 1, 0.01) var down_legs := 0.15
@export_range(0, 1, 0.01) var down_spine := 0.5
@export_range(0, 1, 0.01) var dead_tone := 0.02
## Total body mass, kg.
@export var body_mass := 75.0
## Standing body physical (muscles track the animation) instead of kinematic.
@export var powered := true
## How much of a standing powered body you see (1 = all physics).
@export_range(0, 1, 0.01) var powered_blend := 1.0
## Muscle stiffness / strength while standing powered (tracking an animation closely).
@export_range(0.5, 4, 0.05) var powered_stiffness := 1.6
## Hit impulse per point of damage, N s (a game's exaggeration: a 9 mm round is ~3 N s).
@export var hit_impulse_per_damage := 0.5
@export var hit_impulse_max := 35.0

var _powered_on := false
var _powered_t := 0.0                         ## seconds since powered on
var _last_anim_hips := Vector3.INF
var _hit_relax := {}                         ## part -> seconds since a hit weakened its limb
var _requests: Array = []                    ## procedural effectors for the coming tick: [method, args...]
## A hit weakens the struck limb's muscles for a moment (a shot arm goes slack, then pulls
## back): tone this low at the hit, back to full over `hit_relax_time`.
@export_range(0, 1, 0.01) var hit_relax_tone := 0.25
@export var hit_relax_time := 0.4


func setup(c: UltraCharacter) -> void:
	character = c
	var sk := c.skeleton
	world = SinewWorld.acquire(c)
	_rig = world.rig_for(c.body_profile, sk, body_mass)
	parts.clear()
	_part_of_region.clear()
	for i in int(world.physics.call("rig_part_count", _rig)):
		var d: Dictionary = world.physics.call("rig_part", _rig, i)
		parts.append(d)
		var r: int = d.region
		var p: int = d.parent
		if r >= 0 and (p < 0 or int(parts[p].region) != r) and not _part_of_region.has(r):
			_part_of_region[r] = i
	_make_character()
	modifier = SinewPoseModifier.new()
	modifier.name = "Sinew"
	modifier.ragdoll = self
	sk.add_child(modifier)
	# Severed parts collapse after the body has posed the skeleton.
	var dm := sk.get_node_or_null("Dismember")
	if dm:
		sk.move_child(dm, -1)
	world.bodies.append(self)


func _exit_tree() -> void:
	if world:
		world.bodies.erase(self)
		if _id:
			world.physics.call("remove_character", _id)
			_id = 0
		world.release()
		world = null


func _make_character() -> void:
	var sk := character.skeleton
	_id = world.physics.call("add_character", _rig, _rigid(sk.global_transform), character.get_instance_id() % 30000 + 1)
	world.physics.call("character_set_kinematic", _id, true)
	_powered_on = false
	_severed = 0
	pose_now = _pose()
	pose_prev = pose_now.duplicate()


# ------------------------------------------------------------------ per tick (SinewWorld)

func sinew_pre_step(dt: float) -> void:
	if character == null or _id == 0:
		return
	_follow_cuts()
	if not active:
		var anim := _anim_world()
		if anim.is_empty():
			_requests.clear()
			return
		if not powered or not character.state.is_grounded():
			# Kinematic: the parts follow the animated pose exactly (also in the air: the
			# stand-in root drive is no balance, it would hold a jump's pelvis like a crane).
			if _powered_on:
				_power(false)
			world.physics.call("character_move_kinematic", _id, anim, dt)
			_requests.clear()
			return
		if not _powered_on:
			_power(true)
		_powered_t += dt
		# Snap onto the animation (no muscle chase): for the first moments (the tree may not have
		# posed the skeleton yet - the arms crept down from a T-pose) and after a teleport (the
		# animated hips jumped: the upper body trailed up to 1.2 m behind for half a second).
		var hips: Vector3 = (anim[0] as Transform3D).origin
		if _powered_t < 0.25 or (_last_anim_hips != Vector3.INF and hips.distance_to(_last_anim_hips) > 0.5):
			world.physics.call("character_set_pose", _id, anim, Vector3.ZERO)
		_last_anim_hips = hips
		# Powered: the legs walk the animation, the upper body's muscles track it.
		world.physics.call("character_move_kinematic", _id, anim, dt)
		world.physics.call("character_set_targets", _id, anim)
		_relax_hit_limbs(dt)
		_apply_requests()
		return
	if _getting_up:
		_requests.clear()
		return
	_apply_requests()
	_t_limp += dt
	if _airborne and character.state.is_grounded():
		_airborne = false
	if not _airborne:
		_t += dt
	var st := character.state
	var tone := lerpf(down_tone_start, down_tone, smoothstep(0.0, 1.2, _t))
	if st.state == MotorState.Id.DEAD or st.has(MotorState.F_UNCONSCIOUS):
		tone = lerpf(tone, dead_tone, smoothstep(0.3, 2.0, _t))
	world.physics.call("character_set_tone", _id, tone)
	# Settling: damping rises once it's down (as the UltraRagdoll's does), so soft muscles
	# pulling toward the pose it fell in don't keep the hands creeping across the floor.
	var settle := smoothstep(0.5, 1.2, _t)
	world.physics.call("character_set_damping", _id, lerpf(0.1, 2.5, settle), lerpf(0.5, 6.0, settle))
	# Holding limbs up against gravity is for a body on its feet: once it's down they lie
	# where they fall (compensation pressing the standing pose into the floor made the hands
	# and feet buzz at 1-3 m/s and kept the hips 40 cm up).
	world.physics.call("character_set_gravity_compensation", _id, 1.0 - smoothstep(0.0, 0.4, _t))
	# Keep the body near the capsule while it falls (the capsule is the gameplay truth).
	var pull := (1.0 - smoothstep(1.0, 1.5, _t)) * pull_strength
	if pull > 0.0 and not pose_now.is_empty():
		var hips := pose_now[0].origin
		var hips_v: Vector3 = world.physics.call("linear_velocity", world.physics.call("character_body", _id, 0))
		var off := Vector3(st.pos.x - hips.x, 0.0, st.pos.z - hips.z)
		var excess := off - off.limit_length(0.6)
		var want := Vector3(st.vel.x, 0.0, st.vel.z) + excess.limit_length(1.5) * 3.0
		var dv := (want - Vector3(hips_v.x, 0.0, hips_v.z)) * minf(5.0 * dt, 1.0) * pull
		world.physics.call("character_add_velocity", _id, dv, 1.0, 0.6)


func _apply_requests() -> void:
	for r: Array in _requests:
		world.physics.callv(r[0], [_id] + r.slice(1))
	_requests.clear()


# ------------------------------------------------------------------ procedural control
# Effectors for the coming physics tick, mixed with the animation by `weight` part by part:
# call them every physics frame for as long as the limb should do it (before the SinewWorld
# steps: a node's _physics_process runs first). They act on the physical parts: standing
# (powered) that's the spine, head and arms; the legs walk the animation until the balancer
# (S5). Down, every part.

## Reach an arm's hand to a world point (out of range: it stretches toward it).
func reach(limb: Limb, point: Vector3, weight := 1.0) -> void:
	_requests.append(["character_reach", limb, point, weight])


## Turn the head toward a world point (at most max_angle off the animated look).
func look_toward(point: Vector3, weight := 1.0, max_angle := 1.2) -> void:
	_requests.append(["character_look_at", point, weight, max_angle])


## Put a leg's ankle at a world point, the foot keeping its animated orientation.
func place_foot(limb: Limb, ankle: Vector3, weight := 1.0) -> void:
	_requests.append(["character_place_foot", limb, ankle, weight])


## Lean the spine: pitch forward (+) / back, roll to the body's right (+) / left, radians.
func lean(pitch: float, roll: float, weight := 1.0) -> void:
	_requests.append(["character_lean", pitch, roll, weight])


## Any part's rotation in its parent part's frame (by part name, e.g. "LeftLowerArm"): a
## procedural pose of your own, mixed in by weight.
func set_part_target(part_name: String, local: Quaternion, weight := 1.0) -> void:
	var i := _part(part_name)
	if i >= 0:
		_requests.append(["character_set_effector", i, local, weight])


## {present, attached, health, end_position, end_velocity, contact, end_contact, reach}
func limb_state(limb: Limb) -> Dictionary:
	return world.physics.call("character_limb_state", _id, limb) if _id != 0 else {}


## Where a part touches something outside the body: [{point, normal, impulse, kind, body}]
## (kind 0 static, 1 kinematic, 2 loose).
func part_contacts(part_name: String) -> Array:
	var i := _part(part_name)
	return world.physics.call("character_part_contacts", _id, i) if _id != 0 and i >= 0 else []


func sinew_post_step(dt: float) -> void:
	if _id == 0:
		return
	pose_prev = pose_now
	pose_now = _pose()
	if not active and modifier:
		var want := powered_blend if _powered_on else 0.0
		modifier.blend = move_toward(modifier.blend, want, dt / 0.3)


## Standing body: physical (true) or kinematic (false). Switching on starts from the animated
## pose, at rest; switching off hands the skeleton back to the animation over 0.3 s.
func _power(on: bool) -> void:
	_powered_on = on
	_powered_t = 0.0
	_last_anim_hips = Vector3.INF
	if on:
		var anim := _anim_world()
		if not anim.is_empty():
			world.physics.call("character_set_pose", _id, anim, Vector3.ZERO)
			world.physics.call("character_set_targets", _id, anim)
		for i in parts.size():
			world.physics.call("character_set_part_kinematic", _id, i, _walks(i))
		world.physics.call("character_set_tone", _id, 1.0)
		world.physics.call("character_set_stiffness", _id, powered_stiffness)
		world.physics.call("character_set_gravity_compensation", _id, 1.0)
		for i in parts.size():
			world.physics.call("character_set_part_tone", _id, i, 1.0 if bool(world.physics.call("character_attached", _id, i)) else 0.0)
	else:
		world.physics.call("character_set_root_assist", _id, Transform3D(), 0.0, 1.0 / 60.0)
		world.physics.call("character_set_kinematic", _id, true)


## Struck limbs come back to full tone over hit_relax_time.
func _relax_hit_limbs(dt: float) -> void:
	for part in _hit_relax.keys():
		var t: float = _hit_relax[part] + dt
		var k := lerpf(hit_relax_tone, 1.0, clampf(t / hit_relax_time, 0.0, 1.0))
		for i in _subtree(part):
			world.physics.call("character_set_part_tone", _id, i, k)
		if t >= hit_relax_time:
			_hit_relax.erase(part)
		else:
			_hit_relax[part] = t


func _subtree(top: int) -> Array:
	var out := []
	for i in parts.size():
		if _below(i, top):
			out.append(i)
	return out


## Parts the animation drives while powered: the pelvis and the legs.
func _walks(i: int) -> bool:
	var n: String = parts[i].name
	return i == 0 or n.contains("Leg") or n.contains("Foot")


## A hit: push the part it struck (the body flinches for real; the muscles bring it back).
## Called on every machine from the replicated `hit` event, like the hit clip.
func hit(region: int, dir: Vector3, amount: float) -> void:
	if _id == 0 or not (_powered_on or active) or not _part_of_region.has(region):
		return
	var part: int = _part_of_region[region]
	if _powered_on and _walks(part):
		part = _part("Spine")          # the legs walk the animation: the shot rocks the body
		if part < 0:
			return
	# The struck part's middle: a capsule's centre in world space.
	var xf: Transform3D = pose_now[part] if part < pose_now.size() else Transform3D()
	var impulse := dir.normalized() * minf(amount * hit_impulse_per_damage, hit_impulse_max)
	var body: int = world.physics.call("character_body", _id, part)
	world.physics.call("apply_impulse", body, impulse, xf.origin)
	if _powered_on:
		_hit_relax[part] = 0.0
		for i in _subtree(part):
			world.physics.call("character_set_part_tone", _id, i, hit_relax_tone)


func _physics_process(delta: float) -> void:
	if character == null or _id == 0:
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
		_getting_up = true
	elif not down and st != MotorState.Id.GET_UP and active:
		stop()
	if _getting_up:
		_fade = maxf(_fade - delta / 0.6, 0.0)
		modifier.blend = _fade
		if _fade <= 0.0:
			stop()


func start() -> void:
	if _powered_on:
		world.physics.call("character_set_root_assist", _id, Transform3D(), 0.0, 1.0 / 60.0)
		_powered_on = false
	active = true
	_getting_up = false
	_fade = 1.0
	_t = 0.0
	_t_limp = 0.0
	_airborne = not character.state.is_grounded()
	limit_violation = 0.0
	var anim := _anim_world()
	var was_physical := modifier.blend >= 0.99
	if not anim.is_empty():
		if not was_physical:
			world.physics.call("character_set_pose", _id, anim, character.state.vel)
		world.physics.call("character_set_targets", _id, anim)
	world.physics.call("character_set_kinematic", _id, false)
	# The knock-down push (a powered body keeps its own motion and gets the push on top).
	if was_physical:
		world.physics.call("character_add_velocity", _id, character.state.vel, 1.0, 1.0)
	else:
		world.physics.call("character_set_velocity", _id, character.state.vel)
	world.physics.call("character_set_tone", _id, down_tone_start)
	world.physics.call("character_set_stiffness", _id, 1.0)
	world.physics.call("character_set_damping", _id, 0.1, 0.5)
	world.physics.call("character_set_gravity_compensation", _id, 1.0)
	for i in parts.size():
		var n: String = parts[i].name
		var k := 1.0
		if n.contains("Leg") or n.contains("Foot"):
			k = down_legs
		elif n in ["Spine", "Chest", "UpperChest"]:
			k = down_spine
		world.physics.call("character_set_part_tone", _id, i, k)
	pose_now = _pose()
	pose_prev = pose_now.duplicate()
	modifier.blend = 1.0
	if _split_dir != Vector3.INF:
		var d := _split_dir
		_split_dir = Vector3.INF
		split_waist(d)


func stop() -> void:
	if split or _split_dir != Vector3.INF:
		_rejoin()
	active = false
	_getting_up = false
	_fade = 0.0
	modifier.blend = 0.0
	_powered_on = false
	world.physics.call("character_set_kinematic", _id, true)
	var anim := _anim_world()
	if not anim.is_empty():
		world.physics.call("character_set_pose", _id, anim, Vector3.ZERO)


## The torso in two at the waist: the chest lets go of the spine and the blast carries the
## upper half off. A fresh body when it stops (respawn).
func split_waist(dir: Vector3) -> void:
	if split:
		return
	if not active:
		_split_dir = dir
		return
	var chest := _part("Chest")
	if chest < 0:
		return
	split = true
	pull_strength = 0.0
	world.physics.call("character_sever", _id, chest)
	for i in parts.size():
		var body: int = world.physics.call("character_body", _id, i)
		var v: Vector3 = world.physics.call("linear_velocity", body)
		var upper := _below(i, chest)
		world.physics.call("set_linear_velocity", body, v * 0.45 + dir + Vector3.UP * 1.2 if upper else v * 0.15 + Vector3.UP * 0.3)


func _rejoin() -> void:
	split = false
	_split_dir = Vector3.INF
	pull_strength = 1.0
	world.physics.call("remove_character", _id)
	_make_character()


## Regions the damage cut off go in Sinew too (the piece goes limp and drops; the gore system
## shows it or throws its gib). A whole body again after a respawn.
func _follow_cuts() -> void:
	var sev := character.state.severed
	if sev == _severed:
		return
	if (sev & _severed) != _severed:          # back in one piece: rebuild
		world.physics.call("remove_character", _id)
		_make_character()
		if active:
			start()
	for r in _part_of_region.keys():
		if (sev >> r) & 1 and not (_severed >> r) & 1:
			world.physics.call("character_sever", _id, _part_of_region[r])
	_severed = sev


func _decide_getup() -> void:
	var chest := _part("Chest")
	var hips := 0
	var head := _part("Neck")
	if chest < 0 or head < 0 or pose_now.is_empty():
		getup_front = false
		getup_yaw = NAN
		return
	var rest: Transform3D = parts[chest].rest
	var fwd_local := rest.basis.orthonormalized().inverse() * Vector3(0, 0, 1)
	var front := pose_now[chest].basis * fwd_local
	getup_front = front.y < -0.2
	var h := pose_now[head].origin - pose_now[hips].origin
	h.y = 0.0
	if h.length() < 0.05:
		getup_yaw = NAN
		return
	h = h.normalized()
	getup_yaw = atan2(-h.x, -h.z) if getup_front else atan2(h.x, h.z)


func hips_offset() -> Vector3:
	if pose_now.is_empty():
		return Vector3.ZERO
	var d := pose_now[0].origin - character.state.pos
	return Vector3(d.x, 0, d.z)


func hips_position() -> Vector3:
	return pose_now[0].origin if not pose_now.is_empty() else character.state.pos


func max_speed() -> float:
	return world.physics.call("character_max_speed", _id) if _id else 0.0


# ------------------------------------------------------------------ helpers

func _pose() -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	out.assign(world.physics.call("character_pose", _id))
	return out


## The animated pose (as the modifier saw it last frame) in world space.
func _anim_world() -> Array:
	if modifier == null or modifier.anim_pose.size() != parts.size():
		return []
	var to_world := _rigid(character.skeleton.global_transform)
	var out := []
	for xf in modifier.anim_pose:
		out.append(to_world * _rigid(xf))
	return out


func _part(part_name: String) -> int:
	for i in parts.size():
		if parts[i].name == part_name:
			return i
	return -1


func _below(i: int, top: int) -> bool:
	while i >= 0:
		if i == top:
			return true
		i = parts[i].parent
	return false


static func _rigid(xf: Transform3D) -> Transform3D:
	return Transform3D(xf.basis.orthonormalized(), xf.origin)
