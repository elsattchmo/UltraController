class_name UltraCompanion
extends RefCounted
## Brain for a helper bot (a server-side NetPlayer driven by a BotInputSource). Follows its
## leader; when the leader lifts one end of a team-lift object, it walks to the other grip,
## takes it, and keeps its end where the leader's movement drags the load; drops when the
## leader drops. Works the same in single-player and on a server.

var bot: UltraCharacter
var leader: UltraCharacter
var _grab_cooldown := 0.0


func _init(p_bot: UltraCharacter, p_leader: UltraCharacter) -> void:
	bot = p_bot
	leader = p_leader
	var src := bot.input_source as BotInputSource
	src.driver = _drive


func _drive(tick: int, src: BotInputSource) -> InputFrame:
	var f := InputFrame.new()
	f.tick = tick
	f.yaw = src.live_yaw
	if not is_instance_valid(leader) or not is_instance_valid(bot):
		return f
	_grab_cooldown = maxf(_grab_cooldown - 1.0 / Engine.physics_ticks_per_second, 0.0)
	var ls := leader.state
	var bs := bot.state
	var team_obj := UltraNet.world.get_object(ls.held_id) if ls.held_id != 0 and ls.held_grip >= 0 else null
	if team_obj and team_obj.rigid():
		var rb := team_obj.rigid()
		var grips := UltraGrab.grip_points(rb)
		var mine := 1 - ls.held_grip if grips.size() == 2 else 0
		var gp := grips[clampi(mine, 0, grips.size() - 1)].global_position
		if bs.held_id == 0:
			# Walk to the free end, face it, grab.
			var stand := gp + (gp - rb.global_position).normalized() * 0.45
			stand.y = bs.pos.y
			var to := stand - bs.pos
			to.y = 0.0
			var face := gp - bs.pos
			src.live_yaw = atan2(-face.x, -face.z)
			if to.length() > 0.35:
				src.live_yaw = atan2(-to.x, -to.z)
				f.move = Vector2(0, clampf(to.length(), 0.3, 1.0))
			elif _grab_cooldown <= 0.0:
				src.live_yaw = atan2(-face.x, -face.z)
				f.buttons |= InputFrame.B_GRAB
				f.target_id = team_obj.net_id
				_grab_cooldown = 0.5
		else:
			# Carrying: follow the leader's motion so our end stays under our hands.
			var want := gp - Vector3(-sin(src.live_yaw), 0, -cos(src.live_yaw)) * 0.55
			var to := want - bs.pos
			to.y = 0.0
			var lv := Vector3(ls.vel.x, 0, ls.vel.z)
			var steer := lv * 0.25 + to * 2.0
			if steer.length() > 0.05:
				var local := Basis(Vector3.UP, src.live_yaw).inverse() * steer
				f.move = Vector2(local.x, -local.z).limit_length(1.0)
			var face := (rb.global_position - bs.pos)
			src.live_yaw = rotate_toward(src.live_yaw, atan2(-face.x, -face.z), 0.05)
	elif bs.held_id != 0:
		f.buttons |= InputFrame.B_DROP                    # leader let go: so do we
	else:
		# Follow at ~2.5 m.
		var to := leader.state.pos - bs.pos
		to.y = 0.0
		if to.length() > 2.5:
			src.live_yaw = atan2(-to.x, -to.z)
			f.move = Vector2(0, 1)
			if to.length() > 7.0:
				f.buttons |= InputFrame.B_SPRINT
	f.yaw = src.live_yaw
	f.pitch = 0.0
	return f


static func rotate_toward(from: float, to: float, step: float) -> float:
	return from + clampf(angle_difference(from, to), -step, step)
