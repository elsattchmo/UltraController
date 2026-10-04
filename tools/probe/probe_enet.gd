extends SceneTree
func _init() -> void:
	print(ClassDB.class_get_integer_constant_list("ENetPacketPeer", true))
	quit()
