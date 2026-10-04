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
## Presentation events from the action layer: &"fire", &"reload", &"mag_in", &"dry_fire"...
signal item_event(kind: StringName, data: Dictionary)
## The authority changed this character's inventory (UltraNet sends it to the owner).
signal inventory_dirty
## Authority: damage was applied (see UltraCombat.DamageInfo).
signal damaged(info: UltraCombat.DamageInfo)
signal died

@export var profile: MovementProfile
@export var body_profile: BodyProfile
## Which local viewport (0..3) watches this character in first person, or -1.
@export var view_index := -1
## Step the simulation from _physics_process (single-player / tests without the net layer).
@export var self_simulate := true
## Build the animated body (off for pure-simulation bots, servers and tests).
@export var build_visuals := true
## Snap state to its network encoding after each tick (on in sessions; deterministic replays).
var quantize_state := false

var input_source: InputSource
## NetPlayer.Role this character plays on this machine (set by UltraNet).
const ROLE_PREDICTED := 2
const ROLE_INTERPOLATED := 3
var net_role: int = 0
## NetPlayer id (0 when not in a session). Seeds deterministic weapon spread.
var net_id: int = 0
var inventory := Inventory.new()
var motor: UltraMotor
var state := MotorState.new()
var tick := 0
## World tick for moving platforms during the next simulate() (set by UltraNet).
var platform_tick := 0
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
	collision_mask = UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC
	if profile.character_collision == MovementProfile.CharacterCollision.HARD:
		collision_mask |= UltraLayers.CHARACTER
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
	if body_profile == null or body_profile.body_scene == null or not build_visuals:
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
		anim.foot_ik.exclude = [get_rid()]
		var eq := UltraEquipmentVisual.new()
		eq.name = "Equipment"
		add_child(eq)
		eq.setup(self)
		item_event.connect(func(kind: StringName, _d: Dictionary) -> void: anim.item_event(kind))
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
	TickPlatform.set_all(tick)
	platform_tick = tick
	simulate(input_source.sample(tick), delta)


## One simulation tick. Used directly (single-player) and by the net layer. `replaying` is
## set during reconciliation: the state advances but presentation events don't re-fire.
func simulate(input: InputFrame, delta: float, replaying := false) -> void:
	_prev_pos = state.pos
	_prev_yaw = state.body_yaw
	var old := state.state
	motor.apply_pushes = net_role != ROLE_PREDICTED and not replaying   # only the authority shoves props
	motor.platform_tick = platform_tick
	motor.step(state, input, delta)
	UltraActionLayer.step(self, state, input, delta, replaying)
	if is_authority() and not replaying and input.target_id != 0 and UltraMotor.pressed_edge(state, input, InputFrame.B_INTERACT):
		UltraItems.interact(self, input.target_id)
	state.prev_buttons = input.buttons
	# Every machine continues from exactly what a snapshot can carry, so a client rebased
	# onto server state and the server itself compute identical futures.
	if quantize_state:
		state.quantize()
	last_input = input
	tick = input.tick + 1
	if replaying:
		return
	if motor.last_step_up > 0.0:
		visual_offset.y -= motor.last_step_up        # the camera/body glide up the step
	if motor.last_landing > 0.0:
		landed.emit(motor.last_landing)
	if old != state.state:
		state_changed.emit(old, state.state)
	_accel = _accel.lerp((state.vel - _prev_vel) / delta, 0.35)
	_prev_vel = state.vel


