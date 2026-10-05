class_name UltraHUD
extends CanvasLayer
## Per-player HUD: crosshair + hit marker, interaction prompt, ammo, health, hotbar, short
## messages, and the inventory window (Tab / pad Back). Mouse: drag to move, right-click to
## drop, double-click to use or equip. Keyboard / pad: D-pad, stick or arrows move the
## selection, accept uses / equips, inv_drop drops, inv_move picks up and puts down, cancel
## closes. Only the devices this player claims drive it (split-screen panes share input).
## Glyph hints follow the player's last-used device. Optional; host projects can replace it.

const MenuStyle := preload("res://addons/ultra_controller/ui/menu_style.gd")
const INV_COLUMNS := 6

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
var _inv_hint: Label
var _sel := 0                  ## selected inventory slot (keyboard / pad)
var _carry := -1               ## slot picked up with inv_move, -1 = none
var _axis_down := {}           ## "device:axis" -> direction held past the threshold (stick edges)
var _sel_style: StyleBoxFlat
var _carry_style: StyleBoxFlat


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


## World events are hooked while in the tree (split screen reparents the HUD into a pane, so
## this runs again) and unhooked on the way out, so a freed HUD never lingers in the handlers.
func _enter_tree() -> void:
	add_to_group(MenuStyle.HUD_GROUP)
	for e in _events():
		UltraNet.world.off_event(e[0], e[1])
		UltraNet.world.on_event(e[0], e[1])


func _exit_tree() -> void:
	for e in _events():
		UltraNet.world.off_event(e[0], e[1])


func _events() -> Array:
	return [[&"hit", _on_hit], [&"pickup", _on_pickup], [&"pickup_failed", _on_pickup_failed], [&"locked", _on_locked]]


func _has_character() -> bool:
	return character != null and is_instance_valid(character) and not character.is_queued_for_deletion()


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
	var eq := character.get_node_or_null("Equipment") as UltraEquipmentVisual if _has_character() else null
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
	if not _has_character():
		if _inv_panel.visible:
			_inv_panel.visible = false
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
	if _inv_panel.visible:
		if _inv_rev != character.inventory.revision:
			_refresh_inventory()
		_inv_hint.text = _inventory_hint()


## Name of the binding for a semantic uc_* action (or a raw Input Map action such as ui_accept
## with `raw`) on the device this player used last.
func _key_hint(action: StringName, raw := false) -> String:
	var src := character.input_source as LocalInputSource if _has_character() else null
	var pad := src != null and src.active_device.begins_with("joy")
	var act := action if raw else UltraInput.action(action)
	if not InputMap.has_action(act):
		return String(action)
	for e in InputMap.action_get_events(act):
		if pad and (e is InputEventJoypadButton):
			return _pad_name((e as InputEventJoypadButton).button_index, UltraInput.glyph_family(src.active_device))
		if pad and e is InputEventJoypadMotion and not raw:
			continue
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
	if _has_character() and attacker_id == character.net_id:
		_hit_t = 0.25


func _on_pickup(who: int, item: String, n: int) -> void:
	if _has_character() and who == character.net_id:
		var def := ItemDB.get_def(StringName(item))
		show_message("+%d %s" % [n, def.display_name if def else item])


func _on_pickup_failed(who: int, why: String) -> void:
	if _has_character() and who == character.net_id:
		show_message(why)


func _on_locked(who: int, text: String) -> void:
	if _has_character() and who == character.net_id:
		show_message(text)


# ------------------------------------------------------------------ inventory window

