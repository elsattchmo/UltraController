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
	b._marker("booth", Vector3(16.6, 0.1, 43.6), 180)


func _post(parent: Node, n: String, pos: Vector3, yaw: float, props: Dictionary) -> void:
	m4._scripted(parent, "res://demo/puzzles/dummy_post.gd", n, pos, props, yaw)
