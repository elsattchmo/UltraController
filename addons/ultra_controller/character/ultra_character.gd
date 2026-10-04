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
## Every machine, when a hit lands on this character (region = UltraLimbs.Region).
signal hit_reacted(region: int, dir: Vector3, amount: float)

@export var profile: MovementProfile
@export var body_profile: BodyProfile
## Which local viewport (0..3) watches this character in first person, or -1.
@export var view_index := -1
## Step the simulation from _physics_process (single-player / tests without the net layer).
@export var self_simulate := true
## Build the animated body (off for pure-simulation bots, servers and tests).
@export var build_visuals := true
## Per-limb damage, dismemberment and gore rules (a default is made if empty).
@export var damage_profile: DamageProfile
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
var body_fx: UltraBodyFX
var ragdoll: UltraRagdoll
## Getting up: the body starts where the ragdoll lay and eases onto the capsule.
var ragdoll_offset := Vector3.ZERO
var _was_wet := false
var anim: UltraAnimDriver

## Visual-only offset that absorbs teleport-free corrections and step pops (decays to zero).
var visual_offset := Vector3.ZERO
## Interpolated feet position this frame (before any presentation offset such as hanging behind a rope).
var visual_feet := Vector3.ZERO
const ROPE_CHEST_GAP := 0.16
var _prev_pos := Vector3.ZERO
var _prev_yaw := 0.0
var _prev_vel := Vector3.ZERO
var _accel := Vector3.ZERO
var _shape: CollisionShape3D


func _ready() -> void:
	add_to_group(&"ultra_character")
	if profile == null:
		profile = MovementProfile.new()
	if damage_profile == null:
		damage_profile = DamageProfile.new()
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
	_make_hit_volume()
	motor = UltraMotor.new(self, _shape, profile, body_profile.anim_set if body_profile else null)
	motor.damage = damage_profile
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
	# First person hides the head: close the neck opening it leaves in the body.
	var bm := body_node.find_child(body_profile.body_mesh_name, true, false) as MeshInstance3D
	if bm and bm.mesh is ArrayMesh:
		bm.mesh = UltraMeshCap.capped(bm.mesh as ArrayMesh)
	var player := body_node.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if player and skeleton:
		anim = UltraAnimDriver.new()
		anim.name = "AnimDriver"
		anim.anim_set = body_profile.anim_set
		anim.library = body_profile.library
		anim.extra_libraries = body_profile.extra_libraries
		add_child(anim)
		anim.setup(player, skeleton)
		anim.foot_ik.exclude = [get_rid()]
		var eq := UltraEquipmentVisual.new()
		eq.name = "Equipment"
		add_child(eq)
		eq.setup(self)
		var tv := UltraTraversalVisual.new()
		tv.name = "TraversalHands"
		add_child(tv)
		tv.setup(self)
		item_event.connect(func(kind: StringName, _d: Dictionary) -> void: anim.item_event(kind))
		body_fx = UltraBodyFX.new()
		body_fx.name = "BodyFX"
		add_child(body_fx)
		body_fx.setup(self)
		ragdoll = UltraRagdoll.new()
		ragdoll.name = "RagdollFX"
		add_child(ragdoll)
		ragdoll.setup(self)
	set_view_index(view_index)
	_sync_visual(1.0)


## Hide our own head from the camera of local viewport `idx` (shadow still cast).
## Presentation of a hit (every machine): hit clip, flinch on the hit bone.
func react_to_hit(region: int, dir: Vector3, amount: float) -> void:
	if body_fx:
		body_fx.react(region, dir, amount)
	hit_reacted.emit(region, dir, amount)


func body_mesh() -> MeshInstance3D:
	return body_node.find_child(body_profile.body_mesh_name, true, false) as MeshInstance3D if body_node else null


func get_accel() -> Vector3:
	return _accel


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
	# Drop out of anything that pins us to the world (a scripted move, a ladder, a rope...).
	if state.state >= MotorState.Id.MANTLE and state.state <= MotorState.Id.ROPE:
		state.state = MotorState.Id.FALL
		state.state_time = 0.0
		state.trav_id = 0
	if not is_nan(yaw):
		state.body_yaw = yaw
		if input_source:
			input_source.reset_aim(yaw)
	global_position = pos
	_prev_pos = pos
	_prev_yaw = state.body_yaw
	visual_offset = Vector3.ZERO
	_sync_visual(1.0)


