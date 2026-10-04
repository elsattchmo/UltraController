extends SceneTree
func _init() -> void:
	for c in ["TwoBoneIK3D", "IKModifier3D", "ChainIK3D"]:
		print("== ", c, " parent=", ClassDB.get_parent_class(c))
		for m in ClassDB.class_get_method_list(c, true):
			var args := []
			for a in m.args: args.append("%s:%s" % [a.name, type_string(a.type)])
			print("  ", m.name, "(", ", ".join(args), ")")
		for p in ClassDB.class_get_property_list(c, true):
			if p.hint_string != "": print("  prop ", p.name, " hint=", p.hint_string)
	quit()
