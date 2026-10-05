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
## thigh L, shin L, thigh R, shin R.
@export var region_hp := PackedFloat32Array([45, 100, 40, 35, 40, 35, 55, 45, 55, 45])
## How much of a hit there comes off overall health.
@export var region_mult := PackedFloat32Array([3.0, 1.0, 0.55, 0.45, 0.55, 0.45, 0.7, 0.55, 0.7, 0.55])
## A single hit that takes a region this far past zero cuts it off (bladed / blast: any overkill).
@export var sever_overkill := 45.0
## Bitmask of regions that can come off (bit = UltraLimbs.Region); torso never does.
@export_flags("Head", "Torso", "Upper arm L", "Forearm L", "Upper arm R", "Forearm R", "Thigh L", "Shin L", "Thigh R", "Shin R")
var severable := 0b1111111101

## Bleeding out: health lost per second (hp/s) while a region is cut off (counted at the top of
## a cut chain - an arm off at the shoulder bleeds as the upper arm). An arm off: dead in
## ~25 s; a leg off at the hip: ~18 s.
@export var bleed_rate := PackedFloat32Array([0.0, 0.0, 4.0, 3.0, 4.0, 3.0, 5.5, 3.5, 5.5, 3.5])
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
## Knockouts (blunt trauma: clubs, gun-butts, thrown props): a hit to the head of at least
## `ko_head`, or a blunt blow anywhere of at least `ko_heavy` after the region multiplier.
@export var ko_head := 18.0
@export var ko_heavy := 55.0
## Blunt to the head counts this much against overall health (a bullet: region_mult, 3x).
@export var blunt_head_mult := 1.2


func gore_on() -> bool:
	return gore != Gore.OFF


func blood_on() -> bool:
	return gore == Gore.FULL
