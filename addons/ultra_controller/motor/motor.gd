class_name UltraMotor
extends RefCounted
## Deterministic character motor. `step()` advances a MotorState by one tick from an
## InputFrame using the CharacterBody3D only as a collision probe, so the same call serves
## single-player, the server, client prediction and reconciliation replays.

const STATE_SCRIPTS := {
	MotorState.Id.IDLE: preload("states/ground_state.gd"),
	MotorState.Id.MOVE: preload("states/ground_state.gd"),
	MotorState.Id.CROUCH: preload("states/ground_state.gd"),
	MotorState.Id.CRAWL: preload("states/ground_state.gd"),
	MotorState.Id.LAND: preload("states/ground_state.gd"),
	MotorState.Id.TURN_IN_PLACE: preload("states/ground_state.gd"),
	MotorState.Id.SLIDE: preload("states/slide_state.gd"),
	MotorState.Id.JUMP: preload("states/air_state.gd"),
	MotorState.Id.FALL: preload("states/air_state.gd"),
	MotorState.Id.ROOT_MOTION: preload("states/root_motion_state.gd"),
	MotorState.Id.DEAD: preload("states/dead_state.gd"),
	MotorState.Id.MANTLE: preload("states/traversal_move_state.gd"),
	MotorState.Id.VAULT: preload("states/traversal_move_state.gd"),
	MotorState.Id.LEDGE_CLIMB: preload("states/traversal_move_state.gd"),
	MotorState.Id.LEDGE_HANG: preload("states/ledge_hang_state.gd"),
	MotorState.Id.LADDER: preload("states/climb_state.gd"),
	MotorState.Id.WALL_CLIMB: preload("states/climb_state.gd"),
	MotorState.Id.ROPE: preload("states/rope_state.gd"),
	MotorState.Id.SWIM: preload("states/swim_state.gd"),
	MotorState.Id.DIVE: preload("states/swim_state.gd"),
	MotorState.Id.RAGDOLL: preload("states/ragdoll_state.gd"),
	MotorState.Id.GET_UP: preload("states/ragdoll_state.gd"),
}

const F_TURNING := 1 << 8       ## idle feet turning toward aim (anim plays a turn)

var body: CharacterBody3D
var shape: CollisionShape3D
var profile: MovementProfile
## Injury rules (speed with a bad leg...). The character sets it; a default otherwise.
var damage: DamageProfile = DamageProfile.new()
var anim_set: AnimationSet
## Only the authority applies impulses to rigid bodies; predicting clients just feel the drag.
var apply_pushes := true
## Optional hooks other systems register (traversal scanner, water, ...):
## Callable(motor, state, input) -> int (next state id) or -1 to pass.
var transition_hooks: Array[Callable] = []

var gravity: float = 9.8
var dt: float = 1.0 / 60.0
## World tick this step simulates (moving platforms are a function of it).
var platform_tick: int = 0
## Per-step outputs for presentation (not part of the simulated state).
var last_step_up: float = 0.0
var last_landing: float = 0.0
var floor_friction: float = 1.0
var floor_normal := Vector3.UP
## Water sampled at the start of the step (volumes are static or a function of the tick).
var water: UltraWater
var water_surface := -INF
var water_depth := 0.0            ## water above the feet (0 = dry)

var _handlers := {}
var _sep_query: PhysicsShapeQueryParameters3D
var _pre_move_vel := Vector3.ZERO
var _state_scripts := {}
var _capsule: CapsuleShape3D


func _init(p_body: CharacterBody3D, p_shape: CollisionShape3D, p_profile: MovementProfile, p_set: AnimationSet) -> void:
	body = p_body
	shape = p_shape
	profile = p_profile
	anim_set = p_set
	gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	_capsule = shape.shape as CapsuleShape3D
	if _capsule == null:
		_capsule = CapsuleShape3D.new()
		shape.shape = _capsule
	_capsule = _capsule.duplicate()       # never share between characters
	shape.shape = _capsule
	body.floor_max_angle = deg_to_rad(profile.max_slope_deg)
	body.floor_snap_length = profile.floor_snap
	body.floor_constant_speed = true
	body.floor_block_on_wall = true
	body.floor_stop_on_slope = true
	body.max_slides = 6
	body.motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
	# Platforms are carried by the motor (deterministic, replayable), not by the engine.
	body.platform_floor_layers = 0
	body.platform_wall_layers = 0
	body.platform_on_leave = CharacterBody3D.PLATFORM_ON_LEAVE_DO_NOTHING
	_state_scripts = STATE_SCRIPTS.duplicate()
	transition_hooks.append(UltraTraversal.hook)
	transition_hooks.append(UltraSwim.hook)
	for id: int in _state_scripts:
		var scr: Script = _state_scripts[id]
		if not _handlers.has(scr):
			_handlers[scr] = scr.new()


