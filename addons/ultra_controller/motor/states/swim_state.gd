extends MotorStateHandler
## SWIM (at the surface) and DIVE (under it). A floating capsule: a damped spring holds the
## feet `float_depth` under the surface while swimming; diving moves in full 3D along the aim
## with a short capsule (the body is horizontal). The water's current carries you. All inputs
## come from MotorState + the tick-driven water level, so it predicts like everything else.

const Id := MotorState.Id


func enter(m: UltraMotor, s: MotorState, _i: InputFrame) -> void:
	s.set_flag(MotorState.F_GROUNDED, false)
	s.set_flag(MotorState.F_SPRINTING, false)
	s.stance = MotorState.Stance.STAND


func next(m: UltraMotor, s: MotorState, i: InputFrame) -> int:
	var p := m.profile
	if m.water == null:
		return Id.FALL                                     # out of the water (level dropped...)
	var looking_down := i.move.y > 0.3 and i.pitch < deg_to_rad(-35.0)
	if s.state == Id.SWIM:
		if m.water_depth < p.swim_depth - 0.1 and _floor_below(m, s, 0.3):
			return Id.IDLE                                 # touched the bottom in the shallows
		if UltraMotor.pressed_edge(s, i, InputFrame.B_CROUCH) or looking_down:
			return Id.DIVE
		return -1
	# DIVE: come back to the surface once the head is out and we're not heading down.
	var top := s.pos.y + s.height
	var heading_down := i.has(InputFrame.B_CROUCH) or (i.move.y > 0.3 and i.pitch < deg_to_rad(-20.0))
	if top >= m.water_surface - 0.1 and not heading_down and s.state_time > 0.3:
		if m.has_headroom(s, p.stand_height):
			return Id.SWIM
	if m.water_depth < p.swim_depth - 0.1 and _floor_below(m, s, 0.3) and m.has_headroom(s, p.stand_height):
		return Id.IDLE                                     # swam into the shallows
	return -1


func _floor_below(m: UltraMotor, s: MotorState, dist: float) -> bool:
	var q := PhysicsRayQueryParameters3D.create(s.pos + Vector3.UP * 0.1, s.pos + Vector3.DOWN * dist, m.body.collision_mask, [m.body.get_rid()])
	var hit := m.body.get_world_3d().direct_space_state.intersect_ray(q)
	return not hit.is_empty() and (hit.normal as Vector3).y > 0.6


func tick(m: UltraMotor, s: MotorState, i: InputFrame) -> void:
	var p := m.profile
	var dive := s.state == Id.DIVE
	# Capsule: short and horizontal-ish under water, full height at the surface (room allowing).
	var want_h := p.dive_height if dive else p.stand_height
	if want_h < s.height or m.has_headroom(s, minf(want_h, s.height + 0.1)):
		m.set_height(s, move_toward(s.height, want_h, 3.0 * m.dt))
	var cur := m.water.current if m.water else Vector3.ZERO
	var rel := m.body.velocity - cur
	var sprint := i.has(InputFrame.B_SPRINT) and i.move.y > 0.5
	if dive:
		var look := Vector3(-sin(i.yaw) * cos(i.pitch), sin(i.pitch), -cos(i.yaw) * cos(i.pitch))
		var right := Vector3(cos(i.yaw), 0, -sin(i.yaw))
		var wish := look * i.move.y + right * i.move.x
		if i.has(InputFrame.B_JUMP):
			wish += Vector3.UP
		if i.has(InputFrame.B_CROUCH):
			wish += Vector3.DOWN
		wish = wish.limit_length(1.0)
		var target := wish * p.dive_speed * (1.35 if sprint else 1.0) * s.carry_mult
		if wish.length() < 0.1:
			target.y = 0.4                                    # still: lungs full, drift up
		rel = rel.move_toward(target, p.swim_accel * m.dt)
		rel += (target - rel) * (1.0 - exp(-1.5 * m.dt))        # water drag
	else:
		var wish2 := i.move_world(i.yaw)
		var spd := (p.swim_sprint_speed if sprint else p.swim_speed) * s.carry_mult
		var hv := m.horizontal(rel).move_toward(wish2 * spd, p.swim_accel * m.dt)
		# Float: damped spring to the swim line (a little bob after a plunge).
		var err := (m.water_surface - p.float_depth) - s.pos.y
		var vy := rel.y + (err * 18.0 - rel.y * 6.0) * m.dt
		vy = minf(vy, 1.4)                                    # deep down: float up, don't launch
		rel = Vector3(hv.x, vy, hv.z)
	s.set_flag(MotorState.F_SPRINTING, sprint)
	m.body.velocity = rel + cur
	m.update_body_yaw(s, i, true)
	m.move(s, false)
