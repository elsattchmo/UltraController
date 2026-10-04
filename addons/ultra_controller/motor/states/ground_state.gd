extends MotorStateHandler
## IDLE / MOVE / CROUCH / CRAWL / LAND: everything that walks on the floor.

const Id := MotorState.Id


func next(m: UltraMotor, s: MotorState, i: InputFrame) -> int:
	if not s.is_grounded():
		return Id.FALL
	if m.can_jump(s) and s.stance != MotorState.Stance.CRAWL and m.has_headroom(s, m.profile.stand_height):
		return Id.JUMP
	if s.state == Id.LAND:
		var recover := m.profile.hard_land_recover_time if s.has(MotorState.F_HARD_LANDING) else m.profile.land_recover_time
		if s.state_time < recover:
			return -1
	if UltraMotor.pressed_edge(s, i, InputFrame.B_DODGE) and m.profile.enable_roll and s.stance == MotorState.Stance.STAND:
		var idx := m.anim_set.rm_index(_dodge_role(i)) if m.anim_set else -1
		if idx >= 0:
			s.rm_clip = idx
			s.rm_t = 0.0
			s.rm_yaw0 = s.body_yaw
			s.rm_scale = Vector3.ONE
			return Id.ROOT_MOTION
	var hv := m.horizontal(s.vel)
	if m.profile.enable_slide and UltraMotor.pressed_edge(s, i, InputFrame.B_CROUCH) and hv.length() >= m.profile.slide_min_speed and s.stance == MotorState.Stance.STAND:
		return Id.SLIDE
	match s.stance:
		MotorState.Stance.CRAWL:
			return Id.CRAWL
		MotorState.Stance.CROUCH:
			return Id.CROUCH
	if hv.length() > 0.15 or i.move.length() > 0.1:
		return Id.MOVE
	return Id.IDLE


static func _dodge_role(i: InputFrame) -> StringName:
	if i.move.length() < 0.25 or i.move.y > absf(i.move.x):
		return &"roll"
	if -i.move.y > absf(i.move.x):
		return &"dodge_back"
	return &"dodge_right" if i.move.x > 0.0 else &"dodge_left"


func tick(m: UltraMotor, s: MotorState, i: InputFrame) -> void:
	m.probe_floor(s)
	m.update_stance(s, MotorState.Stance.CRAWL if UltraInjury.must_crawl(s) else m.wanted_stance(i))
	var speed := m.target_ground_speed(s, i)
	if s.state == Id.LAND:
		var hard := s.has(MotorState.F_HARD_LANDING)
		var recover := m.profile.hard_land_recover_time if hard else m.profile.land_recover_time
		var k := clampf(s.state_time / maxf(recover, 0.01), 0.0, 1.0)
		speed *= lerpf(0.15 if hard else 0.7, 1.0, k)
	var wish := i.move_world(i.yaw)
	var hv := m.accelerate_ground(s, wish, speed, m.floor_friction)
	m.body.velocity = Vector3(hv.x, minf(m.body.velocity.y, 0.0), hv.z)
	m.update_body_yaw(s, i, hv.length() > 0.2 or wish.length() > 0.1)
	m.move(s, true)
