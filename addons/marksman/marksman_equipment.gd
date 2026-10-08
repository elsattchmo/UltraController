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
	# (As the base: speed and acceleration capped, so an ADS spam never flips the FOV in a frame.)
	_ads_st = UltraFollow.scalar(_ads_st, 1.0 if aiming else 0.0, delta, 7.5, 70.0, 18.0)
	ads = clampf(_ads_st.x, 0.0, 1.0)
	_recoil.target = Vector3.ZERO
	_recoil.step(delta)
