class_name UltraSwim
extends RefCounted
## Water rules shared by the motor: when you start swimming, how wading slows you, breath.
## Registered as a motor transition hook (after traversal).

const Id := MotorState.Id
## Hitting the water this hard (falling at, or moving at, m/s) knocks you limp for a moment -
## you surface and come round (RAGDOLL in the water, then SWIM).
const PLUNGE_FALL_SPEED := 8.5
const PLUNGE_SPEED := 11.5
## How long you stay limp in the water.
const STUN_TIME := 1.3


static func hook(m: UltraMotor, s: MotorState, _i: InputFrame) -> int:
	if not m.profile.enable_swim or m.water == null:
		return -1
	match s.state:
		Id.IDLE, Id.MOVE, Id.CROUCH, Id.CRAWL, Id.LAND, Id.TURN_IN_PLACE, Id.JUMP, Id.FALL, Id.SLIDE:
			if m.water_depth >= m.profile.swim_depth:
				# Hit hard (a high jump, a fast swing off a rope): limp for a moment. The water
				# takes most of the speed.
				if s.state in [Id.JUMP, Id.FALL] and (-s.vel.y > PLUNGE_FALL_SPEED or s.vel.length() > PLUNGE_SPEED):
					s.trav_from = Vector3(s.vel.x * 0.35, s.vel.y * 0.3, s.vel.z * 0.35)
					return Id.RAGDOLL
				return Id.SWIM
	return -1


## Ground speed multiplier while wading (1 when dry).
static func wade_mult(m: UltraMotor) -> float:
	if m.water == null or m.water_depth < 0.3:
		return 1.0
	var k := clampf((m.water_depth - 0.45) / maxf(m.profile.swim_depth - 0.45, 0.1), 0.0, 1.0)
	return lerpf(1.0, m.profile.wade_mult_knee, clampf(m.water_depth / 0.45, 0.0, 1.0)) if m.water_depth < 0.45 \
		else lerpf(m.profile.wade_mult_knee, m.profile.wade_mult_chest, k)


## Air: drains while the head is under, refills 4x faster when it's out.
static func update_breath(m: UltraMotor, s: MotorState) -> void:
	var head := s.pos + Vector3.UP * maxf(s.height - 0.15, 0.3)
	var under := UltraWater.depth_at(head, m.platform_tick) > 0.0 if not UltraWater.all.is_empty() else false
	s.breath = clampf(s.breath + (-m.dt if under else m.dt * 4.0), 0.0, m.profile.breath_time)


## Is the head under water? (presentation / damage)
static func head_under(c: UltraCharacter) -> bool:
	if UltraWater.all.is_empty():
		return false
	var s := c.state
	return UltraWater.depth_at(s.pos + Vector3.UP * maxf(s.height - 0.15, 0.3), c.platform_tick) > 0.0
