class_name UltraLagSim
extends RefCounted
## Delays (and optionally drops) outgoing packets to simulate a bad network on one machine.
## Each side delays its own sends by half the configured round trip, so RTT ≈ `latency_ms`.
## Reliable packets are delayed but never dropped and keep their order.

var latency_ms := 0.0
var jitter_ms := 0.0
var loss_pct := 0.0

var _queue: Array = []        # [deliver_at_ms, Callable]
var _rng := RandomNumberGenerator.new()
var _last_reliable_at := 0.0


func active() -> bool:
	return latency_ms > 0.0 or jitter_ms > 0.0 or loss_pct > 0.0


func configure(lat: float, jit: float, loss: float) -> void:
	latency_ms = maxf(lat, 0.0)
	jitter_ms = maxf(jit, 0.0)
	loss_pct = clampf(loss, 0.0, 100.0)


## Queue `send` (a Callable that performs the real RPC).
func send(send_call: Callable, reliable: bool) -> void:
	if not active():
		send_call.call()
		return
	if not reliable and _rng.randf() * 100.0 < loss_pct:
		return
	var now := Time.get_ticks_msec() as float
	var at := now + latency_ms * 0.5 + _rng.randf_range(-jitter_ms, jitter_ms) * 0.5
	if reliable:
		at = maxf(at, _last_reliable_at)        # reliable stays ordered
		_last_reliable_at = at
	_queue.append([at, send_call])


func flush() -> void:
	if _queue.is_empty():
		return
	var now := Time.get_ticks_msec() as float
	var i := 0
	while i < _queue.size():
		var e: Array = _queue[i]
		if float(e[0]) <= now:
			(e[1] as Callable).call()
			_queue.remove_at(i)
		else:
			i += 1
