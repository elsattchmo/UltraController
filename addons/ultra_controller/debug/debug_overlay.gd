class_name UltraDebugOverlay
extends CanvasLayer
## F1 overlay: motor state, speeds, stance, input, timing. Lines can be added by any system
## through `UltraDebugOverlay.watch(key, callable)`.

static var _watches := {}

var character: UltraCharacter
var _label: Label
var _visible := false


static func watch(key: String, getter: Callable) -> void:
	_watches[key] = getter


func _ready() -> void:
	layer = 50
	_label = Label.new()
	_label.position = Vector2(12, 12)
	_label.add_theme_font_size_override("font_size", 15)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 5)
	add_child(_label)
	_label.visible = _visible


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(UltraInput.action(&"debug_overlay")):
		_visible = not _visible
		_label.visible = _visible


func _process(_delta: float) -> void:
	if not _visible or character == null:
		return
	var s := character.state
	var hv := Vector3(s.vel.x, 0, s.vel.z)
	var lines := PackedStringArray()
	lines.append("FPS %d   tick %d   %s" % [Engine.get_frames_per_second(), character.tick, "TP" if character.last_input.has(InputFrame.B_VIEW_TP) else "FP"])
	lines.append("state %s (%.2fs)   stance %s   %s" % [MotorState.Id.keys()[s.state], s.state_time, MotorState.Stance.keys()[s.stance], "GROUND" if s.is_grounded() else "AIR %.2fs" % s.air_time])
	lines.append("speed %.2f m/s   vy %.2f   height %.2f" % [hv.length(), s.vel.y, s.height])
	lines.append("pos %s   yaw %.0f°" % [s.pos.snappedf(0.01), rad_to_deg(s.body_yaw)])
	lines.append("input move %s  buttons %x" % [character.last_input.move.snappedf(0.01), character.last_input.buttons])
	if character.input_source is LocalInputSource:
		lines.append("device %s" % (character.input_source as LocalInputSource).active_device)
	for k: String in _watches:
		var g: Callable = _watches[k]
		if g.is_valid():
			lines.append("%s: %s" % [k, g.call()])
	_label.text = "\n".join(lines)
