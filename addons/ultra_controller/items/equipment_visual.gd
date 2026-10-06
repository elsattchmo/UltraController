class_name UltraEquipmentVisual
extends Node
## Shows what a character holds and carries: the held item in the right hand (at its fitted
## grip), a firearm that isn't drawn on the hip holster, the left hand on the support grip,
## and aim-down-sights (moves the gun so its sights line up with the camera, first person).
## Presentation only; reads MotorState + Inventory, never writes them.

var character: UltraCharacter
var hand_attach: BoneAttachment3D
var left_hand_attach: BoneAttachment3D
var _side := 1                        ## 1 right hand, -1 left (right arm out of action)
var hip_attach: BoneAttachment3D
var held_node: Node3D                 ## instance of the held item's equip_scene
var holster_node: Node3D              ## what's in the hip holster (first hip item not in hand)
var back_node: Node3D                 ## what's slung on the back (first back item not in hand)
var held_def: ItemDefinition
var ads := 0.0                        ## 0..1, presentation blend
var camera: Camera3D                  ## set for the local first-person viewer

var _held_uid := -1
## Holstered / slung items: bone name -> {"uid": int, "node": Node3D}.
var _stowed := {}
var _stow_attach := {}
## Free-aim offset of the last two ticks (MotorState.sway), for smooth presentation.
var _slide_kick := 0.0
var _mag_hidden := false
var _recoil := UltraSpring.new(Vector3.ZERO, 6.0, 0.55)
var _fp_w := 0.0
var _owns := [false, false]          ## hand IK goals we set (never release someone else's)
var _prop: RigidBody3D
var _owns_prop := false
var _reload_w := 0.0
## First-person gun life: step bob, look lag, sprint lowering.
var _bob_phase := 0.0
var _bob_amp := 0.0
var _sprint_w := 0.0


func setup(c: UltraCharacter) -> void:
	character = c
	# After the camera rig (priority 100): first-person gun targets use this frame's camera.
	process_priority = 110
	var sk := c.skeleton
	hand_attach = BoneAttachment3D.new()
	hand_attach.name = "RightHandAttach"
	hand_attach.bone_name = "RightHand"
	sk.add_child(hand_attach)
	left_hand_attach = BoneAttachment3D.new()
	left_hand_attach.name = "LeftHandAttach"
	left_hand_attach.bone_name = "LeftHand"
	sk.add_child(left_hand_attach)
	hip_attach = BoneAttachment3D.new()
	hip_attach.name = "HipAttach"
	hip_attach.bone_name = "Hips"
	sk.add_child(hip_attach)
	_stow_attach["Hips"] = hip_attach
	c.item_event.connect(_on_item_event)
	_add_item_roles()


## Items can bring the animation roles they need (ItemDefinition.anim_clips): a role the
## character's AnimationSet doesn't define gets the first of the item's clips that exists.
func _add_item_roles() -> void:
	var anim := character.anim
	if anim == null or anim.anim_set == null or anim.player == null:
		return
	for d in ItemDB.all():
		for role: StringName in d.anim_clips:
			if anim.anim_set.has_role(role):
				continue
			var opts: Variant = d.anim_clips[role]
			if not (opts is Array):
				opts = [opts]
			for clip: String in opts:
				var full := clip if clip.contains("/") or anim.library_name == &"" else "%s/%s" % [anim.library_name, clip]
				if anim.player.has_animation(full):
					anim.anim_set.roles[StringName(role)] = clip
					break


func _process(delta: float) -> void:
	if character == null:
		return
	var s := character.state
	# --- held item
	var side := -1 if UltraInjury.weapon_hand(s) == -1 else 1
	if s.held_uid != _held_uid or side != _side:
		# The aim trim is the clip's own error for that item: keep one per item, so a draw
		# starts from its own (the last item's pulled the new gun off for a moment).
		if held_def:
			_aim_fix_of[held_def.id] = _aim_fix
		_held_uid = s.held_uid
		_side = side
		var nd := ItemDB.by_index(s.equipped)
		_aim_fix = _aim_fix_of.get(nd.id, Vector2.ZERO) if nd else Vector2.ZERO
		if held_node:
			held_node.queue_free()
			held_node = null
		held_def = ItemDB.by_index(s.equipped)
		if held_def and held_def.equip_scene:
			held_node = held_def.equip_scene.instantiate() as Node3D
			(hand_attach if _side == 1 else left_hand_attach).add_child(held_node)
			held_node.transform = grip()
			_set_layers(held_node)
	# --- holster / sling: the first hip item and the first back item that aren't in hand
	_update_stowed()
	# --- slide blowback + magazine during reload
	_slide_kick = move_toward(_slide_kick, 0.0, delta * 0.6)
	if held_node:
		var slide := held_node.find_child("Slide", true, false) as Node3D
		if slide:
			if not slide.has_meta("rest"):
				slide.set_meta("rest", slide.position)
			slide.position = (slide.get_meta("rest") as Vector3) + Vector3(0, 0, -minf(_slide_kick, 0.03))
		_drive_pump(delta)
		_drive_barrel_smoke(delta)
		var mag := held_node.find_child("Magazine", true, false) as Node3D
		if mag:
			if not mag.has_meta("rest"):
				mag.set_meta("rest", mag.transform)
			if mag_reload() and _mag_hand != Transform3D():
				mag.global_transform = _mag_hand      # (in the left hand while it's out)
				mag.visible = true
			else:
				mag.transform = mag.get_meta("rest")
				var hide := s.action == UltraActionLayer.Action.RELOADING and s.action_t > 0.35 and s.action_t < float(held_def.stat("reload_commit", 1.5)) - 0.2
				mag.visible = not hide
	if _melee_t >= 0.0:
		# Simulated characters show the strike where the sim has it (the event can arrive a
		# frame late); remote ones run their own clock from the event.
		if s.action == UltraActionLayer.Action.MELEE and character.net_role != UltraCharacter.ROLE_INTERPOLATED:
			_melee_t = maxf(_melee_t, s.action_t)
		else:
			_melee_t += delta
		if _melee_sw.is_empty() or _melee_t > float(_melee_sw.time):
			_melee_t = -1.0
	_drive_hands(delta)
	_drive_held_prop(delta)
	_aim_body()


## Free-aim offset now (radians, x = yaw, y = pitch): the simulated MotorState.sway,
## interpolated between the last two ticks.
func sway_now() -> Vector2:
	if character == null:
		return Vector2.ZERO
	# (The character keeps the value from before its last tick, so a frame that ran two ticks
	# still interpolates - remembering per frame snapped the gun whenever that happened.)
	return character.prev_sway.lerp(character.state.sway, clampf(Engine.get_physics_interpolation_fraction(), 0.0, 1.0))


## The shot ray as it will go (presentation): from the simulated eye along the gun's direction
## (this frame's aim + the free-aim offset). The HUD's gun dot is where it meets the world.
func gun_ray() -> Dictionary:
	var src := character.input_source
	var yaw := src.live_yaw if src else character.last_input.yaw
	var pitch := src.live_pitch if src else character.last_input.pitch
	var eye := character.visual_feet + Vector3.UP * (character.state.height - 0.16)
	var dir := UltraActionLayer.gun_dir(yaw, pitch, sway_now())
	var af := src.aim_from if src else character.last_input.aim_from
	return {"origin": UltraActionLayer.shot_origin(eye, af, dir), "dir": dir}


## World rotation from the aim onto the gun (free aim), about wherever it is applied.
func sway_rotation() -> Basis:
	var src := character.input_source
	var yaw := src.live_yaw if src else character.last_input.yaw
	var pitch := src.live_pitch if src else character.last_input.pitch
	return UltraActionLayer.sway_basis(yaw, pitch, sway_now())


