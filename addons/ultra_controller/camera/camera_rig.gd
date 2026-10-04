class_name UltraCameraRig
extends Node3D
## First / third person camera for one local player.
##
## First person: the eye rides the animated head bone (so the body you see and the bob you
## feel come from the same animation) blended with a low-passed eye for stability; looking down
## eases the eye forward so the chest never fills the view and your legs and feet are visible.
## Third person: a shoulder camera on a collision-aware arm with a lag spring.
## Switching between them is a smooth dolly.

@export var character: UltraCharacter
@export var view_index := 0

var camera: Camera3D
var cam_profile: UltraCameraProfile
var tp_blend := 0.0              ## 0 = first person, 1 = third person

var _eye_lp := Vector3.ZERO      ## low-passed eye, character-local
var _eye_lp_ready := false
var _land := UltraSpring.new(0.0, 2.0, 0.55)
var _roll := UltraSpring.new(0.0, 3.0, 0.8)
var _lean := UltraSpring.new(0.0, 4.0, 0.9)
var _fov := UltraSpring.new(0.0, 2.0, 1.0)
var _kick := UltraSpring.new(Vector2.ZERO, 5.0, 0.6)
var _tp_pivot := Vector3.ZERO
var _tp_dist := 0.0
var _head_bone := -1
var _head_rest_inv := Basis()
var _ray_excl: Array[RID] = []


func _ready() -> void:
	top_level = true
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	camera = Camera3D.new()
	camera.name = "Camera3D"
	add_child(camera)
	camera.current = true
	process_priority = 100        # after the character and its AnimationTree
	if character:
		attach(character)


func attach(c: UltraCharacter) -> void:
	character = c
	cam_profile = c.profile.camera if c.profile and c.profile.camera else UltraCameraProfile.new()
	_land.frequency = cam_profile.land_spring_freq * 0.25
	_land.damping = cam_profile.land_spring_damping
	c.set_view_index(view_index)
	c.landed.connect(_on_landed)
	c.item_event.connect(_on_item_event)
	_ray_excl = [c.get_rid()]
	tp_blend = 1.0 if c.profile.default_view == MovementProfile.View.THIRD_PERSON else 0.0
	if c.input_source:
		c.input_source.view_tp = tp_blend > 0.5
	_tp_pivot = c.global_position + Vector3.UP * cam_profile.tp_pivot_height
	if c.skeleton:
		_head_bone = c.skeleton.find_bone("Head")
		if _head_bone >= 0:
			_head_rest_inv = c.skeleton.get_bone_global_rest(_head_bone).basis.orthonormalized().inverse()
		# Bone poses include IK / aim / lean only once the skeleton has run its modifiers.
		c.skeleton.skeleton_updated.connect(_on_skeleton_updated)


func _on_landed(impact: float) -> void:
	var k := minf(impact * cam_profile.land_kick_per_mps, cam_profile.land_kick_max)
	_land.impulse(-k * 9.0)
	if character.input_source is LocalInputSource:
		(character.input_source as LocalInputSource).rumble(0.2 * k * 6.0, 0.5 * k * 6.0, 0.12)


## Camera kick (recoil, hits): radians of pitch/yaw that spring back.
func kick(pitch: float, yaw: float) -> void:
	_kick.impulse(Vector2(yaw, pitch) * 30.0)


## Recoil: ~30 % stays in the aim (you have to pull down), the rest springs back.
func _on_item_event(kind: StringName, _data: Dictionary) -> void:
	if kind != &"fire" or character.input_source == null:
		return
	var def := character.held_def()
	if def == null:
		return
	var ads := _equipment().ads if _equipment() else 0.0
	var p := deg_to_rad(float(def.stat("recoil_pitch_deg", 2.0))) * lerpf(1.0, 0.6, ads)
	var y := deg_to_rad(float(def.stat("recoil_yaw_deg", 0.5))) * randf_range(-1.0, 1.0)
	character.input_source.add_aim_offset(y * 0.3, p * 0.3)
	kick(p * 0.7, y * 0.7)
	if character.input_source is LocalInputSource:
		(character.input_source as LocalInputSource).rumble(0.3, 0.15, 0.08)


func _equipment() -> UltraEquipmentVisual:
	return character.get_node_or_null("Equipment") as UltraEquipmentVisual


var _eye_sk_cached := Vector3.ZERO
var _have_eye := false


