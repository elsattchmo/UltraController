class_name UltraInjury
extends RefCounted
## What injuries do to movement and handling. Pure functions of MotorState (+ DamageProfile), so
## the motor, the action layer and the animation all agree and everything still predicts.

const S := UltraLimbs.Status


## Ground speed multiplier from the worse leg.
static func speed_mult(s: MotorState, dp: DamageProfile) -> float:
	var worst := maxi(UltraLimbs.leg(s, true), UltraLimbs.leg(s, false))
	match worst:
		S.INJURED:
			return dp.injured_leg_speed
		S.CRIPPLED, S.SEVERED:
			return dp.crippled_leg_speed
	return 1.0


static func can_sprint(s: MotorState) -> bool:
	return UltraLimbs.leg(s, true) == S.HEALTHY and UltraLimbs.leg(s, false) == S.HEALTHY


static func can_jump(s: MotorState) -> bool:
	return UltraLimbs.leg(s, true) < S.CRIPPLED and UltraLimbs.leg(s, false) < S.CRIPPLED


## No legs to stand on: both crippled, or one gone.
static func must_crawl(s: MotorState) -> bool:
	var l := UltraLimbs.leg(s, true)
	var r := UltraLimbs.leg(s, false)
	return (l >= S.CRIPPLED and r >= S.CRIPPLED) or l == S.SEVERED or r == S.SEVERED


## Ledges, ladders, ropes and walls need both arms and at least one good leg.
static func can_climb(s: MotorState) -> bool:
	return UltraLimbs.arm(s, true) < S.CRIPPLED and UltraLimbs.arm(s, false) < S.CRIPPLED and not must_crawl(s)


## Which hand holds a weapon: 1 right, -1 left (right arm out of action), 0 none.
static func weapon_hand(s: MotorState) -> int:
	if UltraLimbs.arm(s, false) < S.CRIPPLED:
		return 1
	if UltraLimbs.arm(s, true) < S.CRIPPLED:
		return -1
	return 0


## Aim spread multiplier: a hurt shooting arm shakes; the off hand is clumsy.
static func aim_mult(s: MotorState, dp: DamageProfile) -> float:
	var hand := weapon_hand(s)
	var m := 1.0
	if hand == -1:
		m *= 1.6
	if UltraLimbs.arm(s, hand == -1) == S.INJURED:
		m *= dp.injured_arm_sway
	return m


## Reload time multiplier: hurt arms are slow, one hand is slower.
static func reload_mult(s: MotorState, dp: DamageProfile) -> float:
	var m := 1.0
	if UltraLimbs.arm(s, true) == S.INJURED or UltraLimbs.arm(s, false) == S.INJURED:
		m *= dp.injured_arm_reload
	if UltraLimbs.arm(s, true) >= S.CRIPPLED or UltraLimbs.arm(s, false) >= S.CRIPPLED:
		m *= 1.8
	return m


## Two-hand carries and team lifts need two working arms; a hurt arm halves your strength.
static func two_hands(s: MotorState) -> bool:
	return UltraLimbs.arm(s, true) < S.CRIPPLED and UltraLimbs.arm(s, false) < S.CRIPPLED


static func strength_mult(s: MotorState) -> float:
	var m := 1.0
	for left in [true, false]:
		var a := UltraLimbs.arm(s, left)
		if a == S.INJURED:
			m *= 0.75
		elif a >= S.CRIPPLED:
			m *= 0.5
	return m
