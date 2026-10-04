extends Node3D
## Start / finish gates for the parkour course. Server times each character from leaving the
## start gate to reaching the finish and broadcasts (`parkour_time`, [net_id, seconds, best]).

@export var start_gate: NodePath
@export var finish_gate: NodePath

var _started := {}          # net id -> start tick
var best := INF


func _ready() -> void:
	(get_node(start_gate) as Area3D).body_exited.connect(_on_start)
	(get_node(finish_gate) as Area3D).body_entered.connect(_on_finish)


func _now() -> int:
	return UltraNet.server_tick if UltraNet.is_active() else Engine.get_physics_frames()


func _on_start(b: Node3D) -> void:
	if b is UltraCharacter and UltraNet.is_server():
		_started[(b as UltraCharacter).net_id] = _now()


func _on_finish(b: Node3D) -> void:
	if not (b is UltraCharacter) or not UltraNet.is_server():
		return
	var id := (b as UltraCharacter).net_id
	if not _started.has(id):
		return
	var t := float(_now() - int(_started[id])) / Engine.physics_ticks_per_second
	_started.erase(id)
	best = minf(best, t)
	UltraNet.world.broadcast(&"parkour_time", [id, t, best], true)
