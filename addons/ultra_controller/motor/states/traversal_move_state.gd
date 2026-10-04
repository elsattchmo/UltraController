extends MotorStateHandler
## MANTLE / VAULT / LEDGE_CLIMB: a scripted move from trav_from to trav_to over trav_dur.
## Mantles and climb-ups follow the ClimbUp clip's own root path, warped per axis to the
## measured ledge; vaults arc over the top (bezier) and keep the run's momentum. Collision is
## skipped (the scanner checked clearance), so the move always lands exactly.

const Id := MotorState.Id


func enter(m: UltraMotor, s: MotorState, _i: InputFrame) -> void:
	s.vel = Vector3.ZERO
	m.body.velocity = Vector3.ZERO
	s.rm_clip = m.anim_set.rm_index(&"climb_up_1m") if m.anim_set and s.state != Id.VAULT else -1
	s.rm_t = 0.0


func exit(_m: UltraMotor, s: MotorState, _i: InputFrame) -> void:
	s.rm_clip = -1
	s.trav_kind = 0


func next(m: UltraMotor, s: MotorState, i: InputFrame) -> int:
	if s.trav_t >= s.trav_dur:
		return Id.MOVE if i.move.length() > 0.1 else Id.IDLE
	return -1


func tick(m: UltraMotor, s: MotorState, _i: InputFrame) -> void:
	s.trav_t = minf(s.trav_t + m.dt, s.trav_dur)
	var u := s.trav_t / maxf(s.trav_dur, 0.001)
	var from := s.trav_from
	var to := s.trav_to
	var p: Vector3
	if s.state == Id.VAULT:
		var apex_y := maxf(from.y, s.trav_point.y) + 0.32
		var mid := (from + to) * 0.5
		var c := Vector3(mid.x, apex_y + (apex_y - (from.y + to.y) * 0.5), mid.z)
		p = from.lerp(c, u).lerp(c.lerp(to, u), u)          # quadratic bezier
	else:
		# Clip path: up first, then forward (curve y/z fractions), warped to this ledge.
		var curve := m.anim_set.rm_curve(s.rm_clip) if m.anim_set and s.rm_clip >= 0 else null
		var fy := u
		var fz := u
		if curve:
			var cp := curve.sample_pos(u * curve.length)
			var tot := curve.extent().size
			fy = absf(cp.y) / maxf(tot.y, 0.01)
			fz = absf(cp.z) / maxf(tot.z, 0.01)
		# Lead with height so the body clears the edge before moving over it.
		fy = smoothstep(0.0, 1.0, minf(fy * 1.25, 1.0))
		fz = smoothstep(0.0, 1.0, maxf(fz * 1.2 - 0.2, 0.0))
		var horiz := Vector3(to.x - from.x, 0, to.z - from.z)
		p = from + Vector3.UP * (to.y - from.y) * fy + horiz * fz
		s.rm_t = u * (curve.length if curve else 0.6)
	var prev := m.body.global_position
	m.body.global_position = p
	m.body.velocity = (p - prev) / m.dt
	s.set_flag(MotorState.F_GROUNDED, u >= 1.0)
	if u >= 1.0:
		if s.state == Id.VAULT:
			var fwd := Vector3(to.x - from.x, 0, to.z - from.z).normalized()
			m.body.velocity = fwd * s.trav_s          # keep the run's momentum
		else:
			m.body.velocity = Vector3.ZERO
		s.coyote_t = m.profile.coyote_time
