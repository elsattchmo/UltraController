class_name SinewCharacter
extends UltraCharacter
## A player driven by Sinew, the active-physics body engine (sinew/ core, GDExtension in
## addons/sinew/bin). It inherits movement, weapons, input, net and HUD from UltraCharacter
## untouched; Sinew takes over the body: ragdoll, hit reactions, balance, behaviours.
##
## The body you see is Sinew's (SinewRagdoll replaces the UltraRagdoll the base builds).
## Standing it's powered: muscles track the animation and hits push it for real (S3); knocked
## down, dead or falling it's a muscled physics body lying in Sinew's mirror of the level,
## handing back to the get-up clips.

## The Sinew physics world this character's body lives in (null if the extension didn't load).
var physics: RefCounted


func _ready() -> void:
	super._ready()
	item_event.connect(_on_item_event)
	if not SinewWorld.available():
		push_warning("Sinew: the GDExtension isn't loaded (addons/sinew/bin) - playing as a plain UltraCharacter")


## The clips this character references (re-point roles there; see SinewAnimationSet). Empty =
## addons/sinew/sinew_animset.tres if present, else the body profile's own set, as imported.
@export var sinew_anim_set: SinewAnimationSet


## The base's visual build with Sinew's own pieces: SinewAnimDriver (the clips as they are - no IK,
## no procedural passes) instead of UltraAnimDriver, no TraversalHands (rope / ladder / ledge hand IK),
## and a SinewRagdoll instead of the UltraRagdoll. The UltraCharacter itself is untouched.
func _build_visual() -> void:
	visual_root = Node3D.new()
	visual_root.name = "VisualRoot"
	visual_root.top_level = true
	visual_root.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(visual_root)
	if body_profile == null or body_profile.body_scene == null or not build_visuals:
		return
	body_node = body_profile.body_scene.instantiate() as Node3D
	body_node.name = "Body"
	if body_profile.model_faces_positive_z:
		body_node.rotation.y = PI
	visual_root.add_child(body_node)
	skeleton = body_node.find_child(body_profile.skeleton_name, true, false) as Skeleton3D
	if skeleton:
		skeleton.skeleton_updated.connect(_capture_hitboxes)
	head_mesh = body_node.find_child(body_profile.head_mesh_name, true, false) as MeshInstance3D if body_profile.head_mesh_name != "" else null
	var bm := body_node.find_child(body_profile.body_mesh_name, true, false) as MeshInstance3D
	if body_profile.cap_meshes:
		for capme: MeshInstance3D in [bm, head_mesh]:
			if capme and capme.mesh is ArrayMesh:
				capme.mesh = UltraMeshCap.capped(capme.mesh as ArrayMesh)
	for mi: MeshInstance3D in [bm, head_mesh]:
		if mi == null or mi.mesh == null:
			continue
		for si in mi.mesh.get_surface_count():
			var m := mi.get_active_material(si) as BaseMaterial3D
			if m:
				mi.set_surface_override_material(si, _near_fade_mat(m))
	var player := body_node.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if player == null or skeleton == null:
		set_view_index(view_index)
		_sync_visual(1.0)
		return
	var set_res := sinew_anim_set
	if set_res == null and ResourceLoader.exists(_default_anim_set()):
		set_res = load(_default_anim_set()) as SinewAnimationSet
	if set_res == null:
		set_res = SinewAnimationSet.new()
	var drv := _new_anim_driver()
	drv.name = "AnimDriver"
	drv.anim_set = set_res.resolved(body_profile.anim_set)
	drv.library = body_profile.library
	drv.extra_libraries = body_profile.extra_libraries
	drv.get_up_time = profile.get_up_time
	anim = drv
	add_child(drv)
	drv.setup(player, skeleton)
	var eq := _new_equipment()
	eq.name = "Equipment"
	add_child(eq)
	eq.setup(self)
	item_event.connect(func(kind: StringName, d: Dictionary) -> void: anim.item_event(kind, d))
	body_fx = UltraBodyFX.new()
	body_fx.name = "BodyFX"
	add_child(body_fx)
	body_fx.setup(self)
	if SinewWorld.available():
		var r := _new_ragdoll()
		r.name = "RagdollFX"
		ragdoll = r
		add_child(r)
		r.setup(self)
		physics = r.world.physics
	else:
		ragdoll = UltraRagdoll.new()
		ragdoll.name = "RagdollFX"
		add_child(ragdoll)
		ragdoll.setup(self)
	set_view_index(view_index)
	_sync_visual(1.0)


