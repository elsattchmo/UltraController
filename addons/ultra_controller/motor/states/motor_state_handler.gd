class_name MotorStateHandler
extends RefCounted
## Stateless behaviour for one or more MotorState.Id values. All data lives in MotorState so
## a tick can be rewound and replayed; handlers are shared between characters.


func enter(_m: UltraMotor, _s: MotorState, _i: InputFrame) -> void:
	pass


func exit(_m: UltraMotor, _s: MotorState, _i: InputFrame) -> void:
	pass


## Return the next state id, or -1 to stay.
func next(_m: UltraMotor, _s: MotorState, _i: InputFrame) -> int:
	return -1


func tick(_m: UltraMotor, _s: MotorState, _i: InputFrame) -> void:
	pass
