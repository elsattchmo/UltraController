extends MotorStateHandler
## RAGDOLL (knocked down) and GET_UP. The simulated body is a low, heavy capsule that slides to
## a stop: deterministic, so the server (even a headless one) and every client agree on where
## you lie. The floppy body you see is a local physics ragdoll (UltraRagdoll) following it.

const Id := MotorState.Id
const LIE_HEIGHT := 0.5
const GET_UP_TIME := 1.5


func enter(m: UltraMotor, s: MotorState, _i: InputFrame) -> void:
	if s.state == Id.RAGDOLL:
		m.body.velocity = Vector3(s.trav_from.x, maxf(s.trav_from.y, 0.0), s.trav_from.z)
		s.set_flag(MotorState.F_GROUNDED, false)
		s.set_flag(MotorState.F_SPRINTING, false)
	else:
		m.body.velocity = Vector3(0, minf(m.body.velocity.y, 0.0), 0)


func next(m: UltraMotor, s: MotorState, _i: InputFrame) -> int:
	if s.hp <= 0.0:
		return Id.DEAD
	if s.state == Id.RAGDOLL:
		var settled := s.is_grounded() and m.horizontal(s.vel).length() < 0.2
		if (s.state_time > 1.4 and settled) or s.state_time > 6.0:
			return Id.GET_UP
		return -1
	if s.state_time >= GET_UP_TIME:
		if UltraInjury.must_crawl(s):
			s.stance = MotorState.Stance.CRAWL
			return Id.CRAWL
		s.stance = MotorState.Stance.STAND
		return Id.IDLE
	return -1


func tick(m: UltraMotor, s: MotorState, _i: InputFrame) -> void:
	var v := m.body.velocity
	if s.state == Id.RAGDOLL:
		m.set_height(s, move_toward(s.height, LIE_HEIGHT, 4.0 * m.dt))
		if s.is_grounded():
			var hv := m.horizontal(v).move_toward(Vector3.ZERO, 5.0 * m.dt)
			v = Vector3(hv.x, v.y, hv.z)
	else:
		var want := m.profile.crawl_height if UltraInjury.must_crawl(s) else m.profile.stand_height
		var next_h := move_toward(s.height, want, 1.6 * m.dt)
		if next_h < s.height or m.has_headroom(s, next_h):
			m.set_height(s, next_h)
		v = Vector3(0, v.y, 0)
	v.y = v.y - m.gravity * m.dt if not s.is_grounded() else minf(v.y, 0.0)
	m.body.velocity = v
	m.move(s, false)
