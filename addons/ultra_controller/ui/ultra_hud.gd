class_name UltraHUD
extends CanvasLayer
## Per-player HUD: crosshair + hit marker, interaction prompt, ammo, health, hotbar, short
## messages, and the Tab inventory (drag to move, right-click to drop, double-click to use).
## Glyph hints follow the player's last-used device. Optional; host projects can replace it.

var character: UltraCharacter
var scanner: UltraInteractionScanner

var _root: Control
var _cross: Control
var _prompt: Label
var _ammo: Label
var _health: ProgressBar
var _breath: ProgressBar
var _msg: Label
var _hotbar: HBoxContainer
var _laid_out_for := Vector2.ZERO
var _inv_panel: PanelContainer
var _inv_grid: GridContainer
var _hit_t := 0.0
var _msg_t := 0.0
var _drag_from := -1
var _inv_rev := -1


func _ready() -> void:
	layer = 10
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	_cross = Control.new()
	_cross.set_anchors_preset(Control.PRESET_CENTER)
	_cross.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cross.draw.connect(_draw_cross)
	_root.add_child(_cross)
	_prompt = _label(_root, 22, Control.PRESET_CENTER, Vector2(-300, 40), Vector2(600, 40))
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_ammo = _label(_root, 28, Control.PRESET_BOTTOM_RIGHT, Vector2(-260, -110), Vector2(240, 40))
	_ammo.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_msg = _label(_root, 20, Control.PRESET_CENTER_TOP, Vector2(-300, 80), Vector2(600, 30))
	_msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_health = ProgressBar.new()
	_health.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_health.position = Vector2(24, -64)
	_health.size = Vector2(260, 22)
	_health.max_value = 100
	_health.show_percentage = false
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.85, 0.2, 0.2)
	fill.set_corner_radius_all(3)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0, 0, 0, 0.45)
	bg.set_corner_radius_all(3)
	_health.add_theme_stylebox_override("fill", fill)
	_health.add_theme_stylebox_override("background", bg)
	_root.add_child(_health)
	# Air: appears under water and while it refills.
	_breath = ProgressBar.new()
	_breath.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_breath.position = Vector2(24, -90)
	_breath.size = Vector2(260, 12)
	_breath.show_percentage = false
	var bfill := StyleBoxFlat.new()
	bfill.bg_color = Color(0.45, 0.8, 1.0)
	bfill.set_corner_radius_all(3)
	_breath.add_theme_stylebox_override("fill", bfill)
	_breath.add_theme_stylebox_override("background", bg)
	_breath.visible = false
	_root.add_child(_breath)
	_hotbar = HBoxContainer.new()
	_hotbar.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_hotbar.position = Vector2(-9 * 37, -64)
	_hotbar.add_theme_constant_override("separation", 4)
	_root.add_child(_hotbar)
	for i in Inventory.HOTBAR:
		var p := Panel.new()
		p.custom_minimum_size = Vector2(70, 50)
		var l := Label.new()
		l.add_theme_font_size_override("font_size", 12)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD
		l.size = Vector2(70, 50)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		p.add_child(l)
		_hotbar.add_child(p)
	_build_inventory()
	UltraNet.world.on_event(&"hit", _on_hit)
	UltraNet.world.on_event(&"pickup", _on_pickup)
	UltraNet.world.on_event(&"pickup_failed", _on_pickup_failed)
	UltraNet.world.on_event(&"locked", _on_locked)


func _label(parent: Control, size: int, preset: int, pos: Vector2, sz: Vector2) -> Label:
	var l := Label.new()
	l.set_anchors_preset(preset)
	l.position = pos
	l.size = sz
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 6)
	parent.add_child(l)
	return l


func _draw_cross() -> void:
	var ads := 0.0
	var eq := character.get_node_or_null("Equipment") as UltraEquipmentVisual if character else null
	if eq:
		ads = eq.ads
	var gap := lerpf(7.0, 2.0, ads)
	var len := lerpf(9.0, 0.0, ads)
	var c := Color(1, 1, 1, 0.85)
	_cross.draw_circle(Vector2.ZERO, 1.6, c)
	if len > 0.5:
		for d: Vector2 in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
			_cross.draw_line(d * gap, d * (gap + len), c, 2.0)
	if _hit_t > 0.0:
		var hc := Color(1, 0.2, 0.2, _hit_t / 0.25)
		for d: Vector2 in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
			_cross.draw_line(d.normalized() * 8.0, d.normalized() * 16.0, hc, 2.5)