func handler(id: int) -> MotorStateHandler:
	var scr: Script = _state_scripts.get(id, _state_scripts[MotorState.Id.IDLE])
	return _handlers[scr]


func register_state(id: int, scr: Script) -> void:
	_state_scripts[id] = scr
	if not _handlers.has(scr):
		_handlers[scr] = scr.new()


## Advance `s` by one tick. `s` is modified in place.
func step(s: MotorState, input: InputFrame, p_dt: float) -> void:
	dt = p_dt
	last_step_up = 0.0
	last_landing = 0.0
	_apply_capsule(s.height)
	body.global_position = s.pos
	body.velocity = s.vel
	_ride_platform(s)
	_sample_water(s)

	# Timers shared by every state.
	if pressed_edge(s, input, InputFrame.B_JUMP):
		s.jump_buf_t = profile.jump_buffer
	else:
		s.jump_buf_t = maxf(s.jump_buf_t - dt, 0.0)

	# Transitions: hooks first (traversal, water...), then the state's own rules.
	for _i in 3:
		var nxt := -1
		for h in transition_hooks:
			nxt = int(h.call(self, s, input))
			if nxt >= 0 and nxt != s.state:
				break
			nxt = -1
		if nxt < 0:
			nxt = handler(s.state).next(self, s, input)
		if nxt < 0 or nxt == s.state:
			break
		change_state(s, input, nxt)

	var swimming := s.state == MotorState.Id.SWIM or s.state == MotorState.Id.DIVE
	body.motion_mode = CharacterBody3D.MOTION_MODE_FLOATING if swimming else CharacterBody3D.MOTION_MODE_GROUNDED
	# Swimmers slip past floating props instead of shoving them: bobbing props are never
	# exactly where a predicting client sees them, so colliding would mean corrections.
	if swimming:
		body.collision_mask &= ~UltraLayers.WORLD_DYNAMIC
	else:
		body.collision_mask |= UltraLayers.WORLD_DYNAMIC
	handler(s.state).tick(self, s, input)

	s.pos = body.global_position
	s.vel = body.velocity
	s.state_time += dt
	UltraSwim.update_breath(self, s)
	# (prev_buttons is advanced by the character after the action layer has seen the edges)


func change_state(s: MotorState, input: InputFrame, nxt: int) -> void:
	handler(s.state).exit(self, s, input)
	s.prev_state = s.state
	s.state = nxt
	s.state_time = 0.0
	handler(nxt).enter(self, s, input)


static func pressed_edge(s: MotorState, input: InputFrame, bit: int) -> bool:
	return input.has(bit) and (s.prev_buttons & bit) == 0


# ---------------------------------------------------------------- shared helpers

func horizontal(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)


