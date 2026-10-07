extends UltraTestSuite
## Sinew stage 6a: a SinewCharacter plays its referenced clips as they are - its own animation
## driver, no IK or procedural passes on the skeleton - and the clip references can be re-pointed
## (SinewAnimationSet) without code.

const IK_PASSES := ["InertialBlend", "BodyDynamics", "FootIK", "ArmClear", "WeaponPose", "HandIK", "ArmClearPost", "Look"]


func _sinew(at: Vector3, anim_set: SinewAnimationSet = null) -> SinewCharacter:
	var c := SinewCharacter.new()
	c.profile = (load("res://addons/ultra_controller/profiles/fps.tres") as MovementProfile).duplicate(true)
	c.body_profile = CharacterModels.body_profile("mannequin")
	c.build_visuals = true
	c.sinew_anim_set = anim_set
	var b := BotInputSource.new()
	b.name = "InputSource"
	c.add_child(b)
	c.input_source = b
	c.position = at
	add_child(c)
	b.body = c
	chars.append(c)
	return c


func test_no_ik_on_the_sinew_body() -> void:
	load_playground()
	var c := _sinew(marker("spawn").global_position)
	await ticks(10)
	check(c.anim is SinewAnimDriver, "Sinew's own animation driver")
	var mods := []
	for n in c.skeleton.get_children():
		if n is SkeletonModifier3D or n is PhysicalBoneSimulator3D:
			mods.append(String(n.name))
	var ik := []
	for m in mods:
		if m in IK_PASSES:
			ik.append(m)
	info("skeleton passes: %s" % [mods])
	check(ik.is_empty(), "no IK / procedural passes (found %s)" % [ik])
	check(c.anim.hand_ik == null and c.anim.foot_ik == null and c.anim.weapon_pose == null, "the driver has none either")
	check(c.get_node_or_null("TraversalHands") == null, "no rope / ladder / ledge hand IK")
	check(c.get_node_or_null("Equipment") != null, "the equipment is there (items still show in the hands)")
	# The UltraController's own player keeps its full stack.
	var u := spawn("spawn")
	await ticks(5)
	check(u.anim is UltraAnimDriver and not (u.anim is SinewAnimDriver) and u.anim.hand_ik != null, "the UltraController keeps its IK")


func test_it_plays_the_clips() -> void:
	load_playground()
	var c := _sinew(marker("spawn").global_position + Vector3(2, 0, 0))
	await ticks(20)
	var arm := c.skeleton.find_bone("LeftUpperArm")
	var off := c.skeleton.get_bone_pose_rotation(arm).angle_to(c.skeleton.get_bone_rest(arm).basis.get_rotation_quaternion())
	check(off > 0.5, "idle: the clip poses the body (upper arm %.0f deg off its rest)" % rad_to_deg(off))
	var b := bot(c)
	b.set_steps([{"ticks": 60, "move": Vector2(0, 1)}])
	await ticks(50)
	var pos: Vector2 = c.anim.tree.get(SinewAnimDriver.GROUND + "move/blend_position")
	check(c.anim._cur_loco == "ground" and pos.y > 0.5, "walking forward: the forward cycles (%s)" % pos)
	b.set_steps([{"ticks": 30, "buttons": InputFrame.B_JUMP}])
	var saw_air := false
	for i in 40:
		await ticks(1)
		saw_air = saw_air or c.anim._cur_loco == "air"
	check(saw_air, "jumping: the air clip")


func test_clip_references_can_be_repointed() -> void:
	load_playground()
	var s := SinewAnimationSet.new()
	s.overrides = {"walk_f": "Jog", "idle": "Idle_Subtle"}
	var c := _sinew(marker("spawn").global_position + Vector3(-2, 0, 0), s)
	await ticks(5)
	check(String(c.anim.anim_set.clip(&"walk_f")) == "Jog", "walk_f now references Jog (%s)" % c.anim.anim_set.clip(&"walk_f"))
	check(String(c.anim.anim_set.clip(&"idle")) == "Idle_Subtle", "idle now references Idle_Subtle")
	check(String(c.anim.anim_set.clip(&"jog_f")) == "Jog", "the rest still come from the default set")
	var root := c.anim.tree.tree_root as AnimationNodeBlendTree
	var g := ((root.get_node("loco") as AnimationNodeStateMachine).get_node("ground") as AnimationNodeBlendTree)
	var bs := g.get_node("move") as AnimationNodeBlendSpace2D
	var walk_node: AnimationNodeAnimation
	for i in bs.get_blend_point_count():
		if bs.get_blend_point_name(i) == &"walk_f":
			walk_node = bs.get_blend_point_node(i)
	check(walk_node != null and String(walk_node.animation) == "Jog", "and the tree plays it")
	var shared := load(SinewCharacter.DEFAULT_ANIM_SET) as SinewAnimationSet
	check(shared != null and shared.overrides.is_empty(), "the default reference set ships empty (= the clips as imported)")


func test_a_gun_still_shows_in_the_hand() -> void:
	load_playground()
	var c := _sinew(marker("spawn").global_position + Vector3(0, 0, 3))
	await ticks(10)
	UltraItems.give(c, &"pistol")
	var uid := 0
	for i in c.inventory.size():
		var it := c.inventory.get_slot(i)
		if it and it.def_id == &"pistol":
			uid = it.uid
	bot(c).set_steps([{"ticks": 60, "slot": c.inventory.find_uid(uid) + 1}])
	await ticks(70)
	var eq := c.get_node("Equipment") as UltraEquipmentVisual
	check(c.state.held_uid != 0 and eq.held_node != null and eq.held_node.is_inside_tree(), "the pistol is drawn and in the hand")
	check(c.anim.item_w > 0.5, "the item's own clip plays on the upper body (%.2f)" % c.anim.item_w)
	await hold(c, 40, Vector2(0, 1))
	check(c.state.held_uid != 0, "walking with it: no errors")
