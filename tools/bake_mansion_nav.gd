extends Node
## Bakes the mansion's navigation mesh from its boxes and saves it (demo/maps/mansion/mansion_nav.res).
## Rerun after changing MansionLayout / MansionBuilder (the map warns and bakes at load when it's stale).
##   godot --headless --path . res://tools/tool_runner.tscn -- --tool=res://tools/bake_mansion_nav.gd


func _ready() -> void:
	var built := Mansion.make_built()
	var t0 := Time.get_ticks_msec()
	var nm := UltraNav.bake(built.boxes.nav_source())
	nm.resource_name = Mansion.nav_hash(built)
	print("mansion navmesh: %d polygons, %d vertices, baked in %d ms (%s)" % [nm.get_polygon_count(), nm.get_vertices().size(), Time.get_ticks_msec() - t0, nm.resource_name])
	print("saved: ", ResourceSaver.save(nm, Mansion.NAV_PATH))
