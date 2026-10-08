extends CanvasLayer
## Demo main menu: level select, character select (controller + model), single-player,
## split-screen, host, join, host + test client,
## launcher presets. The level picked here (Playground, Zombie Mansion...) is what every way of
## playing starts in, launched windows and joined games included.
## Mouse, keyboard or pad: "Single player" has focus on open, D-pad / stick / arrows move it,
## A / Enter presses.

const MenuStyle := preload("res://addons/ultra_controller/ui/menu_style.gd")

var main: Node
var _ip: LineEdit
var _level_buttons := {}                ## level key -> its toggle button
var _char_rows: Array = []              ## [controller buttons, model buttons]: rows of toggles
var _char_buttons := {}                 ## "controller:<key>" / "model:<key>" -> its toggle button


func _ready() -> void:
	add_to_group(MenuStyle.MODAL_GROUP)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.07, 0.09, 0.82)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.theme = MenuStyle.theme()
	add_child(bg)
	# Two columns, centred: playing on the left, launch presets on the right (scrolls if long).
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.add_child(center)
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 18)
	center.add_child(outer)
	var title := Label.new()
	title.text = "ULTRA CONTROLLER"
	title.add_theme_font_size_override("font_size", 34)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	outer.add_child(title)
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 28)
	outer.add_child(cols)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(340, 0)
	box.add_theme_constant_override("separation", 10)
	cols.add_child(box)
	_build_levels(box)
	_build_characters(box)
	_header(box, "Play")
	var single := _button(box, "Single player", func() -> void: main.menu_start("single"))
	_link_levels(single)
	_button(box, "Split-screen (2 players)", func() -> void: main.menu_start("split", "2"))
	_button(box, "Split-screen (4 players)", func() -> void: main.menu_start("split", "4"))
	_button(box, "Host game", func() -> void: main.menu_start("host"))
	var row := HBoxContainer.new()
	_ip = LineEdit.new()
	_ip.text = "127.0.0.1"
	_ip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_ip)
	var j := Button.new()
	j.text = "Join"
	j.custom_minimum_size = Vector2(80, 36)
	j.pressed.connect(func() -> void: main.menu_start("join", _ip.text))
	row.add_child(j)
	box.add_child(row)
	_button(box, "Host + launch a test client", func() -> void: main.menu_start("host_and_client"))
	box.add_child(HSeparator.new())
	_button(box, "Quit", func() -> void: get_tree().quit())
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(380, 470)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	cols.add_child(scroll)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 10)
	scroll.add_child(right)
	if main != null and main.has_method("controller_list"):
		# Sinew's debug view (muscles coloured by effort, bones, balance): also K in game.
		_header(right, "Debug")
		var dbg := CheckButton.new()
		dbg.name = "SinewDebug"
		dbg.text = "Show Sinew muscles (K)"
		dbg.tooltip_text = "Draw the Sinew body over the character: muscles coloured by effort, bones, balance"
		dbg.button_pressed = SinewDebugDraw.view > 0
		dbg.toggled.connect(func(on: bool) -> void: SinewDebugDraw.view = SinewDebugDraw.View.OVERLAY if on else SinewDebugDraw.View.OFF)
		right.add_child(dbg)
		# Marksman's motion-matching legs (the spike) instead of Sinew's procedural gait; also --mm.
		var mm := CheckButton.new()
		mm.name = "MarksmanMM"
		mm.text = "Marksman: motion matching"
		mm.tooltip_text = "Marksman walks on matched clips (standing; unarmed and rifle) instead of Sinew's gait. Takes effect on Play"
		mm.button_pressed = MarksmanCharacter.motion_matching_on()
		mm.toggled.connect(func(on: bool) -> void: Engine.set_meta(MarksmanCharacter.MM_META, on))
		right.add_child(mm)
	_header(right, "Launch presets (separate windows)")
	for p in UltraLauncher.presets():
		var preset := p
		_button(right, preset.title if preset.title != "" else preset.resource_name, func() -> void: UltraLauncher.launch(preset, "", _launch_args()))
	_button(right, "Close launched instances", func() -> void: UltraLauncher.kill_all())
	MenuStyle.focus_first(box, single)


