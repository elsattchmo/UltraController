extends UltraTestSuite
## Marksman: drawing and putting away (MarksmanDraw - the user: "we also need a small animation to equip these items").
## The hand goes to where the item is carried (pistol: the hip holster; long guns, bat, machete: the sling on the back),
## takes it there and brings it up; putting it away is the same backwards. Per item: the hand reaches the item's place,
## the item never jumps (it used to vanish from the holster and appear in the hand), the body shows itself unarmed until
## the hand has it, and it ends in the hand (drawn) / in its place (put away).

## The item may move this far in a frame (m): a quick hand, never a jump between the place and the hand.
const ITEM_STEP_MAX := 0.15
## The hand gets this close to where it takes the item (m).
const REACH_MAX := 0.05


func _marksman(at: Vector3) -> MarksmanCharacter:
	var c := MarksmanCharacter.new()
	c.motion_matching = true
	c.profile = (load("res://addons/ultra_controller/profiles/fps.tres") as MovementProfile).duplicate(true)
	c.body_profile = CharacterModels.body_profile("mannequin")
	c.build_visuals = true
	var b := BotInputSource.new()
	b.name = "InputSource"
	c.add_child(b)
	c.input_source = b
	c.position = at
	add_child(c)
	b.body = c
	chars.append(c)
	return c


func _slot(c: MarksmanCharacter, item: StringName) -> int:
	UltraItems.give(c, item)
	for i in c.inventory.size():
		var it := c.inventory.get_slot(i)
		if it and it.def_id == item:
			return i + 1
	return 0


func test_draw_and_put_away() -> void:
	load_playground()
	var bad := []
	for item: StringName in [&"pistol", &"rifle", &"shotgun", &"bat", &"machete"]:
		var c := _marksman(marker("spawn").global_position + Vector3(-16, 0, -3))
		await ticks(40)
		var sl := _slot(c, item)
		var def := ItemDB.get_def(item)
		var eq := c.get_node("Equipment") as UltraEquipmentVisual
		var gp := (c.ragdoll as MarksmanRagdoll).gun_pass
		var sk := c.skeleton
		var hand := sk.find_bone("RightHand")
		var place_b := sk.find_bone(String(def.holster_bone))
		var rec := {"step": 0.0, "step_at": "", "reach": INF, "armed_early": 0, "placed_frames": 0, "last": Vector3.INF,
				"phase": "draw"}
		var probe := func() -> void:
			var st := c.state
			# (The item where it shows: the held node, else its stowed copy.)
			var node: Node3D = eq.held_node if eq.held_node and is_instance_valid(eq.held_node) else null
			if node == null:
				for bone: String in eq._stowed:
					var n: Node3D = eq._stowed[bone].node
					if is_instance_valid(n):
						node = n
			if node == null:
				return
			var at := node.global_position
			if rec.last != Vector3.INF:
				var d := (at - (rec.last as Vector3)).length()
				if d > float(rec.step):
					rec.step = d
					rec.step_at = "%s %s t %.2f" % [rec.phase, UltraActionLayer.Action.keys()[st.action], st.action_t]
			rec.last = at
			if gp.draw.at_place:
				rec.placed_frames = int(rec.placed_frames) + 1
				if MarksmanStance.of(c) != "unarmed" and MarksmanStance.of_item(def) != "unarmed":
					rec.armed_early = int(rec.armed_early) + 1
			if st.action in [UltraActionLayer.Action.EQUIPPING, UltraActionLayer.Action.HOLSTERING] and eq.held_node:
				var place := sk.global_transform * sk.get_bone_global_pose(place_b) * def.holster_offset
				var hand_at := sk.global_transform * sk.get_bone_global_pose(hand) * eq.grip()
				rec.reach = minf(float(rec.reach), hand_at.origin.distance_to(place.origin))
		sk.skeleton_updated.connect(probe)
		bot(c).set_steps([{"ticks": 70, "slot": sl, "yaw": 0.0}])
		await ticks(70)
		var drawn_ok := c.state.action == UltraActionLayer.Action.READY and eq.held_node != null and not eq.held_node.top_level
		var draw := rec.duplicate()
		rec.step = 0.0
		rec.reach = INF
		rec.phase = "put away"
		var placed_before := int(rec.placed_frames)
		bot(c).set_steps([{"ticks": 70, "slot": 0, "yaw": 0.0}])
		await ticks(70)
		sk.skeleton_updated.disconnect(probe)
		var away_ok := c.state.held_uid == 0 and eq.held_node == null and not eq._stowed.is_empty()
		info("%-8s draw: hand %.1f cm from the item at most close, item steps <= %.1f cm a frame (%s), %d frames in its place; put away: hand %.1f cm, steps <= %.1f cm (%s), %d frames" % [
				item, float(draw.reach) * 100.0, float(draw.step) * 100.0, draw.step_at, placed_before,
				float(rec.reach) * 100.0, float(rec.step) * 100.0, rec.step_at, int(rec.placed_frames) - placed_before])
		if not drawn_ok:
			bad.append("%s: not ready in the hand after the draw" % item)
		if not away_ok:
			bad.append("%s: not back in its place after putting it away" % item)
		if placed_before < 3 or int(rec.placed_frames) - placed_before < 3:
			bad.append("%s: the item didn't wait in its place for the hand" % item)
		for r: Dictionary in [draw, rec]:
			if float(r.reach) > REACH_MAX:
				bad.append("%s %s: the hand stayed %.1f cm off the item" % [item, r.phase, float(r.reach) * 100.0])
			if float(r.step) > ITEM_STEP_MAX:
				bad.append("%s %s: the item jumped %.1f cm in a frame (%s)" % [item, r.phase, float(r.step) * 100.0, r.step_at])
		# (The stance follows the sim's tick, the hand the shown time a tick behind: a frame either side.)
		if int(rec.armed_early) > 2:
			bad.append("%s: the body held the gun before the hand had it (%d frames)" % [item, int(rec.armed_early)])
		chars.erase(c)
		c.queue_free()
		await ticks(3)
	check(bad.is_empty(), "every item is drawn from its place and put back (%s)" % "; ".join(bad))
