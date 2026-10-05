extends CanvasLayer
## Pause menu: Resume, Controls (rebinding + sensitivity), Quit. The world keeps running
## (multiplayer can't pause); local input is suspended while it's open.

signal resumed

var _box: VBoxContainer


func _ready() -> void:
	layer = 55
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_set_input(false)
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.5)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	_box = VBoxContainer.new()
	_box.set_anchors_preset(Control.PRESET_CENTER)
	_box.position = Vector2(-140, -90)
	_box.custom_minimum_size = Vector2(280, 0)
	bg.add_child(_box)
	for spec in [["Resume", _resume], ["Respawn", _respawn], ["Controls", _controls], ["Main menu", _main_menu], ["Quit", func() -> void: get_tree().quit()]]:
		var b := Button.new()
		b.text = spec[0]
		b.custom_minimum_size = Vector2(0, 40)
		b.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
		b.pressed.connect(spec[1])
		_box.add_child(b)
	(_box.get_child(0) as Button).grab_focus()


func _set_input(on: bool) -> void:
	for p in UltraNet.local_players:
		if p.character and p.character.input_source is LocalInputSource:
			(p.character.input_source as LocalInputSource).enabled = on


func _resume() -> void:
	_set_input(true)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	resumed.emit()
	queue_free()


func _respawn() -> void:
	for p in UltraNet.local_players:
		if p.character and UltraNet.is_server():
			UltraNet.respawn_character(p.character)
		elif p.character and p.character.input_source is LocalInputSource:
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
	r.closed.connect(func() -> void: visible = true)


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed(UltraInput.action(&"pause")):
		_resume()
		get_viewport().set_input_as_handled()