## Shots test this wider volume (arms stick out of the movement capsule); which limb was hit
## is then worked out from the region capsules (UltraHitboxes). Movement never touches it.
var hit_volume: StaticBody3D
var _hit_shape: CollisionShape3D


func _make_hit_volume() -> void:
	hit_volume = StaticBody3D.new()
	hit_volume.name = "HitVolume"
	hit_volume.collision_layer = UltraLayers.HITBOX
	hit_volume.collision_mask = 0
	_hit_shape = CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.55
	cap.height = 2.1
	_hit_shape.shape = cap
	_hit_shape.position = Vector3(0, 1.0, 0)
	hit_volume.add_child(_hit_shape)
	add_child(hit_volume)


func _update_hit_volume() -> void:
	if _hit_shape == null:
		return
	var prone := state.state in [MotorState.Id.CRAWL, MotorState.Id.DIVE, MotorState.Id.DEAD, MotorState.Id.RAGDOLL]
	var want := Transform3D(Basis(Vector3.RIGHT, PI * 0.5).rotated(Vector3.UP, state.body_yaw - rotation.y), Vector3(0, 0.35, 0)) if prone \
		else Transform3D(Basis(), Vector3(0, 1.0, 0))
	if not _hit_shape.transform.is_equal_approx(want):
		_hit_shape.transform = want


## The character a ray hit, whether it struck the movement capsule or the hit volume.
static func of_collider(o: Object) -> UltraCharacter:
	if o is UltraCharacter:
		return o
	if o is StaticBody3D and (o as Node).name == "HitVolume" and (o as Node).get_parent() is UltraCharacter:
		return (o as Node).get_parent()
	return null


func _physics_process(delta: float) -> void:
	_update_hit_volume()
	if not self_simulate or input_source == null:
		return
	TickPlatform.set_all(tick)
	platform_tick = tick
	simulate(input_source.sample(tick), delta)
	if state.held_id != 0:
		UltraGrab.server_tick([self], delta)


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
	# Into the water: splash (presentation).
	var wet := motor.water != null and motor.water_depth > 0.15
	if wet and not _was_wet and _prev_vel.y < -1.5 and visual_root:
		var fx := UltraEffects.instance()
		if fx:
			var w := motor.water
			fx.splash(Vector3(state.pos.x, w.surface_y(platform_tick) + w.wave(state.pos), state.pos.z), clampf(-_prev_vel.y / 9.0, 0.3, 1.2))
	_was_wet = wet
	if old != state.state:
		state_changed.emit(old, state.state)
	# Out of air: drowning hurts once a second (authority decides damage).
	if is_authority() and state.breath <= 0.0 and tick % 60 == 0:
		var d := UltraCombat.DamageInfo.new()
		d.amount = 8.0
		d.kind = &"drown"
		d.point = state.pos + Vector3.UP * 1.5
		d.dir = Vector3.DOWN
		apply_damage(d)
	_accel =_accel.lerp((state.vel - _prev_vel) / delta, 0.35)
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
	if e.has("limbs"):
		UltraLimbs.unpack_into(state, int(e.limbs))
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
	ragdoll_offset = ragdoll_offset.lerp(Vector3.ZERO, 1.0 - exp(-2.2 * delta))
	_sync_visual(Engine.get_physics_interpolation_fraction())
	if anim:
		anim.state = state.state
		anim.stance = state.stance
		anim.velocity = state.vel
		anim.air_time = state.air_time
		anim.getup_crawl = UltraInjury.must_crawl(state)
		var S := UltraLimbs.Status
		var ll := UltraLimbs.leg(state, true)
		var lr := UltraLimbs.leg(state, false)
		var sev := func(st: int) -> float: return 0.6 if st == S.INJURED else (1.0 if st >= S.CRIPPLED else 0.0)
		anim.limp = maxf(sev.call(ll), sev.call(lr))
		anim.limp_left = sev.call(ll) >= sev.call(lr)
		var torso := UltraLimbs.status(state, UltraLimbs.Region.TORSO)
		anim.injury_hunch = 0.0 if torso == S.HEALTHY else (0.12 if torso == S.INJURED else 0.25)
		anim.item_left = UltraInjury.weapon_hand(state) == -1
		anim.body_yaw = visual_root.rotation.y
		anim.aim_yaw = input_source.live_yaw if input_source else last_input.yaw
		anim.aim_pitch = input_source.live_pitch if input_source else last_input.pitch
		anim.turning = state.has(UltraMotor.F_TURNING)
		anim.rm_clip = state.rm_clip
		anim.hard_landing = state.has(MotorState.F_HARD_LANDING)
		anim.land_impact = state.land_impact
		anim.on_platform = state.platform_id != 0
		match state.state:
			MotorState.Id.LADDER:
				anim.climb_speed = state.vel.y
				var lad := UltraLadder.find(state.trav_id)
				anim.climb_kind = 1 if lad and lad.kind == UltraLadder.Kind.PIPE else 0
			MotorState.Id.WALL_CLIMB:
				anim.climb_speed = state.vel.y
			MotorState.Id.ROPE:
				# Climb ropes: hand over hand at the climbing speed; swing ropes: just hold on.
				var rope := UltraRope.find(state.trav_id)
				var climbing := rope != null and rope.kind == UltraRope.Kind.CLIMB
				anim.climb_speed = last_input.move.y * 1.1 if climbing else 0.0
			MotorState.Id.LEDGE_HANG:
				anim.climb_speed = last_input.move.x * 0.9
			_:
				anim.climb_speed = 0.0
		anim.climb_duration = state.trav_dur
		anim.aim_weight = 1.0 if faces_aim() else 0.0
		anim.held_def = UltraGrab.CARRY_DEF if state.held_id != 0 else held_def()
		anim.item_action = state.action
		var sprinting := state.has(MotorState.F_SPRINTING) and Vector2(state.vel.x, state.vel.z).length() > profile.jog_speed * 0.9
		anim.item_ready_pose = 0.0 if sprinting or state.action != UltraActionLayer.Action.READY else 1.0
		if state.held_id != 0:
			anim.item_action = UltraActionLayer.Action.READY
			anim.item_ready_pose = 1.0
		anim.accel = _accel


