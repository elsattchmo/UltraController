extends UltraTestSuite
## Menus and HUD with a gamepad (simulated InputEventJoypadButton / Motion through
## Input.parse_input_event), the split-screen character count, and HUD lifetime across
## session restarts. Run windowed with `--out=<dir>` to also save screenshots:
##   godot --path . --resolution 1280x720 res://tests/test_runner.tscn -- --suite=ui --out=C:/Dev/verify/ultra/review/ui_pad

const PAD_A := 0
const PAD_B := 1
const PAD_X := 2
const PAD_Y := 3
const PAD_BACK := 4
const PAD_START := 6
const PAD_UP := 11
const PAD_DOWN := 12
const PAD_LEFT := 13
const PAD_RIGHT := 14

var main: Node
var _out := ""


func before_each() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.trim_prefix("--out=")
	get_tree().root.size = Vector2i(1280, 720)        # headless has a 0x0 window
	UltraArgs.all()
	UltraArgs._args.clear()


func after_each() -> void:
	if main:
		UltraNet.stop()
		main.queue_free()
		main = null
	for n in get_tree().get_nodes_in_group(&"ultra_modal"):
		n.queue_free()
	UltraArgs._args.clear()
	UltraDummyPost.auto_spawn = false
	Engine.time_scale = 1.0
	await ticks(3)
	await super.after_each()


# ------------------------------------------------------------------ helpers

func _start(extra := {}) -> void:
	UltraArgs._args["offline"] = "true"
	for k: String in extra:
		UltraArgs._args[k] = extra[k]
	main = (load("res://demo/main.tscn") as PackedScene).instantiate()
	add_child(main)
	await ticks(20)


func _frames(n := 2) -> void:
	for i in n:
		await get_tree().process_frame


func _pad(button: int, dev := 0, hold := 0) -> void:
	var e := InputEventJoypadButton.new()
	e.device = dev
	e.button_index = button as JoyButton
	e.pressed = true
	e.pressure = 1.0
	Input.parse_input_event(e)
	await _frames(2)
	if hold > 0:
		await ticks(hold)
	var u := e.duplicate() as InputEventJoypadButton
	u.pressed = false
	u.pressure = 0.0
	Input.parse_input_event(u)
	await _frames(2)


func _stick(axis: int, value: float, dev := 0) -> void:
	var e := InputEventJoypadMotion.new()
	e.device = dev
	e.axis = axis as JoyAxis
	e.axis_value = value
	Input.parse_input_event(e)
	await _frames(1)


## Push the left stick to `value` through a few in-between readings (like a real stick) and back.
func _flick(axis: int, value: float, dev := 0) -> void:
	for f in [0.3, 0.6, 0.8, 1.0, 1.0]:
		await _stick(axis, value * f, dev)
	await _stick(axis, 0.0, dev)


func _key(k: Key) -> void:
	for down in [true, false]:
		var e := InputEventKey.new()
		e.physical_keycode = k
		e.keycode = k
		e.pressed = down
		Input.parse_input_event(e)
		await _frames(2)


func _click(p: Vector2, button := MOUSE_BUTTON_LEFT) -> void:
	for down in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = button
		e.position = p
		e.global_position = p
		e.pressed = down
		Input.parse_input_event(e)
		await _frames(2)


func _focus_text() -> String:
	var f := get_viewport().gui_get_focus_owner()
	return (f as Button).text if f is Button else (str(f.name) if f else "<none>")


func _shot(file: String) -> void:
	if _out == "" or DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(_out)
	get_viewport().get_texture().get_image().save_png(_out.path_join(file + ".png"))
	info("shot " + _out.path_join(file + ".png"))


func _huds() -> Array[UltraHUD]:
	var out: Array[UltraHUD] = []
	for n in get_tree().get_nodes_in_group(&"ultra_hud"):
		if not n.is_queued_for_deletion():
			out.append(n as UltraHUD)
	return out


func _hud_for(c: UltraCharacter) -> UltraHUD:
	for h in _huds():
		if h.character == c:
			return h
	return null


