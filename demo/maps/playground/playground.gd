extends Node3D
## Runtime side of the playground: marker lookup for spawns, teleports, tests and scenarios.


func marker(n: String) -> Marker3D:
	return get_node_or_null("Markers/" + n) as Marker3D


func marker_names() -> PackedStringArray:
	var out := PackedStringArray()
	var m := get_node_or_null("Markers")
	if m:
		for c in m.get_children():
			out.append(c.name)
	return out
