extends UltraTour
## Review tour: the mansion - the front, a top-down cutaway, the foyer and the Great Hall, the gallery,
## dining room, kitchen corridor, library, the basement, the upstairs corridor, the conservatory.
##   godot --path . --resolution 1280x720 -- --map=mansion --tour=mansion_walk --out=C:/Dev/verify/ultra/review/mansion_walk

var _cam: Camera3D
var _at := Vector3.ZERO
var _look := Vector3.ZERO


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/mansion_walk")
	steps = [
		{"teleport": "spawn", "t": 0.8, "yaw": 0, "pitch": 0, "view_tp": true},
		{"call": _setup, "t": 1.0},
		{"call": _shot.bind(Vector3(28, 1.7, 66), Vector3(28, 3.0, 40)), "t": 0.6, "shot": "front"},
		{"call": _shot.bind(Vector3(28, 1.7, 46), Vector3(28, 2.0, 30)), "t": 0.5, "shot": "vestibule"},
		{"call": _shot.bind(Vector3(28, 1.6, 33.5), Vector3(28, 2.4, 14)), "t": 0.5, "shot": "foyer_to_hall"},
		{"call": _shot.bind(Vector3(17.5, 2.0, 16.5), Vector3(34, 3.2, 17)), "t": 0.5, "shot": "hall_east"},
		{"call": _shot.bind(Vector3(28, 1.7, 8), Vector3(28, 3.0, 27)), "t": 0.5, "shot": "hall_south"},
		{"call": _shot.bind(Vector3(28, 5.4, 26.8), Vector3(28, 4.0, 8)), "t": 0.5, "shot": "gallery_north"},
		{"call": _shot.bind(Vector3(18.5, 5.2, 9.2), Vector3(36, 1.5, 24)), "t": 0.5, "shot": "gallery_down"},
		{"call": _shot.bind(Vector3(41, 1.7, 1), Vector3(50, 1.2, 10)), "t": 0.5, "shot": "dining"},
		{"call": _shot.bind(Vector3(41, 1.6, 14.7), Vector3(41, 1.5, 27)), "t": 0.5, "shot": "service_corridor"},
		{"call": _shot.bind(Vector3(43, 1.7, 15), Vector3(48, 1.0, 25)), "t": 0.5, "shot": "kitchen"},
		{"call": _shot.bind(Vector3(1.2, 1.7, 1.2), Vector3(6, 1.4, 11)), "t": 0.5, "shot": "library"},
		{"call": _shot.bind(Vector3(9, 1.6, 1.0), Vector3(9, 1.6, 38)), "t": 0.5, "shot": "west_corridor"},
		{"call": _shot.bind(Vector3(41, -1.6, 15), Vector3(47, -3.0, 22)), "t": 0.5, "shot": "basement_boiler"},
		{"call": _shot.bind(Vector3(54.9, -0.9, 16.6), Vector3(54.9, -3.0, 22)), "t": 0.5, "shot": "cellar_stair"},
		{"call": _shot.bind(Vector3(9, 5.3, 1.0), Vector3(9, 5.0, 38)), "t": 0.5, "shot": "upstairs_corridor"},
		{"call": _shot.bind(Vector3(41, 5.4, 41), Vector3(50, 4.4, 30)), "t": 0.5, "shot": "sunroom"},
		{"call": _shot.bind(Vector3(41, 5.4, 1), Vector3(50, 4.2, 10)), "t": 0.5, "shot": "master"},
		{"call": _roof_off, "t": 0.3},
		{"call": _shot.bind(Vector3(28, 80, 20), Vector3(28, 0, 20.5)), "t": 0.6, "shot": "topdown"},
		{"call": _shot.bind(Vector3(28, 55, 74), Vector3(28, 2, 24)), "t": 0.6, "shot": "aerial"},
	]


func _setup() -> void:
	_cam = Camera3D.new()
	main.add_child(_cam)
	_cam.fov = 70.0
	_cam.far = 300.0
	_cam.current = true


func _shot(at: Vector3, look: Vector3) -> void:
	_at = at
	_look = look


func _roof_off() -> void:
	var geo: Node = main.map.get_node("Geometry")
	for n in geo.get_children():
		if n.name == "Mesh_ceiling":
			n.visible = false
	for n in main.map.get_node("Lights").get_children():
		(n as Light3D).shadow_enabled = false


func _process(delta: float) -> void:
	super(delta)
	if _cam:
		_cam.current = true
		_cam.global_position = _at
		var up := Vector3.UP if absf((_look - _at).normalized().y) < 0.95 else Vector3.FORWARD
		_cam.look_at(_look, up)