## Fit the bottom bar to the pane: narrow split-screen panes shrink the hotbar slots and lift
## the health / air bars above it instead of letting them overlap.
func _layout() -> void:
	var sz := _root.size
	if sz == _laid_out_for or sz.x < 10.0:
		return
	_laid_out_for = sz
	var n := Inventory.HOTBAR
	var gap := 4.0
	var slot := clampf((sz.x - 32.0 - gap * (n - 1)) / n, 36.0, 70.0)
	var slot_h := clampf(slot * 0.72, 32.0, 50.0)
	var bar_w := slot * n + gap * (n - 1)
	for i in n:
		var p := _hotbar.get_child(i) as Panel
		p.custom_minimum_size = Vector2(slot, slot_h)
		(p.get_child(0) as Label).size = Vector2(slot, slot_h)
		(p.get_child(0) as Label).add_theme_font_size_override("font_size", 12 if slot >= 60.0 else 10)
	_hotbar.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_hotbar.position = Vector2((sz.x - bar_w) * 0.5, sz.y - slot_h - 14.0)
	var health_w := minf(260.0, sz.x * 0.4)
	var lifted := (sz.x - bar_w) * 0.5 < 24.0 + health_w + 12.0
	var hy := _hotbar.position.y - 34.0 if lifted else sz.y - 58.0
	for c: Control in [_health, _breath]:
		c.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_health.position = Vector2(24.0 if not lifted else (sz.x - health_w) * 0.5, hy)
	_health.size = Vector2(health_w, 22)
	_breath.position = _health.position + Vector2(0, -16)
	_breath.size = Vector2(health_w, 12)


func _process(delta: float) -> void:
	if character == null or not is_instance_valid(character):
		return
	_layout()
	var s := character.state
	var fp := character.is_first_person()
	_cross.visible = fp or s.equipped != 0
	_cross.queue_redraw()
	_hit_t = maxf(_hit_t - delta, 0.0)
	_msg_t = maxf(_msg_t - delta, 0.0)
	_msg.visible = _msg_t > 0.0
	_health.value = s.hp
	_breath.max_value = character.profile.breath_time
	_breath.value = s.breath
	_breath.visible = s.breath < character.profile.breath_time - 0.01
	_breath.modulate = Color(1, 0.35, 0.3) if s.breath < 5.0 else Color.WHITE
	var def := character.held_def()
	if def and def.kind == ItemDefinition.Kind.FIREARM:
		var reserve := character.inventory.count_of(StringName(def.stat("ammo", "")))
		var txt := "%d / %s" % [s.mag, "∞" if UltraActionLayer.infinite_ammo else str(reserve)]
		if s.action == UltraActionLayer.Action.RELOADING:
			txt = "reloading…  " + txt
		_ammo.text = txt
	else:
		_ammo.text = ""
	if scanner and scanner.focus and s.held_id == 0:
		_prompt.text = "[%s]  %s" % [_key_hint(&"interact"), scanner.focus.current_prompt(character)]
	else:
		_prompt.text = ""
	var src := character.input_source as LocalInputSource
	for i in Inventory.HOTBAR:
		var p := _hotbar.get_child(i) as Panel
		var it := character.inventory.get_slot(i)
		var l := p.get_child(0) as Label
		l.text = "%d\n%s%s" % [i + 1, it.def().display_name if it and it.def() else "", (" ×%d" % it.count) if it and it.count > 1 else ""]
		var selected := src != null and src.want_slot == i + 1
		p.self_modulate = Color(1, 0.85, 0.4) if selected else Color(1, 1, 1, 0.75)
	if _inv_panel.visible and _inv_rev != character.inventory.revision:
		_refresh_inventory()


func _key_hint(action: StringName) -> String:
	var src := character.input_source as LocalInputSource
	var pad := src != null and src.active_device.begins_with("joy")
	for e in InputMap.action_get_events(UltraInput.action(action)):
		if pad and (e is InputEventJoypadButton):
			return _pad_name((e as InputEventJoypadButton).button_index, UltraInput.glyph_family(src.active_device))
		if not pad and e is InputEventKey:
			var k := e as InputEventKey
			return OS.get_keycode_string(k.physical_keycode if k.physical_keycode != 0 else k.keycode)
		if not pad and e is InputEventMouseButton:
			return ["", "LMB", "RMB", "MMB"][clampi((e as InputEventMouseButton).button_index, 0, 3)]
	return String(action)


static func _pad_name(b: int, family: String) -> String:
	var xbox := ["A", "B", "X", "Y", "View", "Guide", "Menu", "LS", "RS", "LB", "RB", "Up", "Down", "Left", "Right"]
	var ps := ["Cross", "Circle", "Square", "Triangle", "Share", "PS", "Options", "L3", "R3", "L1", "R1", "Up", "Down", "Left", "Right"]
	var names := ps if family == "playstation" else xbox
	return names[b] if b < names.size() else "Btn%d" % b