## Body yaw rules shared by ground states. Returns the yaw error that remains (for turn anims).
func update_body_yaw(s: MotorState, input: InputFrame, moving: bool) -> void:
	var mode := MovementProfile.Rotation.FACE_AIM
	# A gun up faces where it points, in any view (else in third person the gun swung round
	# behind the body).
	var armed := gun_up(s)
	if input.has(InputFrame.B_VIEW_TP) and not armed:
		mode = profile.tp_rotation
		if mode == MovementProfile.Rotation.FACE_MOVE_UNTIL_AIM:
			mode = MovementProfile.Rotation.FACE_AIM if input.has(InputFrame.B_SECONDARY) else MovementProfile.Rotation.FACE_MOVE
	if mode == MovementProfile.Rotation.FACE_AIM:
		var err := angle_difference(s.body_yaw, input.yaw)
		if moving or s.held_id != 0 or not profile.enable_turn_in_place:
			# Moving: feet follow the aim, slightly smoothed so the hips swing rather than snap.
			s.body_yaw = rotate_toward_angle(s.body_yaw, input.yaw, deg_to_rad(900.0) * dt)
			s.set_flag(F_TURNING, false)
			s.turn_v = 0.0
		else:
			# Idle: the spine absorbs aim; past the threshold the feet step round (a turn clip
			# plays from how far we've turned). Eased: speeds up, then slows to stop on the aim.
			var lim := deg_to_rad(minf(profile.turn_in_place_angle, profile.armed_turn_angle) if armed else profile.turn_in_place_angle)
			if absf(err) > lim:
				s.set_flag(F_TURNING, true)
			if s.has(F_TURNING):
				# A gun up: the feet hurry as the twist grows (turning the view quickly, the upper
				# body swung round far ahead of legs stepping at the usual rate).
				var hurry := 1.0 + 2.0 * smoothstep(lim, lim + deg_to_rad(30.0), absf(err)) if armed else 1.0
				var acc := deg_to_rad(profile.turn_in_place_accel) * hurry
				var want := signf(err) * minf(deg_to_rad(profile.turn_in_place_rate) * hurry, sqrt(2.0 * acc * absf(err)))
				s.turn_v = move_toward(s.turn_v, want, acc * dt)
				var step := s.turn_v * dt
				if absf(step) > absf(err):
					step = err
				s.body_yaw += step
				# ... and never further than this behind the aim.
				var lag := angle_difference(s.body_yaw, input.yaw)
				var max_twist := deg_to_rad(profile.armed_max_twist)
				if armed and absf(lag) > max_twist:
					s.body_yaw = wrapf(input.yaw - signf(lag) * max_twist, -PI, PI)
				if absf(angle_difference(s.body_yaw, input.yaw)) < deg_to_rad(2.0):
					s.set_flag(F_TURNING, false)
					s.turn_v = 0.0
			else:
				s.turn_v = 0.0
	else:
		s.set_flag(F_TURNING, false)
		s.turn_v = 0.0
		var hv := horizontal(s.vel)
		if hv.length() > 0.3:
			var target := atan2(-hv.x, -hv.z)
			var speed_k := clampf(hv.length() / maxf(profile.sprint_speed, 0.1), 0.0, 1.0)
			var rate := deg_to_rad(profile.body_turn_rate) * lerpf(1.0, 0.55, speed_k)
			s.body_yaw = rotate_toward_angle(s.body_yaw, target, rate * dt)


## A firearm in hand, up and ready (it faces the aim, and turns in place sooner).
static func gun_up(s: MotorState) -> bool:
	if s.held_uid == 0 or s.action != UltraActionLayer.Action.READY:
		return false
	var d := ItemDB.by_index(s.equipped)
	return d != null and d.kind == ItemDefinition.Kind.FIREARM


static func rotate_toward_angle(from: float, to: float, max_delta: float) -> float:
	var d := angle_difference(from, to)
	return from + clampf(d, -max_delta, max_delta)


func _sample_water(s: MotorState) -> void:
	water = UltraWater.find(s.pos + Vector3.UP * 0.01, platform_tick) if not UltraWater.all.is_empty() else null
	water_surface = water.surface_y(platform_tick) if water else -INF
	water_depth = maxf(water_surface - s.pos.y, 0.0) if water else 0.0


