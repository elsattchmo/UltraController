class_name SinewMoveSegments
extends RefCounted
## The moves the Sinew gait is judged on, as data, shared by the moves tour (films + measures them,
## demo/tours/sinew_moves_review.gd) and the moves suite (tests/suites/s10_sinew_moves.gd, headless, with limits).
##
## A segment: [label, ticks, input, camera, gait on].
##   input: "move" Vector2, "yaw" deg (absolute), "yaw_rate" deg/s, "yaw_add" deg (once, at the start),
##          "buttons" int, "slot" int.
## Labels starting with "@" move the character first and aren't measured:
##   "@flat" level ground, "@reset" the speed track's start, "@stairs" the playground stairs, "@at:<marker>".

const D := 0.70710678


## Every segment, in order. `chaos_seed` fixes the "direction chaos" stick.
static func all(chaos_seed := 7) -> Array:
	var sprint := InputFrame.B_SPRINT
	var segs := [
		["@flat", 40, {"slot": 0}, "front", true],
		["idle unarmed", 150, {"slot": 0}, "front", true],
		["idle unarmed (clip)", 90, {"slot": 0}, "front", false],
		["idle pistol", 180, {"slot": 1}, "front", true],
		["idle pistol (clip)", 90, {"slot": 1}, "front", false],
		["idle rifle", 180, {"slot": 2}, "front", true],
		["idle rifle (clip)", 90, {"slot": 2}, "front", false],
		["@reset", 60, {"slot": 0}, "behind", true],
		["walk fwd", 180, {"move": Vector2(0, 1)}, "behind", true],
		["@reset", 40, {}, "behind", true],
		["walk fwd-left", 150, {"move": Vector2(-D, D)}, "behind", true],
		["@reset", 40, {}, "behind", true],
		["walk fwd-right", 150, {"move": Vector2(D, D)}, "behind", true],
		["@reset", 40, {}, "front", true],
		["walk back-left", 150, {"move": Vector2(-D, -D)}, "front", true],
		["@reset", 40, {}, "front", true],
		["walk back-right", 150, {"move": Vector2(D, -D)}, "front", true],
		["@reset", 40, {}, "front", true],
		["back-left then", 90, {"move": Vector2(-D, -D)}, "front", true],
		["diagonal reversal", 120, {"move": Vector2(D, -D)}, "front", true],
		["@reset", 60, {}, "side", true],
		["sprint start", 150, {"move": Vector2(0, 1), "buttons": sprint}, "side", true],
		["sprint turn 90/s", 120, {"move": Vector2(0, 1), "buttons": sprint, "yaw_rate": 90.0}, "behind", true],
		["sprint flick 180", 120, {"move": Vector2(0, 1), "buttons": sprint, "yaw_add": 180.0}, "behind", true],
		["stop from sprint", 90, {}, "side", true],
		["@reset", 40, {}, "side", true],
		["walk then", 90, {"move": Vector2(0, 1)}, "side", true],
		["walk reversal", 120, {"move": Vector2(0, -1)}, "side", true],
		["@reset", 40, {}, "side", true],
		["sprint then", 120, {"move": Vector2(0, 1), "buttons": sprint}, "side", true],
		["sprint reversal", 120, {"move": Vector2(0, -1)}, "side", true],
		["stop", 60, {}, "side", true],
		["@stairs", 30, {}, "side", true],
		["stairs up", 280, {"move": Vector2(0, 1), "yaw": 0.0}, "side", true],
		["stairs down", 240, {"move": Vector2(0, 1), "yaw": 180.0}, "side", true],
		# Ramps (playground markers ramp_<a> at the foot, facing up the slope).
		["@at:ramp_20", 40, {}, "side", true],
		["ramp 20 up", 200, {"move": Vector2(0, 1), "yaw": 0.0}, "side", true],
		["ramp 20 down", 200, {"move": Vector2(0, 1), "yaw": 180.0}, "side", true],
		["@at:ramp_30", 40, {}, "side", true],
		["ramp 30 up", 200, {"move": Vector2(0, 1), "yaw": 0.0}, "side", true],
		["ramp 30 down", 200, {"move": Vector2(0, 1), "yaw": 180.0}, "side", true],
		# Strafing: starting from standing, and then backing (the user: "strafing then changing direction backwards").
		["@flat", 40, {"slot": 0}, "front", true],
		["strafe L then", 90, {"move": Vector2(-1, 0)}, "front", true],
		["back after strafe L", 120, {"move": Vector2(0, -1)}, "front", true],
		["@flat", 40, {"slot": 0}, "front", true],
		["strafe R start", 90, {"move": Vector2(1, 0)}, "front", true],
		# The clip alone (gait off) for reference: what the side-step animation itself does with the legs.
		["@flat", 40, {"slot": 0}, "front", false],
		["strafe R start (clip)", 90, {"move": Vector2(1, 0)}, "front", false],
		["@flat", 40, {"slot": 1}, "front", true],
		["pistol strafe R then", 90, {"move": Vector2(1, 0), "slot": 1}, "front", true],
		["pistol back-left after", 120, {"move": Vector2(-D, -D), "slot": 1}, "front", true],
		["@flat", 40, {"slot": 0}, "behind", true],
	]
	# Direction chaos: the stick changes every 0.25 - 0.7 s among 8 directions (seeded), walking then sprinting.
	var rng := RandomNumberGenerator.new()
	rng.seed = chaos_seed
	# The walk pass again with the gait off ("(clip)"): the same stick on the clips alone, for reference.
	for pass_i in 3:
		var chaos: String = ["chaos walk", "chaos sprint", "chaos walk (clip)"][pass_i]
		if pass_i == 2:
			rng.seed = chaos_seed
		var t := 0
		while t < 600:
			var a := float(rng.randi_range(0, 7)) * PI / 4.0
			var n := rng.randi_range(15, 42)
			var extra := {"move": Vector2(sin(a), cos(a))}
			if pass_i == 1:
				extra["buttons"] = sprint
			segs.append([chaos, n, extra, "behind", pass_i != 2])
			t += n
		segs.append(["@flat", 40, {}, "behind", pass_i != 1])
	return segs


## Where an "@" segment puts the character: [position, yaw rad], or [] for none.
static func place(label: String, map: Node) -> Array:
	match label:
		"@flat":
			# (Level ground: the speed track's start marker stands on a 5 cm edge.)
			return [(map.call("marker", "spawn") as Node3D).global_position + Vector3(-16, 0, -3), 0.0]
		"@reset":
			return [(map.call("marker", "speed_start") as Node3D).global_position, 0.0]
		"@stairs":
			return [Vector3(30.0, 0.05, -17.0), 0.0]
	if label.begins_with("@at:"):
		var m := map.call("marker", label.substr(4)) as Node3D
		return [m.global_position, 0.0] if m else []
	return []
