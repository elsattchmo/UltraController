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
	# Substepped: explicit integration blows up once w * dt nears 2 - a single long frame (a
	# hitch compiling a shader on the first shotgun blast) flung the camera kick round 70 deg.
	# (And a stall of seconds - a breakpoint, a window drag - is taken as 0.1 s: past the 64
	# substeps it would grow ~7x a step and send the camera spinning or to NaN.)
	dt = clampf(dt, 0.0, 0.1)
	var n := clampi(int(ceil(dt * w / 0.35)), 1, 64)
	var h := dt / n
	for _i in n:
		velocity += ((target - value) * k - velocity * c) * h
		value += velocity * h
	return value


func impulse(v: Variant) -> void:
	velocity += v


func snap(v: Variant) -> void:
	value = v
	target = v
	velocity = v * 0.0
