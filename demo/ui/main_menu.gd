extends CanvasLayer
## Demo main menu: single-player, split-screen, host, join, host + test client, launcher presets.
## Mouse, keyboard or pad: "Single player" has focus on open, D-pad / stick / arrows move it,
## A / Enter presses.

const MenuStyle := preload("res://addons/ultra_controller/ui/menu_style.gd")

var main: Node
var _ip: LineEdit


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
	_header(box, "Play")
	_button(box, "Single player", func() -> void: main.menu_start("single"))
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
	_header(right, "Launch presets (separate windows)")
	for p in UltraLauncher.presets():
		var preset := p
		_button(right, preset.title if preset.title != "" else preset.resource_name, func() -> void: UltraLauncher.launch(preset))
	_button(right, "Close launched instances", func() -> void: UltraLauncher.kill_all())
	MenuStyle.focus_first(box)


func _header(parent: Control, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color(0.7, 0.75, 0.82))
	parent.add_child(l)


func _button(parent: Control, text: String, cb: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 36)
	b.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
	b.pressed.connect(cb)
	parent.add_child(b)
