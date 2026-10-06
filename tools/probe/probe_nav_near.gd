extends SceneTree
## Navmesh polygons near a point: godot --headless --path . --script res://tools/probe/probe_nav_near.gd
func _initialize() -> void:
	var nm := load("res://demo/maps/mansion/mansion_nav.res") as NavigationMesh
	var vs := nm.get_vertices()
	for target in [Vector3(48, -3.3, 7), Vector3(45, -3.3, 21)]:
		var near := []
		for i in nm.get_polygon_count():
			var poly := nm.get_polygon(i)
			var c := Vector3.ZERO
			for k in poly:
				c += vs[k]
			c /= poly.size()
			if Vector2(c.x - target.x, c.z - target.z).length() < 2.2 and absf(c.y - target.y) < 1.0:
				near.append("poly %d (%d verts) centroid %s" % [i, poly.size(), c])
		print("NEAR ", target, ": ", near.size())
		for n in near:
			print("NEAR   ", n)
	quit()