func _on_skeleton_updated() -> void:
	if _head_bone < 0:
		return
	var sk := character.skeleton
	var head_sk := sk.get_bone_global_pose(_head_bone)
	var rot_sk := head_sk.basis.orthonormalized() * _head_rest_inv
	var to_sk := sk.global_basis.orthonormalized().inverse() * character.visual_root.global_basis
	var eye_sk := head_sk.origin + rot_sk * (to_sk * character.body_profile.eye_offset)
	# Store relative to the visual root so it stays valid when the root moves next frame.
	_eye_sk_cached = character.visual_root.global_transform.affine_inverse() * (sk.global_transform * eye_sk)
	_have_eye = true


func _process(delta: float) -> void:
	if character == null or character.input_source == null:
		return
	var src := character.input_source
	var want_tp := 1.0 if src.view_tp and character.profile.allow_view_toggle else 0.0
	if not character.profile.allow_view_toggle:
		want_tp = 1.0 if character.profile.default_view == MovementProfile.View.THIRD_PERSON else 0.0
	tp_blend = move_toward(tp_blend, want_tp, delta / maxf(cam_profile.view_switch_time, 0.01))
	var t := smoothstep(0.0, 1.0, tp_blend)

	var yaw := src.live_yaw
	var pitch := src.live_pitch
	_kick.step(delta)
	var k: Vector2 = _kick.value
	yaw += k.x
	pitch += k.y
	var vis := character.visual_root.global_transform

	# --- first-person eye
	# Eye from the last fully-modified skeleton pose (aim pitch, lean, IK applied), kept in
	# visual-root space so it follows this frame's body position without lag.
	var eye_local := _eye_sk_cached if _have_eye else Vector3(0, character.get_eye_height(), 0)
	if not _eye_lp_ready:
		_eye_lp = eye_local
		_eye_lp_ready = true
	_eye_lp = _eye_lp.lerp(eye_local, 1.0 - exp(-cam_profile.eye_height_sharpness * delta))
	var bob := (eye_local - _eye_lp) * cam_profile.fp_bob_amount
	var fp_local := _eye_lp.lerp(eye_local, cam_profile.fp_head_follow) + bob * (1.0 - cam_profile.fp_head_follow)
	# Look down: ease forward along the aim so the torso never blocks the view.
	var down := smoothstep(deg_to_rad(25.0), deg_to_rad(80.0), -pitch)
	var aim_fwd_local := vis.basis.inverse() * Vector3(-sin(yaw), 0, -cos(yaw))
	fp_local += aim_fwd_local * cam_profile.fp_lookdown_shift * down
	# Lean.
	var lean_in := 0.0
	if character.profile.enable_lean:
		if character.last_input.has(InputFrame.B_LEAN_L): lean_in -= 1.0
		if character.last_input.has(InputFrame.B_LEAN_R): lean_in += 1.0
	_lean.target = lean_in
	_lean.step(delta)
	var right_local := vis.basis.inverse() * Vector3(cos(yaw), 0, -sin(yaw))
	fp_local += right_local * cam_profile.lean_offset * float(_lean.value)
	_land.step(delta)
	fp_local.y += float(_land.value)
	var fp_pos := _fp_guard(vis, vis * fp_local) if t < 0.99 else vis * fp_local
	# Swimming at the surface: keep the eye just above the water line (never half-submerged).
	if character.state.state == MotorState.Id.SWIM and character.motor and character.motor.water:
		fp_pos.y = maxf(fp_pos.y, character.motor.water.surface_y(TickPlatform.current_tick) + 0.12)

	# --- third-person shoulder
	var pivot_target := character.visual_root.global_position + Vector3.UP * (character.state.height * 0.86)
	_tp_pivot = _tp_pivot.lerp(pivot_target, 1.0 - exp(-cam_profile.tp_follow_sharpness * delta))
	_tp_pivot.y = lerpf(_tp_pivot.y, pivot_target.y, 1.0 - exp(-cam_profile.tp_follow_sharpness * 0.6 * delta))
	var rot := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch)
	var shoulder := rot * Vector3(cam_profile.tp_shoulder.x, cam_profile.tp_shoulder.y, 0)
	var back := rot * Vector3(0, 0, cam_profile.tp_distance)
	var desired := _tp_pivot + shoulder + back
	var hit_dist := _arm_collide(_tp_pivot, _tp_pivot + shoulder, desired)
	_tp_dist = hit_dist if hit_dist < _tp_dist else lerpf(_tp_dist, hit_dist, 1.0 - exp(-6.0 * delta))
	var tp_pos := _tp_pivot + shoulder * clampf(_tp_dist / cam_profile.tp_distance, 0.0, 1.0) + back.normalized() * _tp_dist

	# --- roll from strafing / lean, FOV kick from sprint
	var lv := vis.basis.inverse() * character.state.vel
	_roll.target = clampf(-lv.x / maxf(character.profile.jog_speed, 0.1), -1.0, 1.0) * deg_to_rad(cam_profile.fp_strafe_roll_deg) * (1.0 - t)
	_roll.step(delta)
	var roll: float = _roll.value - float(_lean.value) * deg_to_rad(cam_profile.lean_angle_deg) * (1.0 - t)
	_fov.target = cam_profile.sprint_fov_kick if character.state.has(MotorState.F_SPRINTING) and character.state.vel.length() > character.profile.jog_speed else 0.0
	_fov.step(delta)

	global_position = fp_pos.lerp(tp_pos, t)
	camera.global_transform = Transform3D(rot * Basis(Vector3.BACK, roll), global_position)
	var eq := _equipment()
	var ads := eq.ads if eq else 0.0
	if eq:
		eq.camera = camera if t < 0.5 else null
	var ads_fov := float(character.held_def().stat("ads_fov", cam_profile.fov)) if character.held_def() else cam_profile.fov
	camera.fov = lerpf(cam_profile.fov + float(_fov.value), ads_fov, smoothstep(0.0, 1.0, ads))
	if src is LocalInputSource:
		(src as LocalInputSource).sens_mult = lerpf(1.0, UltraInputSettings.f("ads_sensitivity_mult"), ads)
	camera.near = lerpf(cam_profile.near, 0.08, t)
	var first_person := tp_blend < 0.15
	camera.cull_mask = UltraLayers.camera_cull_mask(view_index, first_person)
	_underwater_fx()


