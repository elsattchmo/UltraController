extends SceneTree
## Take UltraImportTools.PURGED out of the saved mannequin library (ual.res) without re-importing the model.
##   godot --headless --path . --script res://tools/purge_clips.gd

const LIB := "res://assets/characters/mannequin/anims/ual.res"


func _init() -> void:
	var lib := load(LIB) as AnimationLibrary
	var n := 0
	for name in UltraImportTools.PURGED:
		if lib.has_animation(name):
			lib.remove_animation(name)
			n += 1
	var err := ResourceSaver.save(lib, LIB)
	print("purge_clips: removed %d, %d left in %s (err %d)" % [n, lib.get_animation_list().size(), LIB, err])
	quit()
