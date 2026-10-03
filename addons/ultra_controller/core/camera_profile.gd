@tool
class_name UltraCameraProfile
extends Resource
## Camera feel. Lives inside a MovementProfile so a project type swaps the whole feel at once.

@export_group("Common")
@export_range(40, 120, 0.5) var fov := 75.0
@export_range(0, 20, 0.5) var sprint_fov_kick := 6.0
@export_range(0.01, 0.3, 0.005) var near := 0.03

@export_group("First person")
## 0 = fully stabilized eye, 1 = glued to the animated head bone.
@export_range(0, 1, 0.01) var fp_head_follow := 0.35
## Extra oscillation taken from the head bone (high-passed), so bob comes from the real gait.
@export_range(0, 2, 0.01) var fp_bob_amount := 0.8
## Eye point relative to the Head bone, in character space (metres; -Z forward).
## When looking down, move the eye forward so the chest never fills the view.
@export_range(0, 0.4, 0.005) var fp_lookdown_shift := 0.2
@export_range(0, 5, 0.1) var fp_strafe_roll_deg := 1.2
@export_range(0, 30, 0.5) var lean_angle_deg := 12.0
@export_range(0, 0.6, 0.01) var lean_offset := 0.32

@export_group("Third person")
@export_range(0.5, 10, 0.05) var tp_distance := 3.2
@export var tp_shoulder := Vector3(0.45, 0.15, 0.0)
@export_range(0, 40, 0.5) var tp_follow_sharpness := 14.0
@export_range(0, 3, 0.05) var tp_pivot_height := 1.55
@export_range(0.05, 1, 0.01) var view_switch_time := 0.3

@export_group("Springs")
@export_range(1, 40, 0.5) var land_spring_freq := 9.0
@export_range(0.05, 2, 0.01) var land_spring_damping := 0.55
@export_range(0, 0.1, 0.001) var land_kick_per_mps := 0.012
@export_range(0, 0.4, 0.005) var land_kick_max := 0.16
@export_range(1, 40, 0.5) var eye_height_sharpness := 12.0