## Ground speed the player is asking for this tick.
func target_ground_speed(s: MotorState, input: InputFrame) -> float:
	var mag := minf(input.move.length(), 1.0)
	if mag < 0.05:
		return 0.0
	var speed: float
	match s.stance:
		MotorState.Stance.CRAWL:
			speed = profile.crawl_speed
		MotorState.Stance.CROUCH:
			speed = profile.crouch_speed
		_:
			var forwardish := input.move.y > 0.45 * mag
			var want_sprint := input.has(InputFrame.B_SPRINT) and profile.enable_sprint and forwardish and mag > 0.5 and s.carry_mult > 0.55 and UltraInjury.can_sprint(s)
			if want_sprint and s.action == UltraActionLayer.Action.RELOADING:
				# Reloading holds you to a jog (the sprint picks up again after) - a sprint used to
				# cancel the reload a tick after it started.
				speed = profile.jog_speed
				s.set_flag(MotorState.F_SPRINTING, false)
			elif want_sprint:
				speed = profile.sprint_speed
				s.set_flag(MotorState.F_SPRINTING, true)
			elif input.has(InputFrame.B_WALK):
				speed = profile.walk_speed * (0.55 if profile.default_gait == MovementProfile.Gait.WALK else 1.0)
			elif mag < profile.walk_deflection:
				speed = profile.walk_speed * mag / profile.walk_deflection
			elif profile.default_gait == MovementProfile.Gait.WALK:
				speed = profile.walk_speed
			else:
				speed = lerpf(profile.walk_speed, profile.jog_speed, (mag - profile.walk_deflection) / (1.0 - profile.walk_deflection))
	if not (input.has(InputFrame.B_SPRINT) and s.stance == MotorState.Stance.STAND):
		s.set_flag(MotorState.F_SPRINTING, false)
	# Aiming down sights with a weapon: careful steps.
	if s.equipped != 0 and input.has(InputFrame.B_SECONDARY):
		speed = minf(speed, profile.walk_speed * 1.15)
		s.set_flag(MotorState.F_SPRINTING, false)
	# Direction penalty only when the body faces the aim (strafing / backpedalling).
	var faces_aim := not input.has(InputFrame.B_VIEW_TP) or profile.tp_rotation == MovementProfile.Rotation.FACE_AIM \
		or (profile.tp_rotation == MovementProfile.Rotation.FACE_MOVE_UNTIL_AIM and input.has(InputFrame.B_SECONDARY))
	if faces_aim:
		var fwd := input.move.y / mag
		var dir_mult := lerpf(profile.strafe_mult, 1.0, fwd) if fwd >= 0.0 else lerpf(profile.strafe_mult, profile.back_mult, -fwd)
		speed *= dir_mult
	return speed * s.carry_mult * UltraSwim.wade_mult(self) * UltraInjury.speed_mult(s, damage)


## Weighty planar acceleration with momentum-limited turning and plant-and-pivot braking.
func accelerate_ground(s: MotorState, wish: Vector3, target_speed: float, friction: float) -> Vector3:
	var hv := horizontal(body.velocity)
	var speed := hv.length()
	var grip := clampf(friction, 0.04, 1.0)
	if target_speed < 0.01 or wish.length_squared() < 0.0001:
		# From a sprint, momentum carries you a step or two before you're stopped.
		var d := lerpf(profile.decel, profile.sprint_stop_decel, smoothstep(profile.jog_speed, profile.sprint_speed * 0.9, speed))
		return hv.move_toward(Vector3.ZERO, d * grip * dt)
	wish = wish.normalized()
	if speed > 0.2:
		var dir := hv / speed
		var dot := dir.dot(wish)
		if dot < -0.35:
			# Reversing: plant and brake hard before pushing the other way.
			return hv.move_toward(Vector3.ZERO, profile.brake_decel * grip * dt)
		var k := clampf((speed - profile.walk_speed) / maxf(profile.sprint_speed - profile.walk_speed, 0.1), 0.0, 1.0)
		var max_turn := deg_to_rad(lerpf(profile.turn_rate_walk, profile.turn_rate_sprint, k)) * dt * lerpf(0.3, 1.0, grip)
		var ang := dir.signed_angle_to(wish, Vector3.UP)
		dir = dir.rotated(Vector3.UP, clampf(ang, -max_turn, max_turn))
		# Speed bleeds a little through hard turns (cornering costs momentum).
		speed *= 1.0 - clampf(absf(ang) - max_turn, 0.0, 1.0) * 0.6 * dt * 10.0
		hv = dir * speed
		wish = dir if absf(ang) > max_turn else wish
	var ratio := speed / maxf(target_speed, 0.01)
	var a := profile.accel * profile.get_accel_mult(ratio) if speed < target_speed 		else lerpf(profile.decel, profile.sprint_stop_decel, smoothstep(profile.jog_speed, profile.sprint_speed * 0.9, speed))
	return hv.move_toward(wish * target_speed, a * grip * dt)


