extends SceneTree
func _init() -> void:
	var d := DirAccess.open("res://assets/characters/mannequin/rootmotion")
	for f in d.get_files():
		if not f.ends_with(".tres"): continue
		var c: RootMotionCurve = load("res://assets/characters/mannequin/rootmotion/" + f)
		print("%-24s len=%.3f total=%s ext=%s yawEnd=%.1f" % [f, c.length, c.total(), c.extent().size, rad_to_deg(c.sample_yaw(c.length))])
	var ps: PackedScene = load("res://assets/characters/mannequin/mannequin.glb")
	var root := ps.instantiate()
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var m := (mi as MeshInstance3D).mesh
		print(mi.name, " surfaces=", m.get_surface_count(), " tris=", (m.surface_get_arrays(0)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3, " custom0=", (m.surface_get_arrays(0)[Mesh.ARRAY_CUSTOM0]).size() if m.surface_get_arrays(0)[Mesh.ARRAY_CUSTOM0] != null else -1)
	var lib: AnimationLibrary = load("res://assets/characters/mannequin/anims/ual.res")
	print("lib clips=", lib.get_animation_list().size(), " Walk loop=", lib.get_animation(&"Walk").loop_mode, " Roll_RM loop=", lib.get_animation(&"Roll_RM").loop_mode, " Walk tracks=", lib.get_animation(&"Walk").get_track_count())
	var turns := []
	for n in lib.get_animation_list():
		if String(n).begins_with("Turn") or String(n).begins_with("Idle") or String(n).begins_with("Walk") or String(n).begins_with("Jog") or String(n).begins_with("Sprint") or String(n).begins_with("Strafe") or String(n).begins_with("Crouch") or String(n).begins_with("Jump") or String(n).begins_with("Land"):
			turns.append("%s(%.2f)" % [n, lib.get_animation(n).length])
	print(turns)
	quit()
