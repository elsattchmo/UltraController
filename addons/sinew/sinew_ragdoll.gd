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

## Where physics shows, part by part (GTA IV's way): the body plays the animation EXACTLY - your
## IK included (hands on the gun, feet on the ground) - and turns physical only where something
## is happening: a hit makes the struck chain physical for `hit_window` s (an arm hit: that arm; a
## body / head hit: the whole upper body), a stagger the legs too. Standing still with empty hands
## the upper body stays physical (the muscles' idle life). Weights ease per part.
@export var physical_below_speed := 0.8      ## m/s: faster than this the upper body plays the animation
@export var hit_window := 0.9                ## s a struck chain stays physical
var part_w := PackedFloat32Array()           ## per part: 0 = this frame's animation, 1 = physics (shown)
var _dyn := PackedByteArray()                ## per part: dynamic in Sinew (else kinematic, following the animation)
var _hit_t := {}                             ## part -> seconds of hit window left

## Stagger (S5): a hard enough hit on a standing body makes its legs physical and the balancer
## keeps it up - shifting its weight, stepping - until it's steady again (then the legs hand
## back to the animation over 0.3 s) or it can't: in single player that's a real knock-down.
@export var stagger := true
@export var stagger_min_impulse := 10.0      ## N s on the struck part to start one
@export var stagger_max_time := 3.0
@export var stagger_falls := true            ## a lost balance knocks the character down (offline only)
## The balancer's settings for staggers (any BalanceSettings field by name).
@export var balance_settings := {}
var _stagger_t := -1.0                       ## seconds into the stagger (< 0: none)
var _steady_t := 0.0
var _handback_t := -1.0
var _handback_from: Array[Transform3D] = []
## A hit weakens the struck limb's muscles for a moment (a shot arm goes slack, then pulls
## back): tone this low at the hit, back to full over `hit_relax_time`.
@export_range(0, 1, 0.01) var hit_relax_tone := 0.25
## A hit to the torso slackens only the torso, and less (all of the upper body going limp
## folded it over and pulled it off its feet).
@export_range(0, 1, 0.01) var torso_relax_tone := 0.6
@export var hit_relax_time := 0.4

## The procedural walk (S6c): on the ground Sinew's gait makes the pose - footsteps from the motion,
## planted feet locked, legs fitted to the footholds, the rest from key poses sampled off the
## reference clips (SinewAnimationSet.gait_*). Off: the clips' own cycles.
@export var gait := true
## Any GaitSettings field by name (cadence_base, duty_walk, swing_height, bob, arm_swing...).
@export var gait_settings := {}
var gait_w := 0.0                            ## how much of the gait pose shows (eased)
## The torso turned toward the aim off the hips (rad, + left; SinewPoseModifier spreads it up the spine,
## the neck and head taking most): standing, the upper body looks round before the feet turn.
var torso_twist := 0.0
@export var torso_twist_max := deg_to_rad(80.0)
var _twist_v := 0.0
var _twist_raw := 0.0
var _gait_frozen := false
var gait_part_w := PackedFloat32Array()      ## per part: the gait's share (the upper body keeps an item's clip)
var gait_prev: Array[Transform3D] = []       ## the gait pose (world) at the last two ticks
var gait_now: Array[Transform3D] = []
var _gait_on := false
var _gait_running := false


## Every Sinew body in the scene (balls look for bodies to wake here).
static var all: Array[SinewRagdoll] = []


func _enter_tree() -> void:
	if not all.has(self):
		all.append(self)


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
	# The muscles / bones / balance view (off until `sinew_debug`, K, or --sinew-debug).
	var dd := SinewDebugDraw.new()
	dd.name = "SinewDebug"
	dd.ragdoll = self
	add_child(dd)
	# Severed parts collapse after the body has posed the skeleton.
	var dm := sk.get_node_or_null("Dismember")
	if dm:
		sk.move_child(dm, -1)
	world.bodies.append(self)


func _exit_tree() -> void:
	all.erase(self)
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
	_dyn = PackedByteArray()
	part_w = PackedFloat32Array()
	_hit_t.clear()
	_powered_on = false
	_severed = 0
	pose_now = _pose()
	pose_prev = pose_now.duplicate()
	_setup_gait()