## Probe the floor below the feet: friction and normal (deterministic ray, not last-frame data).
func probe_floor(s: MotorState) -> void:
	floor_friction = 1.0
	floor_normal = Vector3.UP
	var space := body.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(s.pos + Vector3.UP * 0.25, s.pos + Vector3.DOWN * 0.4, body.collision_mask, [body.get_rid()])
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return
	floor_normal = hit.normal
	var col: Object = hit.collider
	var mat: PhysicsMaterial = null
	if col is StaticBody3D:
		mat = (col as StaticBody3D).physics_material_override
	elif col is RigidBody3D:
		mat = (col as RigidBody3D).physics_material_override
	if mat:
		floor_friction = mat.friction


## Carry a rider by its platform's motion from the previous tick to this one.
func _ride_platform(s: MotorState) -> void:
	if s.platform_id == 0:
		return
	var plat := TickPlatform.find(s.platform_id)
	if plat == null:
		s.platform_id = 0
		return
	var prev := plat.pose_at(platform_tick - 1)
	var cur := plat.pose_at(platform_tick)
	var delta := cur * prev.affine_inverse()
	body.global_position = delta * body.global_position
	var fwd := delta.basis * Vector3.FORWARD
	s.body_yaw += atan2(-fwd.x, -fwd.z)
	# Climbing onto / hanging from a platform: the move's anchors ride it too (they were
	# world points: the platform moved off and the climb finished in the air).
	if s.state in [MotorState.Id.MANTLE, MotorState.Id.VAULT, MotorState.Id.LEDGE_CLIMB, MotorState.Id.LEDGE_HANG]:
		s.trav_from = delta * s.trav_from
		s.trav_to = delta * s.trav_to
		s.trav_point = delta * s.trav_point
		s.trav_normal = (delta.basis * s.trav_normal).normalized()


func _update_platform(s: MotorState) -> void:
	var on := 0
	if body.is_on_floor():
		for i in body.get_slide_collision_count():
			var c := body.get_slide_collision(i)
			if c.get_normal().y > 0.7 and c.get_collider() is TickPlatform:
				on = (c.get_collider() as TickPlatform).platform_id
				break
		# Walking along the floor leaves no floor contact among the slide collisions (only
		# standing still pressed into it did): the rider stopped being carried as soon as it
		# moved, and the platform slid away underneath. Ask what's just below instead.
		if on == 0:
			var kc := KinematicCollision3D.new()
			if body.test_move(body.global_transform, Vector3.DOWN * 0.06, kc) and kc.get_normal().y > 0.7 and kc.get_collider() is TickPlatform:
				on = (kc.get_collider() as TickPlatform).platform_id
	if s.platform_id != 0 and on == 0 and not s.is_grounded():
		# Leaving a platform: keep its velocity (jumping off a lift carries you up).
		var plat := TickPlatform.find(s.platform_id)
		if plat:
			var pv := (plat.pose_at(platform_tick).origin - plat.pose_at(platform_tick - 1).origin) / dt
			body.velocity += pv
	s.platform_id = on


## Soft character separation: overlapping characters drift apart instead of blocking.
func _separate(s: MotorState) -> void:
	if profile.character_collision != MovementProfile.CharacterCollision.SOFT:
		return
	if _sep_query == null:
		_sep_query = PhysicsShapeQueryParameters3D.new()
		var cyl := CylinderShape3D.new()
		_sep_query.shape = cyl
		_sep_query.collision_mask = UltraLayers.CHARACTER
	var cyl2 := _sep_query.shape as CylinderShape3D
	cyl2.radius = profile.radius * 2.0
	cyl2.height = s.height
	_sep_query.transform = Transform3D(Basis(), body.global_position + Vector3.UP * s.height * 0.5)
	_sep_query.exclude = [body.get_rid()]
	var hits := body.get_world_3d().direct_space_state.intersect_shape(_sep_query, 8)
	var push := Vector3.ZERO
	for h in hits:
		var other := h.collider as Node3D
		if other == null:
			continue
		var d := body.global_position - other.global_position
		d.y = 0.0
		var dist := d.length()
		var overlap := profile.radius * 2.0 - dist
		if overlap <= 0.0:
			continue
		var dir := d / dist if dist > 0.001 else Vector3.RIGHT.rotated(Vector3.UP, float(body.get_instance_id() % 628) / 100.0)
		push += dir * (overlap / (profile.radius * 2.0))
	if push != Vector3.ZERO:
		body.velocity += push.limit_length(1.0) * profile.separation_speed