func _sync_visual(alpha: float) -> void:
	if visual_root == null:
		return
	var p := _prev_pos.lerp(state.pos, alpha) + visual_offset + ragdoll_offset
	var yaw := lerp_angle(_prev_yaw, state.body_yaw, alpha)
	# Locally controlled in first person and facing the aim: glue the body to the live mouse
	# yaw so the arms never lag the camera by a tick.
	if view_index >= 0 and input_source and not last_input.has(InputFrame.B_VIEW_TP) \
			and not state.has(UltraMotor.F_TURNING) and state.state != MotorState.Id.ROOT_MOTION \
			and absf(angle_difference(state.body_yaw, last_input.yaw)) < 0.05:
		yaw = input_source.live_yaw
	visual_feet = p
	var basis := Basis(Vector3.UP, yaw)
	if state.state == MotorState.Id.ROPE:
		# Hang along the rope (pivot at the hands) with the rope just in front of the chest.
		var rope := UltraRope.find(state.trav_id)
		if rope:
			var up := (rope.anchor() - p).normalized()
			var fwd := (basis * Vector3.FORWARD)
			fwd = (fwd - up * fwd.dot(up)).normalized()
			basis = Basis(up.cross(-fwd).normalized(), up, -fwd)
			p -= fwd * ROPE_CHEST_GAP
	elif state.state == MotorState.Id.SWIM or state.state == MotorState.Id.DIVE:
		var xf := _swim_visual(p, yaw)
		basis = xf.basis
		p = xf.origin
	else:
		_dive_pitch = 0.0
	visual_root.global_transform = Transform3D(basis, p)


var _dive_pitch := 0.0


