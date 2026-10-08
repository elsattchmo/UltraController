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



## The main menu's "Marksman: motion matching" toggle: Single player then plays Marksman on matched clips (the spike,
## MarksmanMotionMatcher) instead of Sinew's gait; off again, the gait.
func test_menu_toggles_motion_matching() -> void:
	var had := MarksmanCharacter.motion_matching_on()
	for on in [true, false]:
		main = (load("res://demo/main.tscn") as PackedScene).instantiate()
		add_child(main)
		await ticks(3)
		UltraNet.stop()
		await ticks(2)
		if main.get("menu") == null:
			main.call("_show_menu")         # (headless boots straight into a session: no menu)
			await ticks(2)
		var t := main.find_child("MarksmanMM", true, false) as CheckButton
		if not check(t != null, "the main menu has the motion-matching toggle"):
			break
		t.button_pressed = on
		main.call("set_controller", "marksman")
		main.call("menu_start", "single")
		await ticks(30)
		var c := main.get("player") as MarksmanCharacter
		check(c != null and c.motion_matching == on,
				"toggle %s: Single player's Marksman %s motion matching" % ["on" if on else "off", "uses" if on else "doesn't use"])
		# (Headless the demo's characters have no visuals - no driver; with one, its matcher follows the flag.)
		var drv := c.anim as MarksmanAnimDriver if c else null
		if drv:
			check((drv.mm != null) == on, "its driver %s a matcher" % ["has" if on else "has no"])
		UltraNet.stop()
		main.queue_free()
		main = null
		await ticks(3)
	Engine.set_meta(MarksmanCharacter.MM_META, had)


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


## The Sinew debug view (K / main menu "Show Sinew muscles" / --sinew-debug) draws a Marksman body too: its
## parts as shapes coloured by effort, over the character.
func test_debug_view_draws_marksman() -> void:
	load_playground()
	var c := _marksman(marker("spawn").global_position)
	await ticks(40)
	var r := c.ragdoll as MarksmanRagdoll
	if not check(r != null, "a Marksman body"):
		return
	var dd: SinewDebugDraw = null
	for n in r.get_children():
		if n is SinewDebugDraw:
			dd = n
	if not check(dd != null, "its ragdoll carries the debug view"):
		return
	var was := SinewDebugDraw.view
	SinewDebugDraw.view = SinewDebugDraw.View.OVERLAY
	await ticks(10)
	var shown := 0
	for m in dd._shapes:
		shown += 1 if m.visible else 0
	check(shown >= r.parts.size() - 1, "overlay: a shape per part shown (%d of %d)" % [shown, r.parts.size()])
	SinewDebugDraw.view = SinewDebugDraw.View.OFF
	await ticks(3)
	shown = 0
	for m in dd._shapes:
		shown += 1 if m.is_visible_in_tree() else 0
	check(shown == 0, "off: nothing drawn (%d shown)" % shown)
	SinewDebugDraw.view = was
