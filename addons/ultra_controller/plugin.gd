@tool
extends EditorPlugin
## Registers project settings (shown under Project Settings > General > ultra_controller),
## seeds missing uc_* actions into the Input Map, and adds the Project > Tools > Ultra menu.

const MENU := "Ultra"

var _menu: PopupMenu


func _enable_plugin() -> void:
	UltraInputDefaults.install_missing(true)
	UltraInputSettings.register(true)


func _enter_tree() -> void:
	UltraInputSettings.register(false)
	_menu = PopupMenu.new()
	_menu.add_item("Seed missing input actions", 0)
	_menu.add_item("Reset player rebinds (user://)", 1)
	_menu.id_pressed.connect(_on_menu)
	add_tool_submenu_item(MENU, _menu)


func _exit_tree() -> void:
	remove_tool_menu_item(MENU)


func _on_menu(id: int) -> void:
	match id:
		0:
			var n := UltraInputDefaults.install_missing(true)
			print("UltraController: added %d missing input actions" % n)
		1:
			UltraInput.reset_user_rebinds()