func _setup_gait() -> void:
	_gait_on = false
	_gait_running = false
	gait_w = 0.0
	if not gait or character.anim == null or character.anim.skeleton == null:
		return
	world.physics.call("character_gait_enable", _id, true, gait_settings)
	var cycles := SinewGaitCycles.build(character.anim, parts)
	world.physics.call("character_gait_set_cycles", _id, cycles)
	var idle := SinewGaitCycles.idle_pose(character.anim, parts)
	if not idle.is_empty():
		world.physics.call("character_gait_set_idle", _id, idle.locals, idle.pelvis_height)
	gait_part_w.resize(parts.size())
	gait_part_w.fill(1.0)
	_gait_on = true


## The character's ground point and facing in the rig's model space (= the skeleton's).
func _gait_root() -> Transform3D:
	var rel := character.visual_root.global_transform.affine_inverse() * character.skeleton.global_transform
	return _rigid(Transform3D(Basis(Vector3.UP, character.state.body_yaw), character.state.pos) * rel)


## The gait is walking the body (on the ground, not ragdolling): physical motion can drive.
func gait_walking() -> bool:
	return _gait_on and _gait_running and not active


func _update_gait(dt: float) -> void:
	if not _gait_on:
		gait_w = 0.0
		return
	var st := character.state
	var Id := MotorState.Id
	# Staggering, the balancer has the legs: the gait stops, but its last pose stays the target - it is
	# fitted to the ground (a foot up a step, the hips lowered to reach the other). Fading to the clip's
	# flat-ground pose lifted the hips' target 14 cm and the legs hopped the body up to reach it.
	if _stagger_t >= 0.0 and not active and _gait_running:
		_gait_frozen = true
		_update_twist(dt, false)
		return
	if _gait_frozen:
		_gait_frozen = false
		_gait_running = false        # (restarts from where the body stepped to)
		gait_w = 0.0
	# (Not while staggering: the balancer has the legs.)
	var want := not active and _stagger_t < 0.0 and st.is_grounded() and st.state in _gait_states()
	if want and not _gait_running:
		world.physics.call("character_gait_reset", _id, _gait_root())
		gait_now = []
		_gait_running = true
	if _gait_running:
		var pose: Array[Transform3D] = []
		var cmd: Variant = character.get("motion_command")
		# (Not before the tree has posed the skeleton: the gait puts its feet down on the first stance it's given.)
		var home: Variant = _clip_feet() if _powered_t >= 0.25 and _home_hold <= 0 else null
		_home_hold -= 1
		if _gait_reset_pending:
			world.physics.call("character_gait_reset", _id, _gait_root())
			_gait_reset_pending = false
		pose.assign(world.physics.call("character_gait_update", _id, _gait_root(), st.vel, dt, cmd, home))
		gait_prev = gait_now if gait_now.size() == pose.size() else pose
		gait_now = pose
	gait_w = move_toward(gait_w, 1.0 if want else 0.0, dt / 0.2)
	if gait_w <= 0.0 and not want:
		_gait_running = false
	_update_twist(dt, want and _gait_running)
	# Pelvis and legs walk the gait. The upper body takes the gait's arm swing as it moves; standing,
	# holding an item or playing a one-shot (a hit flinch, a swing) it keeps the clips.
	var drv := character.anim as SinewAnimDriver
	var busy := st.held_uid != 0 or st.held_id != 0 or (drv != null and drv.upper_busy())
	var speed := Vector2(st.vel.x, st.vel.z).length()
	var upper := _gait_upper_weight(busy, speed)
	# Standing and settled, the legs are the clip's own (its width, its stance - the gait put the feet
	# under the hips with bent knees); stepping or moving, the gait's - eased both ways (a step lifts
	# off the clip's spot, where the gait's feet already are).
	var stepping := _gait_running and (speed > 0.05 or bool(world.physics.call("character_gait_stepping", _id)))
	# (Feet that pivoted in place, rather than stepped, stand off the clip's spots: the gait keeps them.)
	var off_home := false
	if _gait_running and not stepping:
		var gs: Dictionary = world.physics.call("character_gait_state", _id)
		off_home = bool(gs.get("pivoting", false)) or not bool(gs.get("feet_home", true))
	var legs := 1.0 if stepping or off_home or not _clip_feet_on_ground() else 0.0
	# The gait taking the legs back from the clip: at once - its feet are where the clip's stood (re-seated on
	# them, or within the hand-over's tolerance). A fade mixed a clip foot standing turned out with the gait's
	# lifting it, joint by joint down the leg: the foot spun 30 deg a frame in the air.
	if legs == 1.0 and not _clip_anchor.is_empty():
		for i in parts.size():
			if _walks(i):
				gait_part_w[i] = 1.0
		_clip_anchor = []
		_reseated = false
	for i in parts.size():
		if _walks(i):
			gait_part_w[i] = move_toward(gait_part_w[i], legs, dt / (0.12 if stepping else 0.3))
		else:
			gait_part_w[i] = move_toward(gait_part_w[i], upper, dt / 0.25)
	# While the clip has (or is taking) the legs its feet are watched from where they stood when the hand-over
	# began (guard_clip_feet); once the clip has them all, the gait is re-seated exactly on them - they are its
	# planted feet from then on, so taking the legs back shows no jump.
	# (Not while the clip's feet aren't trusted - just powered on, or a teleport the skeleton hasn't caught up
	# with: seated on the old spots, the body was left 12 cm behind.)
	if _gait_running and legs == 0.0 and _legs_w() < 1.0 and _powered_t >= 0.25 and _home_hold <= 0:
		var feet: Variant = _clip_feet()
		if feet != null and _clip_anchor.is_empty():
			_clip_anchor = feet
		if feet != null and _legs_w() <= 0.0 and not _reseated and world.physics.has_method("character_gait_reseat_feet"):
			# (Only the feet: a whole reset started the phase, the pelvis drop and the lean again at every pause.)
			world.physics.call("character_gait_reseat_feet", _id)
			world.physics.call("character_gait_update", _id, _gait_root(), st.vel, dt, character.get("motion_command"), feet)
			_clip_anchor = feet
			_reseated = true
	elif _legs_w() >= 1.0:
		_clip_anchor = []
		_reseated = false


