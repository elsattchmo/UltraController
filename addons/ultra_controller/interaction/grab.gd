class_name UltraGrab
extends RefCounted
## Physical holding, carrying, throwing and team lifting.
##
## Decisions (grab / drop / throw / charge) run in the action layer on the client and the
## server alike, so they're predicted. The physics (PD force + torque pulling the prop to the
## hold point, gravity compensation limited by the holder's strength, team-lift load sharing,
## breaking the hold) run on the server only, once per server tick, for every holder.

const THROW_CHARGE_TIME := 0.8
const BREAK_DISTANCE := 1.25
const TEAM_BREAK_STRETCH := 0.8
const OMEGA := 12.0               ## hold stiffness (rad/s)
const ZETA := 1.0                 ## critically damped

## Upper-body pose while holding a prop (uses the held-item animation layer).
static var CARRY_DEF: ItemDefinition:
	get:
		if _carry_def == null:
			_carry_def = ItemDefinition.new()
			_carry_def.id = &"__carry"
			_carry_def.anim_roles = {"idle": "walk_carry", "aim": "walk_carry", "fire": "throw"}
		return _carry_def
static var _carry_def: ItemDefinition


static func interactable_of(o: NetObject) -> Interactable:
	return Interactable.find_on(o.get_parent()) if o else null


static func grip_points(rb: Node3D) -> Array[Node3D]:
	var out: Array[Node3D] = []
	for n in rb.get_children():
		if n is Marker3D and String(n.name).begins_with("Grip"):
			out.append(n)
	return out


## Shared (predicted) part, called by the action layer every tick.
static func step(c: UltraCharacter, s: MotorState, i: InputFrame, dt: float, replaying: bool) -> void:
	if s.held_id != 0:
		var o := UltraNet.world.get_object(s.held_id)
		if o == null or o.rigid() == null:
			_release(c, s, 0.0, replaying)
			return
		var swimming := s.state == MotorState.Id.SWIM or s.state == MotorState.Id.DIVE
		var two_hand := s.held_grip >= 0 or s.held_mass > c.profile.lift_limit
		if (swimming or not UltraInjury.two_hands(s)) and two_hand:
			_release(c, s, 0.0, replaying)               # can't swim with a two-hand load
			return
		if UltraMotor.pressed_edge(s, i, InputFrame.B_DROP) or UltraMotor.pressed_edge(s, i, InputFrame.B_INTERACT) or UltraMotor.pressed_edge(s, i, InputFrame.B_GRAB):
			_release(c, s, 0.0, replaying)
			return
		var team := s.held_grip >= 0
		if i.has(InputFrame.B_THROW) and not team:
			s.throw_charge = minf(s.throw_charge + dt / THROW_CHARGE_TIME, 1.0)
		elif s.throw_charge > 0.0:
			var ch := s.throw_charge
			_release(c, s, maxf(ch, 0.15), replaying)
			return
		var m := s.held_mass * (s.team_share if team else 1.0)
		s.carry_mult = clampf(1.0 - (m / maxf(c.profile.carry_capacity, 1.0)) * 0.6, 0.4, 1.0)
		return
	s.carry_mult = 1.0
	var grab := UltraMotor.pressed_edge(s, i, InputFrame.B_GRAB)
	var tap := UltraMotor.pressed_edge(s, i, InputFrame.B_INTERACT)
	if not (grab or tap) or i.target_id == 0:
		return
	var o := UltraNet.world.get_object(i.target_id)
	var it := interactable_of(o)
	if o == null or it == null or o.rigid() == null:
		return
	var physical := it.kind in [Interactable.Kind.GRAB, Interactable.Kind.CARRY, Interactable.Kind.TEAM_LIFT]
	if not physical and not (grab and it.kind == Interactable.Kind.PICKUP):
		return                                           # a tap on an item is a pickup (server)
	var rb := o.rigid()
	var eye := s.pos + Vector3.UP * (s.height - 0.16)
	if eye.distance_to(rb.global_position) > it.max_distance + 0.6:
		return
	var team := it.kind == Interactable.Kind.TEAM_LIFT
	if not team and rb.mass > c.profile.carry_capacity:
		c.emit_item_event(&"too_heavy", {}, replaying)
		return
	s.held_id = i.target_id
	s.held_mass = rb.mass
	s.throw_charge = 0.0
	s.team_share = 1.0
	s.held_grip = _nearest_grip(rb, s.pos) if team else -1
	if not replaying:
		_set_exceptions(c, rb, true)
	c.emit_item_event(&"grab", {"id": s.held_id}, replaying)


static func _nearest_grip(rb: Node3D, from: Vector3) -> int:
	var best := 0
	var bd := INF
	var grips := grip_points(rb)
	for gi in grips.size():
		var d := grips[gi].global_position.distance_to(from)
		if d < bd:
			bd = d
			best = gi
	return best


