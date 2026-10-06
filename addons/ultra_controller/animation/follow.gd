class_name UltraFollow
extends RefCounted
## Followers for animation controls: a value chasing a target that can jump (an aim flicked, a
## clip's stance swapped, a gun placed from the camera) without ever jumping itself. The speed
## asked for is the most that still stops in time (sqrt(2 a |error|)), capped at `v_max` and
## eased off near the target (`settle` 1/s); the actual speed moves toward it at most `a_max`
## per second. Position, velocity and acceleration all stay bounded - no one-frame snaps, no
## overshoot. State is (value, rate).


static func scalar(st: Vector2, target: float, dt: float, v_max: float, a_max: float, settle := 22.0) -> Vector2:
	if dt <= 0.0:
		return st
	var err := target - st.x
	var want := signf(err) * minf(minf(v_max, sqrt(2.0 * a_max * absf(err))), absf(err) * settle)
	var v := st.y + clampf(want - st.y, -a_max * dt, a_max * dt)
	var x := st.x + v * dt
	# Arrived: snapped onto the target only when nearly stopped (stopping a fast follow dead in
	# one frame is a pop of its own); otherwise it brakes within a_max next frame.
	if signf(target - x) != signf(err) and err != 0.0 and absf(v) <= a_max * dt * 2.0:
		return Vector2(target, 0.0)
	return Vector2(x, v)


## The same on an angle: the target is reached the short way round from where the value is.
static func angle(st: Vector2, target: float, dt: float, v_max: float, a_max: float, settle := 22.0) -> Vector2:
	return scalar(st, st.x + angle_difference(st.x, target), dt, v_max, a_max, settle)


## A vector (a rotation vector, a position) chasing `target`; returns [value, rate].
static func vector(x: Vector3, v: Vector3, target: Vector3, dt: float, v_max: float, a_max: float, settle := 22.0) -> Array:
	if dt <= 0.0:
		return [x, v]
	var err := target - x
	var e := err.length()
	var want := Vector3.ZERO
	if e > 1e-7:
		want = err / e * minf(minf(v_max, sqrt(2.0 * a_max * e)), e * settle)
	var nv := v + (want - v).limit_length(a_max * dt)
	var nx := x + nv * dt
	if (target - nx).dot(err) < 0.0 and nv.length() <= a_max * dt * 2.0:
		return [target, Vector3.ZERO]
	return [nx, nv]
