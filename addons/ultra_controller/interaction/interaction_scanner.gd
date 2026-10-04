class_name UltraInteractionScanner
extends Node
## Finds what a local player is looking at: a ray from the camera (first person) or from the
## character's chest along the aim (third person), then the nearest Interactable on the hit
## object. Feeds the prompt and the InputFrame's target_id (the server re-validates reach).

var character: UltraCharacter
var camera: Camera3D
var focus: Interactable
var focus_id := 0

var _q := PhysicsRayQueryParameters3D.new()


func _physics_process(_delta: float) -> void:
	focus = null
	focus_id = 0
	if character == null or not is_instance_valid(character):
		return
	var space := character.get_world_3d().direct_space_state
	var s := character.state
	var eye := s.pos + Vector3.UP * (s.height - 0.16)
	var from := eye
	var dir := Vector3(-sin(character.last_input.yaw) * cos(character.last_input.pitch), sin(character.last_input.pitch), -cos(character.last_input.yaw) * cos(character.last_input.pitch))
	if camera and is_instance_valid(camera):
		from = camera.global_position
		dir = -camera.global_basis.z
	_q.from = from
	_q.to = from + dir * 4.5
	_q.collision_mask = UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC | UltraLayers.INTERACTABLE
	_q.collide_with_areas = true
	_q.exclude = [character.get_rid()]
	var hit := space.intersect_ray(_q)
	var best: Interactable = null
	if not hit.is_empty():
		best = Interactable.find_on(hit.collider as Node)
	if best == null:
		# Generous fallback: anything interactable within reach in a narrow cone.
		var best_score := 0.97
		for n in character.get_tree().get_nodes_in_group(&"ultra_interactable"):
			var it := n as Interactable
			if not it.enabled or it.target() == null:
				continue
			var to := it.target().global_position - from
			if to.length() > it.max_distance + 0.5:
				continue
			var d := to.normalized().dot(dir)
			if d > best_score:
				best_score = d
				best = it
	if best and best.enabled and best.target().global_position.distance_to(eye) <= best.max_distance + 0.8:
		focus = best
		focus_id = best.net_id()


func target_id() -> int:
	return focus_id
