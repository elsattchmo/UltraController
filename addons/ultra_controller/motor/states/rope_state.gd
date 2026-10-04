extends MotorStateHandler
## ROPE: hanging from a rope = a pendulum around the anchor, length = grip distance + body.
## SWING ropes: forward/back pumps the swing in the facing direction. CLIMB ropes: forward/
## back climbs. Jump lets go and keeps the swing's velocity. All in MotorState (trav_from holds
## the swing velocity), so it's predicted like everything else.

const Id := MotorState.Id
const BODY := 1.95                 ## hands to feet while hanging


func next(m: UltraMotor, s: MotorState, i: InputFrame) -> int:
	var rope := UltraRope.find(s.trav_id)
	if rope == null:
		return Id.FALL
	if UltraMotor.pressed_edge(s, i, InputFrame.B_JUMP) and s.state_time > 0.15:
		m.body.velocity = s.trav_from + Vector3.UP * 2.0
		return Id.FALL
	if UltraMotor.pressed_edge(s, i, InputFrame.B_CROUCH):
		m.body.velocity = s.trav_from
		return Id.FALL
	return -1


func exit(m: UltraMotor, s: MotorState, _i: InputFrame) -> void:
	m.body.velocity = s.trav_from + Vector3.UP * 1.5 if m.body.velocity == Vector3.ZERO else m.body.velocity


func tick(m: UltraMotor, s: MotorState, i: InputFrame) -> void:
	var rope := UltraRope.find(s.trav_id)
	if rope == null:
		return
	var a := rope.anchor()
	if rope.kind == UltraRope.Kind.CLIMB:
		s.trav_s = clampf(s.trav_s - i.move.y * 1.1 * m.dt, 0.3, rope.length - 0.2)
	var L := s.trav_s + BODY
	var v := s.trav_from
	v.y -= m.gravity * m.dt
	if rope.kind == UltraRope.Kind.SWING:
		var fwd := Vector3(-sin(i.yaw), 0, -cos(i.yaw))
		var right := Vector3(cos(i.yaw), 0, -sin(i.yaw))
		# Pumping adds energy only on the low part of the arc, so a swing tops out ~65 degrees.
		var ang := (s.pos - a).angle_to(Vector3.DOWN)
		var pump := 1.0 - smoothstep(deg_to_rad(40.0), deg_to_rad(65.0), ang)
		v += (fwd * i.move.y + right * i.move.x * 0.6) * 3.2 * pump * m.dt
	v *= 0.997
	var prev := s.pos
	var p := prev + v * m.dt
	var d := p - a
	p = a + d.normalized() * L if d.length() > 0.001 else a + Vector3.DOWN * L
	v = (p - prev) / m.dt
	# Body follows the rope; keep the radial part out of the stored velocity.
	s.trav_from = v
	m.body.global_position = p
	m.body.velocity = v
	s.set_flag(MotorState.F_GROUNDED, false)
	m.update_body_yaw(s, i, true)
