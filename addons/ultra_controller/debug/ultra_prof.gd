class_name UltraProf
extends RefCounted
## A tiny scope timer for hunting per-frame cost: `var t := UltraProf.tick()` ... `UltraProf.add("name", t)`;
## `report()` returns "name: ms per frame" lines (and clears). Does nothing unless enabled (`--prof`).

static var enabled := false
static var _acc := {}
static var _n := {}


static func tick() -> int:
	return Time.get_ticks_usec() if enabled else 0


static func add(label: String, t0: int) -> void:
	if enabled:
		_acc[label] = int(_acc.get(label, 0)) + Time.get_ticks_usec() - t0
		_n[label] = int(_n.get(label, 0)) + 1


## ms per `frames` frames for every label, biggest first; clears.
static func report(frames: int) -> String:
	var rows := []
	for k: String in _acc:
		rows.append([k, float(_acc[k]) / 1000.0 / maxf(frames, 1), int(_n[k]) / maxf(frames, 1)])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return a[1] > b[1])
	var out := []
	for r: Array in rows:
		out.append("%-28s %6.2f ms/frame  (%.1f calls/frame)" % [r[0], r[1], r[2]])
	_acc.clear()
	_n.clear()
	return "\n".join(out)