static func _release(c: UltraCharacter, s: MotorState, throw_charge: float, replaying: bool) -> void:
	var o := UltraNet.world.get_object(s.held_id)
	var rb := o.rigid() if o else null
	if rb and c.is_authority() and not replaying:
		_set_exceptions(c, rb, false)
		if throw_charge > 0.0:
			var aim := Vector3(-sin(c.last_input.yaw) * cos(c.last_input.pitch), sin(c.last_input.pitch), -cos(c.last_input.yaw) * cos(c.last_input.pitch))
			var dv := lerpf(4.0, 14.0, throw_charge) / sqrt(maxf(rb.mass, 0.2))
			rb.linear_velocity = s.vel * 0.8 + (aim + Vector3.UP * 0.15).normalized() * dv
			rb.angular_velocity += Vector3(randf_range(-2, 2), randf_range(-2, 2), randf_range(-2, 2))
	elif rb and not replaying:
		_set_exceptions(c, rb, false)
	if o:
		o.set_meta("held_locally", false)
	if rb and rb.has_meta("grab_rel"):
		rb.remove_meta("grab_rel")
	if rb and rb.has_meta("held_for"):
		rb.remove_meta("held_for")
	if rb and rb.has_meta("far_for"):
		rb.remove_meta("far_for")
	c.emit_item_event(&"throw" if throw_charge > 0.0 else &"drop", {"id": s.held_id}, replaying)
	s.held_id = 0
	s.held_mass = 0.0
	s.held_grip = -1
	s.throw_charge = 0.0
	s.team_share = 1.0
	s.carry_mult = 1.0


static func _set_exceptions(c: UltraCharacter, rb: RigidBody3D, on: bool) -> void:
	if on:
		rb.add_collision_exception_with(c)
		c.add_collision_exception_with(rb)
	else:
		rb.remove_collision_exception_with(c)
		c.remove_collision_exception_with(rb)


## Where a holder wants the prop (or its grip) this tick.
static func hold_target(c: UltraCharacter, rb: RigidBody3D) -> Vector3:
	var s := c.state
	var yaw := c.last_input.yaw
	var pitch := clampf(c.last_input.pitch, -1.0, 0.9)
	var eye := s.pos + Vector3.UP * (s.height - 0.16)
	var fwd := Vector3(-sin(yaw), 0, -cos(yaw))
	if s.held_grip >= 0:
		return s.pos + fwd * 0.55 + Vector3.UP * 0.85
	var aim := Vector3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))
	var r := c.profile.radius
	var right := Vector3(cos(yaw), 0, -sin(yaw))
	if rb.mass <= c.profile.lift_limit and support(rb, right) < 0.14:
		# Small: out in front in the hand, following your look, clear of the camera and body.
		var p := eye + aim * (0.45 + support(rb, -aim)) + Vector3.DOWN * 0.2 * cos(pitch)
		var flat := Vector3(p.x - s.pos.x, 0, p.z - s.pos.z)
		var need := r + 0.08 + maxf(support(rb, -fwd), 0.05)
		if flat.dot(fwd) < need:
			p += fwd * (need - flat.dot(fwd))
		return p
	# Two-handed: carried against the chest within arm's reach, a little higher or lower with
	# your look. Its near face sits just in front of the chest, so the camera never ends up
	# inside it and the arms can wrap its sides.
	var y := s.height * 0.61 + pitch * 0.12 - support(rb, Vector3.UP) * 0.15
	return s.pos + Vector3.UP * y + fwd * (r - 0.05 + support(rb, -fwd))


## How far the body's collision shape reaches from its centre in world direction `dir`.
static func support(rb: RigidBody3D, dir: Vector3) -> float:
	var cs: CollisionShape3D = null
	for n in rb.get_children():
		if n is CollisionShape3D and (n as CollisionShape3D).shape:
			cs = n
			break
	if cs == null:
		return 0.25
	var xf := rb.global_transform * cs.transform
	var d := (xf.basis.orthonormalized().inverse() * dir).normalized()
	var off := (xf.origin - rb.global_position).dot(dir.normalized())
	var sh := cs.shape
	if sh is BoxShape3D:
		var h := (sh as BoxShape3D).size * 0.5
		return off + absf(d.x) * h.x + absf(d.y) * h.y + absf(d.z) * h.z
	if sh is SphereShape3D:
		return off + (sh as SphereShape3D).radius
	if sh is CylinderShape3D:
		var cy := sh as CylinderShape3D
		return off + Vector2(d.x, d.z).length() * cy.radius + absf(d.y) * cy.height * 0.5
	if sh is CapsuleShape3D:
		var cp := sh as CapsuleShape3D
		return off + cp.radius + absf(d.y) * maxf(cp.height * 0.5 - cp.radius, 0.0)
	return off + _size(rb)


## Where a hand meets the shape's surface, coming from the centre along `dir` (world).
## Exact for boxes on their faces; a good approximation otherwise.
static func surface_point(rb: RigidBody3D, from: Vector3, dir: Vector3) -> Vector3:
	var d := dir.normalized()
	var p := rb.global_position
	var along := (from - p) - d * (from - p).dot(d)        # keep the offset across the face
	return p + along + d * support(rb, d)


static func _size(rb: RigidBody3D) -> float:
	var r := 0.25
	for n in rb.get_children():
		if n is CollisionShape3D and (n as CollisionShape3D).shape:
			var aabb := (n as CollisionShape3D).shape.get_debug_mesh().get_aabb()
			r = maxf(r, aabb.size.length() * 0.5)
	return clampf(r, 0.1, 1.0)


