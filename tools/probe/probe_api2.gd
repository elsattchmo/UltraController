extends SceneTree
func _init() -> void:
	for cls in ["AnimationNodeBlendSpace2D","AnimationNodeBlendSpace1D","AnimationNodeAnimation","AnimationTree","AnimationMixer","AnimationNodeBlend2"]:
		for p in ClassDB.class_get_property_list(cls, true):
			if p.hint_string != "" and p.hint in [PROPERTY_HINT_ENUM, PROPERTY_HINT_FLAGS] or p.name in ["sync","sync_mode","cyclic_length"]:
				print(cls, ".", p.name, " type=", p.type, " hint=", p.hint, " '", p.hint_string, "'")
	var ms := []
	for m in ClassDB.class_get_method_list("AnimationMixer", true): ms.append(m.name)
	print("Mixer methods: ", ms)
	quit()