## Third person: the arms (spine, via the body modifier's weapon aim) follow the gun's
## direction, so the gun visibly lags turns, bobs and drops for a sprint like the dot does.
## (First person poses the gun from the camera instead.) Runs after the AnimDriver set the
## modifier for this frame; the skeleton applies it at the end of the frame.
func _aim_body() -> void:
	var anim := character.anim
	if anim == null or anim.modifier == null or camera != null or _fp_w > 0.001:
		return
	# (Breathing - a few hundredths of a degree - isn't worth twisting the spine for at this
	# distance: only what's past a 0.25 deg deadband turns the body.)
	var sw := sway_now()
	# The sprint's lowering is the lowered pose's job (aiming the spine down after it too dipped
	# the body as the sprint ended).
	var low := smoothstep(0.0, 1.0, character.state.gun_low)
	if held_def and low > 0.0:
		sw -= Vector2(deg_to_rad(held_def.sprint_lower_deg.x) * _side, deg_to_rad(held_def.sprint_lower_deg.y)) * low
	sw -= sw.limit_length(deg_to_rad(0.25))
	var w := anim.modifier.weapon_aim
	if w <= 0.0 or held_def == null:
		return
	# The aiming clip's own barrel direction, taken back out (a bladed rifle clip points the
	# gun off to one side of the chest).
	var clip := held_def.aim_clip_offset * Vector2(float(_side), 1.0)
	# A gun-butt strike swings the shoulders into it (a pistol whips down).
	var mk := melee_amount()
	if mk != 0.0 and held_def.kind == ItemDefinition.Kind.FIREARM:
		anim.modifier.aim_yaw += 0.35 * mk * w
		anim.modifier.aim_pitch -= (0.55 if not _long_gun() else 0.15) * mk * w
	# Whatever is left - the clip's barrel under this stance, crouch, the legs' warp (the
	# pistol pointed ~20 deg left of the aim) - is measured off the gun as last drawn and
	# trimmed out by turning the spine a little further each frame.
	if held_node and w > 0.3 and character.state.action == UltraActionLayer.Action.READY:   # (not mid-strike)
		var barrel := -held_node.global_basis.z.normalized()
		var want := gun_ray().dir as Vector3
		var err := Vector2(angle_difference(atan2(-want.x, -want.z), atan2(-barrel.x, -barrel.z)),
			asin(clampf(barrel.y, -1.0, 1.0)) - asin(clampf(want.y, -1.0, 1.0)))
		var k := 1.0 - exp(-6.0 * get_process_delta_time())
		_aim_fix = (_aim_fix + Vector2(err.x, -err.y) * k * w).limit_length(deg_to_rad(35.0))
	anim.modifier.aim_yaw += (deg_to_rad(clip.x) - sw.x + _aim_fix.x) * w
	anim.modifier.aim_pitch += (sw.y - deg_to_rad(clip.y) + _aim_fix.y) * w
	# The shot's kick rocks the shoulders back (a shotgun's a lot).
	anim.modifier.aim_pitch += (_recoil.value as Vector3).z * 1.2 * w


## Third person: spine turn (yaw right +, pitch up +) that brings the drawn barrel onto the
## gun direction, learnt from the gun as drawn (see _aim_body).
var _aim_fix := Vector2.ZERO
var _aim_fix_of := {}


func _update_stowed() -> void:
	var want := {}
	var inv := character.inventory
	if inv:
		for i in Inventory.HOTBAR:
			var it := inv.get_slot(i)
			if it == null or it.uid == character.state.held_uid or it.def() == null or it.def().equip_scene == null:
				continue
			var d := it.def()
			if not (d.can_equip(ItemDefinition.EquipSlot.HIP) or d.can_equip(ItemDefinition.EquipSlot.BACK)):
				continue
			var bone := String(d.holster_bone)
			if not want.has(bone):
				want[bone] = it
	for bone: String in _stowed.keys():
		if not want.has(bone) or (want[bone] as ItemInstance).uid != int(_stowed[bone].uid):
			var n: Node3D = _stowed[bone].node
			if is_instance_valid(n):
				n.queue_free()
			_stowed.erase(bone)
	for bone: String in want:
		if _stowed.has(bone):
			continue
		var it: ItemInstance = want[bone]
		var att := _attach_for(bone)
		if att == null:
			continue
		var n := it.def().equip_scene.instantiate() as Node3D
		att.add_child(n)
		n.transform = it.def().holster_offset
		_stowed[bone] = {"uid": it.uid, "node": n}
	holster_node = _stowed["Hips"].node if _stowed.has("Hips") else null
	back_node = null
	for bone: String in _stowed:
		if bone != "Hips":
			back_node = _stowed[bone].node


func _attach_for(bone: String) -> BoneAttachment3D:
	if _stow_attach.has(bone):
		return _stow_attach[bone]
	var sk := character.skeleton
	if sk == null or sk.find_bone(bone) < 0:
		return null
	var a := BoneAttachment3D.new()
	a.name = bone + "StowAttach"
	a.bone_name = bone
	sk.add_child(a)
	_stow_attach[bone] = a
	return a


## Hands on a held prop; the owner's own client shows the predicted hold (the server's
## version arrives ~100 ms later through the prop stream).
func _drive_held_prop(delta: float) -> void:
	var s := character.state
	var anim := character.anim
	var o := UltraNet.world.get_object(s.held_id) if s.held_id != 0 else null
	var rb := o.rigid() if o else null
	if _prop != rb:
		if _prop and is_instance_valid(_prop):
			var po := _prop.find_child("NetObject", false, false)
			if po:
				po.set_meta("held_locally", false)
		_prop = rb
	if rb == null:
		if _owns_prop:
			anim.hand_ik.release(HandIKModifier.Hand.LEFT, 6.0)
			anim.hand_ik.release(HandIKModifier.Hand.RIGHT, 6.0)
			_owns_prop = false
		return
	if character.net_role == UltraCharacter.ROLE_PREDICTED and s.held_grip < 0:
		o.set_meta("held_locally", true)
		var target := UltraGrab.approach(rb, UltraGrab.hold_target(character, rb), delta)
		rb.global_position = rb.global_position.lerp(target, 1.0 - exp(-18.0 * delta))
	_hands_on_prop(rb, s)
	_owns_prop = true


## Both palms flat on the outside of the prop: on its left and right faces (or on top of a
## team-lift grip), fingers pointing forward, at the real surface of its collision shape.
func _hands_on_prop(rb: RigidBody3D, s: MotorState) -> void:
	var ik := character.anim.hand_ik
	var vb := character.visual_root.global_basis.orthonormalized()
	var right := vb.x
	var fwd := -vb.z
	var c := rb.global_position
	for i in 2:
		var side := -1.0 if i == HandIKModifier.Hand.LEFT else 1.0
		var contact: Vector3
		var palm_dir: Vector3            # direction the palm faces (into the object)
		var fingers := (fwd * 0.9 + Vector3.DOWN * 0.3).normalized()
		if s.held_grip >= 0:
			var grips := UltraGrab.grip_points(rb)
			var gp := grips[s.held_grip].global_position if s.held_grip < grips.size() else c
			var axis := rb.global_basis.x.normalized()
			if axis.dot(right) < 0.0:
				axis = -axis
			var top := gp + axis * 0.14 * side
			contact = UltraGrab.surface_point(rb, top, Vector3.UP)
			palm_dir = Vector3.DOWN
		else:
			var out := right * side
			# On the side faces, toward the back half (where the arms come from) and a little low.
			var from := c + Vector3.DOWN * UltraGrab.support(rb, Vector3.DOWN) * 0.25 - fwd * UltraGrab.support(rb, -fwd) * 0.4
			contact = UltraGrab.surface_point(rb, from, out)
			palm_dir = -out
		# Hand bone sits at the wrist: back along the fingers, out by the hand's thickness.
		var wrist := contact - fingers * 0.075 - palm_dir * 0.028
		var basis := _hand_basis(i, fingers, palm_dir)
		ik.set_goal(i, Transform3D(basis, wrist), 1.0, basis != Basis(), 10.0, 0.8)
	_owns_prop = true


