extends RefCounted
## Shared look + focus helpers for the menus (main, pause, controls, inventory). Gamepad and
## keyboard users steer by focus, so the focused control gets a thick amber outline that
## reads at a glance on any background. Use: `const MenuStyle := preload(".../menu_style.gd")`.

const ACCENT := Color(1.0, 0.76, 0.22)
## Menus that take over input (pause, controls, main menu) join this group; HUDs and
## split-screen join/leave stay out of the way while one is open.
const MODAL_GROUP := &"ultra_modal"
const HUD_GROUP := &"ultra_hud"

static var _theme: Theme


static func theme() -> Theme:
	if _theme:
		return _theme
	var t := Theme.new()
	var normal := _box(Color(0.16, 0.18, 0.22, 0.95), Color(0.3, 0.33, 0.4), 1)
	var hover := _box(Color(0.22, 0.25, 0.31, 0.98), Color(0.45, 0.5, 0.6), 1)
	var pressed := _box(Color(0.32, 0.27, 0.14, 1.0), ACCENT, 2)
	var focus := focus_box()
	for type in ["Button", "CheckBox", "OptionButton"]:
		# A ticked CheckBox is "pressed": keep it plain (the tick shows the state) so only
		# focus is ever amber.
		var down := normal if type == "CheckBox" else pressed
		t.set_stylebox("normal", type, normal)
		t.set_stylebox("hover", type, hover)
		t.set_stylebox("pressed", type, down)
		t.set_stylebox("hover_pressed", type, hover if type == "CheckBox" else pressed)
		t.set_stylebox("focus", type, focus)
		t.set_color("font_focus_color", type, Color(1, 0.93, 0.75))
		t.set_color("font_hover_color", type, Color.WHITE)
	t.set_stylebox("focus", "LineEdit", focus)
	t.set_stylebox("focus", "HSlider", focus)
	t.set_stylebox("focus", "ScrollContainer", StyleBoxEmpty.new())
	var panel := _box(Color(0.09, 0.1, 0.13, 0.96), Color(0.3, 0.33, 0.4), 1)
	panel.set_content_margin_all(14)
	t.set_stylebox("panel", "PanelContainer", panel)
	_theme = t
	return t


static func focus_box() -> StyleBoxFlat:
	var f := StyleBoxFlat.new()
	f.draw_center = true
	f.bg_color = Color(ACCENT, 0.16)
	f.border_color = ACCENT
	f.set_border_width_all(3)
	f.set_corner_radius_all(4)
	f.set_expand_margin_all(2)
	return f


static func _box(bg: Color, border: Color, w: int) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = bg
	b.border_color = border
	b.set_border_width_all(w)
	b.set_corner_radius_all(4)
	b.content_margin_left = 12
	b.content_margin_right = 12
	b.content_margin_top = 6
	b.content_margin_bottom = 6
	return b


## First visible, focusable control under `root` (depth first), or null.
static func first_focusable(root: Node) -> Control:
	for c in root.get_children():
		if c is Control and not (c as Control).is_visible_in_tree():
			continue
		if c is Control and (c as Control).focus_mode == Control.FOCUS_ALL and (c is BaseButton or c is Range or c is LineEdit):
			return c
		var deeper := first_focusable(c)
		if deeper:
			return deeper
	return null


## Give focus to `prefer` (if usable) or the first focusable control under `root`. Deferred a
## frame so freshly built containers have their layout (and are visible) first.
static func focus_first(root: Node, prefer: Control = null) -> void:
	await root.get_tree().process_frame
	if not is_instance_valid(root):
		return
	var c: Control = prefer if is_instance_valid(prefer) and prefer.is_visible_in_tree() else first_focusable(root)
	if c:
		c.grab_focus()


static func modal_open(tree: SceneTree) -> bool:
	return tree != null and tree.get_first_node_in_group(MODAL_GROUP) != null