## Server: apply holding forces for every holder (once per server tick).
static func server_tick(chars: Array, dt: float) -> void:
	var team := {}               # held id -> [carriers]
	for c: UltraCharacter in chars:
		var s := c.state
		if s.held_id == 0:
			continue
		var o := UltraNet.world.get_object(s.held_id)
		if o == null or o.rigid() == null:
			s.held_id = 0
			continue
		if s.held_grip >= 0:
			if not team.has(s.held_id):
				team[s.held_id] = []
			(team[s.held_id] as Array).append(c)
			continue
		_hold_single(c, o.rigid(), dt)
	for id: int in team:
		_hold_team(team[id], UltraNet.world.get_object(id).rigid(), dt)


static func _hold_single(c: UltraCharacter, rb: RigidBody3D, dt: float) -> void:
	var s := c.state
	# Standing on what you hold: let go (no lifting yourself up).
	if c.motor and c.is_on_floor():
		for k in c.get_slide_collision_count():
			if c.get_slide_collision(k).get_collider() == rb:
				_release(c, s, 0.0, false)
				return
	var target := hold_target(c, rb)
	var p := rb.global_position
	# A fresh grab gets a moment to bring the prop in (it starts on the floor, out of reach of
	# the hold point); after that, pulling it away (snagged, blocked) breaks the hold.
	var held_for := float(rb.get_meta("held_for", 0.0)) + dt
	rb.set_meta("held_for", held_for)
	# Out of reach for a moment (a snap turn swings the hold point away) is fine; staying
	# out of reach (snagged on something) breaks the hold.
	var far_for := float(rb.get_meta("far_for", 0.0))
	far_for = far_for + dt if p.distance_to(target) > BREAK_DISTANCE else 0.0
	rb.set_meta("far_for", far_for)
	if held_for > 0.8 and far_for > 0.4:
		_release(c, s, 0.0, false)
		return
	rb.sleeping = false
	var m := rb.mass
	var g := Vector3.DOWN * float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	var f := m * ((target - p) * OMEGA * OMEGA - (rb.linear_velocity - c.state.vel * 0.0) * 2.0 * ZETA * OMEGA) - m * g
	f = f.limit_length(c.profile.strength_n * UltraInjury.strength_mult(c.state))
	rb.apply_central_force(f)
	# Keep the orientation it had relative to the holder's facing when grabbed.
	if not rb.has_meta("grab_rel"):
		rb.set_meta("grab_rel", Basis(Vector3.UP, -c.last_input.yaw) * rb.global_basis)
	var want: Basis = Basis(Vector3.UP, c.last_input.yaw) * (rb.get_meta("grab_rel") as Basis)
	var err := (want * rb.global_basis.inverse()).get_rotation_quaternion()
	var axis_angle := err.get_axis() * err.get_angle() if err.get_angle() > 0.0001 else Vector3.ZERO
	var inertia := m * pow(_size(rb), 2) * 0.4
	var t := (axis_angle * OMEGA * OMEGA * 0.5 - rb.angular_velocity * 2.0 * ZETA * OMEGA * 0.7) * inertia
	rb.apply_torque(t.limit_length(c.profile.strength_n * 0.3))


static func _hold_team(carriers: Array, rb: RigidBody3D, dt: float) -> void:
	var grips := grip_points(rb)
	if grips.is_empty():
		return
	rb.sleeping = false
	var g := float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	var com := rb.global_transform * rb.center_of_mass
	# Static load share along the beam: the carrier nearer the centre of mass takes more.
	var axis := (grips[grips.size() - 1].global_position - grips[0].global_position)
	var d := []
	for c: UltraCharacter in carriers:
		var gp := grips[clampi(c.state.held_grip, 0, grips.size() - 1)].global_position
		d.append(absf((gp - com).dot(axis.normalized())))
	for k in carriers.size():
		var c: UltraCharacter = carriers[k]
		var share := 1.0
		if carriers.size() >= 2:
			var other := 0.0
			for j in carriers.size():
				if j != k:
					other += float(d[j])
			share = other / maxf(other + float(d[k]), 0.001)
		c.state.team_share = share if carriers.size() >= 2 else 1.0
		var grip := grips[clampi(c.state.held_grip, 0, grips.size() - 1)]
		var gp := grip.global_position
		var target := hold_target(c, rb)
		if gp.distance_to(target) > TEAM_BREAK_STRETCH + 0.6:
			_release(c, c.state, 0.0, false)
			continue
		var r := gp - rb.global_position
		var v := rb.linear_velocity + rb.angular_velocity.cross(r)
		var m_eff := rb.mass / maxf(float(carriers.size()), 1.0)
		var f := m_eff * ((target - gp) * OMEGA * OMEGA * 0.6 - v * 2.0 * ZETA * OMEGA * 0.6) + Vector3.UP * m_eff * g
		f = f.limit_length(c.profile.strength_n * UltraInjury.strength_mult(c.state))
		rb.apply_force(f, r)