var _palm_local := [Vector3.ZERO, Vector3.ZERO]


## World basis for a hand bone whose fingers point along `fingers` and palm faces `palm`. The
## palm direction in the bone's own frame is learned from the curled fingers of the animation.
func _hand_basis(hand: int, fingers: Vector3, palm: Vector3) -> Basis:
	var sk := character.skeleton
	if _palm_local[hand] == Vector3.ZERO:
		var side := "Left" if hand == 0 else "Right"
		var hb := sk.get_bone_global_pose(sk.find_bone(side + "Hand"))
		var tip := Vector3.ZERO
		for f in ["MiddleDistal", "RingDistal", "IndexDistal"]:
			tip += sk.get_bone_global_pose(sk.find_bone(side + f)).origin / 3.0
		var v := hb.basis.orthonormalized().inverse() * (tip - hb.origin)
		v.y = 0.0                        # bone +Y runs along the fingers
		if v.length() < 0.01:
			return Basis()
		_palm_local[hand] = v.normalized()
	var src_y := Vector3.UP
	var src_p: Vector3 = _palm_local[hand]
	var src := Basis(src_y.cross(src_p), src_y, src_p)
	var f := fingers.normalized()
	var p := (palm - f * palm.dot(f)).normalized()
	var dst := Basis(f.cross(p), f, p)
	return dst * src.inverse()


## Make the first-person gun move like it's held: a small step bob of the hands in time with
## the gait, canted and pulled in while sprinting. Where the barrel POINTS (the lag behind
## turns, the sway, the sprint drop, recoil) is the simulated free aim, applied afterwards.
func _gun_motion(gun: Transform3D, cam: Transform3D, delta: float, ads_e: float) -> Transform3D:
	var s := character.state
	var speed := Vector2(s.vel.x, s.vel.z).length()
	var grounded := s.is_grounded()
	var cadence := clampf(0.55 + speed * 0.17, 0.55, 1.8)       # gait cycles per second
	_bob_phase = fmod(_bob_phase + delta * TAU * cadence, TAU * 8.0)
	var want_amp := smoothstep(0.1, 1.2, speed) * lerpf(1.0, 2.3, smoothstep(2.0, 6.0, speed)) * (1.0 if grounded else 0.2)
	_bob_amp = lerpf(_bob_amp, want_amp, 1.0 - exp(-6.0 * delta))
	var amp := _bob_amp * lerpf(1.0, 0.15, ads_e)
	var right := cam.basis.x
	var up := cam.basis.y
	var pos := right * sin(_bob_phase) * 0.011 * amp + up * -absf(cos(_bob_phase)) * 0.013 * amp
	var roll := sin(_bob_phase) * 0.04 * amp
	# Sprinting: hands down and in, gun canted (the simulated free aim points it low).
	var sprinting := s.has(MotorState.F_SPRINTING) and speed > character.profile.jog_speed * 0.9
	_sprint_w = move_toward(_sprint_w, 1.0 if sprinting and ads_e < 0.1 else 0.0, delta * 5.0)
	var sw := smoothstep(0.0, 1.0, _sprint_w)
	pos += up * -0.05 * sw + right * -0.03 * sw * _side
	# Roll about the barrel's own axis: cants the gun without changing where it points.
	var axis := (gun.basis * Vector3.FORWARD).normalized()
	var g := gun
	g.basis = (Basis(axis, roll + 0.45 * sw * _side) * g.basis).orthonormalized()
	g.origin = gun.origin + pos
	return g


## The held item's grip in its hand's bone space (mirrored for the left hand).
func grip() -> Transform3D:
	return held_def.grip_offset if _side == 1 else UltraAnimMirror.mirror_xform(held_def.grip_offset)


