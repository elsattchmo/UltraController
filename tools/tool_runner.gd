extends Node
## Runs a tool script with the project's autoloads available (a plain `--script` SceneTree
## script can't see autoloads). Usage:
##   godot --headless --path . res://tools/tool_runner.tscn -- --tool=res://tools/build_items.gd
## The tool is a Node script; it does its work in _ready() and the runner quits afterwards.


func _ready() -> void:
	var path := UltraArgs.get_str("tool", "")
	if path == "":
		push_error("tool_runner: pass --tool=res://path/to/tool.gd")
		get_tree().quit(2)
		return
	var tool: Node = (load(path) as Script).new()
	add_child(tool)
	await get_tree().process_frame
	get_tree().quit(0)
