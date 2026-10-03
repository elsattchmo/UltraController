extends SceneTree
func _init() -> void:
	var lib: AnimationLibrary = load("res://assets/characters/mannequin/anims/ual.res")
	var a := lib.get_animation(&"Turn_Left_90")
	for t in a.get_track_count():
		var p := str(a.track_get_path(t))
		if p.ends_with(":Root") or p.ends_with(":Hips") or p.ends_with("Foot"):
			print(p, " type=", a.track_get_type(t), " keys=", a.track_get_key_count(t))
			if a.track_get_type(t) == Animation.TYPE_ROTATION_3D:
				for k in range(0, a.track_get_key_count(t), maxi(1, a.track_get_key_count(t) / 6)):
					var q: Quaternion = a.track_get_key_value(t, k)
					var b := Basis(q)
					print("   t=%.2f euler=%s fwd=%s" % [a.track_get_key_time(t, k), b.get_euler() * 57.3, b * Vector3.FORWARD])
	quit()