## Move with stair stepping, then slide. Updates grounded flags and landing info.
func move(s: MotorState, allow_step: bool) -> void:
	_separate(s)
	var was_grounded := s.is_grounded()
	var fall_speed := -body.velocity.y
	if allow_step and was_grounded:
		_try_step_up()
	_pre_move_vel = body.velocity
	body.move_and_slide()
	_push_bodies()
	var grounded := body.is_on_floor()
	if not grounded and allow_step and was_grounded and body.velocity.y <= 0.5 and s.platform_id == 0:
		grounded = _snap_down()
	s.set_flag(MotorState.F_WAS_GROUNDED, was_grounded)
	s.set_flag(MotorState.F_GROUNDED, grounded)
	_update_platform(s)
	if grounded:
		s.coyote_t = profile.coyote_time
		s.air_time = 0.0
		if not was_grounded:
			last_landing = maxf(fall_speed, 0.0)
			s.land_impact = last_landing
	else:
		s.coyote_t = maxf(s.coyote_t - dt, 0.0)
		s.air_time += dt


## Balance on edges. The capsule's round bottom can rest on a ledge's lip with its middle out
## over the drop (the engine still calls that floor). Nothing under the middle and a real drop
## below: walking out over it steps off (normal fall); stepping back recovers; anything else
## teeters, and after `teeter_time` you topple off toward the drop (RAGDOLL, push in trav_from).
## Pure physics queries on the state: client and server agree.
func update_balance(s: MotorState, i: InputFrame) -> void:
	if not profile.enable_balance or not s.is_grounded() or s.platform_id != 0 or s.stance == MotorState.Stance.CRAWL:
		s.teeter = 0.0
		return
	var p := body.global_position
	var space := body.get_world_3d().direct_space_state
	var mask := body.collision_mask & ~UltraLayers.CHARACTER
	# Moving platforms are left out entirely: a ray can see a TickPlatform's pose a frame stale
	# during replay, and client and server would disagree about the teeter.
	var near_platform := [false]
	var ray := func(from: Vector3, depth: float) -> Dictionary:
		var q := PhysicsRayQueryParameters3D.create(from + Vector3.UP * 0.3, from + Vector3.DOWN * depth, mask, [body.get_rid()])
		var hit := space.intersect_ray(q)
		if not hit.is_empty() and hit.collider is TickPlatform:
			near_platform[0] = true
		return hit
	if not (ray.call(p, profile.step_height + 0.08) as Dictionary).is_empty():
		s.teeter = maxf(s.teeter - dt * 2.0, 0.0)
		return
	var below: Dictionary = ray.call(p, profile.balance_drop + 0.3)
	if near_platform[0]:
		s.teeter = 0.0
		return
	if not below.is_empty() and p.y - (below.position as Vector3).y < profile.balance_drop:
		s.teeter = maxf(s.teeter - dt * 2.0, 0.0)
		return
	# Which way is the drop: the directions around the rim with nothing under them.
	var void_dir := Vector3.ZERO
	for k in 8:
		var d := Vector3(sin(k * TAU / 8.0), 0.0, cos(k * TAU / 8.0))
		if (ray.call(p + d * profile.radius * 0.9, profile.step_height + 0.08) as Dictionary).is_empty():
			void_dir += d
	if void_dir.length() < 0.01 or near_platform[0]:
		s.teeter = 0.0
		return
	void_dir = void_dir.normalized()
	var wish := horizontal(i.move_world(i.yaw))
	var toward := wish.dot(void_dir)
	if wish.length() > 0.2 and toward > 0.35:
		s.teeter = 0.0            # walking off on purpose
		return
	if wish.length() > 0.2 and toward < -0.3:
		s.teeter = maxf(s.teeter - dt * 2.0, 0.0)
		return
	s.teeter += dt
	s.trav_from = void_dir * 2.4 + Vector3.UP * 0.8     # the push if we go over


