class_name ZombieHud
extends CanvasLayer
## The sandbox's numbers: zombies alive / hunting and the kill count top right, the keys bottom left.

var sandbox: MansionSandbox
var _label: Label
var _hint: Label
var _flash := 0.0
var _flash_text := ""


func _ready() -> void:
	layer = 12
	_label = Label.new()
	_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_label.offset_left = -330.0
	_label.offset_top = 14.0
	_label.offset_right = -16.0
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_label.add_theme_font_size_override("font_size", 20)
	_label.add_theme_color_override("font_color", Color(0.92, 0.88, 0.8))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_label.add_theme_constant_override("outline_size", 6)
	add_child(_label)
	_hint = Label.new()
	_hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_hint.offset_left = 16.0
	_hint.offset_top = -108.0
	_hint.offset_bottom = -84.0
	_hint.text = "F11 wave  ·  F12 reset  ·  F10 AI debug   (buttons in the foyer)"
	_hint.add_theme_font_size_override("font_size", 14)
	_hint.add_theme_color_override("font_color", Color(0.75, 0.72, 0.65, 0.8))
	_hint.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_hint.add_theme_constant_override("outline_size", 4)
	add_child(_hint)
	if sandbox:
		sandbox.wave_started.connect(func(woke: int, arrivals: int) -> void:
			_flash = 3.0
			_flash_text = "WAVE  %d woke, %d coming in" % [woke, arrivals])
		sandbox.reset_done.connect(func() -> void:
			_flash = 2.0
			_flash_text = "RESET")


func _process(delta: float) -> void:
	if sandbox == null or sandbox.director == null:
		return
	_flash = maxf(_flash - delta, 0.0)
	var text := "ZOMBIES  %d alive  ·  %d hunting\nKILLS  %d" % [sandbox.alive(), sandbox.hunting(), sandbox.kills]
	if _flash > 0.0:
		text += "\n" + _flash_text
	_label.text = text
