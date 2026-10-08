extends "res://demo/tours/tour_base.gd"
## Marksman in first person (the camera is the head's eye): rifle, shotgun and pistol, standing and crouched, at the
## hip and down the sights, still and walking - the game's own camera.
##   godot --path . --fixed-fps 60 --resolution 1280x720 -- --tour=marksman_fp_review --controller=marksman --out=<dir>

var _c: UltraCharacter
var _slots := {}
var _tick0 := 0


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/marksman_fp_review")
	steps = [{"teleport": "spawn", "t": 0.6, "yaw": 0, "pitch": -3, "view_tp": false, "slot": 0},
			{"call": _setup, "t": 1.0}]
	# (Steps wait for game ticks, not seconds: under a slow renderer a few seconds were a fraction of a weapon switch.)
	for item in ["rifle", "shotgun", "pistol"]:
		for posture in ["stand", "crouch"]:
			var b: int = InputFrame.B_CROUCH if posture == "crouch" else 0
			steps.append({"call": _arm.bind(item), "t": 600.0, "until": _ticks.bind(150), "buttons": b, "yaw": 0, "pitch": -3})
			for spec: Array in [["hip", 0, Vector2.ZERO, 40], ["hip_walk", 0, Vector2(0, 1), 50], ["ads", InputFrame.B_SECONDARY, Vector2.ZERO, 50],
					["ads_walk", InputFrame.B_SECONDARY, Vector2(0, 1), 50]]:
				steps.append({"call": _mark, "t": 600.0, "until": _ticks.bind(spec[3]), "buttons": b | spec[1], "move": spec[2], "yaw": 0, "pitch": -3,
						"shot": "%s_%s_%s" % [item, posture, spec[0]]})
			steps.append({"call": _mark, "t": 600.0, "until": _ticks.bind(30), "buttons": b, "yaw": 0, "pitch": -3})

func _setup() -> void:
	_c = main.player
	var have := {}
	for i in _c.inventory.size():
		var it := _c.inventory.get_slot(i)
		if it:
			have[it.def_id] = true
	for item: StringName in [&"rifle", &"shotgun", &"pistol"]:
		if not have.has(item):
			UltraItems.give(_c, item)
	for i in _c.inventory.size():
		var it := _c.inventory.get_slot(i)
		if it:
			_slots[String(it.def_id)] = i + 1


func _arm(item: String) -> void:
	_c.teleport(main.map.call("marker", "spawn").global_position + Vector3(-16, 0, -3), 0.0)
	_bot.live_yaw = 0.0
	_slot = int(_slots.get(item, 0))
	_mark()


func _mark() -> void:
	_tick0 = Engine.get_physics_frames()


func _ticks(n: int) -> bool:
	return Engine.get_physics_frames() - _tick0 >= n