const DEFAULT_ANIM_SET := "res://addons/sinew/sinew_animset.tres"


# ------------------------------------------------------------------ factories
## The pieces _build_visual puts together - a controller built on Sinew (addons/marksman) swaps its own in.
func _new_anim_driver() -> SinewAnimDriver:
	return SinewAnimDriver.new()


func _new_equipment() -> UltraEquipmentVisual:
	return UltraEquipmentVisual.new()


func _new_ragdoll() -> SinewRagdoll:
	return SinewRagdoll.new()


## The clip references used when `sinew_anim_set` isn't set.
func _default_anim_set() -> String:
	return DEFAULT_ANIM_SET


func _process(delta: float) -> void:
	super._process(delta)
	# The equipment's prop-carrying path drives hand IK unguarded: lend it an inactive one.
	if anim is SinewAnimDriver:
		anim.hand_ik = (anim as SinewAnimDriver).prop_hand_ik if state.held_id != 0 else null


# ------------------------------------------------------------------ physical motion
## The body moves the way its feet allow (single player): the motor still decides what you want
## (direction, speed for the stance / sprint / injuries), but on the ground the capsule moves with
## Sinew's gait - its centre of mass an inverted pendulum over the planted soles, footholds that
## brake and catch it (Gait::drive). Starting takes a step, stopping carries a little, a reversal
## plants a foot and pushes back; nothing is snappier than legs can make it.
## Off: the motor's own movement (as UltraController). Networked play keeps the motor (it has to
## predict) - only OFFLINE / NONE sessions use it.
@export var physical_motion := true
## The motion wanted this tick (world, m/s) while physical motion is on, else null - the gait
## places its feet toward it.
var motion_command: Variant = null
const MOTION_STATES := [MotorState.Id.IDLE, MotorState.Id.MOVE, MotorState.Id.TURN_IN_PLACE]
var _motion_vel := Vector3.ZERO
## Pivot starts (third person, physical motion, no gun up): the body turns toward its new facing at a
## human pace instead of the motor's snap (900 deg/s moving) - eased, at most `pivot_rate` deg/s - and
## while it's still well round (more than PIVOT_FROM) the legs can only push off weakly: the speed
## builds once the first step has turned the body (RDR2: the turn plays before the run).
@export var pivot_rate := 400.0
@export var pivot_accel := 2400.0
const PIVOT_FROM := deg_to_rad(20.0)
const PIVOT_FULL := deg_to_rad(90.0)
const PIVOT_TRAVEL_FROM := 2.5    ## m/s: above this the facing follows the travel (eased in by PIVOT_TRAVEL_FULL)
const PIVOT_TRAVEL_FULL := 4.0
const PIVOT_SPRINT_SHARE := 0.3    ## of pivot_rate left at a sprint
const PIVOT_PUSH := 0.15           ## share of the push-off left while the body faces well away
var _pivot_v := 0.0
var _pivot_on := false
var _motion_on := false

# ------------------------------------------------------------------ being pushed
## A shove taken on the feet (single player, physical motion): its momentum goes into the body's
## motion and the gait's catching steps take it out again - a stumble, over a ledge or down the
## stairs if that's where the steps go - and when the next step can't catch it (Gait::capture_margin
## negative for TRIP_TIME .. TRIP_TIME_FAR s) the body trips and goes down with the speed it has.
const STUMBLE_TIME := 1.0
const TRIP_TIME := 0.5        ## s the next step mustn't be able to catch it, barely gone ..
const TRIP_TIME_FAR := 0.25   ## .. and when it's TRIP_FAR (m) beyond a step's reach
const TRIP_FAR := 0.6
signal tripped(velocity: Vector3)
var _stumble_t := 0.0
var _trip_t := 0.0


