class_name UltraSpring
extends RefCounted
## Semi-implicit damped spring (critically damped at damping = 1). Used for every "weighty"
## presentation value: camera dips, leans, FOV kicks, hand sway.

var value: Variant
var velocity: Variant
var target: Variant
var frequency := 8.0      ## Hz
var damping := 0.7


func _init(initial: Variant = 0.0, freq := 8.0, damp := 0.7) -> void:
	value = initial
	target = initial
	velocity = initial * 0.0
	frequency = freq
	damping = damp


func step(dt: float) -> Variant:
	var w := TAU * frequency
	var k := w * w
	var c := 2.0 * damping * w
	velocity += ((target - value) * k - velocity * c) * dt
	value += velocity * dt
	return value


func impulse(v: Variant) -> void:
	velocity += v


func snap(v: Variant) -> void:
	value = v
	target = v
	velocity = v * 0.0
