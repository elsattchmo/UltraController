@tool
class_name UltraLogicGate
extends Node
## Puzzle wiring without code. Inputs are switches / pressure plates / doors (anything with a
## `changed(on)`, `opened`/`closed` or `activated`/`deactivated` signal). When the gate turns
## on it opens/unlocks its `targets` (UltraDoor) or calls `set_on(true)` on them.
##  AND       all inputs on
##  OR        any input on
##  SEQUENCE  inputs switched on in this exact order (any wrong one resets them all)
## Runs on the server; targets replicate themselves.

signal activated
signal deactivated

enum Mode { AND, OR, SEQUENCE }

@export var mode := Mode.AND
@export var inputs: Array[NodePath] = []
@export var targets: Array[NodePath] = []
## Stay on once solved.
@export var latch := false

var active := false
var _seq_pos := 0
var _states := {}


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	for i in inputs.size():
		var n := get_node_or_null(inputs[i])
		if n == null:
			continue
		var idx := i
		if n.has_signal("changed"):
			n.connect("changed", func(on: bool) -> void: _on_input(idx, on))
		elif n.has_signal("activated"):
			n.connect("activated", func() -> void: _on_input(idx, true))
			n.connect("deactivated", func() -> void: _on_input(idx, false))
		elif n.has_signal("opened"):
			n.connect("opened", func() -> void: _on_input(idx, true))
			n.connect("closed", func() -> void: _on_input(idx, false))


func _on_input(idx: int, on: bool) -> void:
	if not UltraNet.is_server():
		return
	_states[idx] = on
	var now := false
	match mode:
		Mode.AND:
			now = true
			for i in inputs.size():
				now = now and bool(_states.get(i, false))
		Mode.OR:
			for i in inputs.size():
				now = now or bool(_states.get(i, false))
		Mode.SEQUENCE:
			if on:
				if idx == _seq_pos:
					_seq_pos += 1
				else:
					_seq_pos = 0
					_reset_inputs()
			now = _seq_pos >= inputs.size()
	if latch and active:
		return
	if now != active:
		active = now
		(activated if active else deactivated).emit()
		for t in targets:
			var n := get_node_or_null(t)
			if n is UltraDoor:
				if active:
					(n as UltraDoor).set_locked(false)
				(n as UltraDoor).set_open(active)
			elif n and n.has_method("set_on"):
				n.call("set_on", active)
		UltraNet.world.broadcast(&"puzzle", [String(name), active], true)


func _reset_inputs() -> void:
	for i in inputs.size():
		var n := get_node_or_null(inputs[i])
		if n is UltraSwitch and (n as UltraSwitch).on:
			(n as UltraSwitch).set_on(false)
		_states[i] = false
