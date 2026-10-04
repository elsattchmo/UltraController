extends UltraTour
## UI review: pause menu, controls/rebinding screen, inventory window, HUD.
func _build() -> void:
	out_dir = out_dir.replace("/m1", "/ui")
	steps = [
		{"teleport": "range", "t": 1.0, "slot": 1},
		{"call": func() -> void: _open_controls(), "t": 0.6, "shot": "01_controls"},
	]


func _open_controls() -> void:
	var r := UltraRebindMenu.new()
	main.add_child(r)
