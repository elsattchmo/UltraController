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
var _sway_prev := Vector2.ZERO
var _sway_cur := Vector2.ZERO
var _sway_tick := -1
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
		_held_uid = s.held_uid
		_side = side
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
		var mag := held_node.find_child("Magazine", true, false) as Node3D
		if mag:
			var hide := s.action == UltraActionLayer.Action.RELOADING and s.action_t > 0.35 and s.action_t < float(held_def.stat("reload_commit", 1.5)) - 0.2
			mag.visible = not hide
	_drive_hands(delta)
	_drive_held_prop(delta)
	_aim_body()


## Free-aim offset now (radians, x = yaw, y = pitch): the simulated MotorState.sway,
## interpolated between the last two ticks.
func sway_now() -> Vector2:
	if character == null:
		return Vector2.ZERO
	if character.tick != _sway_tick:
		_sway_prev = _sway_cur if _sway_tick >= 0 and character.tick == _sway_tick + 1 else character.state.sway
		_sway_cur = character.state.sway
		_sway_tick = character.tick
	return _sway_prev.lerp(_sway_cur, clampf(Engine.get_physics_interpolation_fraction(), 0.0, 1.0))


## The shot ray as it will go (presentation): from the simulated eye along the gun's direction
## (this frame's aim + the free-aim offset). The HUD's gun dot is where it meets the world.
func gun_ray() -> Dictionary:
	var src := character.input_source
	var yaw := src.live_yaw if src else character.last_input.yaw
	var pitch := src.live_pitch if src else character.last_input.pitch
	var origin := character.visual_feet + Vector3.UP * (character.state.height - 0.16)
	return {"origin": origin, "dir": UltraActionLayer.gun_dir(yaw, pitch, sway_now())}


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
	if anim == null or anim.modifier == null or camera != null:
		return
	# (Breathing - a few hundredths of a degree - isn't worth twisting the spine for at this
	# distance: only what's past a 0.25 deg deadband turns the body.)
	var sw := sway_now()
	sw -= sw.limit_length(deg_to_rad(0.25))
	var w := anim.modifier.weapon_aim
	if w <= 0.0 or held_def == null:
		return
	# The aiming clip's own barrel direction, taken back out (a bladed rifle clip points the
	# gun off to one side of the chest).
	var clip := held_def.aim_clip_offset * Vector2(float(_side), 1.0)
	anim.modifier.aim_yaw += (deg_to_rad(clip.x) - sw.x) * w
	anim.modifier.aim_pitch += (sw.y - deg_to_rad(clip.y)) * w


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
	var ready := held_node != null and s.action == UltraActionLayer.Action.READY
	var aiming := ready and character.last_input.has(InputFrame.B_SECONDARY) and held_def and held_def.kind == ItemDefinition.Kind.FIREARM
	ads = move_toward(ads, 1.0 if aiming else 0.0, delta * 6.0)
	_recoil.target = Vector3.ZERO
	_recoil.step(delta)
	var gun := held_node.global_transform if held_node else Transform3D()
	# First person: the gun pose comes from the camera (the real arms follow by IK), so it
	# always points at the crosshair. Hip pose low-right, ADS puts the sights on the view ray.
	var fp_drive := camera != null and held_node != null and ready and held_def.kind == ItemDefinition.Kind.FIREARM
	_fp_w = move_toward(_fp_w, 1.0 if fp_drive else 0.0, delta * 4.0)
	if camera and held_node and _fp_w > 0.001:
		var rear := UltraPoseSampler.marker(held_node, "M_RearSight")
		var cam := camera.global_transform
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
		target_gun = _gun_motion(target_gun, cam, delta, e)
		target_gun.origin += target_gun.basis * (_recoil.value as Vector3) * lerpf(1.0, 0.5, e)
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
	else:
		for h in [HandIKModifier.Hand.RIGHT, HandIKModifier.Hand.LEFT]:
			if _owns[h] and (h == HandIKModifier.Hand.RIGHT) == (_side == 1):
				anim.hand_ik.release(h, 8.0)
				_owns[h] = false
	# Support hand follows the gun wherever it goes (two working hands only).
	if ready and _side == 1 and UltraInjury.two_hands(s) and held_def and held_def.two_handed and held_def.support_offset != Transform3D.IDENTITY:
		var sup := gun * held_def.support_offset
		# A long gun held low can put the handguard grip out of the arm's reach: the hand
		# slides back along the handguard (up to 15 cm) instead of floating off it.
		sup = _within_reach(sup, (gun.basis * Vector3.BACK).normalized(), 0.15)
		anim.hand_ik.set_goal(HandIKModifier.Hand.LEFT, sup, 1.0, true, 10.0)
		_owns[HandIKModifier.Hand.LEFT] = true
	elif _side == 1 and _owns[HandIKModifier.Hand.LEFT]:
		anim.hand_ik.release(HandIKModifier.Hand.LEFT, 8.0)
		_owns[HandIKModifier.Hand.LEFT] = false
	_drive_reload(delta)


