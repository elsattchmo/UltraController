class_name UltraLayers
extends RefCounted
## Physics and render layer bits. Names are registered in project.godot (layer_names/*).

const WORLD_STATIC := 1 << 0
const WORLD_DYNAMIC := 1 << 1
const CHARACTER := 1 << 2
const HITBOX := 1 << 3
const RAGDOLL := 1 << 4
const HELD_PROP := 1 << 5
const INTERACTABLE := 1 << 6
const CLIMBABLE := 1 << 7
const LADDER := 1 << 8
const NO_TRAVERSE := 1 << 9
const WATER := 1 << 10

## Render layers 11..14 hold each local player's own head, hidden from that player's camera.
const RENDER_LOCAL_HEAD_FIRST := 10


static func local_head_render_layer(view_index: int) -> int:
	return 1 << (RENDER_LOCAL_HEAD_FIRST + clampi(view_index, 0, 3))


static func camera_cull_mask(view_index: int, first_person: bool) -> int:
	var all := 0xFFFFF
	if first_person and view_index >= 0:
		return all & ~local_head_render_layer(view_index)
	return all