## One toggle per level (a pad can reach them by moving up from "Single player"): picking one loads it
## behind the menu. Without a main that offers levels (the menu tests' stand-in) there is no section.
func _build_levels(box: VBoxContainer) -> void:
	if main == null or not main.has_method("level_list") or not main.has_method("set_level"):
		return
	var levels: Array = main.call("level_list")
	if levels.size() < 2:
		return
	_header(box, "Level")
	var group := ButtonGroup.new()
	var current: String = main.get("level")
	for d: Dictionary in levels:
		var b := Button.new()
		b.name = "Level_" + String(d.key)
		b.toggle_mode = true
		b.button_group = group
		b.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(0, 52)
		b.text = "%s
%s" % [d.title, d.blurb]
		b.button_pressed = String(d.key) == current
		var key: String = d.key
		b.toggled.connect(func(on: bool) -> void:
			if on and String(main.get("level")) != key:
				main.call("set_level", key))
		box.add_child(b)
		_level_buttons[key] = b
	box.add_child(HSeparator.new())


## The local player's controller (UltraController / Sinew) and model, a row of toggles each, under
## the levels. Without a main that offers them (the menu tests' stand-ins) there is no section.
func _build_characters(box: VBoxContainer) -> void:
	if main == null or not main.has_method("controller_list") or not main.has_method("model_list"):
		return
	_header(box, "Character")
	for kind: String in ["controller", "model"]:
		var defs: Array = main.call(kind + "_list")
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var group := ButtonGroup.new()
		var current := String(main.get(kind))
		var buttons: Array = []
		for d: Dictionary in defs:
			var b := Button.new()
			b.name = "%s_%s" % [kind.capitalize(), d.key]
			b.toggle_mode = true
			b.button_group = group
			b.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			b.custom_minimum_size = Vector2(0, 40)
			b.text = String(d.title)
			b.tooltip_text = String(d.blurb)
			b.button_pressed = String(d.key) == current
			var key: String = d.key
			var setter: String = "set_" + kind
			b.toggled.connect(func(on: bool) -> void:
				if on and String(main.get(kind)) != key:
					main.call(setter, key))
			row.add_child(b)
			buttons.append(b)
			_char_buttons["%s:%s" % [kind, key]] = b
		box.add_child(row)
		_char_rows.append(buttons)
	box.add_child(HSeparator.new())


## Pad / arrow steering inside the left column: the levels, then the character rows, stack above
## "Single player" (by position alone the engine's "up" jumped to the other column). Inside a
## character row left / right move along it; up / down go to the row's first button.
func _link_levels(below: Control) -> void:
	var rows: Array = []
	for b in _level_buttons.values():
		rows.append([b])
	rows.append_array(_char_rows)
	for i in rows.size():
		var row: Array = rows[i]
		for k in row.size():
			var b: Control = row[k]
			b.focus_neighbor_left = b.get_path_to(row[k - 1] if k > 0 else b)
			b.focus_neighbor_right = b.get_path_to(row[k + 1] if k < row.size() - 1 else b)
			b.focus_neighbor_top = b.get_path_to(rows[i - 1][0] if i > 0 else b)
			b.focus_neighbor_bottom = b.get_path_to(rows[i + 1][0] if i < rows.size() - 1 else below)
	if not rows.is_empty():
		below.focus_neighbor_top = below.get_path_to(rows[rows.size() - 1][0])


## Launched windows play the level picked here.
func _launch_args() -> PackedStringArray:
	var key = main.get("level") if main != null else null
	return PackedStringArray(["--map=" + String(key)]) if key != null and String(key) != "" else PackedStringArray()


func _header(parent: Control, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color(0.7, 0.75, 0.82))
	parent.add_child(l)


func _button(parent: Control, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 36)
	b.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
	b.pressed.connect(cb)
	parent.add_child(b)
	return b
