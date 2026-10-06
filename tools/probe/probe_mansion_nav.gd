extends SceneTree
## Where does the saved mansion navmesh have polygons? (stairs, floors, bands of height)
##   godot --headless --path . --script res://tools/probe/probe_mansion_nav.gd
func _initialize() -> void:
	var nm := load("res://demo/maps/mansion/mansion_nav.res") as NavigationMesh
	var vs := nm.get_vertices()
	print("NAV vertices ", vs.size(), " polygons ", nm.get_polygon_count())
	var bands := {}
	for v in vs:
		var k := snappedf(v.y, 0.5)
		bands[k] = int(bands.get(k, 0)) + 1
	var keys := bands.keys()
	keys.sort()
	for k in keys:
		print("NAV   y~%.1f: %d vertices" % [k, bands[k]])
	for r in [["grand_w", Rect2(19.0, 18.0, 2.6, 6.0)], ["back_w", Rect2(10.3, 30.4, 1.4, 6.0)], ["cellar", Rect2(54.2, 16.0, 1.4, 5.6)]]:
		var ys := []
		for v in vs:
			if (r[1] as Rect2).grow(0.3).has_point(Vector2(v.x, v.z)):
				ys.append(snappedf(v.y, 0.1))
		ys.sort()
		print("NAV stair %s: %d vertices, y %s" % [r[0], ys.size(), str(ys.slice(0, 40))])
	quit()