## A teleport (respawn, reset) stops the physical motion too: its own velocity carried the body on
## walking from where it landed.
func teleport(pos: Vector3, yaw: float = NAN) -> void:
	super(pos, yaw)
	if ragdoll is SinewRagdoll:
		(ragdoll as SinewRagdoll).moved()
	_motion_vel = Vector3.ZERO
	_motion_on = false
	_stumble_t = 0.0
	_trip_t = 0.0
	motion_command = null


## Take a shove of `dv` (m/s, world). False if it can't be taken on the feet (not walking under
## physical motion) - the caller shoves it the plain way then.
func receive_push(dv: Vector3) -> bool:
	if not _motion_on:
		return false
	var h := Vector3(dv.x, 0.0, dv.z)
	_motion_vel += h
	velocity = Vector3(_motion_vel.x, velocity.y, _motion_vel.z)
	state.vel = Vector3(_motion_vel.x, state.vel.y, _motion_vel.z)
	_stumble_t = STUMBLE_TIME
	_trip_t = 0.0
	var sr := ragdoll as SinewRagdoll
	if sr and sr.world and sr._id != 0:
		# A disturbance: the feet catch the body with full capture steps (a change of mind gets one braking step).
		sr.world.physics.call("character_gait_disturb", sr._id, STUMBLE_TIME)
	if ragdoll is SinewRagdoll and h.length() > 0.01:
		(ragdoll as SinewRagdoll).jolt(h.normalized(), 12.0 * h.length())
	return true


func stumbling() -> bool:
	return _stumble_t > 0.0


## The ball launcher (a test tool): its shot is a dud (no range, no damage); a real ball flies.
func _on_item_event(kind: StringName, d: Dictionary) -> void:
	if kind != &"fire" or not is_authority():
		return
	var def := held_def()
	if def == null or def.id != &"ball_launcher" or not d.has("dir"):
		return
	var dir: Vector3 = d.dir
	var eq := get_node_or_null("Equipment") as UltraEquipmentVisual
	var from: Vector3 = eq.muzzle_transform().origin if eq else (d.origin as Vector3)
	# From the muzzle toward where the aim ray points (the crosshair), clear of the hands.
	var target: Vector3 = (d.origin as Vector3) + dir * 30.0
	var aim := (target - from).normalized()
	SinewBall.launch(self, from + aim * 0.3, aim, def)