## Walking off a step (or just after stepping up onto one): stay on the ground if there's
## walkable floor within a step's height below, instead of a few ticks of "falling".
func _snap_down() -> bool:
	# A ray under the capsule's centre, not the capsule: its round bottom rides step edges with
	# a slanted contact the engine won't call floor.
	var p := body.global_position
	var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 0.3, p + Vector3.DOWN * (profile.step_height + 0.06), body.collision_mask, [body.get_rid()])
	var hit := body.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty() or (hit.normal as Vector3).y < cos(body.floor_max_angle):
		return false
	if hit.collider is TickPlatform:
		return false                 # moving platforms: the engine's floor snap carries riders
	var gap := p.y - (hit.position as Vector3).y
	if gap > 0.002:
		var mv := Vector3.DOWN * gap
		var col := KinematicCollision3D.new()
		if body.test_move(body.global_transform, mv, col):
			mv = col.get_travel()
		body.global_position += mv
	body.velocity.y = minf(body.velocity.y, 0.0)
	return true


func _try_step_up() -> void:
	var motion := horizontal(body.velocity) * dt
	if motion.length() < 0.0005:
		return
	var xf := body.global_transform
	var hit := KinematicCollision3D.new()
	if not body.test_move(xf, motion, hit):
		return
	if hit.get_normal().y > cos(body.floor_max_angle):
		return                                   # walkable slope, not a step
	var up := Vector3.UP * profile.step_height
	if body.test_move(xf, up):
		return                                   # head blocked
	var xf_up := xf.translated(up)
	# Push the probe a bit deeper so we land ON the step, not on its lip.
	var fwd := motion.normalized() * maxf(motion.length(), profile.radius * 0.6)
	if body.test_move(xf_up, fwd):
		return                                   # too tall / a wall
	var xf_fwd := xf_up.translated(fwd)
	var down := KinematicCollision3D.new()
	if not body.test_move(xf_fwd, -up - Vector3(0, 0.02, 0), down):
		return                                   # nothing to stand on
	if down.get_normal().y < cos(body.floor_max_angle):
		return
	var rise := profile.step_height - down.get_travel().length() + 0.005
	if rise <= 0.02:
		return
	body.global_position += Vector3.UP * rise
	last_step_up = rise


func _push_bodies() -> void:
	# Velocity-matching push: try to bring the body up to our approach speed along the
	# contact normal, limited by push force. Friction and mass decide what really slides;
	# we end up moving at the body's pace because it's in the way.
	for i in body.get_slide_collision_count():
		var c := body.get_slide_collision(i)
		var rb := c.get_collider() as RigidBody3D
		if rb == null or rb.freeze:
			continue
		var n := -c.get_normal()
		n.y = 0.0
		if n.length() < 0.3:
			continue                                  # standing on it, not pushing it
		n = n.normalized()
		var into := horizontal(_pre_move_vel).dot(n)
		if into <= 0.05:
			continue
		var vb := rb.linear_velocity.dot(n)
		var need := (into - vb) * rb.mass
		var j := clampf(need, 0.0, profile.push_strength * dt)
		if apply_pushes and j > 0.0:
			rb.apply_impulse(n * j, c.get_position() - rb.global_position)
		# The slide stopped us at the contact; keep moving at the pace we're shoving it.
		var follow := minf(vb + j / rb.mass, into)
		if follow > 0.0:
			body.velocity += n * follow


## Falling: how hard (m/s) and how soon (s) we'll hit the ground on the current course - the
## ballistic arc swept as a sphere (the feet's width) against the static world, so a jump to
## the next platform lands on that platform, not on the floor below the gap. {} if it comes
## down in water, on a moving platform, or nowhere within 3 s.
func predict_impact(s: MotorState) -> Dictionary:
	var space := body.get_world_3d().direct_space_state
	var g := gravity * profile.fall_gravity_mult
	if _arc_shape == null:
		_arc_shape = SphereShape3D.new()
		_arc_shape.radius = 0.25
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = _arc_shape
	q.collision_mask = body.collision_mask & (UltraLayers.WORLD_STATIC | UltraLayers.CLIMBABLE)
	q.exclude = [body.get_rid()]
	var step := 0.05
	var p0 := s.pos + Vector3.UP * 0.3                    # sphere resting on the soles
	var v := s.vel
	var t := 0.0
	while t < 3.0:
		var v1 := Vector3(v.x, maxf(v.y - g * step, -profile.max_fall_speed), v.z)
		var d := (v + v1) * 0.5 * step
		q.transform = Transform3D(Basis(), p0)
		q.motion = d
		var r := space.cast_motion(q)
		if r.size() == 2 and float(r[0]) < 1.0:
			var f := float(r[0])
			var at := p0 + d * f
			var vy := -lerpf(v.y, v1.y, f)
			q.transform = Transform3D(Basis(), at + d.normalized() * 0.02)
			var hits := space.intersect_shape(q, 1)
			if not hits.is_empty() and hits[0].collider is TickPlatform:
				return {}
			if not UltraWater.all.is_empty() and UltraWater.find_column(at):
				return {}                                  # coming down in water
			return {"speed": maxf(vy, 0.0), "time": t + step * f, "point": at - Vector3.UP * 0.3}
		p0 += d
		v = v1
		t += step
	return {}


