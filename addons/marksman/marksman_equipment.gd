class_name MarksmanEquipment
extends UltraEquipmentVisual
## Marksman's equipment visual: UltraEquipmentVisual's attach / holster / slide / pump / smoke / muzzle / eject as
## they are, but the hands are the body's (MarksmanGunPass puts the gun on the aim and the hands on the gun), so
## `_drive_hands` keeps only the ADS follower and the recoil spring: under Sinew there is no hand IK and the base
## returned before them - `ads` stayed 0 (no ADS field of view, sensitivity or recoil scale).


func _drive_hands(delta: float) -> void:
	var s := character.state
	var ready := held_node != null and UltraActionLayer.is_up(s.action)
	var aiming := ready and character.last_input.has(InputFrame.B_SECONDARY) and held_def != null \
			and held_def.kind == ItemDefinition.Kind.FIREARM
	# V6: a long gun held in one hand is braced under the arm - no sights to look down (a pistol still comes up).
	if aiming and held_def.two_handed and not UltraInjury.two_hands(s) and held_node.find_child("M_Stock", true, false) != null:
		aiming = false
	# (As the base: speed and acceleration capped, so an ADS spam never flips the FOV in a frame.)
	_ads_st = UltraFollow.scalar(_ads_st, 1.0 if aiming else 0.0, delta, 7.5, 70.0, 18.0)
	ads = clampf(_ads_st.x, 0.0, 1.0)
	_recoil.target = Vector3.ZERO
	_recoil.step(delta)


## The magazine rides the hand that has it (MarksmanGunPass sets _mag_hand) with either hand, one-handed too (V6: the base
## only places it for a right-handed two-handed reload).
func mag_reload() -> bool:
	var s := character.state
	return s.action == UltraActionLayer.Action.RELOADING and held_node != null and held_def != null \
		and held_def.kind == ItemDefinition.Kind.FIREARM and String(held_def.stat("reload_mode", "")) != "shell" \
		and has_view() and held_node.find_child("Magazine", true, false) != null


## The prop's hands are the gun pass's (_carry_hands); Sinew lends a hand IK only while a prop is held, so the base's
## release on letting go called a null one every frame - nothing of it to release here.
func _drive_held_prop(delta: float) -> void:
	if character.anim == null or character.anim.hand_ik == null:
		_owns_prop = false
		if character.state.held_id == 0:
			_prop = null
			return
	super._drive_held_prop(delta)
