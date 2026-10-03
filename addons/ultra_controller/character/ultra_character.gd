class_name UltraCharacter
extends CharacterBody3D
## A universal humanoid: motor (simulation) + visual body (presentation).
##
## Simulation: `simulate(input)` advances MotorState one tick through UltraMotor. In M1 the
## character drives itself from its InputSource; the net layer (M2) takes over and calls
## simulate() for authority / prediction / replay.
## Presentation: every frame the VisualRoot is interpolated between the last two ticks (plus
## reconciliation smoothing), and the AnimDriver is fed from the motor state.

signal landed(impact_speed: float)
signal state_changed(old_state: int, new_state: int)

@export var profile: MovementProfile
@export var body_profile: BodyProfile
## Which local viewport (0..3) watches this character in first person, or -1.
@export var view_index := -1
## Step the simulation from _physics_process (single-player / tests without the net layer).
@export var self_simulate := true

var input_source: InputSource
var motor: UltraMotor
var state := MotorState.new()
var tick := 0
var last_input := InputFrame.new()

var visual_root: Node3D
var body_node: Node3D
var skeleton: Skeleton3D
var head_mesh: MeshInstance3D
var anim: UltraAnimDriver

## Visual-only offset that absorbs teleport-free corrections and step pops (decays to zero).
var visual_offset := Vector3.ZERO
var _prev_pos := Vector3.ZERO
var _prev_yaw := 0.0
var _prev_vel := Vector3.ZERO
var _accel := Vector3.ZERO
var _shape: CollisionShape3D


func _ready() -> void:
	if profile == null:
		profile = MovementProfile.new()
	collision_layer = UltraLayers.CHARACTER
	collision_mask = UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC | UltraLayers.CHARACTER
	_shape = get_node_or_null("CollisionShape3D")
	if _shape == null:
		_shape = CollisionShape3D.new()
		_shape.name = "CollisionShape3D"
		_shape.shape = CapsuleShape3D.new()
		add_child(_shape)
	motor = UltraMotor.new(self, _shape, profile, body_profile.anim_set if body_profile else null)
	state.pos = global_position
	state.height = profile.stand_height
	state.body_yaw = rotation.y
	rotation = Vector3.ZERO
	state.set_flag(MotorState.F_GROUNDED, true)
	_prev_pos = state.pos
	_prev_yaw = state.body_yaw
	_build_visual()
	if input_source == null:
		input_source = get_node_or_null("InputSource") as InputSource
	if input_source:
		input_source.reset_aim(state.body_yaw)


func _build_visual() -> void:
	visual_root = Node3D.new()
	visual_root.name = "VisualRoot"
	visual_root.top_level = true
	visual_root.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(visual_root)
	if body_profile == null or body_profile.body_scene == null:
		return
	body_node = body_profile.body_scene.instantiate() as Node3D
	body_node.name = "Body"
	if body_profile.model_faces_positive_z:
		body_node.rotation.y = PI
	visual_root.add_child(body_node)
	skeleton = body_node.find_child(body_profile.skeleton_name, true, false) as Skeleton3D
	head_mesh = body_node.find_child(body_profile.head_mesh_name, true, false) as MeshInstance3D
	var player := body_node.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if player and skeleton:
		anim = UltraAnimDriver.new()
		anim.name = "AnimDriver"
		anim.anim_set = body_profile.anim_set
		anim.library = body_profile.library
		add_child(anim)
		anim.setup(player, skeleton)
	set_view_index(view_index)
	_sync_visual(1.0)


## Hide our own head from the camera of local viewport `idx` (shadow still cast).
func set_view_index(idx: int) -> void:
	view_index = idx
	if head_mesh:
		head_mesh.layers = 1 if idx < 0 else UltraLayers.local_head_render_layer(idx)


func set_input_source(src: InputSource) -> void:
	input_source = src
	if src:
		src.reset_aim(state.body_yaw)


func teleport(pos: Vector3, yaw: float = NAN) -> void:
	state.pos = pos
	state.vel = Vector3.ZERO
	if not is_nan(yaw):
		state.body_yaw = yaw
		if input_source:
			input_source.reset_aim(yaw)
	global_position = pos
	_prev_pos = pos
	_prev_yaw = state.body_yaw
	visual_offset = Vector3.ZERO
	_sync_visual(1.0)


func _physics_process(delta: float) -> void:
	if not self_simulate or input_source == null:
		return
	simulate(input_source.sample(tick), delta)


## One simulation tick. Used directly (single-player) and by the net layer.
func simulate(input: InputFrame, delta: float) -> void:
	_prev_pos = state.pos
	_prev_yaw = state.body_yaw
	var old := state.state
	motor.step(state, input, delta)
	last_input = input
	tick = input.tick + 1
	if motor.last_step_up > 0.0:
		visual_offset.y -= motor.last_step_up        # the camera/body glide up the step
	if motor.last_landing > 0.0:
		landed.emit(motor.last_landing)
	if old != state.state:
		state_changed.emit(old, state.state)
	_accel = _accel.lerp((state.vel - _prev_vel) / delta, 0.35)
	_prev_vel = state.vel


func _process(delta: float) -> void:
	visual_offset = visual_offset.lerp(Vector3.ZERO, 1.0 - exp(-14.0 * delta))
	_sync_visual(Engine.get_physics_interpolation_fraction())
	if anim:
		anim.state = state.state
		anim.stance = state.stance
		anim.velocity = state.vel
		anim.body_yaw = visual_root.rotation.y
		anim.aim_yaw = input_source.live_yaw if input_source else state.body_yaw
		anim.aim_pitch = input_source.live_pitch if input_source else last_input.pitch
		anim.turning = state.has(UltraMotor.F_TURNING)
		anim.rm_clip = state.rm_clip
		anim.hard_landing = state.has(MotorState.F_HARD_LANDING)
		anim.accel = _accel


func _sync_visual(alpha: float) -> void:
	if visual_root == null:
		return
	var p := _prev_pos.lerp(state.pos, alpha) + visual_offset
	var yaw := lerp_angle(_prev_yaw, state.body_yaw, alpha)
	# Locally controlled in first person and facing the aim: glue the body to the live mouse
	# yaw so the arms never lag the camera by a tick.
	if view_index >= 0 and input_source and not last_input.has(InputFrame.B_VIEW_TP) \
			and not state.has(UltraMotor.F_TURNING) and state.state != MotorState.Id.ROOT_MOTION \
			and absf(angle_difference(state.body_yaw, last_input.yaw)) < 0.05:
		yaw = input_source.live_yaw
	visual_root.global_transform = Transform3D(Basis(Vector3.UP, yaw), p)


func is_first_person() -> bool:
	return not last_input.has(InputFrame.B_VIEW_TP)


func get_eye_height() -> float:
	return state.height - 0.16