func _drive_motion(input: InputFrame, delta: float) -> void:
	var r := ragdoll as SinewRagdoll
	var offline := UltraNet.mode == UltraNet.Mode.NONE or UltraNet.mode == UltraNet.Mode.OFFLINE
	# Staggering (the whole body physical, the balancer stepping it out): the character goes where the
	# simulated body goes - its centre of mass carries the capsule, through the motor's own move, so a
	# body knocked back off a ledge goes over it. (It used to wait behind and floor the body once it was
	# 0.9 m away.)
	if physical_motion and offline and is_authority() and r != null and r.staggering() and state.is_grounded() \
			and state.state in MOTION_STATES:
		var st := r.balance_state()
		if st.has("com"):
			var com: Vector3 = st.com
			var to := Vector3(com.x - state.pos.x, 0.0, com.z - state.pos.z)
			var v := to / delta
			if v.length() > 8.0:
				v = v.normalized() * 8.0
			var before := global_position
			velocity = Vector3(v.x, minf(velocity.y, 0.0), v.z)
			motor.move(state, true)
			var moved := global_position - before
			v = Vector3(moved.x, 0.0, moved.z) / delta
			state.pos = global_position
			# The animation must not walk meanwhile (the muscles would chase a walk cycle that moves
			# with the body: a feedback loop that kicked the legs and launched it): it stands still,
			# the momentum is kept for when the stagger hands back.
			velocity = Vector3(0.0, velocity.y, 0.0)
			state.vel = Vector3(0.0, state.vel.y, 0.0)
			if quantize_state:
				state.quantize()
			_motion_vel = v
			_motion_on = false
			motion_command = null
			return
	var on := physical_motion and offline and is_authority() and r != null and r.gait_walking() \
			and state.state in MOTION_STATES and state.is_grounded() and state.platform_id == 0
	if not on:
		_motion_on = false
		_pivot_on = false
		motion_command = null
		return
	var lag := _pivot(input, delta)
	# What the motor wants: its own target speed along the stick (a copy: it sets flags).
	var wish := input.move_world(input.yaw)
	var speed := motor.target_ground_speed(state.copy(), input) if wish.length() > 0.01 else 0.0
	var u := Vector3(wish.x, 0.0, wish.z).normalized() * speed if speed > 0.0 else Vector3.ZERO
	# Stumbling: nobody walks off while their feet are busy catching them.
	if _stumble_t > 0.0:
		_stumble_t = maxf(_stumble_t - delta, 0.0)
		u *= 1.0 - _stumble_t / STUMBLE_TIME
	var hv := Vector3(state.vel.x, 0.0, state.vel.z)
	var v0 := _motion_vel if _motion_on else hv
	var v: Vector3 = r.world.physics.call("character_gait_drive", r._id, state.pos, v0, u, delta)
	v.y = 0.0
	# Still turning round: little push-off (braking is never held back).
	if v.length() > v0.length():
		v = v0 + (v - v0) * lerpf(1.0, PIVOT_PUSH, smoothstep(PIVOT_FROM, PIVOT_FULL, lag))
	# The motor already moved the capsule at its own velocity: move it by the difference.
	var dv := v - hv
	if dv.length_squared() > 1e-8:
		# Through the motor's own move (steps up, snaps down onto stairs, pushes props, keeps the
		# grounded flags) - a bare slide left the floor on stairs and at a sprint.
		var before := global_position
		velocity = Vector3(dv.x, minf(velocity.y, 0.0), dv.z)
		motor.move(state, true)
		# What the floor / walls let it actually do.
		var moved := global_position - before
		v = hv + Vector3(moved.x, 0.0, moved.z) / delta
		state.pos = global_position
	velocity = Vector3(v.x, velocity.y, v.z)
	state.vel = Vector3(v.x, state.vel.y, v.z)
	if quantize_state:
		state.quantize()
	_motion_vel = v
	_motion_on = true
	motion_command = u
	# A stumble the feet can't catch: it trips (the body goes down with the momentum it has).
	if _stumble_t > 0.0 and is_authority():
		var st: Dictionary = r.world.physics.call("character_gait_state", r._id)
		var margin := float(st.get("capture_margin", 1.0))
		_trip_t = _trip_t + delta if margin < 0.0 else 0.0
		# (Not at once: a body that can't be caught still scrambles a step or two first - the
		# further gone, the sooner it goes down.)
		if _trip_t > lerpf(TRIP_TIME, TRIP_TIME_FAR, clampf(-margin / TRIP_FAR, 0.0, 1.0)):
			_stumble_t = 0.0
			_motion_on = false
			motion_command = null
			tripped.emit(v)
			knock_down(v + Vector3.UP * 0.6)


## The body's facing after the motor's step, turned at a human pace (see pivot_rate); returns how far it
## still is from where the motor wanted it (rad). The motor moves along the aim, never the body's
## facing, so the facing is presentation here (offline only, like the rest of physical motion).
func _pivot(input: InputFrame, delta: float) -> float:
	var want := state.body_yaw
	var gun := UltraMotor.gun_up(state)
	if not input.has(InputFrame.B_VIEW_TP) or gun or pivot_rate <= 0.0:
		_pivot_on = false
		_pivot_v = 0.0
		return 0.0
	if not _pivot_on:
		_pivot_on = true
		_pivot_yaw = want
	# At speed the facing follows where the body is actually going (a sprint can't face about while it
	# still runs the old way), and turns slower the faster it goes: turning round from a sprint is
	# slow down, plant, pivot - the push-off waits for the facing (PIVOT_PUSH).
	var hv := Vector2(state.vel.x, state.vel.z)
	var sp := hv.length()
	var travel_w := smoothstep(PIVOT_TRAVEL_FROM, PIVOT_TRAVEL_FULL, sp)
	if travel_w > 0.0:
		want = _pivot_yaw + angle_difference(_pivot_yaw, want) * (1.0 - travel_w) \
				+ angle_difference(_pivot_yaw, atan2(-hv.x, -hv.y)) * travel_w
	var err := angle_difference(_pivot_yaw, want)
	# Eased: speeds up and brakes to arrive (never overshoots).
	var acc := deg_to_rad(pivot_accel)
	var rate := deg_to_rad(pivot_rate) * lerpf(1.0, PIVOT_SPRINT_SHARE, smoothstep(2.0, 6.0, sp))
	var top := minf(rate, sqrt(2.0 * acc * absf(err)))
	_pivot_v = move_toward(_pivot_v, signf(err) * top, acc * delta)
	var step := _pivot_v * delta
	if absf(step) >= absf(err):
		step = err
		_pivot_v = 0.0
	_pivot_yaw = wrapf(_pivot_yaw + step, -PI, PI)
	state.body_yaw = _pivot_yaw
	# How far round it still has to go: to where the motor is taking the facing (the aim, facing the
	# aim; the way it moves otherwise) - not the motor's next step, which starts from here each tick.
	var goal := input.yaw
	if profile.tp_rotation != MovementProfile.Rotation.FACE_AIM:
		var w := input.move_world(input.yaw)
		goal = atan2(-w.x, -w.z) if Vector2(w.x, w.z).length() > 0.1 else want
	return maxf(absf(angle_difference(_pivot_yaw, want)), absf(angle_difference(_pivot_yaw, goal)))


