extends UltraTestSuite
## Input: every action lives in the Input Map with keyboard and gamepad events, overrides and
## rebinds work, sticks are shaped radially, devices can be claimed per player.


func test_actions_in_project_settings() -> void:
	for suffix: String in UltraInputDefaults.ACTIONS:
		var act := UltraInputDefaults.PREFIX + suffix
		if not check(InputMap.has_action(act), "%s in Input Map" % act):
			continue
		var spec: Array = UltraInputDefaults.ACTIONS[suffix]
		var want_key := false
		var want_pad := false
		for e: String in spec[1]:
			want_key = want_key or e.begins_with("key") or e.begins_with("mouse")
			want_pad = want_pad or e.begins_with("joy") or e.begins_with("axis")
		var has_key := false
		var has_pad := false
		for ev in InputMap.action_get_events(act):
			has_key = has_key or ev is InputEventKey or ev is InputEventMouseButton
			has_pad = has_pad or ev is InputEventJoypadButton or ev is InputEventJoypadMotion
		if want_key:
			check(has_key, "%s has a keyboard/mouse binding" % act)
		if want_pad:
			check(has_pad, "%s has a gamepad binding" % act)
	for core in ["move_forward", "jump", "crouch", "sprint", "interact", "primary", "secondary", "reload", "toggle_view"]:
		var has_pad := false
		for ev in InputMap.action_get_events("uc_" + core):
			has_pad = has_pad or ev is InputEventJoypadButton or ev is InputEventJoypadMotion
		check(has_pad, "gameplay action uc_%s playable on gamepad" % core)


func test_action_override() -> void:
	var key := UltraInputSettings.ROOT + "action_overrides"
	var old: Variant = ProjectSettings.get_setting(key, {})
	ProjectSettings.set_setting(key, {"jump": "my_jump"})
	UltraInput.clear_cache()
	check(UltraInput.action(&"jump") == &"my_jump", "semantic action remaps to host action")
	ProjectSettings.set_setting(key, old)
	UltraInput.clear_cache()
	check(UltraInput.action(&"jump") == &"uc_jump", "default restored")


func test_stick_shaping() -> void:
	check(UltraInput.shape_stick(Vector2(0.05, 0.05)) == Vector2.ZERO, "inner radial deadzone")
	near(UltraInput.shape_stick(Vector2(1, 0)).length(), 1.0, 0.001, "full deflection = 1")
	var diag := UltraInput.shape_stick(Vector2(0.7071, 0.7071))
	near(diag.length(), 1.0, 0.01, "diagonal full deflection is radial (no square corners)")
	check(UltraInput.shape_stick(Vector2(0.5, 0)).x < 0.5, "response curve softens mid-stick")


func test_local_source_devices() -> void:
	var src := LocalInputSource.new()
	add_child(src)
	var w := InputEventKey.new()
	w.physical_keycode = KEY_W
	w.pressed = true
	src._input(w)
	near(src.sample(0).move.y, 1.0, 0.01, "W = forward")
	w.pressed = false
	src._input(w)
	var ax := InputEventJoypadMotion.new()
	ax.device = 0
	ax.axis = JOY_AXIS_LEFT_Y
	ax.axis_value = -0.6
	src._input(ax)
	src.active_device = "joy0"
	var f := src.sample(1)
	check(f.move.y > 0.1 and f.move.y < 0.6, "half stick = analog forward (%.2f)" % f.move.y)
	# Claimed device filtering (split-screen).
	var p2 := LocalInputSource.new()
	p2.claimed_devices = PackedStringArray(["joy1"])
	add_child(p2)
	p2._input(ax)
	near(p2.sample(0).move.y, 0.0, 0.001, "player 2 ignores pad 0")
	ax.device = 1
	p2._input(ax)
	p2.active_device = "joy1"
	check(p2.sample(1).move.y > 0.1, "player 2 reads pad 1")
	src.queue_free()
	p2.queue_free()


func test_user_rebind_roundtrip() -> void:
	var act := &"uc_jump"
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_J
	InputMap.action_erase_events(act)
	InputMap.action_add_event(act, ev)
	UltraInput.save_user_rebind(act)
	InputMap.load_from_project_settings()
	UltraInput.apply_user_rebinds()
	var found := false
	for e in InputMap.action_get_events(act):
		found = found or (e is InputEventKey and (e as InputEventKey).physical_keycode == KEY_J)
	check(found, "rebind survives a restart")
	UltraInput.reset_user_rebinds()
	found = false
	for e in InputMap.action_get_events(act):
		found = found or (e is InputEventKey and (e as InputEventKey).physical_keycode == KEY_SPACE)
	check(found, "reset restores project default")


func test_input_frame_codec() -> void:
	var f := InputFrame.new()
	f.tick = 1234
	f.move = Vector2(0.3, -0.8)
	f.yaw = 2.5
	f.pitch = -0.4
	f.buttons = InputFrame.B_JUMP | InputFrame.B_SPRINT
	f.quantize()
	var b := StreamPeerBuffer.new()
	f.encode(b)
	check(b.data_array.size() == InputFrame.ENCODED_SIZE, "encoded size %d" % b.data_array.size())
	b.seek(0)
	var g := InputFrame.decode(b)
	check(g.tick == f.tick and g.buttons == f.buttons, "tick/buttons survive")
	check(g.move.is_equal_approx(f.move) and is_equal_approx(g.yaw, f.yaw) and is_equal_approx(g.pitch, f.pitch), "quantized values are exact after decode")