func _build_inventory() -> void:
	# Centred by a container (not by offsets), so it stays in the middle of whatever pane the
	# HUD ends up in after split-screen reparenting.
	var center := CenterContainer.new()
	center.name = "InventoryCenter"
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)
	_inv_panel = PanelContainer.new()
	_inv_panel.visible = false
	_inv_panel.theme = MenuStyle.theme()
	center.add_child(_inv_panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	_inv_panel.add_child(v)
	var title := Label.new()
	title.name = "Title"
	title.text = "Inventory"
	title.add_theme_font_size_override("font_size", 22)
	v.add_child(title)
	_inv_grid = GridContainer.new()
	_inv_grid.columns = INV_COLUMNS
	v.add_child(_inv_grid)
	_inv_hint = Label.new()
	_inv_hint.add_theme_font_size_override("font_size", 13)
	_inv_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_inv_hint.custom_minimum_size = Vector2(300, 0)
	v.add_child(_inv_hint)
	_sel_style = MenuStyle.focus_box()
	_sel_style.bg_color = Color(MenuStyle.ACCENT, 0.3)
	_carry_style = MenuStyle.focus_box()
	_carry_style.border_color = Color(0.4, 0.8, 1.0)
	_carry_style.bg_color = Color(0.4, 0.8, 1.0, 0.3)


func is_inventory_open() -> bool:
	return _inv_panel.visible


func open_inventory() -> void:
	if not _has_character() or _inv_panel.visible:
		return
	_inv_panel.visible = true
	_carry = -1
	_drag_from = -1
	var src := character.input_source as LocalInputSource
	if src:
		src.enabled = false
		# Start on what's in hand (or the first slot).
		_sel = clampi(src.want_slot - 1, 0, character.inventory.size() - 1) if src.want_slot > 0 else 0
		if src.claims("kbm"):
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_refresh_inventory()


func close_inventory() -> void:
	if not _inv_panel.visible:
		return
	_inv_panel.visible = false
	_carry = -1
	_drag_from = -1
	if not _has_character():
		return
	var src := character.input_source as LocalInputSource
	if src:
		src.enabled = true
		if src.claims("kbm") and not MenuStyle.modal_open(get_tree()):
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Inventory keys / buttons. `_input` (not `_unhandled_input`) so a focused control elsewhere
## can't swallow Tab as focus-next and leave the window stuck open.
func _input(event: InputEvent) -> void:
	if not _has_character() or not (character.input_source is LocalInputSource):
		return
	var dev := UltraInput.device_of(event)
	if dev == "" or event is InputEventMouseMotion:
		return
	if MenuStyle.modal_open(get_tree()):
		return
	var src := character.input_source as LocalInputSource
	if not src.claims(dev):
		return
	if event.is_action_pressed(UltraInput.action(&"inventory")):
		if _inv_panel.visible:
			close_inventory()
		else:
			open_inventory()
		get_viewport().set_input_as_handled()
		return
	if not _inv_panel.visible:
		return
	if event.is_action_pressed(UltraInput.action(&"pause")):
		close_inventory()            # not handled: the pause menu opens on the same press
		return
	if event is InputEventMouseButton:
		return                       # slots handle their own clicks
	var handled := true
	var fresh := _stick_edge(event, dev)
	if _nav_pressed(event, fresh, &"ui_left"):
		_move_sel(-1, 0)
	elif _nav_pressed(event, fresh, &"ui_right"):
		_move_sel(1, 0)
	elif _nav_pressed(event, fresh, &"ui_up"):
		_move_sel(0, -1)
	elif _nav_pressed(event, fresh, &"ui_down"):
		_move_sel(0, 1)
	elif event.is_action_pressed(&"ui_accept"):
		_activate(_sel)
	elif event.is_action_pressed(UltraInput.action(&"inv_drop")):
		_drop(_sel)
	elif event.is_action_pressed(UltraInput.action(&"inv_move")):
		if _carry < 0:
			_carry = _sel if character.inventory.get_slot(_sel) else -1
		else:
			if _carry != _sel:
				UltraNet.request_inventory(character.net_id, "move", [_carry, _sel])
			_carry = -1
		_restyle()
	elif event.is_action_pressed(&"ui_cancel"):
		if _carry >= 0:
			_carry = -1
			_restyle()
		else:
			close_inventory()
	else:
		# Everything else from this player's devices stays in the window (releases included),
		# so nothing reaches the game behind it.
		handled = event is InputEventJoypadButton or event is InputEventJoypadMotion or event is InputEventKey
	if handled:
		get_viewport().set_input_as_handled()


## Is this stick reading a new push past the threshold? (Every reading past it counts as
## "pressed", so a stick held over would otherwise race across the grid.)
func _stick_edge(event: InputEvent, dev: String) -> bool:
	if not (event is InputEventJoypadMotion):
		return true
	var m := event as InputEventJoypadMotion
	var key := "%s:%d" % [dev, m.axis]
	var dir := int(signf(m.axis_value)) if absf(m.axis_value) >= 0.5 else 0
	var was: int = _axis_down.get(key, 0)
	_axis_down[key] = dir
	return dir != 0 and dir != was


## A direction press: keys / D-pad by action (keys repeat while held), sticks once per push.
func _nav_pressed(event: InputEvent, fresh: bool, act: StringName) -> bool:
	if event is InputEventJoypadMotion:
		return fresh and event.is_action_pressed(act)
	return event.is_action_pressed(act, true)


func _move_sel(dx: int, dy: int) -> void:
	var n := character.inventory.size()
	var rows := ceili(float(n) / INV_COLUMNS)
	var x := clampi(_sel % INV_COLUMNS + dx, 0, INV_COLUMNS - 1)
	var y := clampi(_sel / INV_COLUMNS + dy, 0, rows - 1)
	_sel = clampi(y * INV_COLUMNS + x, 0, n - 1)
	_restyle()


## Accept on a slot: consumables are used; anything holdable goes to the hotbar (if it isn't
## there already) and into the hands; accepting what's in hand puts it away.
func _activate(i: int) -> void:
	var inv := character.inventory
	var it := inv.get_slot(i)
	var src := character.input_source as LocalInputSource
	if it == null or it.def() == null:
		return
	var def := it.def()
	if def.kind == ItemDefinition.Kind.CONSUMABLE:
		UltraNet.request_inventory(character.net_id, "use", [i])
		return
	if def.kind == ItemDefinition.Kind.AMMO or src == null:
		return
	var slot := i
	if i >= Inventory.HOTBAR:
		slot = -1
		for h in Inventory.HOTBAR:
			if inv.get_slot(h) == null:
				slot = h
				break
		if slot < 0:
			slot = maxi(src.want_slot - 1, 0)
		UltraNet.request_inventory(character.net_id, "move", [i, slot])
		_sel = slot
	src.want_slot = 0 if src.want_slot == slot + 1 else slot + 1
	_restyle()


## Drop a slot into the world; what's in hand is holstered first (the server refuses to drop it).
func _drop(i: int) -> void:
	var it := character.inventory.get_slot(i) if i >= 0 else null
	if it == null:
		return
	var src := character.input_source as LocalInputSource
	if it.uid == character.state.held_uid and src:
		src.want_slot = 0
		var c := character
		get_tree().create_timer(0.35).timeout.connect(func() -> void:
			if is_instance_valid(c):
				UltraNet.request_inventory(c.net_id, "drop", [i]))
	else:
		UltraNet.request_inventory(character.net_id, "drop", [i])


func _inventory_hint() -> String:
	var src := character.input_source as LocalInputSource
	if src and src.active_device.begins_with("joy"):
		return "%s use / equip   •   %s drop   •   %s %s   •   %s close   •   first row = hotbar" % [
			_key_hint(&"ui_accept", true), _key_hint(&"inv_drop"), _key_hint(&"inv_move"),
			"put down" if _carry >= 0 else "move", _key_hint(&"ui_cancel", true)]
	return "drag to move • right-click drop • double-click use / equip • arrows + %s, %s drop, %s move • %s close • first row = hotbar" % [
		_key_hint(&"ui_accept", true), _key_hint(&"inv_drop"), _key_hint(&"inv_move"), _key_hint(&"inventory")]


func _unhandled_input(event: InputEvent) -> void:
	if not _has_character() or not (character.input_source is LocalInputSource) or _inv_panel.visible:
		return
	var src := character.input_source as LocalInputSource
	var dev := UltraInput.device_of(event)
	if dev == "" or not src.claims(dev) or not src.enabled or MenuStyle.modal_open(get_tree()):
		return
	if event.is_action_pressed(UltraInput.action(&"drop")) and character.state.held_uid != 0:
		# Drop what's in hand: holster first, then drop that slot.
		_drop(character.inventory.find_uid(character.state.held_uid))


func _refresh_inventory() -> void:
	if not _has_character():
		return
	_inv_rev = character.inventory.revision
	for c in _inv_grid.get_children():
		_inv_grid.remove_child(c)
		c.queue_free()
	var inv := character.inventory
	_sel = clampi(_sel, 0, maxi(inv.size() - 1, 0))
	(_inv_panel.get_child(0).get_node("Title") as Label).text = "Inventory   %.1f / %.0f kg" % [inv.total_mass(), inv.capacity_kg]
	# Slots shrink to fit narrow split-screen panes.
	var pane := _root.size if _root.size.x > 10.0 else Vector2(1280, 720)
	var w := clampf((pane.x - 90.0) / INV_COLUMNS - 4.0, 56.0, 102.0)
	var h := clampf(minf(w * 0.72, (pane.y - 200.0) / ceilf(float(inv.size()) / INV_COLUMNS) - 4.0), 30.0, 74.0)
	for i in inv.size():
		var b := Button.new()
		b.custom_minimum_size = Vector2(w, h)
		b.focus_mode = Control.FOCUS_NONE          # selection is ours: per player, per device
		b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		b.clip_text = true
		b.add_theme_font_size_override("font_size", 14 if w >= 90.0 else 11)
		var it := inv.get_slot(i)
		b.text = ("%s%s" % [it.def().display_name if it.def() else it.def_id, ("\n×%d" % it.count) if it.count > 1 else ""]) if it else ("%d" % (i + 1) if i < Inventory.HOTBAR else "")
		b.modulate = Color(1, 0.9, 0.6) if i < Inventory.HOTBAR else Color.WHITE
		var idx := i
		b.gui_input.connect(func(e: InputEvent) -> void: _slot_input(idx, e))
		_inv_grid.add_child(b)
	_restyle()


func _restyle() -> void:
	for i in _inv_grid.get_child_count():
		var b := _inv_grid.get_child(i) as Button
		b.remove_theme_stylebox_override("normal")
		b.remove_theme_stylebox_override("hover")
		if i == _carry:
			b.add_theme_stylebox_override("normal", _carry_style)
			b.add_theme_stylebox_override("hover", _carry_style)
		elif i == _sel:
			b.add_theme_stylebox_override("normal", _sel_style)
			b.add_theme_stylebox_override("hover", _sel_style)


func _slot_input(i: int, e: InputEvent) -> void:
	if not _has_character() or not (e is InputEventMouseButton):
		return
	var mb := e as InputEventMouseButton
	if not mb.pressed:
		if mb.button_index == MOUSE_BUTTON_LEFT and _drag_from >= 0 and _drag_from != i:
			UltraNet.request_inventory(character.net_id, "move", [_drag_from, i])
		_drag_from = -1
		return
	_sel = i
	_restyle()
	if mb.button_index == MOUSE_BUTTON_LEFT:
		if mb.double_click:
			_activate(i)
		else:
			_drag_from = i
	elif mb.button_index == MOUSE_BUTTON_RIGHT:
		_drop(i)
