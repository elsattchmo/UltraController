extends MotorStateHandler
## RAGDOLL (knocked down) and GET_UP. The simulated body is a low, heavy capsule that slides to
## a stop: deterministic, so the server (even a headless one) and every client agree on where
## you lie. The floppy body you see is a local physics ragdoll (UltraRagdoll) following it.

const Id := MotorState.Id
const LIE_HEIGHT := 0.5
const GET_UP_TIME := 2.8                 ## (the default: MovementProfile.get_up_time)
## Lying still this long (on the ground, barely moving) before getting up.
const STILL_TIME := 1.0


func enter(m: UltraMotor, s: MotorState, _i: InputFrame) -> void:
	if s.state == Id.RAGDOLL:
		# (Going limp mid-fall keeps the fall speed; a shove from the ground never pushes down.)
		var vy := s.trav_from.y if s.trav_from.y < -1.0 and not s.is_grounded() else maxf(s.trav_from.y, 0.0)
		m.body.velocity = Vector3(s.trav_from.x, vy, s.trav_from.z)
		s.set_flag(MotorState.F_GROUNDED, false)
		s.set_flag(MotorState.F_SPRINTING, false)
		s.trav_t = 0.0
	else:
		m.body.velocity = Vector3(0, minf(m.body.velocity.y, 0.0), 0)


func next(m: UltraMotor, s: MotorState, _i: InputFrame) -> int:
	if s.hp <= 0.0:
		return Id.DEAD
	if s.state == Id.RAGDOLL and s.has(MotorState.F_UNCONSCIOUS):
		return -1                        # out cold: no getting up, no coming round to swim
	if s.state == Id.RAGDOLL:
		# Limp in the water, not lying on the bottom: come round and swim.
		if m.water != null and m.water_depth > 0.15 and not s.is_grounded():
			return Id.SWIM if s.state_time > UltraSwim.STUN_TIME else -1
		# Get up once the body has come to rest - not while it's still sliding / tumbling.
		if (s.state_time > 1.4 and s.trav_t >= STILL_TIME) or s.state_time > 8.0:
			return Id.GET_UP
		return -1
	if s.state_time >= m.profile.get_up_time:
		if UltraInjury.must_crawl(s):
			s.stance = MotorState.Stance.CRAWL
			return Id.CRAWL
		s.stance = MotorState.Stance.STAND
		return Id.IDLE
	return -1


func exit(_m: UltraMotor, s: MotorState, _i: InputFrame) -> void:
	if s.state == Id.RAGDOLL:
		s.set_flag(MotorState.F_UNCONSCIOUS, false)
		s.ko_t = 0.0


func tick(m: UltraMotor, s: MotorState, _i: InputFrame) -> void:
	# Knocked out: count down; coming round, the usual "lain still" check gets us up.
	if s.state == Id.RAGDOLL and s.has(MotorState.F_UNCONSCIOUS):
		s.ko_t = maxf(s.ko_t - m.dt, 0.0)
		if s.ko_t <= 0.0:
			s.set_flag(MotorState.F_UNCONSCIOUS, false)
	var v := m.body.velocity
	if s.state == Id.RAGDOLL and m.water != null and m.water_depth > 0.15 and not s.is_grounded():
		# Limp in the water: thick drag, and the body bobs back up to float at the surface.
		m.set_height(s, move_toward(s.height, LIE_HEIGHT, 4.0 * m.dt))
		var err := (m.water_surface - 0.35) - s.pos.y
		v.y += (err * 14.0 - v.y * 5.0) * m.dt
		var hv := m.horizontal(v) * exp(-1.6 * m.dt)
		var cur := m.water.current
		v = Vector3(hv.x + cur.x * m.dt, minf(v.y, 2.0), hv.z + cur.z * m.dt)
		s.trav_t = 0.0
		m.body.velocity = v
		m.move(s, false)
		return
	if s.state == Id.RAGDOLL:
		m.set_height(s, move_toward(s.height, LIE_HEIGHT, 4.0 * m.dt))
		# A body tumbling along the ground keeps rolling while it's fast, then stops quickly.
		var sp := m.horizontal(v).length()
		# (In the air a limp body keeps nearly all its speed.)
		var decel := lerpf(10.0, 3.5, smoothstep(1.5, 5.0, sp)) if s.is_grounded() else 0.3
		var hv := m.horizontal(v).move_toward(Vector3.ZERO, decel * m.dt)
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
	# How long we've lain still (only then does the get-up start).
	if s.state == Id.RAGDOLL:
		var still := s.is_grounded() and m.horizontal(m.body.velocity).length() < 0.2 and absf(m.body.velocity.y) < 0.5
		s.trav_t = s.trav_t + m.dt if still else 0.0