var _uw_env: Environment
var underwater := false


## Under the surface: murky blue fog through a per-camera environment override.
func _underwater_fx() -> void:
	var under := not UltraWater.all.is_empty() and UltraWater.depth_at(camera.global_position, TickPlatform.current_tick) > 0.02
	if under == underwater:
		return
	underwater = under
	if under:
		if _uw_env == null:
			var base := get_world_3d().environment if get_world_3d() else null
			if base == null:
				var we := get_tree().root.find_child("WorldEnvironment", true, false) as WorldEnvironment
				base = we.environment if we else null
			_uw_env = base.duplicate() if base else Environment.new()
			_uw_env.fog_enabled = true
			_uw_env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
			_uw_env.fog_light_color = Color(0.08, 0.36, 0.44)
			_uw_env.fog_light_energy = 0.9
			_uw_env.fog_density = 0.1
			_uw_env.fog_sky_affect = 1.0
			_uw_env.adjustment_enabled = true
			_uw_env.adjustment_saturation = 0.75
			_uw_env.adjustment_brightness = 0.85
			# Tint everything (fog only reaches the distance): a blue-green colour grade.
			var gt := GradientTexture1D.new()
			var gr := Gradient.new()
			gr.set_color(0, Color(0.0, 0.03, 0.06))
			gr.set_color(1, Color(0.62, 0.9, 0.95))
			gt.gradient = gr
			_uw_env.adjustment_color_correction = gt
		camera.environment = _uw_env
	else:
		camera.environment = null


## Keep the first-person eye out of walls: the head bone can dip into a ledge while mantling
## or into the wall while hanging. Sweep from the capsule axis (at eye height) to the eye.
func _fp_guard(vis: Transform3D, eye: Vector3) -> Vector3:
	var space := get_world_3d().direct_space_state
	var h := clampf((vis.affine_inverse() * eye).y, 0.3, maxf(character.state.height - 0.12, 0.3))
	var origin := vis.origin + vis.basis.y.normalized() * h
	var sphere := SphereShape3D.new()
	sphere.radius = maxf(cam_profile.near * 2.5, 0.08)
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sphere
	q.transform = Transform3D(Basis(), origin)
	q.collision_mask = UltraLayers.WORLD_STATIC | UltraLayers.CLIMBABLE
	q.exclude = _ray_excl
	if not space.intersect_shape(q, 1).is_empty():
		return eye                       # axis itself inside geometry: nothing sensible to do
	q.motion = eye - origin
	var r := space.cast_motion(q)
	return origin + (eye - origin) * r[0]


func _arm_collide(pivot: Vector3, shoulder_pt: Vector3, desired: Vector3) -> float:
	var space := get_world_3d().direct_space_state
	var full := (desired - shoulder_pt).length()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.2
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sphere
	q.transform = Transform3D(Basis(), shoulder_pt)
	q.motion = desired - shoulder_pt
	q.collision_mask = UltraLayers.WORLD_STATIC
	q.exclude = _ray_excl
	var r := space.cast_motion(q)
	# Also make sure the pivot can see the shoulder.
	var ray := PhysicsRayQueryParameters3D.create(pivot, shoulder_pt, UltraLayers.WORLD_STATIC, _ray_excl)
	if not space.intersect_ray(ray).is_empty():
		return 0.3
	return maxf(full * r[0], 0.3)
