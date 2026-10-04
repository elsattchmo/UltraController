extends MotorStateHandler
## LADDER (ladders and pipes) and WALL_CLIMB (climbable surfaces).
## Ladder: forward/back climbs, sprint climbs faster; at the top, forward climbs out; at the
## bottom, back steps off; jump pushes off backwards.
## Wall: move freely across the wall face; reaching the top climbs out; crouch lets go.

const Id := MotorState.Id


func enter(m: UltraMotor, s: MotorState, _i: InputFrame) -> void:
	m.body.velocity = Vector3.ZERO
	s.set_flag(MotorState.F_GROUNDED, false)


func next(m: UltraMotor, s: MotorState, i: InputFrame) -> int:
	if UltraMotor.pressed_edge(s, i, InputFrame.B_JUMP) and s.state_time > 0.2:
		m.body.velocity = s.trav_normal * 3.0 + Vector3.UP * 2.5
		return Id.FALL
	if s.state == Id.LADDER:
		var lad := UltraLadder.find(s.trav_id)
		if lad == null:
			return Id.FALL
		if s.trav_s >= lad.height - 0.95 and i.move.y > 0.3:
			var top := lad.global_position + Vector3.UP * lad.height - lad.normal() * (m.profile.radius + 0.25)
			return UltraTraversal.start_climb_up(m, s, top, lad.normal())
		if s.trav_s <= 0.02 and i.move.y < -0.3:
			s.set_flag(MotorState.F_GROUNDED, true)
			return Id.IDLE
		return -1
	# Wall climb
	if UltraMotor.pressed_edge(s, i, InputFrame.B_CROUCH):
		m.body.velocity = s.trav_normal * 1.0
		return Id.FALL
	if s.is_grounded() and i.move.y < -0.3:
		return Id.IDLE
	# Top of the wall: a ledge within reach and no wall at head height.
	if i.move.y > 0.3:
		var l := UltraTraversal.scan(m, s.pos, -s.trav_normal, 2.4)
		if l and l.height <= 2.1 and (l.standable or l.crouch_only):
			var space := m.body.get_world_3d().direct_space_state
			var head := s.pos + Vector3.UP * 2.0
			var q := PhysicsRayQueryParameters3D.create(head, head - s.trav_normal * 0.8, UltraLayers.WORLD_STATIC | UltraLayers.CLIMBABLE, [m.body.get_rid()])
			if space.intersect_ray(q).is_empty():
				return UltraTraversal.start_climb_up(m, s, l.top - l.normal * (m.profile.radius + 0.15), l.normal)
	return -1


func tick(m: UltraMotor, s: MotorState, i: InputFrame) -> void:
	var prev := m.body.global_position
	if s.state == Id.LADDER:
		var lad := UltraLadder.find(s.trav_id)
		if lad == null:
			return
		var speed := lad.climb_speed * (1.5 if i.has(InputFrame.B_SPRINT) else 1.0)
		s.trav_s = clampf(s.trav_s + i.move.y * speed * m.dt, 0.0, lad.height - 0.9)
		var p := lad.stand_point(s.trav_s)
		m.body.global_position = p
		m.body.velocity = (p - prev) / m.dt
		return
	# Wall: stick to the surface at a fixed distance, move in its plane.
	var space := m.body.get_world_3d().direct_space_state
	var chest := s.pos + Vector3.UP * 1.2
	var q := PhysicsRayQueryParameters3D.create(chest, chest - s.trav_normal * 1.0, UltraLayers.CLIMBABLE | UltraLayers.WORLD_STATIC, [m.body.get_rid()])
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		m.body.velocity = s.trav_normal * 0.5 + Vector3.DOWN
		m.move(s, false)
		return
	var n := Vector3((hit.normal as Vector3).x, 0, (hit.normal as Vector3).z).normalized()
	s.trav_normal = n
	s.body_yaw = atan2(n.x, n.z)
	var right := Vector3(cos(s.body_yaw), 0, -sin(s.body_yaw))
	var v := right * i.move.x * 0.9 + Vector3.UP * i.move.y * 0.9
	var dist := chest.distance_to(hit.position)
	v += -n * (dist - (m.profile.radius + 0.06)) / m.dt * 0.5
	m.body.velocity = v
	m.move(s, false)
