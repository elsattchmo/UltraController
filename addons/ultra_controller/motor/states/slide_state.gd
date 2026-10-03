extends MotorStateHandler
## SLIDE: crouch at sprint speed. Low friction, gravity pulls you down slopes, light steering.

const Id := MotorState.Id


func enter(m: UltraMotor, s: MotorState, _i: InputFrame) -> void:
	var hv := m.horizontal(m.body.velocity)
	if hv.length() > 0.1:
		hv += hv.normalized() * m.profile.slide_boost
	m.body.velocity = Vector3(hv.x, m.body.velocity.y, hv.z)
	s.stance = MotorState.Stance.CROUCH


func next(m: UltraMotor, s: MotorState, i: InputFrame) -> int:
	if not s.is_grounded():
		return Id.FALL
	if m.can_jump(s) and m.has_headroom(s, m.profile.stand_height):
		return Id.JUMP
	var speed := m.horizontal(s.vel).length()
	var done := speed < m.profile.crouch_speed + 0.4 or s.state_time > m.profile.slide_max_time
	done = done or (not i.has(InputFrame.B_CROUCH) and s.state_time > 0.25)
	if done:
		if i.has(InputFrame.B_CROUCH) or not m.has_headroom(s, m.profile.stand_height):
			return Id.CROUCH
		return Id.MOVE
	return -1


func tick(m: UltraMotor, s: MotorState, i: InputFrame) -> void:
	m.probe_floor(s)
	m.update_stance(s, MotorState.Stance.CROUCH)
	var hv := m.horizontal(m.body.velocity)
	var n := m.floor_normal
	var downhill := Vector3.DOWN - n * Vector3.DOWN.dot(n)
	hv += m.horizontal(downhill) * m.gravity * m.dt
	var speed := hv.length()
	speed = maxf(speed - m.profile.slide_friction * clampf(m.floor_friction, 0.05, 1.0) * m.dt, 0.0)
	var dir := hv.normalized() if hv.length() > 0.01 else Vector3.ZERO
	var wish := i.move_world(i.yaw)
	if wish.length_squared() > 0.01 and dir != Vector3.ZERO:
		var ang := dir.signed_angle_to(wish.normalized(), Vector3.UP)
		dir = dir.rotated(Vector3.UP, clampf(ang, -1.0, 1.0) * m.dt)
	hv = dir * speed
	m.body.velocity = Vector3(hv.x, minf(m.body.velocity.y, 0.0), hv.z)
	m.update_body_yaw(s, i, true)
	m.move(s, false)