func _src(c: UltraCharacter) -> LocalInputSource:
	return c.input_source as LocalInputSource


func _characters() -> PackedStringArray:
	var s := PackedStringArray()
	for n in get_tree().get_nodes_in_group(&"ultra_character"):
		if not n.is_queued_for_deletion():
			s.append(str(n.name))
	return s


# ------------------------------------------------------------------ tests

func test_ui_actions_have_pad_buttons() -> void:
	for spec in [["ui_accept", PAD_A], ["ui_cancel", PAD_B]]:
		var found := false
		for e in InputMap.action_get_events(spec[0]):
			found = found or (e is InputEventJoypadButton and (e as InputEventJoypadButton).button_index == spec[1])
		check(found, "%s has pad button %d in the Input Map" % spec)
		var events: Array = (ProjectSettings.get_setting("input/" + spec[0], {}) as Dictionary).get("events", [])
		var saved := false
		for e: Variant in events:
			saved = saved or (e is InputEventJoypadButton and (e as InputEventJoypadButton).button_index == spec[1])
		check(saved, "%s pad button saved in project.godot" % spec[0])
	for a in ["ui_up", "ui_down", "ui_left", "ui_right"]:
		var pad := false
		for e in InputMap.action_get_events(a):
			pad = pad or e is InputEventJoypadButton
		check(pad, a + " navigates with the D-pad")
	for e in InputMap.action_get_events(UltraInput.action(&"companion")):
		check(not (e is InputEventJoypadButton), "companion is not on a pad button (D-pad Up summoned a stray bot)")


func test_main_menu_with_pad() -> void:
	var fake := FakeMain.new()
	add_child(fake)
	var m: CanvasLayer = (load("res://demo/ui/main_menu.gd") as Script).new()
	m.set("main", fake)
	add_child(m)
	await _frames(3)
	check(_focus_text() == "Single player", "main menu opens with focus on the first button (got %s)" % _focus_text())
	await _pad(PAD_DOWN)
	check(_focus_text() == "Split-screen (2 players)", "D-pad down moves focus (got %s)" % _focus_text())
	await _flick(JOY_AXIS_LEFT_Y, 1.0)
	check(_focus_text() == "Split-screen (4 players)", "one stick push = one step (got %s)" % _focus_text())
	await _flick(JOY_AXIS_LEFT_Y, -1.0)
	check(_focus_text() == "Split-screen (2 players)", "stick up moves back (got %s)" % _focus_text())
	await _shot("01_main_menu_focus")
	await _pad(PAD_A)
	check(fake.calls == [["split", "2"]], "A presses the focused button (calls %s)" % [fake.calls])
	m.queue_free()
	fake.queue_free()
	await _frames(2)


