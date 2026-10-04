extends SceneTree
func _init() -> void:
	var lib: AnimationLibrary = load("res://assets/characters/mannequin/anims/ual.res")
	for n in ["Jump_Start", "Jump_Land", "Land_Three_Point", "Run_Jump", "Slide_Start", "LayToIdle"]:
		var a := lib.get_animation(n)
		var t := a.find_track(NodePath("%GeneralSkeleton:Hips"), Animation.TYPE_POSITION_3D)
		var out := []
		var steps := 20
		for i in steps + 1:
			var tt := a.length * i / steps
			out.append("%.2f:%.2f" % [tt, a.position_track_interpolate(t, tt).y * 0.9167])
		print(n, " len=", a.length, "  ", " ".join(out))
	quit()
