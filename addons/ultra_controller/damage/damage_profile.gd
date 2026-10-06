class_name DamageProfile
extends Resource
## How a character takes damage: per-region health and multipliers, when limbs come off, what
## injuries do to movement, and how much gore to show. Turn `limb_damage` off for plain HP.

enum Gore { OFF, NO_BLOOD, FULL }

@export var limb_damage := true
@export var dismemberment := true
@export var gore := Gore.FULL
@export var health := 100.0

@export_group("Regions")
## Absolute health per region: head, torso, upper arm L, forearm L, upper arm R, forearm R,
## thigh L, shin L, thigh R, shin R, hand L, hand R, foot L, foot R.
@export var region_hp := PackedFloat32Array([45, 100, 40, 35, 40, 35, 55, 45, 55, 45, 22, 22, 28, 28])
## How much of a hit there comes off overall health.
@export var region_mult := PackedFloat32Array([3.0, 1.0, 0.55, 0.45, 0.55, 0.45, 0.7, 0.55, 0.7, 0.55, 0.3, 0.3, 0.35, 0.35])
## A single hit that takes a region this far past zero cuts it off (bladed / blast: any overkill).
@export var sever_overkill := 45.0
## A blast (buckshot summed / explosion) into the torso this big that kills blows the body in
## two at the waist (with a cut set: UltraCutBody).
@export var halve_min := 90.0
## ... and only from this close (m), and only a load that struck the waist (within
## `halve_reach` of the cut between Spine and Chest). Further off a blast from the front
## opens the belly and throws the body.
@export var halve_range := 3.0
@export var halve_reach := 0.13
## The undead: a close blast (summed buckshot / explosion >= `halve_alive_min`, within `halve_range`) or a
## blade blow (>= `halve_blade_min`) through the waist cuts the body in two WITHOUT killing it: both
## legs come off with the lower half, health is capped at `halved_hp_cap`, and the upper half
## (MotorState.F_HALVED) knocks down, then crawls on its arms.
@export var halve_survives := false
@export var halve_alive_min := 70.0
@export var halve_blade_min := 55.0
@export var halved_hp_cap := 45.0
## Bitmask of regions that can come off (bit = UltraLimbs.Region); torso never does.
@export_flags("Head", "Torso", "Upper arm L", "Forearm L", "Upper arm R", "Forearm R", "Thigh L", "Shin L", "Thigh R", "Shin R", "Hand L", "Hand R", "Foot L", "Foot R")
var severable := 0b11111111111101

## Bleeding out: health lost per second (hp/s) while a region is cut off (counted at the top of
## a cut chain - an arm off at the shoulder bleeds as the upper arm). An arm off: dead in
## ~25 s; a leg off at the hip: ~18 s.
@export var bleed_rate := PackedFloat32Array([0.0, 0.0, 4.0, 3.0, 4.0, 3.0, 5.5, 3.5, 5.5, 3.5, 1.8, 1.8, 2.2, 2.2])
## A crippled region (still on) seeps: hp/s each - a slow bleed (one crippled limb takes
## ~6 minutes to kill you; a medkit's 50 hp buys a few more).
@export var cripple_bleed_rate := 0.25

@export_group("Injuries")
## Ground speed with a hurt / crippled leg (worst leg).
@export_range(0.1, 1, 0.01) var injured_leg_speed := 0.65
@export_range(0.1, 1, 0.01) var crippled_leg_speed := 0.4
## Aim sway multiplier with a hurt arm; reload time multiplier.
@export_range(1, 5, 0.1) var injured_arm_sway := 2.0
@export_range(1, 3, 0.05) var injured_arm_reload := 1.5
## A hit this heavy (after the region multiplier) knocks you down.
@export var knockdown_damage := 45.0
## A shove (UltraCombat.DamageInfo.shove, m/s: shotgun blasts) this big knocks you off your feet.
@export var shove_knockdown := 3.5
## Knockouts (blunt trauma: clubs, gun-butts, thrown props): a hit to the head of at least
## `ko_head`, or a blunt blow anywhere of at least `ko_heavy` after the region multiplier.
@export var ko_head := 18.0
@export var ko_heavy := 55.0
## Blunt to the head counts this much against overall health (a bullet: region_mult, 3x).
@export var blunt_head_mult := 1.2
## A held melee block (UltraActionLayer, MotorState.F_BLOCKING) facing the blow (within
## `block_arc_deg` either side) takes this much of a melee hit; no knockout, cut or knock-down.
@export_range(0, 1, 0.05) var block_mult := 0.2
@export var block_arc_deg := 55.0
## A shot through the heart (a ball `heart_radius` m in the chest, on the shot's line): bleeds
## `heart_bleed_rate` hp/s on top of everything else.
@export var heart_radius := 0.045
@export var heart_bleed_rate := 12.0


func gore_on() -> bool:
	return gore != Gore.OFF


func blood_on() -> bool:
	return gore == Gore.FULL
