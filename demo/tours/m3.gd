extends UltraTour
## M3 review tour: feet planted on rocks, slopes and stairs; head glance in third person.


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/m3")
	var F := InputFrame
	steps = [
		{"teleport": "rocks", "t": 0.5, "view_tp": true, "pitch": -25},
		{"t": 6.0, "move": Vector2(0, 0.35), "shot": "01_tp_rocks_walk"},
		{"t": 1.2, "move": Vector2.ZERO, "pitch": -20, "shot": "02_tp_rocks_idle"},
		{"t": 1.0, "view_tp": false, "pitch": -70, "shot": "03_fp_rocks_feet"},
		{"call": func() -> void: _side_on("ramp_20", 1.4, -20.0 - 3.43), "t": 1.5, "view_tp": true, "yaw": 90, "pitch": -10, "shot": "04_tp_ramp_sideways"},
		{"call": func() -> void: _side_on("stairs_20", 1.0, -21.12), "t": 1.5, "yaw": 90, "pitch": -15, "shot": "05_tp_stairs_sideways"},
		{"t": 0.8, "yaw": 150, "pitch": 5, "shot": "06_tp_head_glance"},
		{"teleport": "stairs_20", "t": 0.5, "yaw": 0, "pitch": -15},
		{"t": 2.0, "move": Vector2(0, 0.6), "shot": "07_tp_stairs_climb"},
	]


func _side_on(marker_name: String, y: float, z: float) -> void:
	var m := main.map.call("marker", marker_name) as Marker3D
	main.player.teleport(Vector3(m.global_position.x, y, z), PI * 0.5)