## The clip's feet (world) as they stood when the clip began taking the legs (re-set when it has them all and
## the gait is re-seated on them); empty while the gait has the legs.
var _clip_anchor: Array = []
var _reseated := false
var _gait_reset_pending := false
## Taking the legs back moves a foot past these (m, rad).
const CLIP_FEET_SLIP := 0.015
const CLIP_FEET_TURN := 0.05


func _legs_w() -> float:
	return gait_part_w[_feet_parts[0]] if _feet_parts.size() == 2 and _feet_parts[0] < gait_part_w.size() else 1.0


## Called by the pose modifier each frame, with the clip's pose (skeleton space) before the gait goes over it.
## While the clip has the legs, its feet are the feet on the ground: if they move or turn (the body's facing
## snapped round to the aim, a change of stance cross-fading two idles' feet) a real foot would pivot on its
## ball or step - so the gait takes the legs back at once, from the very spots they stood on, and steps or
## pivots to the new ones. (Left to the clip, the feet turned 35-110 deg in a frame, flat on the ground.)
func guard_clip_feet(sk_xf: Transform3D, clip: Array) -> void:
	if _clip_anchor.size() != 2 or _feet_parts.size() != 2:
		return
	# (Moved somewhere else - a teleport the character didn't report through moved(): the gait starts again
	# there. Further than any turn on the spot swings a foot.)
	if (sk_xf * (clip[_feet_parts[0]] as Transform3D)).origin.distance_to((_clip_anchor[0] as Transform3D).origin) > 1.5:
		_clip_anchor = []
		_reseated = false
		return
	for k in 2:
		var now: Transform3D = sk_xf * (clip[_feet_parts[k]] as Transform3D)
		var was: Transform3D = _clip_anchor[k]
		var turn := (was.basis.orthonormalized().get_rotation_quaternion().inverse() * now.basis.orthonormalized().get_rotation_quaternion()).get_angle()
		if now.origin.distance_to(was.origin) > CLIP_FEET_SLIP or turn > CLIP_FEET_TURN:
			for i in parts.size():
				if _walks(i):
					gait_part_w[i] = 1.0
			_clip_anchor = []
			_reseated = false
			return


