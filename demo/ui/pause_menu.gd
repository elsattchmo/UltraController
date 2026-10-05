extends CanvasLayer
## Pause menu: Resume, Respawn, Controls (rebinding + sensitivity), Main menu, Quit. The world
## keeps running (multiplayer can't pause); local input is suspended while it's open.
## Mouse, keyboard or any pad: the first button has focus, D-pad / stick / arrows move it,
## accept (A / Enter) presses, cancel (B / Esc) or pause (Start / Esc) resumes.

signal resumed

const MenuStyle := preload("res://addons/ultra_controller/ui/menu_style.gd")

var _box: VBoxContainer
var _controls_button: Button


func _ready() -> void:
	layer = 55
	add_to_group(MenuStyle.MODAL_GROUP)
	# An open inventory would otherwise keep its player's input switched off after Resume.
	for hud in get_tree().get_nodes_in_group(MenuStyle.HUD_GROUP):
		if hud.has_method("close_inventory"):
			hud.call("close_inventory")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_set_input(false)
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.5)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.theme = MenuStyle.theme()
	add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.add_child(center)
	_box = VBoxContainer.new()
	_box.custom_minimum_size = Vector2(280, 0)
	_box.add_theme_constant_override("separation", 8)
	center.add_child(_box)
	var title := Label.new()
	title.text = "Paused"
	title.add_theme_font_size_override("font_size", 28)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_box.add_child(title)
	for spec in [["Resume", _resume], ["Respawn", _respawn], ["Controls", _controls], ["Main menu", _main_menu], ["Quit", func() -> void: get_tree().quit()]]:
		var b := Button.new()
		b.name = String(spec[0]).replace(" ", "")
		b.text = spec[0]
		b.custom_minimum_size = Vector2(0, 40)
		b.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
		b.pressed.connect(spec[1])
		_box.add_child(b)
		if spec[0] == "Controls":
			_controls_button = b
	MenuStyle.focus_first(_box)


func _set_input(on: bool) -> void:
	for p in UltraNet.local_players:
		if is_instance_valid(p.character) and p.character.input_source is LocalInputSource:
			(p.character.input_source as LocalInputSource).enabled = on


func _resume() -> void:
	_set_input(true)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	resumed.emit()
	queue_free()


func _respawn() -> void:
	for p in UltraNet.local_players:
		if not is_instance_valid(p.character):
			continue
		if UltraNet.is_server():
			UltraNet.respawn_character(p.character)
		elif p.character.input_source is LocalInputSource:
			(p.character.input_source as LocalInputSource).pulse(InputFrame.B_RESPAWN)
	_resume()


## Leave the session and go back to the title menu.
func _main_menu() -> void:
	UltraNet.stop()
	Engine.set_meta("ultra_to_menu", true)
	get_tree().reload_current_scene()


func _controls() -> void:
	visible = false
	var r := UltraRebindMenu.new()
	get_parent().add_child(r)
	r.closed.connect(func() -> void:
		visible = true
		MenuStyle.focus_first(_box, _controls_button))


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed(UltraInput.action(&"pause")) or event.is_action_pressed(&"ui_cancel"):
		_resume()
		get_viewport().set_input_as_handled()