## Client view of somebody else's character: interpolated snapshot values, every frame.
## `e` is the newest snapshot entry (discrete fields), pos/vel/yaw are interpolated.
func apply_remote(pos: Vector3, vel: Vector3, yaw: float, e: Dictionary) -> void:
	var aim_yaw: float = e.aim_yaw
	var pitch: float = e.pitch
	var st: int = e.state
	var stance: int = e.stance
	var flags: int = e.flags
	var height: float = e.height
	var rm_clip: int = e.rm_clip
	var land_impact: float = e.land_impact
	var buttons: int = e.buttons
	var seq: int = e.get("fire_seq", state.fire_seq)
	if seq != state.fire_seq:
		var def := ItemDB.by_index(int(e.get("equipped", 0)))
		item_event.emit(&"fire", {"remote": true})
		if def == null:
			pass
	state.fire_seq = seq
	state.equipped = int(e.get("equipped", 0))
	state.action = int(e.get("action", 0))
	state.hp = float(e.get("hp", state.hp))
	var old := state.state
	var dt := maxf(get_process_delta_time(), 0.001)
	_accel = _accel.lerp((vel - state.vel) / dt, 0.2)
	state.pos = pos
	state.vel = vel
	state.body_yaw = yaw
	state.state = st
	state.stance = stance
	state.flags = flags
	state.height = height
	state.rm_clip = rm_clip
	state.land_impact = land_impact
	last_input.yaw = aim_yaw
	last_input.pitch = pitch
	last_input.buttons = buttons
	_prev_pos = pos
	_prev_yaw = yaw
	global_position = pos
	motor.update_stance(state, stance)
	if old != st:
		state_changed.emit(old, st)
		if st == MotorState.Id.LAND or (old in [MotorState.Id.JUMP, MotorState.Id.FALL] and st != MotorState.Id.FALL):
			landed.emit(land_impact)


func _process(delta: float) -> void:
	visual_offset = visual_offset.lerp(Vector3.ZERO, 1.0 - exp(-14.0 * delta))
	_sync_visual(Engine.get_physics_interpolation_fraction())
	if anim:
		anim.state = state.state
		anim.stance = state.stance
		anim.velocity = state.vel
		anim.body_yaw = visual_root.rotation.y
		anim.aim_yaw = input_source.live_yaw if input_source else last_input.yaw
		anim.aim_pitch = input_source.live_pitch if input_source else last_input.pitch
		anim.turning = state.has(UltraMotor.F_TURNING)
		anim.rm_clip = state.rm_clip
		anim.hard_landing = state.has(MotorState.F_HARD_LANDING)
		anim.land_impact = state.land_impact
		anim.on_platform = state.platform_id != 0
		anim.aim_weight = 1.0 if faces_aim() else 0.0
		anim.held_def = held_def()
		anim.item_action = state.action
		var sprinting := state.has(MotorState.F_SPRINTING) and Vector2(state.vel.x, state.vel.z).length() > profile.jog_speed * 0.9
		anim.item_ready_pose = 0.0 if sprinting or state.action != UltraActionLayer.Action.READY else 1.0
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


## Authority only. Characters take damage here (limb damage arrives in M8).
func apply_damage(info: UltraCombat.DamageInfo) -> void:
	if not is_authority() or state.state == MotorState.Id.DEAD:
		return
	state.hp = maxf(state.hp - info.amount, 0.0)
	UltraNet.world.broadcast(&"hit", [net_id, info.point, info.dir, info.amount, info.attacker_id], false)
	damaged.emit(info)
	if state.hp <= 0.0:
		motor.change_state(state, last_input, MotorState.Id.DEAD)
		UltraNet.world.broadcast(&"died", [net_id, info.attacker_id], true)
		died.emit()


func respawn(at: Transform3D) -> void:
	state.hp = 100.0
	state.state = MotorState.Id.IDLE
	state.action = 0
	teleport(at.origin, at.basis.get_euler().y)


func is_authority() -> bool:
	return net_role == 0 or net_role == 1


func emit_item_event(kind: StringName, data: Dictionary, replaying: bool) -> void:
	if not replaying:
		item_event.emit(kind, data)


func inventory_changed_by_server() -> void:
	inventory_dirty.emit()


func held_def() -> ItemDefinition:
	return ItemDB.by_index(state.equipped)


## Does the body turn to face the aim right now? (first person, or TP aiming modes)
func faces_aim() -> bool:
	if state.equipped != 0 and state.action == UltraActionLayer.Action.READY:
		return true                       # holding a weapon ready: always face the aim
	if not last_input.has(InputFrame.B_VIEW_TP):
		return true
	match profile.tp_rotation:
		MovementProfile.Rotation.FACE_AIM:
			return true
		MovementProfile.Rotation.FACE_MOVE_UNTIL_AIM:
			return last_input.has(InputFrame.B_SECONDARY)
	return false


func is_first_person() -> bool:
	return not last_input.has(InputFrame.B_VIEW_TP)


func get_eye_height() -> float:
	return state.height - 0.16
