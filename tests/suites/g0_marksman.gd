extends UltraTestSuite
## Marksman stage V0: the third controller is registered, Single player plays it, and it is Sinew's body
## and gait underneath (its own driver / ragdoll classes in place). See addons/marksman/README.md.

var main: Node


func after_each() -> void:
	if main:
		UltraNet.stop()
		main.queue_free()
		main = null
	Engine.set_meta("ultra_controller", "ultra")
	Engine.set_meta("ultra_model", "mannequin")
	await super.after_each()


func _marksman(at: Vector3) -> MarksmanCharacter:
	var c := MarksmanCharacter.new()
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


func test_single_player_plays_marksman() -> void:
	check(CharacterModels.has_controller("marksman"), "the controller list has Marksman")
	main = (load("res://demo/main.tscn") as PackedScene).instantiate()
	add_child(main)
	await ticks(3)
	UltraNet.stop()
	await ticks(2)
	main.call("set_controller", "marksman")
	main.call("menu_start", "single")
	await ticks(10)
	var c: UltraCharacter = main.get("player")
	check(c is MarksmanCharacter, "Single player plays a MarksmanCharacter (got %s)" % [c])


func test_marksman_is_a_sinew_body_that_walks() -> void:
	load_playground()
	var c := _marksman(marker("spawn").global_position)
	await ticks(40)
	check(c.anim is MarksmanAnimDriver, "its own animation driver (got %s)" % [c.anim])
	if not check(c.ragdoll is MarksmanRagdoll, "its own body: a MarksmanRagdoll (got %s)" % [c.ragdoll]):
		return
	var r := c.ragdoll as MarksmanRagdoll
	check(r.world != null and r.gait, "on Sinew's physics world, with the gait on")
	var from := c.state.pos
	bot(c).set_steps([{"ticks": 120, "move": Vector2(0, 1)}])
	await ticks(120)
	check(c.state.pos.distance_to(from) > 1.2, "walks (%.2f m in 2 s)" % c.state.pos.distance_to(from))
	var st: Dictionary = r.world.physics.call("character_gait_state", r._id)
	check(bool(st.get("stepping", false)), "the gait steps")
