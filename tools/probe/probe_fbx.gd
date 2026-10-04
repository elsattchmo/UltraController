extends SceneTree
func _init() -> void:
	var n: Node = (load("res://intake/mixamo/Mixamo_Jog_loop.fbx") as PackedScene).instantiate()
	for sk in n.find_children("*", "Skeleton3D", true, false):
		var s := sk as Skeleton3D
		var names := []
		for i in mini(s.get_bone_count(), 12): names.append(s.get_bone_name(i))
		print("skel ", s.name, " bones ", s.get_bone_count(), " ", names)
	for ap in n.find_children("*", "AnimationPlayer", true, false):
		var p := ap as AnimationPlayer
		for a in p.get_animation_list():
			var an := p.get_animation(a)
			print("anim ", a, " len ", an.length, " tracks ", an.get_track_count(), " first ", an.track_get_path(0) if an.get_track_count() else "")
	quit()
