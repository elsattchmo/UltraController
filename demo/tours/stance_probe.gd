extends UltraTour
## Probe: how far each held item's stance turns the chest from the aim (idle, standing), and the
## item clip's own hips yaw. Prints STANCE lines; no shots.
##   godot --path . -- --tour=stance_probe

func _build() -> void:
	steps = [
		{"teleport": "speed_start", "t": 0.6, "yaw": 0, "pitch": -4, "view_tp": true, "slot": 0},
		{"call": _give, "t": 0.3},
	]
	for slot in [0, 1, 0, 4, 0, 5]:
		for k in 14:
			steps.append({"t": 0.12, "slot": slot, "call": _measure.bind(slot)})


func _give() -> void:
	for it: Array in [[&"pistol", 1], [&"rifle", 1], [&"bat", 1], [&"machete", 1]]:
		if main.player.inventory.count_of(it[0]) == 0:
			UltraItems.give(main.player, it[0], it[1])


func _measure(slot: int) -> void:
	var c: UltraCharacter = main.player
	var sk := c.skeleton
	var fwd := -c.visual_root.global_basis.z
	var out := []
	for b in ["Hips", "Chest", "UpperChest", "Head"]:
		var g := sk.global_transform * sk.get_bone_global_pose(sk.find_bone(b))
		# The bone's facing: its +Z (model faces +Z; the body node is turned 180) flattened.
		var f := g.basis.z
		f.y = 0.0
		var ang := rad_to_deg(fwd.signed_angle_to(-f.normalized(), Vector3.UP))
		out.append("%s %.0f" % [b, ang])
	var held: Variant = c.get_node("Equipment").get("held_def")
	print("STANCE slot %d %s  item_hips_yaw %.0f  %s" % [slot, (held as ItemDefinition).id if held else "-",
		rad_to_deg(c.anim.modifier.item_hips_yaw) if not is_nan(c.anim.modifier.item_hips_yaw) else 0.0, " ".join(out)])