## Left hand on the support grip; right hand aims down sights (first person, local viewer).
func _drive_hands(delta: float) -> void:
	var anim := character.anim
	if anim == null or anim.hand_ik == null:
		return
	var s := character.state
	var ready := held_node != null and UltraActionLayer.is_up(s.action)
	var aiming := ready and character.last_input.has(InputFrame.B_SECONDARY) and held_def and held_def.kind == ItemDefinition.Kind.FIREARM
	ads = move_toward(ads, 1.0 if aiming else 0.0, delta * 6.0)
	_recoil.target = Vector3.ZERO
	_recoil.step(delta)
	var gun := held_node.global_transform if held_node else Transform3D()
	# (Fingers wrap a part of the held item only while a hand is on it - set below.)
	anim.hand_ik.set_wrap(HandIKModifier.Hand.LEFT, null)
	anim.hand_ik.set_wrap(HandIKModifier.Hand.RIGHT, null)
	# First person: the gun pose comes from the camera (the real arms follow by IK), so it
	# always points at the crosshair. Hip pose low-right, ADS puts the sights on the view ray.
	# Loading a tube a shell at a time, first person: the gun comes up in front of you, rolled
	# so the loading port faces you.
	var shell_fp := has_view() and held_node != null and held_def != null and held_def.kind == ItemDefinition.Kind.FIREARM 		and String(held_def.stat("reload_mode", "")) == "shell" and s.action == UltraActionLayer.Action.RELOADING
	_shell_fp_w = move_toward(_shell_fp_w, 1.0 if shell_fp else 0.0, delta * 4.0)
	# Drawing, the gun rises from the hand onto the camera pose with the draw (it used to
	# ride the clip's low hand and only slide to the camera once ready).
	var rise := smoothstep(0.15, 1.0, UltraActionLayer.raised(s))
	if mag_reload():
		rise = 1.0                            # (the gun stays where it's held: the left hand reloads)
	var fp_drive := has_view() and held_node != null and rise > 0.0 and held_def.kind == ItemDefinition.Kind.FIREARM 		and anim.sprint_carry < 0.5          # (sprinting with a rifle the body carries it, as others see it)
	fp_drive = fp_drive or shell_fp
	anim.fp_gun = fp_drive
	var fp_target := (1.0 if shell_fp else rise) if fp_drive else 0.0
	# (Let go of a little slower than it's taken up - holstering jolted the head - but quickly
	# into a sprint carry, where the body takes the gun.)
	var fp_rate := 5.0 if fp_target > _fp_w or anim.sprint_carry > 0.05 else 3.0
	_fp_w = move_toward(_fp_w, fp_target, delta * fp_rate)
	if held_node and _fp_w > 0.001:
		var rear := UltraPoseSampler.marker(held_node, "M_RearSight")
		var cam := view_xf()
		var fwd := -cam.basis.z
		var right := cam.basis.x
		var cup := cam.basis.y
		var aim_basis := Basis.looking_at(fwd, cup)
		# Hip: low and to the right, toed in a touch so it converges on the crosshair ~20 m out.
		var ho := held_def.fp_hip_offset
		var hip_pos := cam.origin + fwd * ho.z + right * ho.x * _side + cup * ho.y
		var hip_basis := Basis.looking_at((cam.origin + fwd * 20.0) - hip_pos, cup)
		var hip_gun := Transform3D(hip_basis, hip_pos - hip_basis * rear.origin)
		var ads_gun := Transform3D(aim_basis, cam.origin + fwd * held_def.fp_ads_distance - aim_basis * rear.origin)
		var e := smoothstep(0.0, 1.0, ads)
		var target_gun := hip_gun.interpolate_with(ads_gun, e)
		if _shell_fp_w > 0.0:
			var tilt := Basis(right, deg_to_rad(14.0)) * aim_basis
			var lb := Basis((tilt * Vector3.FORWARD).normalized(), deg_to_rad(SHELL_ROLL) * _side) * tilt
			var load_gun := Transform3D(lb, cam.origin + fwd * 0.40 + right * 0.05 * _side - cup * 0.16)
			target_gun = target_gun.interpolate_with(load_gun, smoothstep(0.0, 1.0, _shell_fp_w))
		target_gun = _gun_motion(target_gun, cam, delta, e)
		target_gun.origin += target_gun.basis * (_recoil.value as Vector3) * lerpf(1.0, 0.5, e)
		# Racking the pump jolts the gun back and down a touch.
		target_gun.origin += target_gun.basis * Vector3(0.0, -0.012, 0.022) * pump_amount()
		# A gun-butt strike (the arms make it: the shouldered body keeps a quarter of it).
		var strike_off := melee_offset()
		target_gun = target_gun * strike_off
		# Reloading: rolled a little toward the off hand, nose up a touch, brought in a bit.
		var rw := _mag_w
		if rw > 0.0:
			var roll := Basis(Vector3.BACK, deg_to_rad(-22.0) * rw * float(_side)) * Basis(Vector3.RIGHT, deg_to_rad(8.0) * rw)
			target_gun = target_gun * Transform3D(roll, Vector3(0.0, -0.03 * rw, 0.06 * rw))
		# Free aim: turn the gun onto the simulated gun direction - about the rear sight at the
		# hip, about the eye when aiming (so the sights stay in line with the eye and the dot).
		var rot := sway_rotation()
		var pivot := (target_gun * rear.origin).lerp(cam.origin, e)
		target_gun = Transform3D(rot, pivot - rot * pivot) * target_gun
		var hand_target := target_gun * grip().affine_inverse()
		var w := smoothstep(0.0, 1.0, _fp_w)
		var gun_hand := HandIKModifier.Hand.RIGHT if _side == 1 else HandIKModifier.Hand.LEFT
		var other := HandIKModifier.Hand.LEFT if _side == 1 else HandIKModifier.Hand.RIGHT
		anim.hand_ik.set_goal(gun_hand, hand_target, w, true, 40.0)
		_owns[gun_hand] = true
		if _side == -1 and _owns[other]:
			anim.hand_ik.release(other, 8.0)
			_owns[other] = false
		gun = gun.interpolate_with(target_gun, w)
		var body_gun := target_gun * Transform3D.IDENTITY.interpolate_with(strike_off, 0.75).affine_inverse()
		_shoulder_gun(body_gun, w * (1.0 - smoothstep(0.0, 1.0, _shell_fp_w)))      # (not shouldered while loading)
	else:
		_shoulder_gun(Transform3D(), 0.0)
		for h in [HandIKModifier.Hand.RIGHT, HandIKModifier.Hand.LEFT]:
			if _owns[h] and (h == HandIKModifier.Hand.RIGHT) == (_side == 1):
				anim.hand_ik.release(h, 8.0)
				_owns[h] = false
	# Support hand follows the gun wherever it goes (two working hands only).
	if ready and _side == 1 and UltraInjury.two_hands(s) and held_def and held_def.two_handed and held_def.support_offset != Transform3D.IDENTITY:
		var sup := _support_under(gun) if held_def.support_fingers != Vector3.ZERO else gun * held_def.support_offset
		# A long gun held low can put the handguard grip out of the arm's reach: the hand
		# slides back along the handguard (up to 15 cm) instead of floating off it.
		sup = _within_reach(sup, (gun.basis * Vector3.BACK).normalized(), 0.15)
		anim.hand_ik.set_goal(HandIKModifier.Hand.LEFT, sup, 1.0, true, 10.0)
		# On the gun as the gun hand ends up this frame (`gun` is last frame's in third person).
		anim.hand_ik.follow_hand(HandIKModifier.Hand.LEFT, HandIKModifier.Hand.RIGHT, gun * grip().affine_inverse())
		if held_def.support_fingers != Vector3.ZERO:
			anim.hand_ik.set_curl(HandIKModifier.Hand.LEFT, 1.0)
			_wrap_on(HandIKModifier.Hand.LEFT, gun * UltraPoseSampler.marker(held_node, "M_SupportGrip").origin)
		_owns[HandIKModifier.Hand.LEFT] = true
	elif _side == 1 and _owns[HandIKModifier.Hand.LEFT] and not mag_reload():
		anim.hand_ik.release(HandIKModifier.Hand.LEFT, 8.0)
		_owns[HandIKModifier.Hand.LEFT] = false
	_drive_mag_reload(gun, delta)
	_drive_reload(delta)
	_drive_shells()
	_drive_free_hand(delta)


## A gun with a stock is held shouldered (WeaponPoseModifier). First person: the body comes to
## the camera-placed gun (`fp_target`, weight `fp_w`). Third person: the gun goes to the body -
## stock in the shoulder pocket, along the free-aim direction - and the hands go onto it.
func _shoulder_gun(fp_target: Transform3D, fp_w: float) -> void:
	var anim := character.anim
	var wp := anim.weapon_pose if anim else null
	if wp == null:
		return
	var s := character.state
	var stock := UltraPoseSampler.marker(held_node, "M_Stock") if held_node and held_def else Transform3D.IDENTITY
	if stock == Transform3D.IDENTITY or not held_def.two_handed:
		wp.weight = 0.0
		return
	var sk := character.skeleton
	var to_sk := sk.global_basis.orthonormalized().inverse() * character.visual_root.global_basis.orthonormalized()
	wp.stock = stock.origin
	wp.side = _side
	wp.eye_offset_sk = to_sk * character.body_profile.eye_offset / maxf(sk.global_basis.get_scale().x, 0.001)
	if camera != null or _fp_w > 0.001:
		wp.from_body = false
		wp.weight = fp_w
		wp.gun = fp_target
		wp.eye_target = camera.global_position if camera else Vector3.INF
		return
	# Third person: weapon up, two working hands, not reloading / sprinting (the clips do those).
	var rise := UltraActionLayer.raised(s)
	# (Prone the clips hold the gun to the shoulder lying down.)
	var up := rise > 0.0 and _side == 1 and UltraInjury.two_hands(s) and s.state != MotorState.Id.CRAWL
	wp.from_body = true
	# Eased: reloading / holstering / lowering used to drop the shouldered pose (hands, stance,
	# cheek) in a frame.
	var dt := get_process_delta_time()
	# (A reload lets go quickly - the clip's hands have to get to the magazine.)
	# (So does a strike played from a clip.)
	var reloading := s.action == UltraActionLayer.Action.RELOADING or anim.swing_w > 0.0
	_tp_w = move_toward(_tp_w, anim.modifier.weapon_aim * smoothstep(0.2, 1.0, rise) if up and anim.modifier else 0.0, dt * (6.0 if reloading else 3.5))
	_tp_ads = move_toward(_tp_ads, ads, dt * 2.5)
	wp.weight = smoothstep(0.0, 1.0, _tp_w)
	wp.extra = melee_offset() if anim.swing_w <= 0.0 else Transform3D.IDENTITY
	wp.eye_target = Vector3.INF
	wp.gun_dir = gun_ray().dir
	wp.ads = smoothstep(0.0, 1.0, _tp_ads)
	# Aiming: the eye a hand's width behind the rear sight, a little above the sight line.
	wp.eye_in_gun = UltraPoseSampler.marker(held_node, "M_RearSight").origin + Vector3(0.0, 0.03, 0.11)
	wp.grip_inv = grip().affine_inverse()
	var g := held_node.global_transform.orthonormalized()
	wp.support = g.affine_inverse() * (_support_under(g) if held_def.support_fingers != Vector3.ZERO else g * held_def.support_offset)
	wp.hand_ik = anim.hand_ik


