extends RefCounted
## M8 playground: the dummy yard next to the range - standing dummies to shoot limb by limb, a
## walking one (limps and dangling arms show up on it), and a damage booth whose buttons cripple,
## cut off, knock down or heal its dummy.

var b: Node
var m4: RefCounted


func _init(builder: Node) -> void:
	b = builder
	m4 = (load("res://demo/maps/playground/zones_m4.gd") as Script).new(builder)


func build() -> void:
	var y: Node3D = b._node(b.scene_root, "DummyYard")
	b._block(y, "Floor", Vector3(12, 0.05, 18), 19, 42, 0.05, b.grid)
	b._block(y, "Backstop", Vector3(12, 4, 0.8), 19, 51.4, 4.0, b.grid_dark)
	b._label(y, "DUMMY YARD   shoot limbs · booth buttons cut, cripple, knock down, heal", Vector3(19, 3.0, 33.2), 52, 180)
	_post(y, "DummyA", Vector3(15.5, 0.05, 40), 0.0, {"dummy_name": "Dummy A"})
	_post(y, "DummyB", Vector3(19.0, 0.05, 42), 0.0, {"dummy_name": "Dummy B"})
	_post(y, "Walker", Vector3(23.0, 0.05, 37), 180.0, {"dummy_name": "Walker", "pace": 7.0})
	_post(y, "Booth", Vector3(15.0, 0.05, 47), 0.0, {"dummy_name": "Booth dummy", "booth": true})
	b._marker("dummies", Vector3(19, 0.1, 33.5), 180)
	# The sprint track (open ground south-west of the hub): a dummy sprinting round an 18 m square.
	var t: Node3D = b._node(b.scene_root, "SprintTrack")
	const SIDE := 18.0
	var at := Vector3(-39, 0.0, 79)          # the post: the square runs north (-Z) then east (+X) from here
	for e: Array in [[Vector3(SIDE * 0.5, 0, 0), Vector3(SIDE, 0.02, 0.3)], [Vector3(SIDE * 0.5, 0, -SIDE), Vector3(SIDE, 0.02, 0.3)],
			[Vector3(0, 0, -SIDE * 0.5), Vector3(0.3, 0.02, SIDE)], [Vector3(SIDE, 0, -SIDE * 0.5), Vector3(0.3, 0.02, SIDE)]]:
		var p: Vector3 = at + (e[0] as Vector3)
		b._block(t, "Line%d" % t.get_child_count(), e[1], p.x, p.z, 0.02, b.grid)
	b._label(t, "SPRINT TRACK   a dummy at full speed: shoot it, ball it, shove it", at + Vector3(SIDE * 0.5, 3.0, 3.0), 52, 180)
	_post(t, "Sprinter", at, 0.0, {"dummy_name": "Sprinter", "sprint_loop": SIDE})
	b._marker("sprint_track", at + Vector3(SIDE * 0.5, 0.1, 6.0), 180)
	# The gap walk: a raised path (0.6 m) north from z 111 with gaps of 0.4 / 0.7 / 1.0 / 1.4 m - a stride or a fall.
	var gw: Node3D = b._node(b.scene_root, "GapWalk")
	const H := 0.6
	const SEG := 3.0
	var z := 111.0
	var gaps := [0.4, 0.7, 1.0, 1.4]
	for i in gaps.size() + 1:
		b._block(gw, "Path%d" % i, Vector3(2.0, H, SEG), 0.0, z - SEG * 0.5, H, b.grid if i % 2 == 0 else b.grid_dark)
		z -= SEG
		if i < gaps.size():
			b._label(gw, "%.1f m" % gaps[i], Vector3(1.6, H + 0.6, z - gaps[i] * 0.5), 44, 0)
			z -= float(gaps[i])
	b._label(gw, "GAP WALK   strides over what the legs can span", Vector3(0, 3.2, 112.5), 52, 0)
	b._marker("gap_walk", Vector3(0, H + 0.05, 110.0), 0)
	b._marker("booth", Vector3(16.6, 0.1, 43.6), 180)


func _post(parent: Node, n: String, pos: Vector3, yaw: float, props: Dictionary) -> void:
	m4._scripted(parent, "res://demo/puzzles/dummy_post.gd", n, pos, props, yaw)