var _left_reach := 0.0


## Slide a left-hand target along `dir` (at most `max_slide` m) until the left arm can reach it.
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
	var shoulder := sk.global_transform * sk.get_bone_global_pose(ua).origin
	var r := _left_reach + 0.03
	var out := t
	var steps := 6
	for k in steps:
		if shoulder.distance_to(out.origin) <= r:
			break
		out.origin += dir * (max_slide / steps)
	return out


## Reload. Third person: the clip as authored (with the fitted grip it reads right: gun up by
## the chin, tilted to the off hand, which meets the grip). First person that happens inside
## the camera, so move the clip's hand motion - both hands together, untouched otherwise - out
## in front of and below the eye, where you can watch it.
func _drive_reload(delta: float) -> void:
	var anim := character.anim
	var s := character.state
	var reloading := held_node != null and held_def != null and held_def.kind == ItemDefinition.Kind.FIREARM 		and s.action == UltraActionLayer.Action.RELOADING and camera != null
	var was := _reload_w > 0.001
	_reload_w = move_toward(_reload_w, 1.0 if reloading else 0.0, delta * 5.0)
	if _reload_w <= 0.001:
		if was:
			for h in [HandIKModifier.Hand.LEFT, HandIKModifier.Hand.RIGHT]:
				if _owns[h] and not (h == HandIKModifier.Hand.LEFT and ready_support()):
					anim.hand_ik.release(h, 8.0)
					_owns[h] = false
		return
	var sk := character.skeleton
	var cam := camera.global_transform
	var flat := Vector3(-cam.basis.z.x, 0, -cam.basis.z.z)
	flat = flat.normalized() if flat.length() > 0.1 else -character.visual_root.global_basis.z
	var left := Vector3.UP.cross(flat).normalized()
	var shift := flat * 0.18 + Vector3.DOWN * 0.08 + left * 0.07 * _side
	var w := smoothstep(0.0, 1.0, _reload_w)
	# Bone poses read in _process are the clip's (before IK), so this follows the animation.
	for h in [HandIKModifier.Hand.LEFT, HandIKModifier.Hand.RIGHT]:
		var b := anim.hand_ik.hand_bone(h)
		if b < 0:
			continue
		var xf := sk.global_transform * sk.get_bone_global_pose(b)
		xf.origin += shift
		anim.hand_ik.set_goal(h, xf, w, true, 20.0)
		_owns[h] = true


func ready_support() -> bool:
	var s := character.state
	return s.action == UltraActionLayer.Action.READY and _side == 1 and UltraInjury.two_hands(s) and held_def != null and held_def.two_handed


func _on_item_event(kind: StringName, _data: Dictionary) -> void:
	if kind == &"fire":
		_slide_kick = 0.045
		_recoil.impulse(Vector3(0, 0.35, 1.2))


## Held item in first person: same layers as the body so it's never culled.
func _set_layers(n: Node) -> void:
	for c in n.find_children("*", "VisualInstance3D", true, false):
		(c as VisualInstance3D).layers = 1


func muzzle_transform() -> Transform3D:
	if held_node == null:
		return character.visual_root.global_transform
	return held_node.global_transform * UltraPoseSampler.marker(held_node, "M_Muzzle")


func eject_transform() -> Transform3D:
	if held_node == null:
		return muzzle_transform()
	return held_node.global_transform * UltraPoseSampler.marker(held_node, "M_EjectPort")
