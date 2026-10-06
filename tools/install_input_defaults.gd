extends SceneTree
## Adds any new default input actions (UltraInputDefaults.ACTIONS) to project.godot - what the editor
## plugin does when it loads. For a headless checkout after adding an action:
##   godot --headless --path . --script res://tools/install_input_defaults.gd
func _initialize() -> void:
	print("input actions added: ", UltraInputDefaults.install_missing(true))
	quit()
