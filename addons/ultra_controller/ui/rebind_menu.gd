class_name UltraRebindMenu
extends CanvasLayer
## Controls screen: every uc_* action with a keyboard/mouse slot and a gamepad slot. Click a
## slot, press the new input (Esc cancels). Conflicts are flagged. Changes go into the live
## Input Map and user://ultra_input.cfg (UltraInput.save_user_rebind); "Reset" restores the
## project defaults from Project Settings. Also exposes the main sensitivity settings.
## Works with a pad too: focus starts on the first binding, D-pad / stick move it, A picks a
## binding (then press the new key / button; Esc or 5 s without input cancels), B goes back.

signal closed

const MenuStyle := preload("res://addons/ultra_controller/ui/menu_style.gd")
const CAPTURE_TIMEOUT := 5.0

var _list: VBoxContainer
var _capture_action := StringName()
var _capture_pad := false
var _capture_t := 0.0
var _status: Label
var _back: Button
var _refocus := Vector2i(-1, -1)      ## (row, column) to focus again after a rebuild


func _ready() -> void:
	layer = 60
	add_to_group(MenuStyle.MODAL_GROUP)
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.06, 0.08, 0.92)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.theme = MenuStyle.theme()
	add_child(bg)
	var panel := VBoxContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = 60
	panel.offset_right = -60
	panel.offset_top = 40
	panel.offset_bottom = -40
	bg.add_child(panel)
	var title := Label.new()
	title.text = "Controls"
	title.add_theme_font_size_override("font_size", 30)
	panel.add_child(title)
	panel.add_child(_settings_row())
	_status = Label.new()
	_status.text = "Pick a binding (click / A), then press the new key or button. Esc cancels. B goes back."
	panel.add_child(_status)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.follow_focus = true
	panel.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)
	var row := HBoxContainer.new()
	var reset := Button.new()
	reset.text = "Reset to defaults"
	reset.pressed.connect(func() -> void:
		UltraInput.reset_user_rebinds()
		_rebuild())
	row.add_child(reset)
	_back = Button.new()
	_back.text = "Back"
	_back.pressed.connect(close)
	row.add_child(_back)
	panel.add_child(row)
	_rebuild()
	MenuStyle.focus_first(_list)


func close() -> void:
	if is_queued_for_deletion():
		return
	closed.emit()
	queue_free()


