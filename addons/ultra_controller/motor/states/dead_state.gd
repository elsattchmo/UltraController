extends MotorStateHandler
## DEAD: no control; the body settles (ragdoll takes over visually in M8). Leaves only when the
## authority restores health (respawn).

const Id := MotorState.Id


func next(_m: UltraMotor, s: MotorState, i: InputFrame) -> int:
	if s.hp > 0.0:
		return Id.MOVE if i.move.length() > 0.1 else Id.IDLE
	return -1


func tick(m: UltraMotor, s: MotorState, _i: InputFrame) -> void:
	var v := m.body.velocity
	var hv := m.horizontal(v).move_toward(Vector3.ZERO, 8.0 * m.dt)
	v.y = v.y - m.gravity * m.dt if not s.is_grounded() else minf(v.y, 0.0)
	m.body.velocity = Vector3(hv.x, v.y, hv.z)
	m.move(s, false)