## The motor states the gait walks in (a controller built on Sinew adds crouching).
func _gait_states() -> Array:
	return [MotorState.Id.IDLE, MotorState.Id.MOVE, MotorState.Id.TURN_IN_PLACE, MotorState.Id.LAND]


## How much of the upper body (spine, arms) the gait's cycles show: none while the hands are busy (an item,
## a carried prop, a one-shot), the cycles' arm swing from a slow walk on.
func _gait_upper_weight(busy: bool, speed: float) -> float:
	return 0.0 if busy else smoothstep(0.1, 0.6, speed)


## The clip's feet as world transforms (the gait's standing spots), or null before the first frame.
func _clip_feet() -> Variant:
	if modifier == null or modifier.clip_pose.size() != parts.size():
		return null
	if _feet_parts.is_empty():
		for i in parts.size():
			var b: String = character.skeleton.get_bone_name(parts[i].bone)
			if b == "LeftFoot" or b == "RightFoot":
				_feet_parts.append(i)
		if _feet_parts.size() == 2 and character.skeleton.get_bone_name(parts[_feet_parts[0]].bone) != "LeftFoot":
			_feet_parts.reverse()
	if _feet_parts.size() != 2:
		return null
	var sk_xf := character.skeleton.global_transform
	var out := []
	for i: int in _feet_parts:
		var t: Transform3D = sk_xf * modifier.clip_pose[i]
		out.append(Transform3D(t.basis.orthonormalized(), t.origin))
	return out


var _feet_parts: Array[int] = []
## Ticks the clip's standing feet aren't trusted (after a teleport the skeleton is still where it was: the
## gait put its feet down on the old spots and stepped across to the new ones).
var _home_hold := 0


## The character was moved (teleport / respawn): the gait starts again on the next pose's stance.
func moved() -> void:
	_home_hold = 3
	_clip_anchor = []
	_reseated = false
	# (Whatever the distance: the gait only resets itself on a jump of its root, and a teleport onto the same
	# spot facing another way kept the old footholds - the feet stood backwards and turned round in the air.
	# On the next gait update, where its own reset for a jump would happen.)
	_gait_reset_pending = true


## Is the ground level under the clip's feet (where they stand on flat ground)? On a stair or a slope
## the clip's feet would sink into it or float: the gait's ground-fitted legs stay.
func _clip_feet_on_ground() -> bool:
	var feet: Variant = _clip_feet()
	if feet == null:
		return false
	var y0 := character.state.pos.y
	for t: Transform3D in feet:
		var hit: Dictionary = world.physics.call("ground_below", Vector3(t.origin.x, y0 + 0.4, t.origin.z), 1.0)
		if hit.is_empty() or not bool(hit.get("hit", false)) or absf((hit.point as Vector3).y - y0) > 0.03:
			return false
	return true


## The torso's turn toward the aim: the aim off the hips (the facing, plus the gait's hip offset when
## standing), kept continuous through the back (unwrapped) before the clamp, followed on a damped spring
## with a speed cap (a flick must not snap the chest round).
func _update_twist(dt: float, on: bool) -> void:
	var target := 0.0
	if on:
		var off := angle_difference(character.state.body_yaw, character.last_input.yaw)
		off -= float(world.physics.call("character_gait_pelvis_turn", _id))
		_twist_raw += angle_difference(_twist_raw, off)
		if absf(_twist_raw) > deg_to_rad(200.0):
			_twist_raw = wrapf(_twist_raw, -PI, PI)
		target = clampf(_twist_raw, -torso_twist_max, torso_twist_max)
	const W := 14.0
	var steps := maxi(1, ceili(dt * W / 0.35))
	var h := dt / steps
	for k in steps:
		_twist_v += (W * W * (target - torso_twist) - 2.0 * W * _twist_v) * h
		_twist_v = clampf(_twist_v, -7.0, 7.0)
		torso_twist += _twist_v * h


