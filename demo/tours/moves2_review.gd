extends UltraTour
## Review tour (round 10): prone with the rifle (lying still, firing, crawling each way, pivoting),
## drawing the rifle and the pistol (one movement into the ready pose), lowering off the cliff
## into a hang and climbing down the cliff ladder, and hopping off a short drop at a run.
##   godot --path . --resolution 1280x720 -- --tour=moves2_review --out=C:/Dev/verify/ultra/review/moves2_review

var _cam: Camera3D
var _cam_side := 3.2
var _cam_up := 0.8


const SLOW := 0.35


func _slow(on: bool) -> void:
	Engine.time_scale = SLOW if on else 1.0


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/moves2_review")
	var F := InputFrame
	var P := F.B_CRAWL | F.B_CROUCH
	steps = [
		{"teleport": "speed_start", "t": 0.6, "yaw": 0, "pitch": -8, "view_tp": true, "slot": 0},
		{"call": _give, "t": 0.3},
		# Drawing: rifle, then pistol (side on, slow motion).
		{"call": _side_on, "t": 1.0, "slot": 0},
		{"call": _slow.bind(true), "t": 0.01, "slot": 0},
	]
	for k in 10:
		steps.append({"t": 0.07 / SLOW, "slot": 2, "shot": "draw_rifle_%d" % k})
	steps.append({"t": 1.0 / SLOW, "slot": 0})
	for k in 8:
		steps.append({"t": 0.06 / SLOW, "slot": 1, "shot": "draw_pistol_%d" % k})
	steps.append({"call": _slow.bind(false), "t": 1.0, "slot": 1})
	# Prone with the rifle.
	steps.append({"t": 1.0, "slot": 2})
	steps.append({"t": 1.6, "slot": 2, "buttons": P, "shot": "prone_idle"})
	steps.append({"t": 0.05, "slot": 2, "buttons": P | F.B_PRIMARY})
	for k in 3:
		steps.append({"t": 0.08, "slot": 2, "buttons": P, "shot": "prone_fire_%d" % k})
	for spec: Array in [["fwd", Vector2(0, 1)], ["back", Vector2(0, -1)], ["right", Vector2(1, 0)], ["left", Vector2(-1, 0)]]:
		steps.append({"t": 0.7, "slot": 2, "buttons": P, "move": spec[1]})
		for k in 4:
			steps.append({"t": 0.2, "slot": 2, "buttons": P, "move": spec[1], "shot": "prone_%s_%d" % [spec[0], k]})
	steps.append({"t": 0.5, "slot": 2, "buttons": P})
	for k in 4:
		steps.append({"t": 0.2, "slot": 2, "buttons": P, "yaw_rate": 70.0, "shot": "prone_turn_%d" % k})
	steps.append({"call": _reload_prone, "t": 0.05, "slot": 2, "buttons": P | F.B_RELOAD})
	for k in 4:
		steps.append({"t": 0.5, "slot": 2, "buttons": P, "shot": "prone_reload_%d" % k})
	steps.append({"t": 1.2, "slot": 0})
	# Off the cliff into a hang (slow motion), then down the cliff ladder.
	steps.append({"call": _to.bind(Vector3(128.5, 8.05, -24.8), PI), "t": 0.8, "slot": 0, "yaw": 180})
	steps.append({"call": _slow.bind(true), "t": 0.01, "slot": 0})
	for k in 16:
		steps.append({"t": 0.1 / SLOW, "slot": 0, "move": Vector2(0, 1), "shot": "drop_hang_%02d" % k})
	steps.append({"call": _slow.bind(false), "t": 1.0, "slot": 0})
	steps.append({"t": 0.6, "slot": 0, "shot": "hanging"})
	steps.append({"call": _to.bind(Vector3(132.0, 8.05, -24.8), PI), "t": 0.8, "slot": 0, "yaw": 180})
	for k in 10:
		steps.append({"t": 0.15, "slot": 0, "move": Vector2(0, 1), "shot": "ladder_down_%d" % k})
	steps.append({"t": 0.3, "slot": 0})
	for k in 6:
		steps.append({"t": 0.4, "slot": 0, "move": Vector2(0, -1), "yaw": 0, "shot": "ladder_climb_%d" % k})
	# Hopping off the 1 m wall at a run.
	steps.append({"call": _to.bind(Vector3(63.0, 1.05, -31.5), PI), "t": 0.6, "slot": 0, "yaw": 180})
	steps.append({"t": 0.45, "slot": 0, "move": Vector2(0, 1), "buttons": F.B_SPRINT})
	for k in 8:
		steps.append({"t": 0.06, "slot": 0, "move": Vector2(0, 1), "buttons": F.B_SPRINT, "shot": "hop_%d" % k})


func _give() -> void:
	for it: Array in [[&"pistol", 1], [&"rifle", 1], [&"ammo_556", 90]]:
		if main.player.inventory.count_of(it[0]) == 0:
			UltraItems.give(main.player, it[0], it[1])


func _reload_prone() -> void:
	main.player.state.mag = 3


func _to(p: Vector3, yaw: float) -> void:
	main.player.teleport(p, yaw)


func _side_on() -> void:
	_cam = Camera3D.new()
	main.add_child(_cam)
	_cam.fov = 45.0


func _process(delta: float) -> void:
	super(delta)
	if _cam:
		_cam.current = true
		var c: UltraCharacter = main.player
		var yaw := c.state.body_yaw
		var right := Vector3(cos(yaw), 0, -sin(yaw))
		var p := c.visual_root.global_position + Vector3.UP * _cam_up
		if c.state.state == MotorState.Id.CRAWL:
			p = c.visual_root.global_position + Vector3.UP * 0.3
		if c.state.state in [MotorState.Id.LEDGE_CLIMB, MotorState.Id.LEDGE_HANG, MotorState.Id.LADDER]:
			p += Vector3.UP * (1.0 + c.camera_lift())
		_cam.global_position = p + right * _cam_side + Vector3.UP * 0.4
		_cam.look_at(p)