## The support hand under the fore-end: palm up against it, fingers wrapping round the far
## side - it stays below the sights (on top, the hand came up into the sight picture).
func _support_under(gun: Transform3D) -> Transform3D:
	var gb := gun.basis.orthonormalized()
	var f := (gb * held_def.support_fingers).normalized()
	var p := (gb * held_def.support_palm).normalized()
	var b := character.anim.hand_ik.hand_basis(HandIKModifier.Hand.LEFT, f, p)
	if b == Basis():
		return gun * held_def.support_offset
	var contact := gun * UltraPoseSampler.marker(held_node, "M_SupportGrip").origin
	# The hand bone sits at the wrist: back along the hand, down off the palm.
	return Transform3D(b, contact - f * 0.065 - (p - f * p.dot(f)).normalized() * 0.03)


## Curl `hand`'s fingers round the held item's part at `at` (world): the thickest mesh whose
## box (grown 1.2 cm) holds the point - not a groove ring or a rail on it.
func _wrap_on(hand: int, at: Vector3) -> void:
	var key := "%d:%d" % [held_node.get_instance_id(), hand]
	if not _wrap_parts.has(key):
		var best: MeshInstance3D = null
		var best_v := INF
		for m in held_node.find_children("*", "MeshInstance3D", true, false):
			var mi := m as MeshInstance3D
			if mi.mesh == null or mi.name.begins_with("M_"):
				continue
			var a := mi.get_aabb()
			var q := mi.global_transform.affine_inverse() * at
			var thick := minf(minf(a.size.x, a.size.y), a.size.z)
			if a.grow(0.012).has_point(q) and -thick < best_v:
				best = mi
				best_v = -thick
		_wrap_parts[key] = best
	var part := _wrap_parts[key] as MeshInstance3D
	if part == null or not is_instance_valid(part):
		return
	var box := part.get_aabb()
	character.anim.hand_ik.set_wrap(hand, part, Transform3D(Basis(), box.get_center()), box.size * 0.5)


var _wrap_parts := {}
var _left_reach := 0.0
var _tp_w := 0.0
var _tp_ads := 0.0


## Slide a left-hand target along `dir` (at most `max_slide` m) until the left arm can reach it.
## The slide is solved exactly and eased: stepping it 2.5 cm at a time made the hand flick
## back and forth along the handguard as the walk bobbed the shoulder across a step.
func _within_reach(t: Transform3D, dir: Vector3, max_slide: float) -> Transform3D:
	var sk := character.skeleton
	var ua := sk.find_bone("LeftUpperArm")
	var la := sk.find_bone("LeftLowerArm")
	var hb := sk.find_bone("LeftHand")
	if ua < 0 or la < 0 or hb < 0:
		return t
	if _left_reach <= 0.0:
		_left_reach = sk.get_bone_rest(la).origin.length() + sk.get_bone_rest(hb).origin.length()
		_left_reach *= sk.global_basis.get_scale().x
	# (The shoulder as animated, before IK: HandIK rolls the clavicle forward a little more
	# when the arm comes up short, worth a few cm.)
	var pre: Vector3 = character.anim.hand_ik.pre_shoulder[HandIKModifier.Hand.LEFT]
	var shoulder := sk.global_transform * (pre if pre != Vector3.INF else sk.get_bone_global_pose(ua).origin)
	var r := _left_reach + 0.03
	var o := t.origin - shoulder
	var want := 0.0
	if o.length() > r:
		# Smallest x >= 0 with |o + dir x| = r (or the closest approach if it never gets there).
		var od := o.dot(dir)
		var disc := od * od - o.length_squared() + r * r
		want = -od - sqrt(disc) if disc >= 0.0 else -od
		want = clampf(want, 0.0, max_slide)
	var dt := get_process_delta_time()
	# (A critically damped spring: the shoulder is read before the inertial blend smooths a
	# change of clip, so `want` can jump ~10 cm in a frame - a plain ease flicked the hand 2 cm.)
	if _left_slide < 0.0:
		_left_slide = want
		_left_slide_v = 0.0
	else:
		var om := 14.0
		var h := minf(dt, 0.05)
		var acc := om * om * (want - _left_slide) - 2.0 * om * _left_slide_v
		_left_slide_v += acc * h
		_left_slide = clampf(_left_slide + _left_slide_v * h, 0.0, max_slide)
	var out := t
	out.origin += dir * _left_slide
	return out


var _left_slide := -1.0
var _left_slide_v := 0.0


## Reload. Third person: the clip as authored (with the fitted grip it reads right: gun up by
## the chin, tilted to the off hand, which meets the grip). First person that happens inside
## the camera, so move the clip's hand motion - both hands together, untouched otherwise - out
## in front of and below the eye, where you can watch it.
func _drive_reload(delta: float) -> void:
	var anim := character.anim
	var s := character.state
	var reloading := held_node != null and held_def != null and held_def.kind == ItemDefinition.Kind.FIREARM 		and s.action == UltraActionLayer.Action.RELOADING and has_view() and not mag_reload() 		and String(held_def.stat("reload_mode", "")) != "shell"      # (a tube is loaded by _drive_shells)
	var was := _reload_w > 0.001
	_reload_w = move_toward(_reload_w, 1.0 if reloading else 0.0, delta * 3.5)
	if _reload_w <= 0.001:
		if anim.arm_out:
			anim.arm_out.hand_give = 0.0
		if was:
			for h in [HandIKModifier.Hand.LEFT, HandIKModifier.Hand.RIGHT]:
				if _owns[h] and not (h == HandIKModifier.Hand.LEFT and ready_support()):
					anim.hand_ik.release(h, 8.0)
					_owns[h] = false
		return
	var sk := character.skeleton
	var cam := view_xf()
	var flat := Vector3(-cam.basis.z.x, 0, -cam.basis.z.z)
	flat = flat.normalized() if flat.length() > 0.1 else -character.visual_root.global_basis.z
	var left := Vector3.UP.cross(flat).normalized()
	var shift := flat * 0.24 - left * 0.18 * _side       # (forward and a little to the gun side: the right arm crossing to the off side went through the chest)
	var w := smoothstep(0.0, 1.0, _reload_w)
	if anim.arm_out:
		anim.arm_out.hand_give = w             # (the reloading hands may give way to the chest)
	# Bone poses read in _process are the clip's (before IK), so this follows the animation.
	for h in [HandIKModifier.Hand.LEFT, HandIKModifier.Hand.RIGHT]:
		var b := anim.hand_ik.hand_bone(h)
		if b < 0:
			continue
		var xf := sk.global_transform * sk.get_bone_global_pose(b)
		xf.origin += shift
		anim.hand_ik.set_goal(h, xf, w, true, 20.0)
		_owns[h] = true


## Every view holds the gun the same way: first person from the camera, third person (and other
## players) from a virtual eye at the simulated eye height looking along the aim. (Third person
## used the item clips plus a shouldered pass: it looked worse than first person, and the rifle
## reload's arms went through the body; the gun-butt is the first-person strike too.)
func has_view() -> bool:
	return character != null and character.visual_root != null and character.anim != null


## The first-person eye from this character's camera rig (set every frame, any view).
var fp_view := Transform3D()
var fp_view_frame := -1


