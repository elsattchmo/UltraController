@tool
extends EditorPlugin
## Registers project settings (shown under Project Settings > General > ultra_controller),
## seeds missing uc_* actions into the Input Map, and adds the Project > Tools > Ultra menu.

const MENU := "Ultra"

var _menu: PopupMenu


func _enable_plugin() -> void:
	add_autoload_singleton("UltraNet", "res://addons/ultra_controller/net/ultra_net.gd")
	UltraInputDefaults.install_missing(true)
	UltraInputSettings.register(true)


func _disable_plugin() -> void:
	remove_autoload_singleton("UltraNet")


func _enter_tree() -> void:
	UltraInputSettings.register(false)
	_menu = PopupMenu.new()
	_menu.add_item("Seed missing input actions", 0)
	_menu.add_item("Reset player rebinds (user://)", 1)
	_menu.add_separator("Launch instances")
	var presets := UltraLauncher.presets()
	for i in presets.size():
		var p := presets[i]
		_menu.add_item(p.title if p.title != "" else p.resource_name, 100 + i)
	_menu.add_item("Kill all launched instances", 2)
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
		2:
			print("UltraController: closed %d instances" % UltraLauncher.kill_all())
		_:
			var presets := UltraLauncher.presets()
			if id >= 100 and id - 100 < presets.size():
				UltraLauncher.launch(presets[id - 100])