func show_message(t: String, secs := 2.0) -> void:
	_msg.text = t
	_msg_t = secs


func _on_hit(_target_id: int, _pos: Vector3, _dir: Vector3, _amount: float, attacker_id: int, _region := -1, _kind := &"") -> void:
	if character and attacker_id == character.net_id:
		_hit_t = 0.25


func _on_pickup(who: int, item: String, n: int) -> void:
	if character and who == character.net_id:
		var def := ItemDB.get_def(StringName(item))
		show_message("+%d %s" % [n, def.display_name if def else item])


func _on_pickup_failed(who: int, why: String) -> void:
	if character and who == character.net_id:
		show_message(why)


func _on_locked(who: int, text: String) -> void:
	if character and who == character.net_id:
		show_message(text)


# ------------------------------------------------------------------ inventory window

func _build_inventory() -> void:
	_inv_panel = PanelContainer.new()
	_inv_panel.set_anchors_preset(Control.PRESET_CENTER)
	_inv_panel.position = Vector2(-330, -230)
	_inv_panel.custom_minimum_size = Vector2(660, 420)
	_inv_panel.visible = false
	_root.add_child(_inv_panel)
	var v := VBoxContainer.new()
	_inv_panel.add_child(v)
	var title := Label.new()
	title.name = "Title"
	title.text = "Inventory"
	title.add_theme_font_size_override("font_size", 22)
	v.add_child(title)
	_inv_grid = GridContainer.new()
	_inv_grid.columns = 6
	v.add_child(_inv_grid)
	var hint := Label.new()
	hint.text = "drag to move • right-click to drop • double-click to use • first row = hotbar"
	hint.add_theme_font_size_override("font_size", 13)
	v.add_child(hint)


func _unhandled_input(event: InputEvent) -> void:
	if character == null or not (character.input_source is LocalInputSource):
		return
	var src := character.input_source as LocalInputSource
	if UltraInput.device_of(event) != "" and not src.claims(UltraInput.device_of(event)):
		return
	if event.is_action_pressed(UltraInput.action(&"inventory")):
		_inv_panel.visible = not _inv_panel.visible
		src.enabled = not _inv_panel.visible
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if _inv_panel.visible else Input.MOUSE_MODE_CAPTURED
		_refresh_inventory()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(UltraInput.action(&"drop")) and not _inv_panel.visible and character.state.held_uid != 0:
		# Drop what's in hand: holster first, then drop that slot.
		var slot := character.inventory.find_uid(character.state.held_uid)
		src.want_slot = 0
		get_tree().create_timer(0.35).timeout.connect(func() -> void: UltraNet.request_inventory(character.net_id, "drop", [slot]))


func _refresh_inventory() -> void:
	_inv_rev = character.inventory.revision
	for c in _inv_grid.get_children():
		c.queue_free()
	var inv := character.inventory
	(_inv_panel.get_child(0).get_node("Title") as Label).text = "Inventory   %.1f / %.0f kg" % [inv.total_mass(), inv.capacity_kg]
	for i in inv.size():
		var b := Button.new()
		b.custom_minimum_size = Vector2(102, 74)
		var it := inv.get_slot(i)
		b.text = ("%s%s" % [it.def().display_name if it.def() else it.def_id, ("\n×%d" % it.count) if it.count > 1 else ""]) if it else ("%d" % (i + 1) if i < Inventory.HOTBAR else "")
		b.modulate = Color(1, 0.9, 0.6) if i < Inventory.HOTBAR else Color.WHITE
		var idx := i
		b.gui_input.connect(func(e: InputEvent) -> void: _slot_input(idx, e))
		_inv_grid.add_child(b)


func _slot_input(i: int, e: InputEvent) -> void:
	if not (e is InputEventMouseButton) or not e.pressed:
		if e is InputEventMouseButton and not e.pressed and e.button_index == MOUSE_BUTTON_LEFT and _drag_from >= 0 and _drag_from != i:
			UltraNet.request_inventory(character.net_id, "move", [_drag_from, i])
			_drag_from = -1
		return
	var mb := e as InputEventMouseButton
	if mb.button_index == MOUSE_BUTTON_LEFT:
		if mb.double_click:
			UltraNet.request_inventory(character.net_id, "use", [i])
		else:
			_drag_from = i
	elif mb.button_index == MOUSE_BUTTON_RIGHT:
		UltraNet.request_inventory(character.net_id, "drop", [i])
