class_name UltraBotCourses
extends RefCounted
## Named scripted input courses for bots, tests and scenarios (`--bot=<name>`).



static func get_course(name: String) -> Array:
	match name:
		"idle":
			return [{"ticks": 60}]
		"gunplay":
			# Draw, fire a magazine while strafing, reload, holster, repeat.
			var out := [{"ticks": 30, "slot": 1}]
			for i in 12:
				out.append({"ticks": 2, "slot": 1, "tap": InputFrame.B_PRIMARY, "move": Vector2(0.6 if i % 4 < 2 else -0.6, 0)})
				out.append({"ticks": 10, "slot": 1, "move": Vector2(0.6 if i % 4 < 2 else -0.6, 0), "yaw_rate": 0.4})
			out.append({"ticks": 2, "slot": 1, "tap": InputFrame.B_RELOAD})
			out.append({"ticks": 150, "slot": 1})
			out.append({"ticks": 40, "slot": 1, "buttons": InputFrame.B_SECONDARY, "move": Vector2(0, 0.5)})
			out.append({"ticks": 2, "slot": 1, "buttons": InputFrame.B_SECONDARY, "tap": InputFrame.B_PRIMARY})
			out.append({"ticks": 40, "slot": 0})
			return out
		"carry":
			# Grab whatever is nearest, wander with it, throw it, repeat.
			return [
				{"ticks": 20},
				{"ticks": 2, "target": -1, "tap": InputFrame.B_GRAB},
				{"ticks": 90, "move": Vector2(0, 0.7), "yaw_rate": 0.8},
				{"ticks": 60, "move": Vector2(0.6, 0), "pitch": 0.2},
				{"ticks": 45, "buttons": InputFrame.B_THROW, "pitch": 0.3},
				{"ticks": 30},
				{"ticks": 60, "move": Vector2(0, -0.6)},
			]
		"walk_short":
			# Ride whatever we spawned on: stand, shuffle a little, jump once.
			return [{"ticks": 240}, {"ticks": 30, "move": Vector2(0, 0.3)}, {"ticks": 2, "tap": InputFrame.B_JUMP}, {"ticks": 300}]
		"walk":
			return [{"ticks": 600, "move": Vector2(0, 0.4)}]
		"course_full":
			return [
				{"ticks": 60, "move": Vector2(0, 1)},
				{"ticks": 50, "move": Vector2(0, 1), "buttons": InputFrame.B_SPRINT},
				{"ticks": 2, "move": Vector2(0, 1), "buttons": InputFrame.B_SPRINT, "tap": InputFrame.B_JUMP},
				{"ticks": 50, "move": Vector2(0, 1), "buttons": InputFrame.B_SPRINT | InputFrame.B_JUMP},
				{"ticks": 40, "move": Vector2(0, 1), "yaw_rate": 2.2},
				{"ticks": 40, "move": Vector2(0.8, 0.6), "buttons": InputFrame.B_SPRINT},
				{"ticks": 25, "move": Vector2(0, 1), "buttons": InputFrame.B_SPRINT | InputFrame.B_CROUCH},
				{"ticks": 40, "move": Vector2(-1, 0), "buttons": InputFrame.B_CROUCH},
				{"ticks": 40, "move": Vector2(0, -1), "yaw_rate": -1.5},
				{"ticks": 2, "tap": InputFrame.B_DODGE},
				{"ticks": 120},
				{"ticks": 60, "move": Vector2(0, 0.5), "yaw_rate": 3.0},
				{"ticks": 30},
			]
		"circle":
			return [{"ticks": 600, "move": Vector2(0, 1), "yaw_rate": 1.2}]
		"circle_east":
			# Get clear of the other spawns first, then circle (multi-client tests).
			return [{"ticks": 180, "move": Vector2(1, 0)}, {"ticks": 900, "move": Vector2(0, 1), "yaw_rate": 1.2}]
	return [{"ticks": 60}]
