extends MotorStateHandler
## JUMP / FALL: gravity shaping (variable height, heavier fall), momentum-preserving air control.

const Id := MotorState.Id
const AIR_RAGDOLL_LEAD := 0.6       ## s before a ragdoll-hard landing that the body goes limp


func enter(m: UltraMotor, s: MotorState, i: InputFrame) -> void:
	if s.state == Id.JUMP:
		m.do_jump(s, i)


func next(m: UltraMotor, s: MotorState, i: InputFrame) -> int:
	# A fall we know we won't land on our feet (the jump arc swept against the world: a jump to
	# the next platform lands on it): go limp a little before the ground, keeping all our speed,
	# so the body hits the ground loose and tumbles on with its momentum.
	if s.state == Id.FALL and not s.is_grounded() and s.vel.y < -1.0:
		var pred := m.predict_impact(s)
		if not pred.is_empty() and float(pred.speed) > m.profile.hard_land_speed and float(pred.time) < AIR_RAGDOLL_LEAD:
			s.trav_from = s.vel
			return Id.RAGDOLL
	if s.is_grounded() and s.state_time > 0.0:
		var impact := s.land_impact
		if impact > m.profile.hard_land_speed:
			# A big drop: the legs give way - crumple (ragdoll) and get back up.
			s.trav_from = m.horizontal(s.vel) * 0.6 + Vector3.DOWN * minf(impact * 0.35, 4.0)
			s.set_flag(MotorState.F_HARD_LANDING, false)
			return Id.RAGDOLL
		s.set_flag(MotorState.F_HARD_LANDING, false)
		if impact > 3.2:
			return Id.LAND
		return Id.MOVE if i.move.length() > 0.1 else Id.IDLE
	if s.state == Id.FALL and m.can_jump(s) and s.prev_state != Id.JUMP:
		return Id.JUMP                      # coyote jump
	if s.state == Id.JUMP and s.vel.y < -0.5:
		return Id.FALL
	return -1


func tick(m: UltraMotor, s: MotorState, i: InputFrame) -> void:
	if not i.has(InputFrame.B_JUMP):
		s.set_flag(MotorState.F_JUMP_HELD, false)
	m.update_stance(s, MotorState.Stance.CROUCH if i.has(InputFrame.B_CROUCH) else MotorState.Stance.STAND)
	var v := m.body.velocity
	v.y = maxf(v.y - m.gravity_for(s, i) * m.dt, -m.profile.max_fall_speed)
	# Air control: steer freely, but only gain speed up to what you already had (or a walk).
	var hv := Vector3(v.x, 0, v.z)
	var wish := i.move_world(i.yaw)
	if wish.length_squared() > 0.0001:
		var cap := maxf(hv.length(), m.profile.walk_speed * m.profile.air_control * 2.0)
		hv += wish * m.profile.air_accel * m.profile.air_control * 2.0 * m.dt
		if hv.length() > cap:
			hv = hv.normalized() * cap
	v.x = hv.x
	v.z = hv.z
	m.body.velocity = v
	m.update_body_yaw(s, i, true)
	m.move(s, false)