# ------------------------------------------------------------------ per tick (SinewWorld)

func sinew_pre_step(dt: float) -> void:
	if character == null or _id == 0:
		return
	_follow_cuts()
	_update_gait(dt)
	if not active:
		var anim := _anim_world()
		if anim.is_empty():
			_requests.clear()
			return
		if not powered or not character.state.is_grounded():
			# Kinematic: the parts follow the animated pose exactly (also in the air: the
			# stand-in root drive is no balance, it would hold a jump's pelvis like a crane).
			if _stagger_t >= 0.0:
				_end_stagger(false)
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
			if _stagger_t >= 0.0:
				_end_stagger(false)
			_handback_t = -1.0
			world.physics.call("character_set_pose", _id, anim, Vector3.ZERO)
		_last_anim_hips = hips
		# Powered: the animation drives what isn't physical right now (see part_w).
		_update_parts(dt)
		world.physics.call("character_move_kinematic", _id, _handback(anim, dt), dt)
		world.physics.call("character_set_targets", _id, anim)
		_relax_hit_limbs(dt)
		_apply_requests()
		if _stagger_t >= 0.0:
			_update_stagger(dt, anim)
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
	_drive_parts(_limb_parts(limb))
	_requests.append(["character_reach", limb, point, weight])


## Turn the head toward a world point (at most max_angle off the animated look).
func look_toward(point: Vector3, weight := 1.0, max_angle := 1.2) -> void:
	_drive_parts(_limb_parts(Limb.NECK))
	_requests.append(["character_look_at", point, weight, max_angle])


## Put a leg's ankle at a world point, the foot keeping its animated orientation.
func place_foot(limb: Limb, ankle: Vector3, weight := 1.0) -> void:
	_drive_parts(_limb_parts(limb))
	_requests.append(["character_place_foot", limb, ankle, weight])


## Lean the spine: pitch forward (+) / back, roll to the body's right (+) / left, radians.
func lean(pitch: float, roll: float, weight := 1.0) -> void:
	_drive_parts(_limb_parts(Limb.SPINE))
	_requests.append(["character_lean", pitch, roll, weight])


## Any part's rotation in its parent part's frame (by part name, e.g. "LeftLowerArm"): a
## procedural pose of your own, mixed in by weight.
func set_part_target(part_name: String, local: Quaternion, weight := 1.0) -> void:
	var i := _part(part_name)
	if i >= 0:
		_drive_parts([i])
		_requests.append(["character_set_effector", i, local, weight])


## Code driving a limb makes it physical while it does (and ~0.2 s after), even when the body
## would otherwise play the animation there (gun in hand, running).
func _drive_parts(chain: Array) -> void:
	for i in chain:
		if not _walks(i):
			_hit_t[i] = maxf(float(_hit_t.get(i, 0.0)), 0.2)


func _limb_parts(limb: Limb) -> Array:
	var names: Array = []
	match limb:
		Limb.ARM_L: names = ["LeftShoulder", "LeftUpperArm", "LeftLowerArm", "LeftHand"]
		Limb.ARM_R: names = ["RightShoulder", "RightUpperArm", "RightLowerArm", "RightHand"]
		Limb.LEG_L: names = ["LeftUpperLeg", "LeftLowerLeg", "LeftFoot"]
		Limb.LEG_R: names = ["RightUpperLeg", "RightLowerLeg", "RightFoot"]
		Limb.SPINE: names = ["Spine", "Chest", "UpperChest"]
		Limb.NECK: names = ["Neck"]
	var out := []
	for n in names:
		var i := _part(n)
		if i >= 0:
			out.append(i)
	return out


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
		_all_parts(false, 0.0)      # _update_parts turns on what should be physical
		_hit_t.clear()
		world.physics.call("character_set_tone", _id, 1.0)
		world.physics.call("character_set_stiffness", _id, powered_stiffness)
		world.physics.call("character_set_gravity_compensation", _id, 1.0)
		for i in parts.size():
			world.physics.call("character_set_part_tone", _id, i, 1.0 if bool(world.physics.call("character_attached", _id, i)) else 0.0)
	else:
		world.physics.call("character_set_root_assist", _id, Transform3D(), 0.0, 1.0 / 60.0)
		_all_parts(false, 0.0)


