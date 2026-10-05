@tool
class_name MovementProfile
extends Resource
## Everything that makes a controller feel like an FPS, an adventure game, a survival game
## or a shooter. Presets live in addons/ultra_controller/profiles/. Speeds are in m/s.

enum Rotation { FACE_AIM, FACE_MOVE, FACE_MOVE_UNTIL_AIM }
## How characters treat each other. SOFT (default) lets them overlap slightly and pushes them
## apart: predicted clients never get blocked by a remote player they only see ~100 ms late.
enum CharacterCollision { SOFT, HARD, NONE }
enum View { FIRST_PERSON, THIRD_PERSON }

@export_group("View")
@export var default_view := View.FIRST_PERSON
@export var allow_view_toggle := true
## Body rotation in first person is always FACE_AIM; this applies to third person.
@export var tp_rotation := Rotation.FACE_MOVE_UNTIL_AIM
@export var camera: UltraCameraProfile = UltraCameraProfile.new()

enum Gait { WALK, JOG }

@export_group("Speeds")
## What full movement input does without Sprint: WALK (walk / sprint, the default) or JOG
## (walk on a light stick, jog at full deflection, sprint).
@export var default_gait := Gait.WALK
@export_range(0.5, 4, 0.05) var walk_speed := 1.35
@export_range(1, 8, 0.05) var jog_speed := 3.6
@export_range(2, 12, 0.05) var sprint_speed := 6.2
@export_range(0.3, 4, 0.05) var crouch_speed := 1.5
@export_range(0.1, 2, 0.05) var crawl_speed := 0.75
@export_range(0.2, 1, 0.01) var back_mult := 0.82
@export_range(0.2, 1, 0.01) var strafe_mult := 0.95
## Analog sticks: below this deflection speed scales up to a walk; above it, the default gait.
@export_range(0.1, 1, 0.01) var walk_deflection := 0.55

@export_group("Inertia")
## Ground acceleration (m/s²) and its shape over speed ratio (0 = standing, 1 = target speed).
@export_range(1, 80, 0.5) var accel := 9.0
@export var accel_curve: Curve
@export_range(1, 80, 0.5) var decel := 11.0
## Deceleration used when input opposes velocity — the weighty plant-and-pivot.
@export_range(1, 80, 0.5) var brake_decel := 16.0
## How fast the velocity heading can swing (deg/s) at walk and at sprint: momentum.
@export_range(30, 2000, 5) var turn_rate_walk := 720.0
@export_range(30, 2000, 5) var turn_rate_sprint := 150.0
## Body yaw tracking for FACE_MOVE (deg/s).
@export_range(30, 2000, 5) var body_turn_rate := 540.0
## Idle FACE_AIM: the spine absorbs aim up to this angle before the feet turn.
@export_range(10, 120, 1) var turn_in_place_angle := 70.0
@export_range(10, 900, 5) var turn_in_place_rate := 180.0
## Turn in place eases in and out at this angular acceleration (deg/s^2).
@export_range(100, 5000, 10) var turn_in_place_accel := 720.0
## With a gun up the feet come round sooner (the chest is already bladed off the aim).
@export_range(10, 120, 1) var armed_turn_angle := 45.0

@export_group("Air")
@export_range(0, 40, 0.5) var air_accel := 3.5
@export_range(0, 1, 0.01) var air_control := 0.35
@export_range(0.1, 4, 0.05) var jump_height := 1.05
@export_range(1, 4, 0.05) var fall_gravity_mult := 1.55
@export_range(1, 6, 0.05) var jump_cut_gravity_mult := 2.2
@export_range(0, 0.4, 0.01) var coyote_time := 0.12
@export_range(0, 0.4, 0.01) var jump_buffer := 0.12
@export_range(5, 100, 1) var max_fall_speed := 45.0

@export_group("Ground")
@export_range(10, 70, 0.5) var max_slope_deg := 46.0
@export_range(0, 0.7, 0.01) var step_height := 0.36
@export_range(0, 1, 0.01) var floor_snap := 0.45

