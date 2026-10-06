extends MotorStateHandler
## LEDGE_HANG: hanging by the hands. Left/right shimmies along the edge (re-scanned every
## tick so it follows corners of straight edges and stops at the end); up/jump climbs up if
## there's room, back/crouch drops.

const Id := MotorState.Id
const SHIMMY_SPEED := 0.5


func _hang_pos(s: MotorState) -> Vector3:
	return s.trav_point + s.trav_normal * UltraTraversal.HANG_BACK + Vector3.DOWN * UltraTraversal.HANG_DROP


## The stick in the hang's own terms: y = toward the wall (up), x = along it to the right -
## taken through the camera, so it means the same however the view faces the wall.
func _push(s: MotorState, i: InputFrame) -> Vector2:
	var wish := i.move_world(i.yaw)
	var right := Vector3(cos(s.body_yaw), 0, -sin(s.body_yaw))
	return Vector2(wish.dot(right), wish.dot(-s.trav_normal))


func enter(m: UltraMotor, s: MotorState, _i: InputFrame) -> void:
	m.body.velocity = Vector3.ZERO
	m.body.global_position = _hang_pos(s)
	s.set_flag(MotorState.F_GROUNDED, false)


func next(m: UltraMotor, s: MotorState, i: InputFrame) -> int:
	if s.state_time < 0.25:
		return -1
	var push := _push(s, i)
	var up := push.y > 0.5 or UltraMotor.pressed_edge(s, i, InputFrame.B_JUMP)
	if up and s.trav_s > 0.5:
		var to := s.trav_point - s.trav_normal * (m.profile.radius + 0.15)
		return UltraTraversal.start_climb_up(m, s, to, s.trav_normal)
	if push.y < -0.5 or UltraMotor.pressed_edge(s, i, InputFrame.B_CROUCH):
		m.body.velocity = s.trav_normal * 1.2
		return Id.FALL
	return -1


func tick(m: UltraMotor, s: MotorState, i: InputFrame) -> void:
	var right := Vector3(cos(s.body_yaw), 0, -sin(s.body_yaw))
	var dx := _push(s, i).x * SHIMMY_SPEED * m.dt
	if absf(dx) > 0.0001:
		# Probe the ledge where we'd move to (and a bit further, so we stop before the end).
		var cand := s.trav_point + right * dx
		var lookahead := cand + right * signf(dx) * 0.25
		var feet := lookahead + s.trav_normal * (UltraTraversal.HANG_BACK + 0.25) + Vector3.DOWN * (UltraTraversal.HANG_DROP - 0.3)
		var l := UltraTraversal.scan(m, feet, -s.trav_normal, 2.4)
		# (Not along to where the ground comes up under the feet.)
		if l and absf(l.top.y - s.trav_point.y) < 0.25 and UltraTraversal.room_to_hang(m, Vector3(lookahead.x, l.top.y, lookahead.z), l.normal):
			s.trav_point = Vector3(cand.x, l.top.y, cand.z)
			s.trav_normal = l.normal
			s.trav_s = 1.0 if (l.standable or l.crouch_only) else 0.0
			s.body_yaw = atan2(l.normal.x, l.normal.z)
	var p := _hang_pos(s)
	var prev := m.body.global_position
	m.body.global_position = p
	m.body.velocity = (p - prev) / m.dt
