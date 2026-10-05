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
var _aim_frame_w := 1.0
var _head_eye_cached := Vector3.ZERO
var _head_look_cached := Basis()
var _down_w := 0.0                  ## knocked down / dead / getting up: the view is the head's
var _down_q := Quaternion.IDENTITY
var _down_p := Vector3.INF          ## low-passed down-eye position (world)
var _neck_bone := -1
var _neck_cached := Vector3.INF
## The eye stays this far above / in front of the neck joint (crouching or running bends the
## head down below the shoulders; the camera must not follow it into the body).
const EYE_ABOVE_NECK := 0.13
const EYE_AHEAD_OF_NECK := 0.09
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
	c.plunged.connect(_on_plunged)
	c.item_event.connect(_on_item_event)
	c.hit_reacted.connect(_on_hit)
	_ray_excl = [c.get_rid()]
	if c.hit_volume:
		_ray_excl.append(c.hit_volume.get_rid())
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


## Hitting the water: the view jolts down with the impact; a hard one leaves you dazed a moment.
func _on_plunged(speed: float) -> void:
	var k := clampf((speed - 3.0) / 10.0, 0.0, 1.0)
	if k <= 0.0:
		return
	_land.impulse(-k * 6.0)
	kick(-0.05 * k, randf_range(-0.03, 0.03) * k)
	if speed > UltraSwim.PLUNGE_FALL_SPEED:
		_concuss_amp = clampf(k, 0.4, 0.8)
		_concuss = 1.6 * _concuss_amp
	if character.input_source is LocalInputSource:
		(character.input_source as LocalInputSource).rumble(0.4 * k, 0.8 * k, 0.25)


## Camera kick (recoil, hits): radians of pitch/yaw that spring back.
var _was_out := false               ## knocked out last frame (waking up is groggy)
var _concuss := 0.0                ## seconds of head-hit wobble left
var _concuss_amp := 0.0


## Hits jolt the view; head hits leave you reeling for a moment (wobble, FOV pulse).
func _on_hit(region: int, _dir: Vector3, amount: float) -> void:
	if region == UltraLimbs.Region.HEAD:
		_concuss_amp = clampf(amount / 40.0, 0.4, 1.0)
		_concuss = 2.5 * _concuss_amp
		kick(0.1 * _concuss_amp, randf_range(-0.08, 0.08))
	else:
		kick(clampf(amount * 0.0015, 0.01, 0.05), randf_range(-0.02, 0.02))


func kick(pitch: float, yaw: float) -> void:
	_kick.impulse(Vector2(yaw, pitch) * 30.0)


