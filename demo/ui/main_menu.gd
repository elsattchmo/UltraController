extends CanvasLayer
## Demo main menu: single-player, split-screen, host, join, host + test client, launcher presets.

var main: Node
var _ip: LineEdit


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.07, 0.09, 0.82)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.custom_minimum_size = Vector2(380, 0)
	box.position = Vector2(-190, -260)
	box.add_theme_constant_override("separation", 10)
	bg.add_child(box)
	var title := Label.new()
	title.text = "ULTRA CONTROLLER"
	title.add_theme_font_size_override("font_size", 34)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
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
	j.pressed.connect(func() -> void: main.menu_start("join", _ip.text))
	row.add_child(j)
	box.add_child(row)
	_button(box, "Host + launch a test client", func() -> void: main.menu_start("host_and_client"))
	var sep := HSeparator.new()
	box.add_child(sep)
	var lbl := Label.new()
	lbl.text = "Launch presets (separate windows)"
	box.add_child(lbl)
	for p in UltraLauncher.presets():
		var preset := p
		_button(box, preset.title if preset.title != "" else preset.resource_name, func() -> void: UltraLauncher.launch(preset))
	_button(box, "Close launched instances", func() -> void: UltraLauncher.kill_all())
	_button(box, "Quit", func() -> void: get_tree().quit())


func _button(parent: Control, text: String, cb: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 36)
	b.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
	b.pressed.connect(cb)
	parent.add_child(b)