func test_pause_menu_with_pad() -> void:
	await _start()
	var c: UltraCharacter = main.player
	check(c != null and _src(c) != null, "local player with a LocalInputSource")
	await _pad(PAD_START)
	var pause: Node = main.get("_pause")
	if not check(pause != null and is_instance_valid(pause), "Start opens the pause menu"):
		return
	await _frames(2)
	check(_focus_text() == "Resume", "pause opens with focus on Resume (got %s)" % _focus_text())
	check(not _src(c).enabled, "game input is off while paused")
	await _pad(PAD_DOWN)
	check(_focus_text() == "Respawn", "D-pad down -> Respawn (got %s)" % _focus_text())
	await _flick(JOY_AXIS_LEFT_Y, 1.0)
	check(_focus_text() == "Controls", "stick down -> Controls (got %s)" % _focus_text())
	await _shot("02_pause_focus_controls")
	await _pad(PAD_A)
	await _frames(3)
	var rb: UltraRebindMenu = null
	for n in get_tree().get_nodes_in_group(&"ultra_modal"):
		if n is UltraRebindMenu:
			rb = n
	if not check(rb != null and not (pause as CanvasLayer).visible, "A on Controls opens the controls screen"):
		return
	var first := _focus_text()
	check(get_viewport().gui_get_focus_owner() != null and rb.is_ancestor_of(get_viewport().gui_get_focus_owner()), "controls screen has focus (%s)" % first)
	await _pad(PAD_DOWN)
	await _pad(PAD_DOWN)
	check(_focus_text() != first, "D-pad moves through the bindings (%s -> %s)" % [first, _focus_text()])
	await _shot("03_controls_focus")
	# Rebind with the pad: A picks the binding, the next button is captured.
	await _pad(PAD_RIGHT)
	await _pad(PAD_A)
	check(rb.get("_capture_action") != &"", "A on a binding starts capturing")
	await _frames(2)
	var row_action: StringName = rb.get("_capture_action")
	var before := InputMap.action_get_events(row_action).duplicate()
	if rb.get("_capture_pad"):
		await _pad(9)                       # LB
		var got := false
		for e in InputMap.action_get_events(row_action):
			got = got or (e is InputEventJoypadButton and (e as InputEventJoypadButton).button_index == 9)
		check(got, "pad button captured for %s" % row_action)
		await _frames(3)
		check(get_viewport().gui_get_focus_owner() != null, "focus is back on the list after a rebind")
	# restore the project bindings
	InputMap.action_erase_events(row_action)
	for e: InputEvent in before:
		InputMap.action_add_event(row_action, e)
	UltraInput.reset_user_rebinds()
	await _pad(PAD_B)
	await _frames(3)
	check(not is_instance_valid(rb) or rb.is_queued_for_deletion(), "B closes the controls screen")
	check((pause as CanvasLayer).visible, "pause menu is back")
	check(_focus_text() == "Controls", "focus returns to Controls (got %s)" % _focus_text())
	# A on Resume while holding A: must not jump.
	await _pad(PAD_UP)
	await _pad(PAD_UP)
	check(_focus_text() == "Resume", "back up to Resume (got %s)" % _focus_text())
	var y0 := c.state.pos.y
	await _pad(PAD_A, 0, 20)
	check(not is_instance_valid(pause) or pause.is_queued_for_deletion(), "A on Resume closes the menu")
	check(_src(c).enabled, "game input back on")
	var top := y0
	for i in 20:
		await ticks(1)
		top = maxf(top, c.state.pos.y)
	check(top - y0 < 0.05, "the A that pressed Resume didn't also jump (rose %.2f m)" % (top - y0))
	# Start toggles; B resumes.
	await _pad(PAD_START)
	pause = main.get("_pause")
	check(pause != null and is_instance_valid(pause), "Start opens it again")
	await _pad(PAD_START)
	await _frames(2)
	check(main.get("_pause") == null, "Start closes it")
	await _pad(PAD_START)
	await _pad(PAD_B)
	await _frames(2)
	check(main.get("_pause") == null, "B closes it")
	# Keyboard still works.
	await _key(KEY_ESCAPE)
	check(main.get("_pause") != null, "Esc opens it")
	await _key(KEY_DOWN)
	check(_focus_text() == "Respawn", "arrow keys move focus (got %s)" % _focus_text())
	await _key(KEY_ESCAPE)
	await _frames(2)
	check(main.get("_pause") == null, "Esc closes it")


