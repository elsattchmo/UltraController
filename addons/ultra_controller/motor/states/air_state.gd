extends MotorStateHandler
## JUMP / FALL: gravity shaping (variable height, heavier fall), momentum-preserving air control.

const Id := MotorState.Id


func enter(m: UltraMotor, s: MotorState, i: InputFrame) -> void:
	if s.state == Id.JUMP:
		m.do_jump(s, i)


func next(m: UltraMotor, s: MotorState, i: InputFrame) -> int:
	if s.is_grounded() and s.state_time > 0.0:
		var impact := s.land_impact
		var moving_fwd := i.move.y > 0.5
		if impact > m.profile.hard_land_speed * 0.75 and moving_fwd and i.has(InputFrame.B_CROUCH) and m.profile.enable_roll:
			var idx := m.anim_set.rm_index(&"roll") if m.anim_set else -1
			if idx >= 0:
				s.rm_clip = idx
				s.rm_t = 0.0
				s.rm_yaw0 = s.body_yaw
				s.rm_scale = Vector3.ONE
				return Id.ROOT_MOTION
		s.set_flag(MotorState.F_HARD_LANDING, impact > m.profile.hard_land_speed)
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
