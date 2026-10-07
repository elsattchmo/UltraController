extends UltraTestSuite
## Sinew stage 0: the GDExtension loads and simulates, and the main menu's Character pick
## (controller + model) is what Single player plays - players only, dummies untouched.

var main: Node


func after_each() -> void:
	if main:
		UltraNet.stop()
		main.queue_free()
		main = null
	# The pick is kept in Engine meta (across Pause > Main menu): don't leak it into other suites.
	Engine.set_meta("ultra_controller", "ultra")
	Engine.set_meta("ultra_model", "mannequin")
	await super.after_each()


func test_extension_loads_and_simulates() -> void:
	if not check(ClassDB.class_exists(&"SinewPhysics"), "the Sinew GDExtension is loaded (addons/sinew/bin)"):
		return
	var v := SinewCharacter.engine_version()
	check(v.begins_with("sinew 0.1.0") and v.contains("box3d"), "version names the core and its Box3D (%s)" % v)
	var w: RefCounted = ClassDB.instantiate(&"SinewPhysics")
	w.call("add_static_box", Transform3D(Basis(), Vector3(0, -0.5, 0)), Vector3(10, 0.5, 10))
	var body: int = w.call("add_capsule", Transform3D(Basis(), Vector3(0, 1.5, 0)), Vector3(-0.2, 0, 0), Vector3(0.2, 0, 0), 0.1, 1000.0)
	for i in 180:
		w.call("step", 1.0 / 60.0)
	var t: Transform3D = w.call("body_transform", body)
	near(t.origin.y, 0.1, 0.01, "a dropped capsule rests on the ground")
	check((w.call("linear_velocity", body) as Vector3).length() < 0.01, "and is still")


func test_single_player_plays_the_picked_character() -> void:
	main = (load("res://demo/main.tscn") as PackedScene).instantiate()
	add_child(main)
	await ticks(3)
	UltraNet.stop()                                   # (headless boots straight into a session)
	await ticks(2)
	check(main.get("controller") == "ultra" and main.get("model") == "mannequin", "defaults: the UltraController as the mannequin")
	main.call("set_controller", "sinew")
	main.call("set_model", "zombie")
	main.call("set_controller", "nobody")
	check(main.get("controller") == "sinew" and main.get("model") == "zombie", "picked Sinew as the zombie (an unknown key is refused)")
	main.call("menu_start", "single")
	await ticks(10)
	var c: UltraCharacter = main.get("player")
	if not check(c is SinewCharacter, "Single player plays a SinewCharacter (got %s)" % [c]):
		return
	check(c.body_profile.cut_scene.resource_path.begins_with("res://assets/characters/zombie/"), "wearing the zombie model (cut set %s)" % c.body_profile.cut_scene.resource_path)
	check(c.body_profile.visual_tier == BodyProfile.Tier.FULL, "at the player's FULL visual tier")
	# The Sinew body is the visual body: headless main builds none (suite s2 builds them).
	check(c.build_visuals or (c as SinewCharacter).physics == null, "headless: no visual body, so no Sinew body")
	main.call("set_controller", "ultra")
	check(main.get("controller") == "sinew", "the pick can't change mid-session")
	var dummy := UltraNet.spawn_bot("Dummy T", Transform3D(Basis(), c.state.pos + Vector3(3, 0, 0)))
	await ticks(2)
	check(dummy != null and dummy.character is SinewCharacter and dummy.character.body_profile.resource_path.ends_with("mannequin_body_profile.tres"),
			"a dummy spawned meanwhile follows the Controller pick (Sinew, to be pushed about) but keeps the mannequin")
	# Pause > Main menu reloads the scene: the pick stays.
	UltraNet.stop()
	main.queue_free()
	await ticks(3)
	Engine.set_meta("ultra_to_menu", true)
	main = (load("res://demo/main.tscn") as PackedScene).instantiate()
	add_child(main)
	await ticks(3)
	check(main.get("controller") == "sinew" and main.get("model") == "zombie", "the main menu after a game keeps the pick (%s / %s)" % [main.get("controller"), main.get("model")])
	Engine.remove_meta("ultra_level")


## The zombie model on the player's animation set (the mannequin's clips: both skeletons are the
## same humanoid) builds and walks.
func test_zombie_model_builds_the_full_body_and_walks() -> void:
	load_playground()
	var c := SinewCharacter.new()
	c.profile = (load("res://addons/ultra_controller/profiles/fps.tres") as MovementProfile).duplicate(true)
	c.body_profile = CharacterModels.body_profile("zombie")
	c.build_visuals = true
	var b := BotInputSource.new()
	b.name = "InputSource"
	c.add_child(b)
	c.input_source = b
	c.position = marker("spawn").global_position
	add_child(c)
	b.body = c
	chars.append(c)
	await ticks(5)
	check(c.skeleton != null and c.anim is SinewAnimDriver, "skeleton + Sinew's animation driver (clips, no IK)")
	# Animated, not standing in its rest (T) pose: the upper arms hang well away from their rest.
	var arm := c.skeleton.find_bone("LeftUpperArm")
	var off := c.skeleton.get_bone_pose_rotation(arm).angle_to(c.skeleton.get_bone_rest(arm).basis.get_rotation_quaternion())
	check(off > 0.5, "the clips play on it: idle upper arm %.0f deg off its rest" % rad_to_deg(off))
	var from := c.state.pos
	await hold(c, 90, Vector2(0, 1))
	check(c.state.pos.distance_to(from) > 1.0, "walks (%.2f m)" % c.state.pos.distance_to(from))
	off = c.skeleton.get_bone_pose_rotation(arm).angle_to(c.skeleton.get_bone_rest(arm).basis.get_rotation_quaternion())
	check(off > 0.5, "and while walking (%.0f deg)" % rad_to_deg(off))