## Struck limbs come back to full tone over hit_relax_time.
func _relax_hit_limbs(dt: float) -> void:
	for part in _hit_relax.keys():
		var t: float = _hit_relax[part] + dt
		for i in _relaxed(part):
			var k := lerpf(_relax_floor(part), 1.0, clampf(t / hit_relax_time, 0.0, 1.0))
			world.physics.call("character_set_part_tone", _id, i, k)
		if t >= hit_relax_time:
			_hit_relax.erase(part)
		else:
			_hit_relax[part] = t


## The parts a hit on `part` slackens: a limb below the hit; a torso hit only the torso.
func _relaxed(part: int) -> Array:
	var torso := UltraLimbs.Region.TORSO
	if int(parts[part].region) != torso:
		return _subtree(part)
	var out := []
	for i in _subtree(part):
		if int(parts[i].region) == torso and not _walks(i):
			out.append(i)
	return out


func _relax_floor(part: int) -> float:
	return torso_relax_tone if int(parts[part].region) == UltraLimbs.Region.TORSO else hit_relax_tone


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


## Dynamic (physics) or kinematic (following the animation) in Sinew, tracked here.
func _set_dyn(i: int, on: bool) -> void:
	if _dyn.size() != parts.size():
		_dyn.resize(parts.size())
		part_w.resize(parts.size())
	if bool(_dyn[i]) == on:
		return
	_dyn[i] = 1 if on else 0
	world.physics.call("character_set_part_kinematic", _id, i, not on)


func _all_parts(dyn: bool, w: float) -> void:
	_dyn.resize(parts.size())
	part_w.resize(parts.size())
	for i in parts.size():
		_dyn[i] = 1 if dyn else 0
		part_w[i] = w
	world.physics.call("character_set_kinematic", _id, not dyn)


## Hands busy or on the move: the upper body plays the animation (and the IK on it).
## Seconds of standing still before the upper body turns physical (see _update_parts).
@export var calm_delay := 0.35
var _calm_t := 0.0


func _upper_animated() -> bool:
	var st := character.state
	if st.held_uid != 0 or st.held_id != 0:
		return true
	if st.state not in [MotorState.Id.IDLE, MotorState.Id.CROUCH, MotorState.Id.TURN_IN_PLACE, MotorState.Id.MOVE]:
		return true
	# Moving, or about to (physical motion: the wish comes before the speed - a slow start left the
	# arms physical while the walk's arm swing came in, and a hand whipped at 14 m/s).
	var cmd: Variant = character.get("motion_command")
	if cmd is Vector3 and Vector2((cmd as Vector3).x, (cmd as Vector3).z).length() > 0.3:
		return true
	return Vector2(st.vel.x, st.vel.z).length() > physical_below_speed


func _update_parts(dt: float) -> void:
	if _dyn.size() != parts.size():
		_all_parts(false, 0.0)
	for k in _hit_t.keys():
		_hit_t[k] = float(_hit_t[k]) - dt
		if _hit_t[k] <= 0.0:
			_hit_t.erase(k)
	# Physical upper body only once it has been still a moment: a reversal passes through zero
	# speed while the pelvis is being swung round (a physical torso folded over in that jolt).
	_calm_t = _calm_t + dt if not _upper_animated() else 0.0
	var calm := _calm_t >= calm_delay
	var legs := _stagger_t >= 0.0 or _handback_t >= 0.0
	for i in parts.size():
		if not bool(world.physics.call("character_attached", _id, i)):
			part_w[i] = 1.0          # a cut-off piece is all physics
			continue
		var want: bool
		if _walks(i):
			want = legs
		else:
			want = calm or _stagger_t >= 0.0 or _hit_t.has(i)
		if _walks(i):
			# The legs go physical with a stagger and come back through the hand-back glide (whose
			# kinematic targets ARE the glide): show them for exactly as long.
			if want:
				_set_dyn(i, _stagger_t >= 0.0)
			part_w[i] = 1.0 if want else 0.0
			continue
		if want:
			_set_dyn(i, true)
			part_w[i] = minf(part_w[i] + dt / 0.15, 1.0)
		else:
			# Ease the picture back to the animation while the part is still physical, then
			# let the animation drive it (no pop: by then nothing of the physics shows).
			part_w[i] = maxf(part_w[i] - dt / 0.3, 0.0)
			if part_w[i] <= 0.0:
				_set_dyn(i, false)