var _arc_shape: SphereShape3D


func gravity_for(s: MotorState, input: InputFrame) -> float:
	var g := gravity
	if body.velocity.y > 0.0:
		if not (input.has(InputFrame.B_JUMP) and s.has(MotorState.F_JUMP_HELD)):
			g *= profile.jump_cut_gravity_mult
	else:
		g *= profile.fall_gravity_mult
	return g


func can_jump(s: MotorState) -> bool:
	if s.held_id != 0 and s.held_mass * s.team_share > profile.lift_limit:
		return false                              # can't hop with a heavy load
	if not UltraInjury.can_jump(s):
		return false                              # a crippled leg won't push off
	return s.jump_buf_t > 0.0 and (s.is_grounded() or s.coyote_t > 0.0)


func do_jump(s: MotorState, input: InputFrame) -> void:
	s.jump_buf_t = 0.0
	s.coyote_t = 0.0
	var v := profile.jump_velocity(gravity) * lerpf(0.75, 1.0, s.carry_mult)
	v *= lerpf(1.0, 0.6, clampf(water_depth / maxf(profile.swim_depth, 0.1), 0.0, 1.0))   # wading
	body.velocity.y = v
	s.set_flag(MotorState.F_JUMP_HELD, true)
	s.set_flag(MotorState.F_GROUNDED, false)


# ---------------------------------------------------------------- stance / capsule

func stance_height(stance: int) -> float:
	match stance:
		MotorState.Stance.CROUCH: return profile.crouch_height
		MotorState.Stance.CRAWL: return profile.crawl_height
	return profile.stand_height


## Can the capsule grow to `h` here?
func has_headroom(s: MotorState, h: float) -> bool:
	if h <= s.height + 0.001:
		return true
	return not body.test_move(body.global_transform, Vector3.UP * (h - s.height + 0.02))


func update_stance(s: MotorState, want: int) -> void:
	if want != s.stance:
		var h := stance_height(want)
		if h < s.height or has_headroom(s, h):
			s.stance = want
	var target := stance_height(s.stance)
	var rate := (profile.stand_height - profile.crouch_height) / maxf(profile.stance_transition, 0.01)
	s.height = move_toward(s.height, target, rate * dt)
	_apply_capsule(s.height)


## Set the capsule height directly (swimming / diving), feet stay put.
func set_height(s: MotorState, h: float) -> void:
	s.height = h
	_apply_capsule(h)


func _apply_capsule(h: float) -> void:
	var r := minf(profile.radius, h * 0.5)
	if not is_equal_approx(_capsule.height, h) or not is_equal_approx(_capsule.radius, r):
		_capsule.radius = r
		_capsule.height = h
		shape.position = Vector3(0, h * 0.5, 0)


func wanted_stance(input: InputFrame) -> int:
	if input.has(InputFrame.B_CRAWL) and profile.enable_crawl:
		return MotorState.Stance.CRAWL
	if input.has(InputFrame.B_CROUCH) and profile.enable_crouch:
		return MotorState.Stance.CROUCH
	return MotorState.Stance.STAND


# ---------------------------------------------------------------- root motion

func start_root_motion(s: MotorState, input: InputFrame, rm_index: int, yaw: float, scale := Vector3.ONE) -> bool:
	var curve := anim_set.rm_curve(rm_index) if anim_set else null
	if curve == null:
		return false
	s.rm_clip = rm_index
	s.rm_t = 0.0
	s.rm_yaw0 = yaw
	s.rm_scale = scale
	change_state(s, input, MotorState.Id.ROOT_MOTION)
	return true