func view_xf() -> Transform3D:
	if camera:
		return camera.global_transform
	if fp_view_frame >= Engine.get_process_frames() - 1:
		return fp_view
	var yaw := character.anim.aim_yaw
	var pitch := clampf(character.anim.aim_pitch, -1.45, 1.45)
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var eye := character.visual_root.global_position + Vector3.UP * (character.state.height - 0.14) + fwd * 0.08
	# Lying down the head is ~0.8 m ahead of the capsule: the eye is the head's (its clip pose -
	# read here, before the modifiers, so the gun pose can't feed back into it).
	if character.state.state == MotorState.Id.CRAWL and character.skeleton:
		var hb := character.skeleton.find_bone("Head")
		if hb >= 0:
			eye = (character.skeleton.global_transform * character.skeleton.get_bone_global_pose(hb)).origin + Vector3.UP * 0.06
	return Transform3D(Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch), eye)


## The hand that isn't holding anything. A one-handed melee weapon: up in a loose guard in front
## of the chest, swinging against the strike for balance (it flailed with the clip's sword arm).
## A club held in both hands (stat "two_hand_grip": metres below the gun hand): on the handle.
## Prone with a one-handed gun: braced on the ground under the chin. Never for a lost / crippled
## arm (UltraInjury.two_hands).
func _drive_free_hand(delta: float) -> void:
	var anim := character.anim
	var s := character.state
	var free := HandIKModifier.Hand.LEFT if _side == 1 else HandIKModifier.Hand.RIGHT
	var want := 0
	var target := Transform3D()
	var rotate := false
	var ok := held_node != null and held_def != null and UltraInjury.two_hands(s) and has_view() \
		and s.state not in UltraActionLayer.TWO_HANDED and UltraActionLayer.raised(s) > 0.0
	var vr := character.visual_root.global_transform if character.visual_root else Transform3D()
	var fwd := -vr.basis.z
	var side := vr.basis.x * float(-_side)          # (toward the free hand's side)
	if ok and held_def.kind == ItemDefinition.Kind.MELEE and s.state != MotorState.Id.CRAWL:
		var grip2 := float(held_def.stat("two_hand_grip", 0.0))
		if grip2 > 0.0:
			# Both hands on the club: the free hand just below the gun hand on the handle,
			# wrapped round it from the other side, fingers closed - and locked to the gun
			# hand's final pose (a spring on its own trailed a fast swing off the handle).
			var tip := UltraPoseSampler.marker(held_node, "M_Tip")
			var g := held_node.global_transform
			var axis := (g * tip.origin - g.origin).normalized() if tip != Transform3D.IDENTITY else g.basis.y.normalized()
			var hand_r := g * grip().affine_inverse()          # the gun hand, as the club implies
			var fr := hand_r.basis.y.normalized()               # its fingers
			var pr := (hand_r.basis.orthonormalized() * _palm_dir(HandIKModifier.Hand.RIGHT if _side == 1 else HandIKModifier.Hand.LEFT)).normalized()
			var fl := (fr - axis * fr.dot(axis)).normalized()
			var b := anim.hand_ik.hand_basis(free, fl, -pr)
			var on := g.origin - axis * grip2
			target = Transform3D(b if b != Basis() else hand_r.basis, on - fl * 0.065 + pr * 0.03)
			rotate = b != Basis()
			want = 2
		else:
			# Guard, swung against the weapon hand's travel (chest space).
			var chest := character.skeleton.global_transform * character.skeleton.get_bone_global_pose(_chest_bone())
			var hand_now := g_hand_pos()
			var lat := (hand_now - _prev_weapon_hand).dot(side) / maxf(delta, 0.001) if _prev_weapon_hand != Vector3.INF else 0.0
			_prev_weapon_hand = hand_now
			_counter = lerpf(_counter, clampf(-lat * 0.06, -0.18, 0.18), 1.0 - exp(-8.0 * delta))
			target = Transform3D(Basis(), chest.origin + fwd * 0.26 + side * (0.1 + _counter) + Vector3.DOWN * 0.08 - fwd * absf(_counter) * 0.5)
			want = 1
	elif ok and s.state == MotorState.Id.CRAWL and not held_def.two_handed and held_def.kind == ItemDefinition.Kind.FIREARM:
		var chest2 := character.skeleton.global_transform * character.skeleton.get_bone_global_pose(_chest_bone())
		target = Transform3D(Basis(), chest2.origin + fwd * 0.3 + side * 0.12 + Vector3.DOWN * 0.22)
		want = 1
	var guard_w := 1.0 if want > 0 else 0.0
	if held_def and held_def.kind == ItemDefinition.Kind.MELEE and float(held_def.stat("two_hand_grip", 0.0)) <= 0.0:
		guard_w *= lerpf(0.55, 1.0, anim.swing_w)       # (a looser guard between strikes)
	_free_w = move_toward(_free_w, guard_w, delta * 4.0)
	if want == 2:
		_free_w = 1.0                      # (on the handle at once: no easing on and off it)
	if _free_w > 0.001 and want > 0:
		anim.hand_ik.set_goal(free, target, smoothstep(0.0, 1.0, _free_w), rotate, 40.0 if want == 2 else 12.0)
		if want == 2:
			var gun_hand := HandIKModifier.Hand.RIGHT if _side == 1 else HandIKModifier.Hand.LEFT
			anim.hand_ik.follow_hand(free, gun_hand, held_node.global_transform * grip().affine_inverse())
			anim.hand_ik.set_curl(free, 1.0)
			_wrap_on(free, target.origin + target.basis.y.normalized() * 0.065)
		_owns[free] = true
		_free_owned = true
	elif _free_owned:
		anim.hand_ik.release(free, 6.0)
		_owns[free] = false
		_free_owned = false
		_prev_weapon_hand = Vector3.INF


var _free_w := 0.0
var _free_owned := false


## The palm's direction in the hand bone's frame (HandIK learns it from the curled fingers).
func _palm_dir(h: int) -> Vector3:
	var hik := character.anim.hand_ik
	var v: Vector3 = hik._palm_local[h] if hik._palm_local[h] != Vector3.ZERO else Vector3.ZERO
	if v == Vector3.ZERO:
		hik.hand_basis(h, Vector3.FORWARD, Vector3.DOWN)     # (learns it)
		v = hik._palm_local[h]
	return v if v != Vector3.ZERO else Vector3.BACK
var _counter := 0.0
var _prev_weapon_hand := Vector3.INF
var _chest_b := -1


func _chest_bone() -> int:
	if _chest_b < 0:
		_chest_b = character.skeleton.find_bone("UpperChest")
	return _chest_b


## Where the weapon hand is (world).
func g_hand_pos() -> Vector3:
	var sk := character.skeleton
	var b := sk.find_bone("RightHand" if _side == 1 else "LeftHand")
	return (sk.global_transform * sk.get_bone_global_pose(b)).origin if b >= 0 else Vector3.ZERO


## A magazine reload done by hand: the gun stays up, the left hand swaps the magazine.
func mag_reload() -> bool:
	var s := character.state
	return s.action == UltraActionLayer.Action.RELOADING and held_node != null and held_def != null \
		and held_def.kind == ItemDefinition.Kind.FIREARM and String(held_def.stat("reload_mode", "")) != "shell" \
		and has_view() and _side == 1 and UltraInjury.two_hands(s) and s.state != MotorState.Id.CRAWL \
		and held_node.find_child("Magazine", true, false) != null


var _mag_w := 0.0
var _mag_hand := Transform3D()