## Recoil: the gun itself kicks in the simulation (free aim, UltraActionLayer._recoil); the
## view gets a little: ~30 % stays in the aim (you have to pull down), a short shake on top.
func _on_item_event(kind: StringName, _data: Dictionary) -> void:
	if kind == &"melee_hit" and character.input_source != null:
		# A blow landing jars the view; a miss barely.
		var landed: bool = _data.get("hit", false)
		kick(0.03 if landed else 0.008, randf_range(-0.02, 0.02) if landed else 0.0)
		if landed and character.input_source is LocalInputSource:
			(character.input_source as LocalInputSource).rumble(0.5, 0.3, 0.1)
		return
	if kind != &"fire" or character.input_source == null:
		return
	var def := character.held_def()
	if def == null:
		return
	var ads := _equipment().ads if _equipment() else 0.0
	var p := deg_to_rad(float(def.stat("recoil_pitch_deg", 2.0))) * lerpf(1.0, 0.6, ads)
	var y := deg_to_rad(float(def.stat("recoil_yaw_deg", 0.5))) * randf_range(-1.0, 1.0)
	character.input_source.add_aim_offset(y * 0.3, p * 0.3)
	kick(p * 0.35, y * 0.35)
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
	# A shouldered gun pulls the body after it (WeaponPoseModifier): the eye comes from the pose
	# before that, else the body chasing the camera-placed gun would move the camera.
	var wp := character.anim.weapon_pose if character.anim else null
	var shouldered := wp != null and wp.shouldered
	if shouldered:
		head_sk = wp.pre_head
	var rot_sk := head_sk.basis.orthonormalized() * _head_rest_inv
	var to_sk := sk.global_basis.orthonormalized().inverse() * character.visual_root.global_basis
	# The eye follows the head's turn but not its nod: pitching the head would swing the eye out
	# in front of the body exactly when you look down at it.
	var rot_v := to_sk.inverse() * rot_sk * to_sk
	var f := rot_v * Vector3.FORWARD
	f.y = 0.0
	var yaw_v := Basis(Vector3.UP, atan2(-f.x, -f.z)) if f.length() > 0.05 else Basis()
	var vis_inv := character.visual_root.global_transform.affine_inverse()
	# Stored relative to the visual root so it stays valid when the root moves next frame.
	_eye_sk_cached = vis_inv * (sk.global_transform * head_sk.origin) + yaw_v * character.body_profile.eye_offset
	# The real eye (full head rotation) and where the head looks, for when the body is down.
	var vis_b_inv := character.visual_root.global_basis.orthonormalized().inverse()
	var head_world_b := sk.global_basis.orthonormalized() * rot_sk
	_head_eye_cached = vis_inv * (sk.global_transform * head_sk.origin) + vis_b_inv * (head_world_b * (to_sk * character.body_profile.eye_offset))
	_head_look_cached = vis_b_inv * head_world_b * Basis(Vector3.UP, PI)     # model +Z forward -> camera -Z
	if _neck_bone < 0:
		_neck_bone = sk.find_bone("Neck")
	if _neck_bone >= 0:
		_neck_cached = vis_inv * (sk.global_transform * (wp.pre_neck if shouldered else sk.get_bone_global_pose(_neck_bone).origin))
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

	# Coming round from a knockout: a groggy few seconds.
	var out := character.state.has(MotorState.F_UNCONSCIOUS)
	if _was_out and not out:
		_concuss_amp = 0.9
		_concuss = 2.5 * _concuss_amp + 1.5
	_was_out = out
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
	# Standing / moving, the eye's offset from the body axis follows where you look, not where
	# the body faces: when the feet shuffle round (turn in place) the view just pivots instead
	# of the eye orbiting the capsule. Ladders, ropes, swimming etc. keep the head-based eye.
	var Id := MotorState.Id
	var upright := character.state.state in [Id.IDLE, Id.MOVE, Id.CROUCH, Id.CRAWL, Id.LAND, Id.TURN_IN_PLACE, Id.JUMP, Id.FALL, Id.SLIDE]
	_aim_frame_w = move_toward(_aim_frame_w, 1.0 if upright else 0.0, delta * 3.0)
	var aim_basis := Basis(Vector3.UP, src.live_yaw)
	var e_world := vis * fp_local
	var d := aim_basis.inverse() * (e_world - vis.origin)
	# Side-to-side (in the aim frame): stay on the body's axis, keeping a little of the sway.
	var lat := cam_profile.fp_lateral_follow * lerpf(1.0, 0.35, smoothstep(deg_to_rad(15.0), deg_to_rad(60.0), -src.live_pitch))
	d.x *= lat
	if _neck_cached != Vector3.INF:
		var nd := aim_basis.inverse() * (vis.basis * _neck_cached)
		d.y = maxf(d.y, nd.y + EYE_ABOVE_NECK)
		# Looking straight down the collar would sit right under the eye: get further ahead.
		var steep := smoothstep(deg_to_rad(40.0), deg_to_rad(80.0), -src.live_pitch)
		d.z = minf(d.z, nd.z - EYE_AHEAD_OF_NECK - 0.09 * steep)
	var fp_base := e_world.lerp(vis.origin + aim_basis * d, _aim_frame_w)
	# Look down: ease forward along the aim so the torso never blocks the view.
	var down := smoothstep(deg_to_rad(25.0), deg_to_rad(80.0), -pitch)
	var shift := Vector3(-sin(yaw), 0, -cos(yaw)) * cam_profile.fp_lookdown_shift * down
	# Lean.
	var lean_in := 0.0
	if character.profile.enable_lean:
		if character.last_input.has(InputFrame.B_LEAN_L): lean_in -= 1.0
		if character.last_input.has(InputFrame.B_LEAN_R): lean_in += 1.0
	_lean.target = lean_in
	_lean.step(delta)
	shift += Vector3(cos(yaw), 0, -sin(yaw)) * cam_profile.lean_offset * float(_lean.value)
	_land.step(delta)
	shift.y += float(_land.value)
	var fp_raw := fp_base + shift
	# Aiming down a shouldered gun's sights: the head goes down onto the stock.
	var ads_eq := _equipment()
	if ads_eq and ads_eq.held_def and ads_eq.ads > 0.0 and ads_eq.held_def.fp_ads_eye != Vector3.ZERO:
		var o := ads_eq.held_def.fp_ads_eye
		fp_raw += Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch) * Vector3(o.x, o.y, -o.z) * smoothstep(0.0, 1.0, ads_eq.ads)
	var fp_pos := _fp_guard(vis, fp_raw) if t < 0.99 else fp_raw
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
	var wob := 0.0
	if _concuss > 0.0:
		_concuss = maxf(_concuss - delta, 0.0)
		wob = _concuss_amp * smoothstep(0.0, 1.0, _concuss / (2.5 * _concuss_amp))
		var now := Time.get_ticks_msec() / 1000.0
		roll += sin(now * 5.3) * 0.07 * wob
		rot = rot * Basis(Vector3.RIGHT, sin(now * 3.1) * 0.03 * wob) * Basis(Vector3.UP, sin(now * 2.3) * 0.04 * wob)
	_fov.target = cam_profile.sprint_fov_kick if character.state.has(MotorState.F_SPRINTING) and character.state.vel.length() > character.profile.jog_speed else 0.0
	_fov.step(delta)

	# Down (ragdoll, dead, getting up): first person looks out of the head's real eye, the way
	# the head faces (smoothed a little so a tumbling head doesn't shake the view to pieces).
	var Id2 := MotorState.Id
	var is_down := character.state.state in [Id2.RAGDOLL, Id2.DEAD, Id2.GET_UP] and _have_eye
	_down_w = move_toward(_down_w, 1.0 if is_down else 0.0, delta * (6.0 if is_down else 2.0))
	var cam_basis := rot * Basis(Vector3.BACK, roll)
	if _down_w > 0.001:
		var getting_up := character.state.state == Id2.GET_UP
		var head_q := _tame_view((vis.basis.orthonormalized() * _head_look_cached).get_rotation_quaternion())
		# Never look back down into our own neck / chest (a tucked chin while getting up).
		if _neck_cached != Vector3.INF:
			var to_neck := (vis * _neck_cached - vis * _head_eye_cached).normalized()
			var look := Basis(head_q) * Vector3.FORWARD
			var lim := cos(deg_to_rad(60.0))
			if look.dot(to_neck) > lim:
				var axis := to_neck.cross(look)
				if axis.length() > 0.001:
					var ang := acos(clampf(look.dot(to_neck), -1.0, 1.0))
					head_q = Quaternion(axis.normalized(), deg_to_rad(60.0) - ang) * head_q
		# Getting up: the get-up clip throws the head about. Follow it loosely and hand the view
		# back to your own aim as you rise, so you're looking where you aim once you're up.
		var handback := smoothstep(0.1, 0.75, character.state.state_time / UltraAnimDriver.GETUP_TIME) if getting_up else 0.0
		head_q = head_q.slerp(cam_basis.get_rotation_quaternion(), handback)
		if _down_w < 0.02 or _down_p == Vector3.INF:
			_down_q = head_q
		else:
			var nq := _down_q.slerp(head_q, 1.0 - exp(-(4.0 if getting_up else 12.0) * delta))
			var step := _down_q.angle_to(nq)
			var max_step := deg_to_rad(90.0 if getting_up else 360.0) * delta
			_down_q = _down_q.slerp(nq, max_step / step) if step > max_step else nq
		var dw := smoothstep(0.0, 1.0, _down_w)
		# Out in front of the face: a tucked head puts the real eye right against the collar.
		var face := Basis(_down_q) * Vector3.FORWARD
		var eye_t := vis * _head_eye_cached + face * 0.15
		_down_p = eye_t if _down_p == Vector3.INF else _down_p.lerp(eye_t, 1.0 - exp(-(6.0 if getting_up else 18.0) * delta))
		fp_pos = fp_pos.lerp(_down_p.lerp(fp_pos, handback), dw)
		# Lying on your face, "in front of the face" is in the floor: keep the eye out of it.
		fp_pos = _sweep_clear(vis.origin + Vector3.UP * 0.35, fp_pos)
		cam_basis = Basis(cam_basis.get_rotation_quaternion().slerp(_down_q, dw))
	else:
		_down_q = cam_basis.get_rotation_quaternion()
		_down_p = Vector3.INF
	global_position = fp_pos.lerp(tp_pos, t)
	camera.global_transform = Transform3D(cam_basis.slerp(rot * Basis(Vector3.BACK, roll), t) if t > 0.0 else cam_basis, global_position)
	# Shots start where we look from (UltraActionLayer.shot_origin): tell the sim where that is.
	src.aim_from = global_position - (character.visual_feet + Vector3.UP * (character.state.height - 0.16))
	var eq := _equipment()
	var ads := eq.ads if eq else 0.0
	if eq:
		eq.camera = camera if t < 0.5 else null
	var ads_fov := float(character.held_def().stat("ads_fov", cam_profile.fov)) if character.held_def() else cam_profile.fov
	camera.fov = lerpf(cam_profile.fov + float(_fov.value), ads_fov, smoothstep(0.0, 1.0, ads)) + sin(Time.get_ticks_msec() / 1000.0 * 2.0) * 4.0 * wob
	if src is LocalInputSource:
		(src as LocalInputSource).sens_mult = lerpf(1.0, UltraInputSettings.f("ads_sensitivity_mult"), ads)
	camera.near = lerpf(cam_profile.near, 0.08, t)
	var first_person := tp_blend < 0.15
	# (The eye sits inside the head mesh: our own head stays hidden in first person, always.)
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
## Sweep a small sphere from `origin` (known clear) toward `target`; stop short of geometry.
func _sweep_clear(origin: Vector3, target: Vector3) -> Vector3:
	var space := get_world_3d().direct_space_state
	var sphere := SphereShape3D.new()
	sphere.radius = maxf(cam_profile.near * 2.5, 0.08)
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sphere
	q.transform = Transform3D(Basis(), origin)
	q.collision_mask = UltraLayers.WORLD_STATIC | UltraLayers.CLIMBABLE
	q.exclude = _ray_excl
	if not space.intersect_shape(q, 1).is_empty():
		return target
	q.motion = target - origin
	var r := space.cast_motion(q)
	return origin + (target - origin) * r[0]


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


## Keep the knocked-down eye view watchable: no more than 50 deg down (face down you'd stare
## along your own arms into the floor) and at most 35 deg of roll.
static func _tame_view(q: Quaternion) -> Quaternion:
	var b := Basis(q)
	var f := -b.z
	# Heading: looking near straight down (lying on your face) the view direction alone gives
	# a heading that spins wildly; the top of the head points where the face does then.
	var hv := Vector2(f.x, f.z) + Vector2(b.y.x, b.y.z) * (-f.y)
	var yaw := atan2(-hv.x, -hv.y)
	var raw_pitch := asin(clampf(f.y, -1.0, 1.0))
	var pitch := clampf(raw_pitch, deg_to_rad(-50.0), deg_to_rad(70.0))
	# Roll: the head's up against the level "up" for that heading and pitch, measured around
	# the view direction (measuring it against world up flips +-90 when looking down).
	var level := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, raw_pitch)
	var roll := clampf(atan2(-b.y.dot(level.x), b.y.dot(level.y)), deg_to_rad(-25.0), deg_to_rad(25.0))
	return (Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch) * Basis(Vector3.BACK, roll)).get_rotation_quaternion()


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
