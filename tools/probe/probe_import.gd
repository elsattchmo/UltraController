extends SceneTree
# Throwaway probe: dumps the imported mannequin structure.
func _init() -> void:
	var ps: PackedScene = load("res://assets/characters/mannequin/mannequin.glb")
	var root := ps.instantiate()
	_dump(root, 0)
	for sk in root.find_children("*", "Skeleton3D", true, false):
		var s := sk as Skeleton3D
		print("SKELETON ", s.get_path(), " bones=", s.get_bone_count(), " motion_scale=", s.motion_scale)
		for i in s.get_bone_count():
			var r := s.get_bone_rest(i)
			print("  bone %d %s parent=%d rest_o=%s" % [i, s.get_bone_name(i), s.get_bone_parent(i), r.origin])
	for ap in root.find_children("*", "AnimationPlayer", true, false):
		var p := ap as AnimationPlayer
		var names := p.get_animation_list()
		print("ANIMPLAYER ", p.get_path(), " clips=", names.size())
		for n in names:
			var a := p.get_animation(n)
			if n.ends_with("_RM") or n in ["Walk", "Idle_A", "Jog", "Sprint"]:
				print("  clip ", n, " len=", a.length, " tracks=", a.get_track_count(), " loop=", a.loop_mode)
				for t in a.get_track_count():
					var path := str(a.track_get_path(t))
					if path.ends_with(":root") or path.ends_with(":Root") or path.ends_with(":pelvis") or path.ends_with(":Hips"):
						print("    track ", t, " ", path, " type=", a.track_get_type(t), " keys=", a.track_get_key_count(t))
						if a.track_get_type(t) == Animation.TYPE_POSITION_3D and a.track_get_key_count(t) > 0:
							print("      first=", a.track_get_key_value(t, 0), " last=", a.track_get_key_value(t, a.track_get_key_count(t) - 1))
	quit()

func _dump(n: Node, d: int) -> void:
	var extra := ""
	if n is MeshInstance3D:
		extra = " mesh=%s skin=%s skel=%s" % [(n as MeshInstance3D).mesh, (n as MeshInstance3D).skin, (n as MeshInstance3D).skeleton]
	print("  ".repeat(d), n.name, " <", n.get_class(), ">", extra)
	if d < 4:
		for c in n.get_children():
			_dump(c, d + 1)
