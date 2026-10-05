class_name NetObject
extends Node
## Makes its parent part of the replicated world. Add as a child of a door, lever, world item,
## crate... Level-placed objects get a stable id from their scene path (same on every
## machine); objects the server spawns at runtime get ids from the server.
##
## Two kinds of replication, both optional:
##  * discrete state  - the parent implements get_net_state() -> Dictionary and
##                      set_net_state(d: Dictionary); call mark_dirty() after a change
##  * physics stream  - a RigidBody3D parent is simulated on the server only; clients hold it
##                      kinematic and interpolate snapshots

signal state_applied

var net_id: int = 0
var dynamic := false              ## spawned at runtime by the server
var spawn_info: Dictionary = {}   ## how clients recreate a dynamic object
var snaps: Array = []             ## client: [{tick, pos, rot, vel}] for rigid bodies
var _prio := 0.0


func _ready() -> void:
	UltraNet.world.register(self)


func _exit_tree() -> void:
	UltraNet.world.unregister(self)


func body() -> Node3D:
	return get_parent() as Node3D


func rigid() -> RigidBody3D:
	return get_parent() as RigidBody3D


func mark_dirty() -> void:
	if UltraNet.is_server():
		UltraNet.world.object_dirty(self)


func net_state() -> Dictionary:
	var p := get_parent()
	var d: Dictionary = p.call("get_net_state") if p.has_method("get_net_state") else {}
	# A breakable body (a "Breakable" child) carries whether it's broken.
	var br := p.get_node_or_null("Breakable") as UltraBreakable
	if br:
		d = d.duplicate()
		d["broken"] = br.broken
	return d


func apply_state(d: Dictionary) -> void:
	var p := get_parent()
	if p.has_method("set_net_state"):
		p.call("set_net_state", d)
	var br := p.get_node_or_null("Breakable") as UltraBreakable
	if br:
		br.apply_broken(bool(d.get("broken", false)))
	state_applied.emit()