func test_inventory_with_pad() -> void:
	await _start()
	var c: UltraCharacter = main.player
	var hud := _hud_for(c)
	if not check(hud != null, "player has a HUD"):
		return
	var inv := c.inventory
	info("inventory: %s" % [range(4).map(func(i: int) -> String: return str(inv.get_slot(i).def_id) if inv.get_slot(i) else "-")])
	await _pad(PAD_BACK)
	check(hud.is_inventory_open(), "Back opens the inventory")
	check(not _src(c).enabled, "game input is off while it's open")
	check(hud.get("_sel") == 0, "selection starts on the first slot")
	await _pad(PAD_RIGHT)
	check(hud.get("_sel") == 1, "D-pad right selects the next slot")
	await _flick(JOY_AXIS_LEFT_X, 1.0)
	check(hud.get("_sel") == 2, "one stick push = one slot (got %d)" % hud.get("_sel"))
	await _flick(JOY_AXIS_LEFT_Y, 1.0)
	check(hud.get("_sel") == 2 + UltraHUD.INV_COLUMNS, "stick down = next row (got %d)" % hud.get("_sel"))
	await _pad(PAD_UP)
	await _pad(PAD_LEFT)
	await _pad(PAD_LEFT)
	check(hud.get("_sel") == 0, "back to slot 0 (got %d)" % hud.get("_sel"))
	await _shot("04_inventory_pad_select")
	# A equips (pistol in slot 0).
	await _pad(PAD_A)
	check(_src(c).want_slot == 1, "A on the pistol equips it (want_slot %d)" % _src(c).want_slot)
	# Y picks the medkit up, Y on slot 7 puts it down there.
	var med := -1
	for i in inv.size():
		if inv.get_slot(i) and inv.get_slot(i).def_id == &"medkit":
			med = i
	if check(med >= 0, "kit has a medkit"):
		hud.set("_sel", med)
		await _pad(PAD_Y)
		check(hud.get("_carry") == med, "Y picks the item up")
		await _shot("05_inventory_pad_carry")
		hud.set("_sel", 2)
		await _pad(PAD_DOWN)
		await _pad(PAD_LEFT)
		check(hud.get("_sel") == 7, "down + left -> slot 7 (got %d)" % hud.get("_sel"))
		await _pad(PAD_Y)
		await _frames(3)
		check(inv.get_slot(7) != null and inv.get_slot(7).def_id == &"medkit", "Y puts it down in slot 7")
		# A uses it.
		c.state.hp = 40.0
		await _pad(PAD_A)
		await ticks(2)
		check(c.state.hp > 40.0, "A on the medkit heals (hp %.0f)" % c.state.hp)
	# X drops the ammo.
	var ammo := -1
	for i in inv.size():
		if inv.get_slot(i) and inv.get_slot(i).def_id == &"ammo_9mm":
			ammo = i
	if check(ammo >= 0, "kit has ammo"):
		hud.set("_sel", ammo)
		await _pad(PAD_X)
		await ticks(2)
		check(inv.get_slot(ammo) == null, "X drops the selected item")
	# B closes; holding B doesn't crouch afterwards.
	await _pad(PAD_B, 0, 15)
	check(not hud.is_inventory_open(), "B closes the inventory")
	check(_src(c).enabled, "game input back on")
	await ticks(3)
	check(not c.last_input.has(InputFrame.B_CROUCH), "the B that closed it isn't also crouch")
	# Keyboard: Tab opens, a click on a slot doesn't steal Tab, Tab closes.
	await _key(KEY_TAB)
	check(hud.is_inventory_open(), "Tab opens it")
	await _frames(2)
	var slot := hud.get("_inv_grid").get_child(3) as Control
	await _click(slot.get_global_rect().get_center())
	check(hud.get("_sel") == 3, "clicking a slot selects it")
	await _key(KEY_TAB)
	check(not hud.is_inventory_open(), "Tab still closes it after a click (used to be eaten as focus-next)")
	# Pause closes the inventory instead of leaving input off behind it.
	await _pad(PAD_BACK)
	await _pad(PAD_START)
	check(not hud.is_inventory_open() and main.get("_pause") != null, "Start closes the inventory and pauses")
	await _pad(PAD_B)
	await _frames(2)
	check(_src(c).enabled, "input on after resuming")