var _pivot_yaw := 0.0


# ------------------------------------------------------------------ unarmed push (testing)
## Empty-handed, the throw button pushes whatever is in front: tap for a shove that rocks a
## character back, hold (up to PUSH_CHARGE_TIME) for one that knocks it over (DamageInfo.shove
## past the target's DamageProfile.shove_knockdown) - and loose props get the same push. The
## authority applies it PUSH_CONTACT s after the release, when the arms are out.
const PUSH_CHARGE_TIME := 0.8
const PUSH_CONTACT := 0.18
const PUSH_REACH := 0.75            ## chest to the hands' reach, m
const PUSH_SHOVE := Vector2(3.0, 5.0)   ## m/s given to a character: tap .. full charge
const PUSH_COOLDOWN := 0.6
const PUSH_STUMBLE := Vector2(1.2, 4.5)  ## m/s into a Sinew body's motion: tap .. full charge
const PUSH_STATES := [MotorState.Id.IDLE, MotorState.Id.MOVE, MotorState.Id.CROUCH, MotorState.Id.LAND, MotorState.Id.TURN_IN_PLACE]

signal pushed(target: Object, shove: Vector3)

var push_charge := 0.0
var _push_held := false
var _push_due := -1.0               ## s until the pending push lands (-1: none)
var _push_power := 0.0
var _push_wait := 0.0
var _push_arm_t := 0.0
const PUSH_ARMS_HOLD := 0.3


## The arms do the pushing (Sinew's reach, physical): drawn in to the chest while it's charged, then
## straight out at the target's chest - the Push clip threw them up into the air.
func _push_arms(delta: float) -> void:
	var r := ragdoll as SinewRagdoll
	if r == null or not can_push():
		_push_arm_t = 0.0
		return
	var out := _push_arm_t > 0.0
	_push_arm_t = maxf(_push_arm_t - delta, 0.0)
	if not out and push_charge <= 0.0:
		return
	var fwd := _push_dir()
	var side := fwd.cross(Vector3.UP).normalized()       # (to the right)
	var chest := state.pos + Vector3.UP * state.height * 0.74
	var ahead := PUSH_REACH + 0.05 if out else 0.22 - 0.06 * push_charge
	for s in [-1.0, 1.0]:
		var limb := SinewRagdoll.Limb.ARM_R if s > 0.0 else SinewRagdoll.Limb.ARM_L
		r.reach(limb, chest + fwd * ahead + side * (0.17 * s) - Vector3.UP * 0.04)


func simulate(input: InputFrame, delta: float, replaying := false) -> void:
	super.simulate(input, delta, replaying)
	if replaying:
		return
	_drive_motion(input, delta)
	_push_arms(delta)
	_push_wait = maxf(_push_wait - delta, 0.0)
	if _push_due >= 0.0:
		_push_due -= delta
		if _push_due < 0.0:
			_push_land(_push_power)
	var held := input.has(InputFrame.B_THROW)
	var able := can_push()
	if held and able and _push_wait <= 0.0:
		if not _push_held:
			push_charge = 0.0
		push_charge = minf(push_charge + delta / PUSH_CHARGE_TIME, 1.0)
	elif _push_held and not held and able and push_charge > 0.0:
		push(push_charge)
	if not held or not able:
		push_charge = 0.0
	_push_held = held