func _unhandled_input(event: InputEvent) -> void:
	if _capture_action == &"" and event.is_action_pressed(&"ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if _capture_action != &"":
		_capture_t += delta
		if _capture_t > CAPTURE_TIMEOUT:
			_capture_action = &""
			_status.text = "Cancelled."


func _settings_row() -> Control:
	var h := HFlowContainer.new()
	h.add_theme_constant_override("h_separation", 16)
	for spec in [["Mouse sensitivity", "mouse_sensitivity", 0.02, 0.6], ["Stick look speed", "stick_yaw_speed_deg", 60.0, 480.0]]:
		var l := Label.new()
		l.text = spec[0]
		h.add_child(l)
		var s := HSlider.new()
		s.custom_minimum_size = Vector2(200, 0)
		s.min_value = spec[2]
		s.max_value = spec[3]
		s.step = (spec[3] - spec[2]) / 200.0
		s.value = UltraInputSettings.f(spec[1])
		var key: String = spec[1]
		s.value_changed.connect(func(v: float) -> void: UltraInputSettings.set_user_value(key, v))
		h.add_child(s)
	for spec in [["Invert Y (mouse)", "mouse_invert_y"], ["Invert Y (stick)", "stick_invert_y"], ["Toggle crouch", "toggle_crouch"], ["Toggle sprint", "toggle_sprint"], ["Vibration", "vibration_enabled"]]:
		var c := CheckBox.new()
		c.text = spec[0]
		c.button_pressed = UltraInputSettings.b(spec[1])
		var key2: String = spec[1]
		c.toggled.connect(func(v: bool) -> void: UltraInputSettings.set_user_value(key2, v))
		h.add_child(c)
	return h


func _rebuild() -> void:
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	var used := {}
	for suffix: String in UltraInputDefaults.ACTIONS:
		var act := UltraInput.action(StringName(suffix))
		if not InputMap.has_action(act):
			continue
		for e in InputMap.action_get_events(act):
			var k := _event_key(e)
			used[k] = (used.get(k, []) as Array) + [suffix]
	for suffix: String in UltraInputDefaults.ACTIONS:
		if suffix.begins_with("debug"):
			continue
		var act := UltraInput.action(StringName(suffix))
		if not InputMap.has_action(act):
			continue
		var row := HBoxContainer.new()
		var name_l := Label.new()
		name_l.text = suffix.capitalize()
		name_l.custom_minimum_size = Vector2(220, 0)
		row.add_child(name_l)
		for pad in [false, true]:
			var b := Button.new()
			b.custom_minimum_size = Vector2(260, 0)
			var txt := PackedStringArray()
			var conflict := false
			for e in InputMap.action_get_events(act):
				var is_pad := e is InputEventJoypadButton or e is InputEventJoypadMotion
				if is_pad == pad:
					txt.append(_describe(e))
					conflict = conflict or (used.get(_event_key(e), []) as Array).size() > 1
			b.text = ", ".join(txt) if not txt.is_empty() else "—"
			if conflict:
				b.modulate = Color(1, 0.6, 0.4)
				b.tooltip_text = "Shared with another action"
			var a := act
			var p: bool = pad
			var at := Vector2i(_list.get_child_count(), 1 if pad else 0)
			b.pressed.connect(func() -> void:
				_refocus = at
				_begin_capture(a, p))
			row.add_child(b)
		_list.add_child(row)
	# Rebuilt rows are new buttons: put focus back on the binding that was just changed.
	if _refocus.x >= 0 and _refocus.x < _list.get_child_count():
		var again := _list.get_child(_refocus.x).get_child(1 + _refocus.y) as Control
		_refocus = Vector2i(-1, -1)
		MenuStyle.focus_first(_list, again)


static func _event_key(e: InputEvent) -> String:
	if e is InputEventKey:
		return "k%d" % (e as InputEventKey).physical_keycode
	if e is InputEventMouseButton:
		return "m%d" % (e as InputEventMouseButton).button_index
	if e is InputEventJoypadButton:
		return "j%d" % (e as InputEventJoypadButton).button_index
	if e is InputEventJoypadMotion:
		return "a%d%s" % [(e as InputEventJoypadMotion).axis, "+" if (e as InputEventJoypadMotion).axis_value > 0 else "-"]
	return e.as_text()


static func _describe(e: InputEvent) -> String:
	if e is InputEventKey:
		var k := e as InputEventKey
		return OS.get_keycode_string(k.physical_keycode if k.physical_keycode != 0 else k.keycode)
	if e is InputEventMouseButton:
		return "Mouse %d" % (e as InputEventMouseButton).button_index
	if e is InputEventJoypadButton:
		return "Pad " + UltraHUD._pad_name((e as InputEventJoypadButton).button_index, "xbox")
	if e is InputEventJoypadMotion:
		var m := e as InputEventJoypadMotion
		var axes := ["LS X", "LS Y", "RS X", "RS Y", "LT", "RT"]
		return "Pad %s%s" % [axes[m.axis] if m.axis < axes.size() else str(m.axis), "+" if m.axis_value > 0 else "-"]
	return e.as_text()


func _begin_capture(act: StringName, pad: bool) -> void:
	_capture_action = act
	_capture_pad = pad
	_capture_t = 0.0
	_status.text = "Press the new %s for %s…  (Esc or wait %d s to cancel)" % ["gamepad button" if pad else "key or mouse button", act, int(CAPTURE_TIMEOUT)]


func _input(event: InputEvent) -> void:
	if _capture_action == &"":
		return
	var cancel_key := event is InputEventKey and (event as InputEventKey).physical_keycode == KEY_ESCAPE
	var cancel_pad := not _capture_pad and event is InputEventJoypadButton and event.is_action_pressed(&"ui_cancel")
	if (cancel_key or cancel_pad) and event.pressed:
		_capture_action = &""
		_status.text = "Cancelled."
		get_viewport().set_input_as_handled()
		return
	var ok := false
	if _capture_pad:
		ok = (event is InputEventJoypadButton and event.pressed) or (event is InputEventJoypadMotion and absf((event as InputEventJoypadMotion).axis_value) > 0.6)
	else:
		ok = (event is InputEventKey and event.pressed and not (event as InputEventKey).echo) or (event is InputEventMouseButton and event.pressed)
	if not ok:
		return
	var fresh := event.duplicate() as InputEvent
	if fresh is InputEventJoypadMotion:
		(fresh as InputEventJoypadMotion).axis_value = signf((fresh as InputEventJoypadMotion).axis_value)
	if fresh is InputEventKey:
		var k := fresh as InputEventKey
		k.physical_keycode = k.physical_keycode if k.physical_keycode != 0 else k.keycode
		k.keycode = 0
		k.pressed = false
	fresh.device = -1
	for e in InputMap.action_get_events(_capture_action):
		var is_pad := e is InputEventJoypadButton or e is InputEventJoypadMotion
		if is_pad == _capture_pad:
			InputMap.action_erase_event(_capture_action, e)
	InputMap.action_add_event(_capture_action, fresh)
	UltraInput.save_user_rebind(_capture_action)
	_status.text = "%s -> %s" % [_capture_action, _describe(fresh)]
	_capture_action = &""
	get_viewport().set_input_as_handled()
	_rebuild()
