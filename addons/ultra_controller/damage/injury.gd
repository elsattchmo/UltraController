class_name UltraInjury
extends RefCounted
## What injuries do to movement and handling. Pure functions of MotorState (+ DamageProfile), so
## the motor, the action layer and the animation all agree and everything still predicts.

const S := UltraLimbs.Status


## Ground speed multiplier from the worse leg.
static func speed_mult(s: MotorState, dp: DamageProfile) -> float:
	var worst := maxi(UltraLimbs.leg(s, true), UltraLimbs.leg(s, false))
	if worst >= S.CRIPPLED:
		return dp.crippled_leg_speed
	# Graded: a grazed leg slows you a little, an injured one (<= 50 %) to injured_leg_speed.
	var d := maxf(leg_damage(s, true), leg_damage(s, false))
	return lerpf(1.0, dp.injured_leg_speed, clampf(d / LEG_INJURED_DAMAGE, 0.0, 1.0))


## How hurt a leg is, 0 (fine, >= 85 % health) .. 1 (<= 25 %, crippled or gone): drives the
## limp (and the speed above). Deterministic: from MotorState.
const LEG_INJURED_DAMAGE := 0.583   ## leg_damage at 50 % health (the INJURED threshold)
static func leg_damage(s: MotorState, left: bool) -> float:
	var R := UltraLimbs.Region
	var worst := 0.0
	for r: int in ([R.THIGH_L, R.SHIN_L] if left else [R.THIGH_R, R.SHIN_R]):
		if (s.severed >> r) & 1:
			return 1.0
		worst = maxf(worst, clampf((85.0 - float(s.limb_hp[r])) / 60.0, 0.0, 1.0))
	return worst


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