## Empty hands (no prop held, nothing equipped), standing on the ground.
func can_push() -> bool:
	return state.held_id == 0 and held_def() == null and state.state in PUSH_STATES


## Start a push of `power` 0..1 (0 = the lightest tap): the arms go out, it lands PUSH_CONTACT later.
func push(power: float) -> void:
	_push_power = clampf(power, 0.0, 1.0)
	_push_due = PUSH_CONTACT
	_push_wait = PUSH_COOLDOWN
	push_charge = 0.0
	_push_arm_t = PUSH_CONTACT + PUSH_ARMS_HOLD


func _push_dir() -> Vector3:
	var y := last_input.yaw if last_input else state.body_yaw
	return Vector3(-sin(y), 0.0, -cos(y))


func _push_land(power: float) -> void:
	if not is_authority() or not can_push():
		return
	var fwd := _push_dir()
	var chest := state.pos + Vector3.UP * state.height * 0.72
	var q := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.35
	q.shape = sphere
	q.transform = Transform3D(Basis(), chest + fwd * (PUSH_REACH - 0.2))
	q.collision_mask = UltraLayers.CHARACTER | UltraLayers.HITBOX | UltraLayers.WORLD_DYNAMIC
	q.exclude = [get_rid()] + ([hit_volume.get_rid()] if hit_volume else [])
	var best: Object = null
	var best_d := INF
	for r in get_world_3d().direct_space_state.intersect_shape(q, 16):
		var o := _push_target(r.collider)
		if o == null or o == self:
			continue
		var d := ((o as Node3D).global_position - chest).length() - (10.0 if o is UltraCharacter else 0.0)
		if d < best_d:
			best_d = d
			best = o
	var dv := lerpf(PUSH_SHOVE.x, PUSH_SHOVE.y, power)
	var shove := (fwd + Vector3.UP * 0.1).normalized() * dv
	# A Sinew body takes it on its feet: a tap is a step or two back, a full push a stumble it may
	# not catch (it trips). Anyone else is shoved the controller's way.
	var on_feet := best is SinewCharacter and (best as SinewCharacter).receive_push(fwd * lerpf(PUSH_STUMBLE.x, PUSH_STUMBLE.y, power))
	if best is UltraCharacter:
		var c := best as UltraCharacter
		var info := UltraCombat.DamageInfo.new()
		info.amount = 0.0
		info.kind = &"impact"         # (blunt, no blood; 0 damage: no knockout)
		info.region = UltraLimbs.Region.TORSO
		info.dir = fwd
		info.point = c.state.pos + Vector3.UP * c.state.height * 0.7
		info.attacker_id = net_id
		info.collider = c
		info.shove = Vector3.ZERO if on_feet else shove     # (the hit event still flinches it)
		c.apply_damage(info)
	elif best is RigidBody3D:
		var rb := best as RigidBody3D
		rb.apply_impulse(shove * minf(rb.mass, 80.0), chest + fwd * PUSH_REACH - rb.global_position)
	pushed.emit(best, shove)


## The character or loose prop a collider belongs to (hit volumes and child shapes forward up).
static func _push_target(col: Object) -> Object:
	var n := col as Node
	while n and not (n is UltraCharacter):
		if n is RigidBody3D and not (n as RigidBody3D).freeze:
			return n
		n = n.get_parent()
	return n


## A hit lands on the Sinew body too (every machine: this runs from the `hit` event).
func react_to_hit(region: int, dir: Vector3, amount: float, kind := &"bullet") -> void:
	super.react_to_hit(region, dir, amount, kind)
	if ragdoll is SinewRagdoll:
		(ragdoll as SinewRagdoll).hit(region, dir, amount)


## "sinew 0.1.0 (box3d <commit>)", or "" without the extension.
static func engine_version() -> String:
	if not ClassDB.class_exists(&"SinewPhysics"):
		return ""
	return String(ClassDB.class_call_static(&"SinewPhysics", &"version"))
