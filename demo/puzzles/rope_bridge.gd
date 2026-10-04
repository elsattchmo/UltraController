extends Node3D
## A drawbridge held up by a rope. Shoot the rope's knot and the plank swings down across the
## gap. The plank is a replicated rigid body (frozen until the rope breaks).

var broken := false


func _ready() -> void:
	var o := NetObject.new()
	o.name = "NetObject"
	add_child(o)
	($Plank as RigidBody3D).freeze = true


## UltraCombat forwards hits on the knot (child StaticBody) here.
func take_damage(_info: UltraCombat.DamageInfo) -> void:
	if broken:
		return
	_break()
	(find_child("NetObject", false, false) as NetObject).mark_dirty()
	UltraNet.world.broadcast(&"rope_cut", [String(name)], true)


func _break() -> void:
	broken = true
	if UltraNet.is_server():
		($Plank as RigidBody3D).freeze = false
		($Plank as RigidBody3D).apply_torque_impulse(Vector3(-40, 0, 0))
	$Knot.visible = false
	$RopeVisual.visible = false


func get_net_state() -> Dictionary:
	return {"broken": broken}


func set_net_state(d: Dictionary) -> void:
	if bool(d.get("broken", false)) and not broken:
		_break()