func test_split_screen_two_players() -> void:
	UltraDummyPost.auto_spawn = true                 # the playground's 4 dummies are intended
	await _start({"players": "2"})
	main.locals.join_enabled = true                  # as when started from the main menu
	var players := 0
	var bots := 0
	for p: NetPlayer in UltraNet.players.values():
		if p.is_bot:
			bots += 1
		else:
			players += 1
	check(players == 2 and UltraNet.local_players.size() == 2, "2 player characters (%s)" % _characters())
	check(bots == 4, "plus the 4 yard dummies (%d bots)" % bots)
	var n0 := _characters().size()
	await _pad(PAD_UP, 0)
	await ticks(3)
	check(_characters().size() == n0, "D-pad up doesn't spawn a helper (%s)" % _characters())
	await _pad(PAD_START, 1)
	await ticks(3)
	check(_characters().size() == n0, "Start on the second pad doesn't hot-join a third player (%s)" % _characters())
	check(main.get("_pause") != null, "... it pauses instead")
	await _pad(PAD_B, 1)
	await _frames(2)
	check(main.get("_pause") == null, "B resumes")
	var p1: UltraCharacter = UltraNet.local_players[0].character
	var p2: UltraCharacter = UltraNet.local_players[1].character
	var h1 := _hud_for(p1)
	var h2 := _hud_for(p2)
	check(h1 != null and h2 != null and h1 != h2, "one HUD per player")
	check(_huds().size() == 2, "exactly 2 HUDs (%d)" % _huds().size())
	check(_src(p1).claims("kbm") and _src(p1).claims("joy1") and _src(p2).claims("joy0"), "P1 = keyboard + pad 1, P2 = pad 0")
	# P2's pad drives only P2's inventory.
	await _pad(PAD_BACK, 0)
	check(h2.is_inventory_open() and not h1.is_inventory_open(), "P2's Back opens only P2's inventory")
	await _pad(PAD_RIGHT, 0)
	check(h2.get("_sel") == 1 and h1.get("_sel") == 0, "P2's D-pad moves only P2's selection")
	check(_src(p1).enabled and not _src(p2).enabled, "only P2's game input is off")
	# P1 with keyboard + mouse in their pane.
	await _key(KEY_TAB)
	check(h1.is_inventory_open(), "P1's Tab opens P1's inventory")
	await _frames(2)
	var slot := h1.get("_inv_grid").get_child(4) as Control
	var vp := slot.get_viewport()
	var pane := vp.get_parent() as Control
	var at := pane.get_global_rect().position + slot.get_global_rect().get_center()
	await _click(at)
	check(h1.get("_sel") == 4, "P1 can click a slot in their split-screen pane (sel %d)" % h1.get("_sel"))
	await _shot("06_split_inventories")
	await _pad(PAD_B, 0)
	await _key(KEY_ESCAPE)        # Esc: pause (closes P1's inventory on the way)
	check(not h1.is_inventory_open() and not h2.is_inventory_open(), "both closed")
	await _pad(PAD_START, 0)
	await _frames(2)
	check(main.get("_pause") == null, "P2's Start resumes")
	check(_src(p1).enabled and _src(p2).enabled, "both players' input back on")


func test_session_restart_leaves_no_stale_hud() -> void:
	await _start()
	check(_huds().size() == 1, "one HUD")
	var handlers: Dictionary = UltraNet.world.get("_handlers")
	var hits := (handlers.get(&"hit", []) as Array).size()
	main.menu_start("split", "2")
	await ticks(5)
	check(_huds().size() == 2, "restart as 2 players: exactly 2 HUDs (%d)" % _huds().size())
	for h in _huds():
		check(is_instance_valid(h.character), "HUD bound to a live character")
	UltraNet.stop()
	await ticks(3)
	check(_huds().is_empty(), "stopping the session removes its HUDs (%d left)" % _huds().size())
	main.queue_free()
	main = null
	await ticks(2)
	var stale := 0
	for cb: Callable in handlers.get(&"hit", []):
		if not cb.is_valid():
			stale += 1
	check(stale == 0, "no stale hit handlers left behind (%d)" % stale)
	info("hit handlers: %d with one session, %d now" % [hits, (handlers.get(&"hit", []) as Array).size()])


class FakeMain:
	extends Node
	var calls: Array = []

	func menu_start(kind: String, value := "") -> void:
		calls.append([kind, value])