## The magazine swap, keyed off the sim's reload clock (action_t, reload_commit / reload_time):
## to the magazine, pull it out and down to a pouch at the belt, a fresh one up, seated in the
## well, back to the handguard. The magazine rides in the hand meanwhile.
func _drive_mag_reload(gun: Transform3D, delta: float) -> void:
	var on := mag_reload()
	_mag_w = move_toward(_mag_w, 1.0 if on else 0.0, delta * 4.0)
	if character.anim.arm_out and (on or _mag_w > 0.0):
		character.anim.arm_out.hand_give = smoothstep(0.0, 1.0, _mag_w)
	if not on:
		_mag_hand = Transform3D()
		return
	var anim := character.anim
	var s := character.state
	var commit := float(held_def.stat("reload_commit", 1.5))
	var t := s.action_t
	var mag := held_node.find_child("Magazine", true, false) as Node3D
	var mag_rest: Transform3D = mag.get_meta("rest") if mag.has_meta("rest") else mag.transform
	var g := gun.orthonormalized()
	# Where the magazine sits in the gun (its rest pose, taken into the gun's own frame).
	var par := mag.get_parent() as Node3D
	var mag_in_gun := held_node.global_transform.affine_inverse() * par.global_transform * mag_rest if par != held_node else mag_rest
	var in_well := gun * mag_in_gun
	var vr := character.visual_root.global_transform
	var fwd := -vr.basis.z
	var left := -vr.basis.x * float(_side)
	var chest := character.skeleton.global_transform * character.skeleton.get_bone_global_pose(_chest_bone())
	# (Out in front of the hip, clear of the waist: at the belt itself the hand went through it.)
	var pouch := Transform3D(g.basis, chest.origin + fwd * 0.26 + left * 0.2 + Vector3.DOWN * 0.34)
	var below := Transform3D(g.basis, in_well.origin + g.basis.y * -0.18 + left * 0.05)
	# Key poses of the magazine (world) over the reload; the hand holds it from below.
	var keys := [[0.0, in_well], [0.3, in_well], [0.5, below], [0.75, pouch], [commit - 0.55, pouch],
		[commit - 0.3, below], [commit - 0.12, in_well]]
	var mag_at := in_well
	var holding := t > 0.25 and t < commit - 0.1
	for k in range(keys.size() - 1):
		var a: Array = keys[k]
		var b: Array = keys[k + 1]
		if t >= float(a[0]) and t <= float(b[0]):
			var u := smoothstep(float(a[0]), float(b[0]), t)
			mag_at = (a[1] as Transform3D).interpolate_with(b[1], u)
	_mag_hand = mag_at if holding else Transform3D()
	# The hand: under the magazine, palm up (back on the handguard outside the swap).
	var palm_up := anim.hand_ik.hand_basis(HandIKModifier.Hand.LEFT, (g.basis * Vector3.FORWARD).normalized(), Vector3.UP)
	var grip_mag := Transform3D(palm_up if palm_up != Basis() else g.basis, mag_at.origin + Vector3.DOWN * 0.07 - (g.basis * Vector3.FORWARD) * 0.05)
	var sup := _support_under(gun) if held_def.support_fingers != Vector3.ZERO else gun * held_def.support_offset
	var reach := smoothstep(0.0, 0.25, t) * (1.0 - smoothstep(commit - 0.1, commit + 0.15, t))
	var goal := sup.interpolate_with(grip_mag, reach)
	anim.hand_ik.set_goal(HandIKModifier.Hand.LEFT, goal, smoothstep(0.0, 1.0, _mag_w), true, 18.0)
	anim.hand_ik.set_curl(HandIKModifier.Hand.LEFT, 0.7)
	_owns[HandIKModifier.Hand.LEFT] = true


func ready_support() -> bool:
	var s := character.state
	return UltraActionLayer.is_up(s.action) and _side == 1 and UltraInjury.two_hands(s) and held_def != null and held_def.two_handed


func _on_item_event(kind: StringName, _data: Dictionary) -> void:
	if kind == &"melee":
		_melee_t = 0.0
		_melee_sw = UltraActionLayer.melee_swing(held_def, int(_data.get("combo", 0)))
	elif kind == &"melee_cancel":
		_melee_t = -1.0
	if kind == &"fire":
		_slide_kick = 0.045
		var def := character.held_def()
		_recoil.impulse(Vector3(0, 0.5, 1.8) * (float(def.stat("kick", 1.0)) if def else 1.0))
		if pumps():
			_pump_t = 0.0
			_pump_ejected = false
		_heat = minf(_heat + (float(def.stat("smoke", 0.6)) if def else 0.6) * 0.6, 2.0)


# ---------------------------------------------------------------- barrel smoke

var _heat := 0.0                      ## shots' worth of heat in the barrel (decays)
var _wisps: GPUParticles3D


## A hot barrel smokes: thin wisps curl up off the muzzle for a while after firing, more after
## a burst or a shotgun blast.
func _drive_barrel_smoke(delta: float) -> void:
	_heat = maxf(_heat - delta * 0.3, 0.0)
	if _wisps == null or not is_instance_valid(_wisps) or _wisps.get_parent() != held_node:
		var fx := UltraEffects.instance()
		if fx == null:
			return
		_wisps = fx.smoke_particles(24, 2.0, 0.2, 0.06, 2.5)
		var pm := _wisps.process_material as ParticleProcessMaterial
		pm.direction = Vector3.UP
		pm.spread = 12.0
		pm.initial_velocity_min = 0.05
		pm.initial_velocity_max = 0.2
		pm.gravity = Vector3(0, 0.25, 0)
		pm.damping_min = 0.3
		pm.damping_max = 0.6
		_wisps.emitting = false
		held_node.add_child(_wisps)
		_wisps.transform = Transform3D(Basis(), UltraPoseSampler.marker(held_node, "M_Muzzle").origin)      # (gun frame, not the marker's)
	_wisps.emitting = _heat > 0.2
	_wisps.speed_scale = 0.8 + minf(_heat, 1.5) * 0.3


# ---------------------------------------------------------------- pump-action

const PUMP_TRAVEL := 0.085             ## m the fore-end racks back
var _pump_t := -1.0                    ## s since the shot (-1: not racking)
var _pump_ejected := false
var _shell_mesh: MeshInstance3D


## A pump-action: the fore-end is racked after every shot.
func pumps() -> bool:
	return held_def != null and float(held_def.stat("pump_time", 0.0)) > 0.0


## 0..1: how far back the pump is right now (snapped back, a beat, driven home).
func pump_amount() -> float:
	if _pump_t < 0.0 or not pumps():
		return 0.0
	var u := (_pump_t - float(held_def.stat("pump_delay", 0.2))) / float(held_def.stat("pump_time", 0.4))
	if u <= 0.0 or u >= 1.0:
		return 0.0
	if u < 0.35:
		return 1.0 - pow(1.0 - u / 0.35, 3.0)             # fast and hard to the back
	if u < 0.5:
		return 1.0
	return 1.0 - smoothstep(0.0, 1.0, (u - 0.5) / 0.5)


func _drive_pump(delta: float) -> void:
	if not pumps():
		_pump_t = -1.0
		return
	if _pump_t >= 0.0:
		_pump_t += delta
		var u := (_pump_t - float(held_def.stat("pump_delay", 0.2))) / float(held_def.stat("pump_time", 0.4))
		# The spent shell flies out as the pump hits the back; the rack thumps the gun.
		if not _pump_ejected and u >= 0.3:
			_pump_ejected = true
			var fx := UltraEffects.instance()
			if fx:
				fx.shell(eject_transform(), eject_side(), String(held_def.stat("shell", "9mm")))
			_recoil.impulse(Vector3(0.0, -0.25, 0.6))
		if u >= 1.0:
			_pump_t = -1.0
	var pump := held_node.find_child("Pump", true, false) as Node3D
	if pump:
		if not pump.has_meta("rest"):
			pump.set_meta("rest", pump.position)
		pump.position = (pump.get_meta("rest") as Vector3) + Vector3(0, 0, -PUMP_TRAVEL * pump_amount())


## Loading a tube magazine a shell at a time (on the simulation's clock: UltraActionLayer
## _reload_shells): the support hand goes down to the belt for a shell, up to the loading port
## under the gun, thumbs it in, and back - riding the gun as the gun hand holds it.
const POUCH := Vector3(-0.1, 1.0, -0.17)           ## visual-root space: front of the belt, left
const SHELL_ROLL := 70.0                           ## deg the gun is rolled loading in first person
var _shell_fp_w := 0.0


