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
	if set_res == null and ResourceLoader.exists(DEFAULT_ANIM_SET):
		set_res = load(DEFAULT_ANIM_SET) as SinewAnimationSet
	if set_res == null:
		set_res = SinewAnimationSet.new()
	var drv := SinewAnimDriver.new()
	drv.name = "AnimDriver"
	drv.anim_set = set_res.resolved(body_profile.anim_set)
	drv.library = body_profile.library
	drv.extra_libraries = body_profile.extra_libraries
	drv.get_up_time = profile.get_up_time
	anim = drv
	add_child(drv)
	drv.setup(player, skeleton)
	var eq := UltraEquipmentVisual.new()
	eq.name = "Equipment"
	add_child(eq)
	eq.setup(self)
	item_event.connect(func(kind: StringName, d: Dictionary) -> void: anim.item_event(kind, d))
	body_fx = UltraBodyFX.new()
	body_fx.name = "BodyFX"
	add_child(body_fx)
	body_fx.setup(self)
	if SinewWorld.available():
		var r := SinewRagdoll.new()
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
var _motion_on := false


func _drive_motion(input: InputFrame, delta: float) -> void:
	var r := ragdoll as SinewRagdoll
	var offline := UltraNet.mode == UltraNet.Mode.NONE or UltraNet.mode == UltraNet.Mode.OFFLINE
	var on := physical_motion and offline and is_authority() and r != null and r.gait_walking() \
			and state.state in MOTION_STATES and state.is_grounded() and state.platform_id == 0
	if not on:
		_motion_on = false
		motion_command = null
		return
	# What the motor wants: its own target speed along the stick (a copy: it sets flags).
	var wish := input.move_world(input.yaw)
	var speed := motor.target_ground_speed(state.copy(), input) if wish.length() > 0.01 else 0.0
	var u := Vector3(wish.x, 0.0, wish.z).normalized() * speed if speed > 0.0 else Vector3.ZERO
	var hv := Vector3(state.vel.x, 0.0, state.vel.z)
	var v0 := _motion_vel if _motion_on else hv
	var v: Vector3 = r.world.physics.call("character_gait_drive", r._id, state.pos, v0, u, delta)
	v.y = 0.0
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
const PUSH_STATES := [MotorState.Id.IDLE, MotorState.Id.MOVE, MotorState.Id.CROUCH, MotorState.Id.LAND, MotorState.Id.TURN_IN_PLACE]

signal pushed(target: Object, shove: Vector3)

var push_charge := 0.0
var _push_held := false
var _push_due := -1.0               ## s until the pending push lands (-1: none)
var _push_power := 0.0
var _push_wait := 0.0


func simulate(input: InputFrame, delta: float, replaying := false) -> void:
	super.simulate(input, delta, replaying)
	if replaying:
		return
	_drive_motion(input, delta)
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
	if anim is SinewAnimDriver:
		(anim as SinewAnimDriver).play_push(PUSH_CONTACT)


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
		info.shove = shove
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
