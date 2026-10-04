extends SceneTree
func _init() -> void:
	var n: Node = (load("res://assets/items/pistol/pistol.glb") as PackedScene).instantiate()
	_d(n, 0)
	quit()
func _d(n: Node, d: int) -> void:
	var extra := ""
	if n is Node3D: extra = " pos=%s" % (n as Node3D).position.snappedf(0.001)
	print("  ".repeat(d), n.name, " <", n.get_class(), ">", extra)
	for c in n.get_children(): _d(c, d + 1)
