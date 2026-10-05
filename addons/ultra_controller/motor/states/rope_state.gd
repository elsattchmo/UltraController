extends MotorStateHandler
## ROPE: hanging from a rope = a pendulum around the anchor, length = grip distance + body.
## Looking level, forward/back pumps the swing in the facing direction; looking up / down,
## forward/back climbs (UltraRope.climb_input). Jump lets go and keeps the swing's velocity.
## The body collides on the way round: walls stop the swing, and feet meeting the ground
## (climbing down, or a low swing) put you on your feet. All in MotorState (trav_from holds
## the swing velocity), so it's predicted like everything else.

const Id := MotorState.Id
const BODY := 1.95                 ## hands to feet while hanging
const COM_BELOW_HANDS := 1.0       ## hands to the body's centre of mass


func next(m: UltraMotor, s: MotorState, i: InputFrame) -> int:
	var rope := UltraRope.find(s.trav_id)
	if rope == null:
		return Id.FALL
	if s.is_grounded():
		return Id.MOVE if m.horizontal(s.trav_from).length() > 0.3 or i.move.length() > 0.1 else Id.IDLE
	if UltraMotor.pressed_edge(s, i, InputFrame.B_JUMP) and s.state_time > 0.15:
		m.body.velocity = s.trav_from + Vector3.UP * 2.0
		return Id.FALL
	if UltraMotor.pressed_edge(s, i, InputFrame.B_CROUCH):
		m.body.velocity = s.trav_from
		return Id.FALL
	return -1


func exit(m: UltraMotor, s: MotorState, _i: InputFrame) -> void:
	if s.is_grounded():
		m.body.velocity = m.horizontal(s.trav_from) * 0.5      # stepped off onto the ground
		return
	m.body.velocity = s.trav_from + Vector3.UP * 1.5 if m.body.velocity == Vector3.ZERO else m.body.velocity


func tick(m: UltraMotor, s: MotorState, i: InputFrame) -> void:
	var rope := UltraRope.find(s.trav_id)
	if rope == null:
		return
	var a := rope.anchor()
	var climb := UltraRope.climb_input(rope, i)
	if climb != 0.0:
		s.trav_s = clampf(s.trav_s - climb * 1.1 * m.dt, 0.3, rope.length - 0.2)
	var L := s.trav_s + BODY
	var v := s.trav_from
	# The swing's period comes from where the weight is (the body's centre, ~1 m under the
	# hands), not the feet we track: gravity scaled by L / L_com gives the right period.
	v.y -= m.gravity * (L / (s.trav_s + COM_BELOW_HANDS)) * m.dt
	if climb == 0.0:
		var fwd := Vector3(-sin(i.yaw), 0, -cos(i.yaw))
		var right := Vector3(cos(i.yaw), 0, -sin(i.yaw))
		# Pumping adds energy only on the low part of the arc, so a swing tops out ~65 degrees.
		var ang := (s.pos - a).angle_to(Vector3.DOWN)
		var pump := 1.0 - smoothstep(deg_to_rad(40.0), deg_to_rad(65.0), ang)
		v += (fwd * i.move.y + right * i.move.x * 0.6) * 3.2 * pump * m.dt
	v *= 0.9985                       # air drag: a swing dies down over ~10 s
	var prev := s.pos
	var p := prev + v * m.dt
	var d := p - a
	p = a + d.normalized() * L if d.length() > 0.001 else a + Vector3.DOWN * L
	# The body collides on its way round: walls and props stop it; the ground under the feet
	# (climbing down to it, or a swing that low) puts you on your feet.
	var grounded := false
	var col := KinematicCollision3D.new()
	m.body.global_position = prev
	var hit := m.body.test_move(m.body.global_transform, p - prev, col)
	if hit:
		p = prev + col.get_travel()
		grounded = col.get_normal().y > 0.7 and s.state_time > 0.3 and v.y <= 0.5
	v = (p - prev) / m.dt               # the motion actually made (no radial part, no wall)
	if hit and not grounded:
		v -= col.get_normal() * minf(v.dot(col.get_normal()), 0.0)
	# Body follows the rope; keep the radial part out of the stored velocity.
	s.trav_from = v
	m.body.global_position = p
	m.body.velocity = Vector3.ZERO if grounded else v
	s.set_flag(MotorState.F_GROUNDED, grounded)
	m.update_body_yaw(s, i, true)