## Swimming presentation: the stroke clip is horizontal ~1 m above its root, the tread clip is
## upright. Lift the stroke to the waterline; under water, sink the body into the short capsule
## and pitch it along the swim direction (around the capsule centre).
func _swim_visual(p: Vector3, yaw: float) -> Transform3D:
	var v := state.vel
	var hs := Vector2(v.x, v.z).length()
	var f := clampf((profile.stand_height - state.height) / maxf(profile.stand_height - profile.dive_height, 0.1), 0.0, 1.0)
	var lift := 0.35 * smoothstep(0.15, 0.8, hs) * (1.0 - f) - 0.6 * f
	if state.state == MotorState.Id.SWIM and motor and motor.water:
		lift += motor.water.wave(p) * 0.8                 # ride the waves
	var want_pitch := 0.0
	if state.state == MotorState.Id.DIVE and v.length() > 0.3:
		want_pitch = clampf(atan2(v.y, maxf(hs, 0.01)), deg_to_rad(-75.0), deg_to_rad(75.0))
	_dive_pitch = lerpf(_dive_pitch, want_pitch, 1.0 - exp(-5.0 * get_process_delta_time()))
	var yaw_b := Basis(Vector3.UP, yaw)
	var b := yaw_b * Basis(Vector3.RIGHT, _dive_pitch)
	var c := p + Vector3.UP * state.height * 0.5
	var o := p + Vector3.UP * lift
	return Transform3D(b, c + (b * yaw_b.inverse()) * (o - c))


## Authority only. Characters take damage here (limb damage arrives in M8).
## Damage lands on a region: it hurts overall health (head 3x, limbs less) and that region's
## own health. A region at 0 is crippled; a big enough overkill (or a blade / blast) cuts it off.
func apply_damage(info: UltraCombat.DamageInfo) -> void:
	if not is_authority() or state.state == MotorState.Id.DEAD:
		return
	var dp := damage_profile
	var R := UltraLimbs.Region
	var r := info.region if info.region >= 0 else UltraHitboxes.nearest(self, info.point)
	if info.kind == &"drown":
		r = R.TORSO
	info.region = r
	var mult := dp.region_mult[r] if dp.limb_damage else 1.0
	state.hp = maxf(state.hp - info.amount * mult, 0.0)
	var cut := 0
	if dp.limb_damage and info.kind != &"drown":
		var max_hp := dp.region_hp[r]
		var after := state.limb_hp[r] / 100.0 * max_hp - info.amount
		state.limb_hp[r] = clampi(int(ceil(after / max_hp * 100.0)), 0, 100)
		var sharp := info.kind == &"blast" or info.kind == &"blade"
		if dp.dismemberment and dp.gore_on() and (dp.severable >> r) & 1 and not (state.severed >> r) & 1 \
				and (after <= -dp.sever_overkill or (sharp and after <= 0.0)):
			cut = UltraLimbs.sever_mask(r) & ~state.severed
			state.severed |= cut
			for k in UltraLimbs.COUNT:
				if cut & (1 << k):
					state.limb_hp[k] = 0
	UltraNet.world.broadcast(&"hit", [net_id, info.point, info.dir, info.amount, info.attacker_id, r], false)
	if cut != 0:
		UltraNet.world.broadcast(&"sever", [net_id, cut, info.dir, info.point], true)
	damaged.emit(info)
	var legs := (1 << R.THIGH_L) | (1 << R.SHIN_L) | (1 << R.THIGH_R) | (1 << R.SHIN_R)
	var dead := state.hp <= 0.0 or (cut & (1 << R.HEAD)) != 0 or (dp.limb_damage and state.limb_hp[R.HEAD] == 0)
	if dead:
		state.hp = 0.0
		state.trav_from = info.dir * clampf(info.amount * 0.06, 1.0, 6.0)   # the body's push
		motor.change_state(state, last_input, MotorState.Id.DEAD)
		UltraNet.world.broadcast(&"died", [net_id, info.attacker_id], true)
		died.emit()
	elif info.amount * mult >= dp.knockdown_damage or info.kind == &"blast" or (cut & legs) != 0:
		knock_down(info.dir * clampf(info.amount * 0.08, 2.0, 8.0) + Vector3.UP * 1.5)


## Authority: fall over (ragdoll); you get up once the body settles. Predicted from here on.
func knock_down(push: Vector3) -> void:
	if not is_authority() or state.state in [MotorState.Id.DEAD, MotorState.Id.RAGDOLL, MotorState.Id.GET_UP]:
		return
	state.trav_from = push
	motor.change_state(state, last_input, MotorState.Id.RAGDOLL)


func respawn(at: Transform3D) -> void:
	state.hp = 100.0
	state.limb_hp = UltraLimbs.full_health()
	state.severed = 0
	state.breath = profile.breath_time
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