## The chain a hit on `part` makes physical: an arm from its shoulder down; else the upper body.
func _hit_chain(part: int) -> Array:
	var torso := UltraLimbs.Region.TORSO
	if int(parts[part].region) != torso and int(parts[part].region) != UltraLimbs.Region.HEAD:
		var top := part
		while int(parts[top].parent) >= 0 and int(parts[int(parts[top].parent)].region) != torso:
			top = int(parts[top].parent)
		return _subtree(top)
	var out := []
	for i in parts.size():
		if not _walks(i):
			out.append(i)
	return out


## A hit: push the part it struck (the body flinches for real; the muscles bring it back).
## Called on every machine from the replicated `hit` event, like the hit clip.
func hit(region: int, dir: Vector3, amount: float) -> void:
	if _id == 0 or not (_powered_on or active) or not _part_of_region.has(region):
		return
	var part: int = _part_of_region[region]
	if _powered_on and _walks(part) and _stagger_t < 0.0:
		part = _part("Spine")          # the legs walk the animation: the shot rocks the body
		if part < 0:
			return
	if _powered_on and _dyn.size() == parts.size():
		# The struck chain turns physical (at once: its physics pose is the animated one) for a while.
		for i in _hit_chain(part):
			_hit_t[i] = hit_window
			_set_dyn(i, true)
			part_w[i] = 1.0
	# The struck part's middle: a capsule's centre in world space.
	var xf: Transform3D = pose_now[part] if part < pose_now.size() else Transform3D()
	var impulse := dir.normalized() * minf(amount * hit_impulse_per_damage, hit_impulse_max)
	var body: int = world.physics.call("character_body", _id, part)
	world.physics.call("apply_impulse", body, impulse, xf.origin)
	if _powered_on:
		_hit_relax[part] = 0.0
		for i in _relaxed(part):
			world.physics.call("character_set_part_tone", _id, i, _relax_floor(part))
		# (An arm taking a hit swings; it takes a blow to the body, head or legs to unbalance it.)
		var arms := [UltraLimbs.Region.ARM_L, UltraLimbs.Region.ARM_R, UltraLimbs.Region.FOREARM_L, UltraLimbs.Region.FOREARM_R, UltraLimbs.Region.HAND_L, UltraLimbs.Region.HAND_R]
		if stagger and _stagger_t < 0.0 and not region in arms and impulse.length() >= stagger_min_impulse and character.state.is_grounded():
			start_stagger()


## A shove's jolt to the upper body (`impulse` N s along `dir` at the chest) without starting the
## physical-legs stagger: the stumble is the gait's (SinewCharacter.receive_push).
func jolt(dir: Vector3, impulse: float) -> void:
	jolt_region(UltraLimbs.Region.TORSO, dir, impulse)


## The same on any region (an arm swings, the head snaps back...).
func jolt_region(region: int, dir: Vector3, impulse: float) -> void:
	var keep := stagger
	stagger = false
	hit(region, dir, impulse / maxf(hit_impulse_per_damage, 1e-3))
	stagger = keep


## Something is about to strike the body (a ball): make it all physical now - the stagger mode (legs on
## the balancer) - so the contact itself decides what happens. Standing powered bodies only.
func brace() -> void:
	if _id == 0 or active or not _powered_on or _stagger_t >= 0.0 or not character.state.is_grounded():
		return
	start_stagger()