func _drive_shells() -> void:
	var s := character.state
	var anim := character.anim
	var on := held_node != null and held_def != null and String(held_def.stat("reload_mode", "")) == "shell" \
		and s.action == UltraActionLayer.Action.RELOADING and _side == 1 and UltraInjury.two_hands(s) and anim != null and anim.hand_ik != null
	if _shell_mesh:
		_shell_mesh.visible = false
	if not on:
		return
	var slow := UltraInjury.reload_mult(s, character.damage_profile)
	var start := float(held_def.stat("reload_start", 0.35)) * slow
	var each := float(held_def.stat("shell_time", 0.55)) * slow
	var end_t := float(held_def.stat("reload_end", 0.3)) * slow
	var gun := held_node.global_transform.orthonormalized()
	var sup := _support_under(gun) if held_def.support_fingers != Vector3.ZERO else gun * held_def.support_offset
	var contact := gun * UltraPoseSampler.marker(held_node, "M_SupportGrip").origin
	var port := sup
	port.origin += gun * UltraPoseSampler.marker(held_node, "M_LoadPort").origin - contact
	var pouch := Transform3D(sup.basis, character.visual_root.global_transform * POUCH)
	var fwd := -gun.basis.z.normalized()
	var t := s.action_t - start
	var target := sup
	var carry := false
	if t < 0.0:
		target = sup.interpolate_with(pouch, smoothstep(0.0, 1.0, s.action_t / maxf(start, 0.01)))
	elif s.mag >= int(held_def.stat("mag_size", 0)):
		# Full: from the last shell back onto the pump.
		var since := fposmod(t, each)
		target = port.interpolate_with(sup, smoothstep(0.0, 1.0, since / maxf(end_t, 0.01)))
	else:
		var u := fposmod(t, each) / each
		if u < 0.4:
			target = pouch.interpolate_with(port, smoothstep(0.0, 1.0, u / 0.4))
			carry = true
		elif u < 0.75:
			target = port
			target.origin += fwd * 0.035 * smoothstep(0.4, 0.7, u)     # thumbing it into the tube
			carry = u < 0.68
		else:
			target = port.interpolate_with(pouch, smoothstep(0.0, 1.0, (u - 0.75) / 0.25))
	anim.hand_ik.set_goal(HandIKModifier.Hand.LEFT, target, 1.0, true, 12.0)
	anim.hand_ik.follow_hand(HandIKModifier.Hand.LEFT, HandIKModifier.Hand.RIGHT, gun * grip().affine_inverse())
	anim.hand_ik.set_curl(HandIKModifier.Hand.LEFT, 0.7)
	_owns[HandIKModifier.Hand.LEFT] = true
	if carry:
		if _shell_mesh == null:
			_shell_mesh = MeshInstance3D.new()
			var cm := CylinderMesh.new()
			cm.top_radius = 0.0105
			cm.bottom_radius = 0.0105
			cm.height = 0.068
			cm.radial_segments = 10
			var m := StandardMaterial3D.new()
			m.albedo_color = Color(0.7, 0.1, 0.07)
			m.roughness = 0.5
			cm.material = m
			_shell_mesh.mesh = cm
			left_hand_attach.add_child(_shell_mesh)
			# Across the fingers, held in the curl.
			_shell_mesh.transform = Transform3D(Basis(Vector3.FORWARD, PI * 0.5), Vector3(0.0, 0.085, 0.025))
			_set_layers(_shell_mesh)
		_shell_mesh.visible = true


# ---------------------------------------------------------------- gun-butt

var _melee_t := -1.0                  ## s into the strike being shown (-1: none)
var _melee_sw := {}


func _long_gun() -> bool:
	return held_def != null and held_def.equip_slots & ItemDefinition.EquipSlot.BACK != 0


## -0.3..1: where the strike is - drawn back, driven through the blow, recovering.
func melee_amount() -> float:
	if _melee_t < 0.0 or _melee_sw.is_empty() or held_def == null or held_def.kind != ItemDefinition.Kind.FIREARM:
		return 0.0
	var h: float = _melee_sw.hit_from
	var T: float = _melee_sw.time
	var t := _melee_t
	if t < h * 0.55:
		return -0.3 * smoothstep(0.0, 1.0, t / (h * 0.55))
	if t < h:
		return lerpf(-0.3, 1.0, smoothstep(0.0, 1.0, (t - h * 0.55) / (h * 0.45)))
	return 1.0 - smoothstep(0.0, 1.0, (t - h) / maxf(T - h, 0.01))


## The gun's offset for a gun-butt strike, in its own frame (-Z the barrel): a long gun is
## driven forward stock-first, swung across; a pistol whips down and forward.
func melee_offset() -> Transform3D:
	var k := melee_amount()
	if k == 0.0:
		return Transform3D.IDENTITY
	# Turned during the wind-up so what strikes leads, then driven forward through the blow;
	# both ease back after it. (Gun frame, about the grip: -Z the barrel, +Y up.)
	var h: float = _melee_sw.hit_from
	var T: float = _melee_sw.time
	var t := _melee_t
	var back := 1.0 - smoothstep(h, T, t)
	var turn := smoothstep(0.0, h * 0.75, t) * back
	var thrust := smoothstep(h * 0.45, h, t) * back
	if _long_gun():
		# A horizontal butt stroke: cocked back with the muzzle a little left, then the stock
		# swung forward and across from the shoulder (the muzzle goes out to the right) - the
		# butt and the side of the stock hit. (Tipping the barrel up over the shoulder threw the
		# whole body over after the stock.)
		var wind := smoothstep(0.0, h * 0.6, t) * (1.0 - smoothstep(h * 0.45, h, t))
		var strike := smoothstep(h * 0.45, h, t) * back
		var b := Basis(Vector3.UP, 0.3 * wind - 1.35 * strike) * Basis(Vector3.BACK, -0.25 * strike)
		return Transform3D(b, Vector3(-0.14 * strike, 0.02 * strike, 0.06 * wind - 0.32 * strike))
	# A pistol whip: muzzle tipped up so the base of the grip leads, hammered forward and down.
	return Transform3D(Basis(Vector3.RIGHT, 1.75 * turn), Vector3(0.0, -0.1 * thrust + 0.05 * turn, -0.3 * thrust))


## Held item in first person: same layers as the body so it's never culled.
func _set_layers(n: Node) -> void:
	for c in n.find_children("*", "VisualInstance3D", true, false):
		(c as VisualInstance3D).layers = 1


## The muzzle: at the M_Muzzle marker, -Z along the barrel (the gun's own frame - the marker's
## basis comes from Blender and pointed the muzzle smoke back down the barrel).
func muzzle_transform() -> Transform3D:
	if held_node == null:
		return character.visual_root.global_transform
	var g := held_node.global_transform
	return Transform3D(g.basis.orthonormalized(), g * UltraPoseSampler.marker(held_node, "M_Muzzle").origin)


## World direction out of the ejection port: whichever side of the gun the port marker is on
## (spent cases went out of the far side, through the gun).
func eject_side() -> Vector3:
	if held_node == null:
		return character.visual_root.global_basis.x
	var m := UltraPoseSampler.marker(held_node, "M_EjectPort").origin
	return (held_node.global_basis * Vector3(signf(m.x) if absf(m.x) > 0.001 else 1.0, 0.0, 0.0)).normalized()


func eject_transform() -> Transform3D:
	if held_node == null:
		return muzzle_transform()
	return held_node.global_transform * UltraPoseSampler.marker(held_node, "M_EjectPort")
