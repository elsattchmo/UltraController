extends UltraTour
## Review tour: sprinting on an angle - the stick a little off forward, and gentle turns while
## sprinting - unarmed and with the rifle, third person from behind.
##   godot --path . --resolution 1280x720 -- --tour=sprint_angle --out=C:/Dev/verify/ultra/review/sprint_angle


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/sprint_angle")
	var F := InputFrame
	steps = [
		{"teleport": "speed_start", "t": 0.6, "yaw": 0, "pitch": -8, "view_tp": true, "slot": 0},
		{"call": _give, "t": 0.2},
	]
	for slot in [0, 2]:
		var item: String = ["unarmed", "", "rifle"][slot]
		for spec: Array in [["d20", Vector2(0.34, 0.94), 0.0], ["d40", Vector2(0.64, 0.77), 0.0], ["turn", Vector2(0, 1), 25.0]]:
			steps.append({"teleport": "speed_start", "t": 1.2, "yaw": 0, "pitch": -8, "view_tp": true, "slot": slot})
			steps.append({"t": 1.5, "slot": slot, "move": spec[1], "buttons": F.B_SPRINT, "yaw_rate": spec[2]})
			for k in 8:
				steps.append({"t": 0.07, "slot": slot, "move": spec[1], "buttons": F.B_SPRINT, "yaw_rate": spec[2], "shot": "%s_%s_%d" % [item, spec[0], k]})


func _give() -> void:
	for it: Array in [[&"pistol", 1], [&"rifle", 1]]:
		if main.player.inventory.count_of(it[0]) == 0:
			UltraItems.give(main.player, it[0], it[1])
