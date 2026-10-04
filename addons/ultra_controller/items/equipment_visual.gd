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
var holster_node: Node3D
var held_def: ItemDefinition
var ads := 0.0                        ## 0..1, presentation blend
var camera: Camera3D                  ## set for the local first-person viewer

var _held_uid := -1
var _holster_uid := -1
var _slide_kick := 0.0
var _mag_hidden := false
var _recoil := UltraSpring.new(Vector3.ZERO, 6.0, 0.55)
var _fp_w := 0.0
var _owns := [false, false]          ## hand IK goals we set (never release someone else's)
var _prop: RigidBody3D
var _owns_prop := false


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
	c.item_event.connect(_on_item_event)


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
	# --- holster: first firearm in the inventory that isn't in hand
	var hol := _holster_item()
	var hol_uid := hol.uid if hol else 0
	if hol_uid != _holster_uid:
		_holster_uid = hol_uid
		if holster_node:
			holster_node.queue_free()
			holster_node = null
		if hol and hol.def().equip_scene:
			holster_node = hol.def().equip_scene.instantiate() as Node3D
			hip_attach.add_child(holster_node)
			holster_node.transform = hol.def().holster_offset
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
		var target := UltraGrab.hold_target(character, rb)
		rb.global_position = rb.global_position.lerp(target, 1.0 - exp(-18.0 * delta))
	# Hands on the sides (or on the team-lift grip).
	var xf := rb.global_transform
	var half := 0.18
	for n in rb.get_children():
		if n is CollisionShape3D and (n as CollisionShape3D).shape is BoxShape3D:
			half = ((n as CollisionShape3D).shape as BoxShape3D).size.x * 0.5
	var right := character.visual_root.global_basis.x
	var center := xf.origin
	if s.held_grip >= 0:
		var grips := UltraGrab.grip_points(rb)
		if s.held_grip < grips.size():
			center = grips[s.held_grip].global_position
			half = 0.2
	var hand_rot := character.visual_root.global_basis
	anim.hand_ik.set_goal(HandIKModifier.Hand.LEFT, Transform3D(hand_rot, center - right * (half + 0.03)), 1.0, false, 8.0)
	anim.hand_ik.set_goal(HandIKModifier.Hand.RIGHT, Transform3D(hand_rot, center + right * (half + 0.03)), 1.0, false, 8.0)
	_owns_prop = true


func _holster_item() -> ItemInstance:
	var inv := character.inventory
	if inv == null:
		return null
	for i in Inventory.HOTBAR:
		var it := inv.get_slot(i)
		if it and it.uid != character.state.held_uid and it.def() and it.def().can_equip(ItemDefinition.EquipSlot.HIP):
			return it
	return null


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
		var hip_pos := cam.origin + fwd * 0.42 + right * 0.16 * _side + cup * -0.17
		var hip_basis := Basis.looking_at((cam.origin + fwd * 20.0) - hip_pos, cup)
		var hip_gun := Transform3D(hip_basis, hip_pos - hip_basis * rear.origin)
		var ads_gun := Transform3D(aim_basis, cam.origin + fwd * 0.37 - aim_basis * rear.origin)
		var e := smoothstep(0.0, 1.0, ads)
		var target_gun := hip_gun.interpolate_with(ads_gun, e)
		target_gun.origin += target_gun.basis * (_recoil.value as Vector3) * lerpf(1.0, 0.5, e)
		target_gun.basis = target_gun.basis * Basis(Vector3.RIGHT, (_recoil.value as Vector3).y * 0.25)
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
		anim.hand_ik.set_goal(HandIKModifier.Hand.LEFT, gun * held_def.support_offset, 1.0, true, 10.0)
		_owns[HandIKModifier.Hand.LEFT] = true
	elif _side == 1 and _owns[HandIKModifier.Hand.LEFT]:
		anim.hand_ik.release(HandIKModifier.Hand.LEFT, 8.0)
		_owns[HandIKModifier.Hand.LEFT] = false


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
