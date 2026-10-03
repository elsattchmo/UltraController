extends MotorStateHandler
## ROOT_MOTION: plays a baked RootMotionCurve (roll, dodge, knockback, climb-up...) through
## move_and_slide so collisions still apply. rm_scale warps the path per axis.

const Id := MotorState.Id


func next(m: UltraMotor, s: MotorState, i: InputFrame) -> int:
	var c := m.anim_set.rm_curve(s.rm_clip) if m.anim_set else null
	if c == null or s.rm_t >= c.length - 0.0001:
		if not s.is_grounded():
			return Id.FALL
		return Id.MOVE if i.move.length() > 0.1 else Id.IDLE
	return -1


func exit(_m: UltraMotor, s: MotorState, _i: InputFrame) -> void:
	s.rm_clip = -1


func tick(m: UltraMotor, s: MotorState, _i: InputFrame) -> void:
	var c := m.anim_set.rm_curve(s.rm_clip)
	if c == null:
		return
	var t1 := minf(s.rm_t + m.dt, c.length)
	var d := (c.sample_pos(t1) - c.sample_pos(s.rm_t)) * s.rm_scale
	var v := Basis(Vector3.UP, s.rm_yaw0) * d / m.dt
	var vertical_clip := absf(c.extent().size.y) > 0.15
	if not vertical_clip:
		if s.is_grounded():
			v.y = minf(m.body.velocity.y, 0.0)
		else:
			v.y = m.body.velocity.y - m.gravity * m.dt
	m.body.velocity = v
	s.body_yaw = s.rm_yaw0 + c.sample_yaw(t1)
	s.rm_t = t1
	m.move(s, not vertical_clip)