@export_group("Body")
@export_range(0.1, 0.6, 0.01) var radius := 0.3
@export_range(1, 2.5, 0.01) var stand_height := 1.8
@export_range(0.6, 2, 0.01) var crouch_height := 1.2
@export_range(0.3, 1.2, 0.01) var crawl_height := 0.7
@export_range(0.02, 0.6, 0.01) var stance_transition := 0.14
@export_range(20, 300, 1) var mass := 80.0
## Pushing force against rigid bodies (N). Friction decides what actually slides.
@export_range(0, 2000, 10) var push_strength := 420.0
## Up to this mass you hold things out in front (one-handed feel, can jump).
@export_range(1, 200, 0.5) var lift_limit := 25.0
## Heaviest thing you can carry alone (two hands, slow, no jumping). Heavier: push or team up.
@export_range(1, 300, 1) var carry_capacity := 60.0
## Maximum holding force (N); gravity compensation counts against it.
@export_range(100, 5000, 10) var strength_n := 1100.0
@export var character_collision := CharacterCollision.SOFT
## Separation speed when two characters overlap (SOFT).
@export_range(0, 10, 0.1) var separation_speed := 2.5

@export_group("Slide")
@export var enable_slide := true
@export_range(1, 10, 0.1) var slide_min_speed := 4.6
@export_range(0, 20, 0.1) var slide_friction := 3.2
@export_range(0, 6, 0.1) var slide_boost := 1.0
@export_range(0, 3, 0.05) var slide_max_time := 1.1

@export_group("Landing")
## Landing faster than this (m/s) crumples you into a ragdoll (13.5 m/s ~ a 9 m drop).
@export_range(2, 30, 0.5) var hard_land_speed := 13.5
@export_range(0, 1, 0.01) var land_recover_time := 0.22
@export_range(0, 1, 0.01) var hard_land_recover_time := 0.6
## A thrown prop hitting this hard (kg*m/s, relative to you) knocks you over; softer hits
## shove and hurt a little (a 10 kg box thrown at full charge is ~45).
@export_range(5, 300, 1) var impact_knockdown := 40.0

@export_group("Balance")
## Standing on an edge with nothing under the middle of you over a drop deeper than this (m):
## you teeter, and after teeter_time lose your balance and topple off (ragdoll). Walking out
## over the edge steps off it as normal; stepping back recovers.
@export_range(0.2, 3, 0.05) var balance_drop := 0.45
@export_range(0.1, 3, 0.05) var teeter_time := 0.7
## 0 turns the balance check off.
@export var enable_balance := true

@export_group("Water")
@export var enable_swim := true
## Water this deep above the feet floats you (about chest height).
@export_range(0.5, 2.0, 0.01) var swim_depth := 1.3
## Floating: feet this far below the surface (head and shoulders out).
@export_range(0.5, 2.0, 0.01) var float_depth := 1.5
@export_range(0.2, 5, 0.05) var swim_speed := 1.5
@export_range(0.2, 6, 0.05) var swim_sprint_speed := 2.4
@export_range(0.2, 5, 0.05) var dive_speed := 1.8
@export_range(0.5, 20, 0.1) var swim_accel := 3.0
## Underwater capsule height (horizontal body).
@export_range(0.5, 1.5, 0.01) var dive_height := 0.8
## Seconds of air; refills 4x faster than it drains.
@export_range(1, 120, 1) var breath_time := 20.0
## Wading speed multiplier from knee-deep (0) to chest-deep (1).
@export_range(0.1, 1, 0.01) var wade_mult_knee := 0.85
@export_range(0.1, 1, 0.01) var wade_mult_chest := 0.5

@export_group("Features")
@export var enable_sprint := true
@export var enable_crouch := true
@export var enable_crawl := true
@export var enable_roll := true
@export var enable_lean := true
@export var enable_turn_in_place := true


func get_accel_mult(speed_ratio: float) -> float:
	if accel_curve == null:
		# Default: strong initial push, tapering as you reach speed (feels heavy, not floaty).
		return lerpf(1.35, 0.55, clampf(speed_ratio, 0.0, 1.0))
	return accel_curve.sample_baked(clampf(speed_ratio, 0.0, 1.0))


func jump_velocity(gravity: float) -> float:
	return sqrt(2.0 * gravity * jump_height)
