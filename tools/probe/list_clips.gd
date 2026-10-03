extends SceneTree
func _init() -> void:
	var lib: AnimationLibrary = load("res://assets/characters/mannequin/anims/ual.res")
	var out := []
	for n in lib.get_animation_list():
		out.append("%s:%.2f%s" % [n, lib.get_animation(n).length, "L" if lib.get_animation(n).loop_mode else ""])
	print(", ".join(out))
	quit()