## Legs physical, the balancer on: the body has to stay up by itself for a moment.
func start_stagger() -> void:
	if _id == 0 or not _powered_on or _stagger_t >= 0.0:
		return
	_stagger_t = 0.0
	_steady_t = 0.0
	_handback_t = -1.0
	for i in parts.size():
		if bool(world.physics.call("character_attached", _id, i)):
			_set_dyn(i, true)          # the whole body (the upper body balances too)
			part_w[i] = 1.0
	world.physics.call("character_balance_enable", _id, true, balance_settings)
	world.physics.call("character_balance_reset", _id)


func staggering() -> bool:
	return _stagger_t >= 0.0


## The balancer's view: {fallen, reason, stepping, steps, com, capture_point, support...}
## ({} when it isn't running).
func balance_state() -> Dictionary:
	return world.physics.call("character_balance_state", _id) if _id != 0 else {}


func _update_stagger(dt: float, anim: Array) -> void:
	_stagger_t += dt
	var st: Dictionary = balance_state()
	if st.is_empty():
		_stagger_t = -1.0
		return
	var com_v: Vector3 = st.com_velocity
	var hips: Vector3 = (anim[0] as Transform3D).origin
	var off := Vector2(pose_now[0].origin.x - hips.x, pose_now[0].origin.z - hips.z).length() if not pose_now.is_empty() else 0.0
	# Gone: the balancer gave up, or the body is careering away from the capsule.
	if bool(st.fallen) or (off > 0.9 and Vector2(com_v.x, com_v.z).length() > 0.8):
		var v := com_v
		var offline := UltraNet.mode == UltraNet.Mode.NONE or UltraNet.mode == UltraNet.Mode.OFFLINE
		if stagger_falls and offline and character.is_authority():
			# Single player: the body lost its balance, so the character goes down (the capsule
			# follows the body's own motion; the legs stay physical into the fall). In a session
			# the capsule is the truth.
			_end_stagger(false, false)
			character.knock_down(Vector3(v.x, maxf(v.y, 0.0), v.z))
		else:
			_end_stagger(true)
		return
	var steady := not bool(st.stepping) and float(st.capture_error) < -0.03 and Vector2(com_v.x, com_v.z).length() < 0.2
	_steady_t = _steady_t + dt if steady else 0.0
	if (_stagger_t > 0.4 and _steady_t > 0.4) or _stagger_t > stagger_max_time or off > 0.9:
		_end_stagger(true)


## Back to the animation: the legs go kinematic again and glide from where they stand onto the
## animated pose over 0.3 s. Single player, the character first moves to where the body
## stepped to (else the feet would slide back under the capsule).
func _end_stagger(handback: bool, legs_kinematic := true) -> void:
	if _stagger_t < 0.0:
		return
	_stagger_t = -1.0
	world.physics.call("character_balance_enable", _id, false, {})
	for i in parts.size():
		if _walks(i) and legs_kinematic:
			_set_dyn(i, false)
	if not handback or pose_now.is_empty():
		return
	var anim := _anim_world()
	var offline := UltraNet.mode == UltraNet.Mode.NONE or UltraNet.mode == UltraNet.Mode.OFFLINE
	if offline and character.is_authority() and not anim.is_empty() and character.state.is_grounded():
		var d := pose_now[0].origin - (anim[0] as Transform3D).origin
		d.y = 0.0
		if d.length() > 0.12 and d.length() < 0.9:
			character.teleport(character.state.pos + d)
			_last_anim_hips = Vector3.INF     # (expected jump: no snap)
	_handback_t = 0.0
	_handback_from = pose_now.duplicate()


## The kinematic legs' targets: the animation, or on the way back to it after a stagger.
func _handback(anim: Array, dt: float) -> Array:
	if _handback_t < 0.0 or _handback_from.size() != anim.size():
		return anim
	_handback_t += dt
	var k := smoothstep(0.0, 0.3, _handback_t)
	if _handback_t >= 0.3:
		_handback_t = -1.0
		return anim
	var out := anim.duplicate()
	for i in anim.size():
		if _walks(i):
			out[i] = _handback_from[i].interpolate_with(anim[i], k)
	return out


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
	if _stagger_t >= 0.0:
		_end_stagger(false)
	_handback_t = -1.0
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
	_all_parts(true, 1.0)
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
	_all_parts(false, 0.0)
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
