class_name MarksmanMotionMatcher
extends RefCounted
## Motion matching (spike): picks which locomotion clip frame plays. Every SEARCH_EVERY s (and at once when the
## stick / stance changes) it asks the stance's MarksmanMMDatabase for the frame whose feet and hips continue the
## current frame's and whose next second matches where the MOTOR will take the body (the motor's own ground
## acceleration run forward: the animation follows the gameplay, never the other way round). The driver plays the
## pick with a dead blend (InertialBlendModifier); MarksmanMMPass warps the legs onto the real travel and locks
## planted feet.
##
## Presentation only: nothing here feeds the motor.

const SEARCH_EVERY := 0.1
## A new pick must beat carrying on by this much (normalised cost) - else small differences flip clips.
const SWITCH_MARGIN := 0.4
## Playback rate range used to match the clip's ground speed to the body's.
const RATE_MIN := 0.5
const RATE_MAX := 1.35

## Clips per stance and posture (key "<stance>" standing, "<stance>_crouch" crouched; the player's animation names,
## "library/clip"; "mirror:" = mirrored left / right). Picked by their own legs' closest approach (thighs, shins, feet as
## capsules): not the crossover side steps Strafe_Walk_L / R (cross by design), U_Walk_L (-6.2 cm: the left step is a
## mirrored U_Walk_R, +2.5), U_Walk_F (-2.5; N_StdWalk2 +1.8). Crouched, every stance walks the rifle pack's 8-way crouch
## legs; ARMS (below) lays calmer arms over them where the rifle's would show.
const RFP_CROUCH := ["mixamo/RFP_IdleCrouching", "mixamo/RFP_WalkCrouchingForward", "mixamo/RFP_WalkCrouchingForwardLeft",
	"mixamo/RFP_WalkCrouchingForwardRight", "mixamo/RFP_WalkCrouchingLeft", "mixamo/RFP_WalkCrouchingRight",
	"mixamo/RFP_WalkCrouchingBackward", "mixamo/RFP_WalkCrouchingBackwardLeft", "mixamo/RFP_WalkCrouchingBackwardRight"]
const SETS := {
	"unarmed": ["Idle_A", "mixamo/N_StdWalk2", "mixamo/U_Walk_R", "mirror:mixamo/U_Walk_R", "Walk_Backwards", "mixamo/U_Run_F", "mixamo/U_Run_B",
		"mixamo/U_Run_L", "mixamo/U_Run_R", "mixamo/S_Fast"],
	"rifle": ["mixamo/RFP_Idle", "mixamo/RFP_WalkForward", "mixamo/RFP_WalkForwardLeft", "mixamo/RFP_WalkForwardRight",
		"mixamo/RFP_WalkLeft", "mixamo/RFP_WalkRight", "mixamo/RFP_WalkBackward", "mixamo/RFP_WalkBackwardLeft",
		"mixamo/RFP_WalkBackwardRight", "mixamo/RFP_RunForward", "mixamo/RFP_RunForwardLeft", "mixamo/RFP_RunForwardRight",
		"mixamo/RFP_RunLeft", "mixamo/RFP_RunRight", "mixamo/RFP_RunBackward", "mixamo/RFP_RunBackwardLeft",
		"mixamo/RFP_RunBackwardRight", "mixamo/RFP_SprintForward", "mixamo/RFP_SprintForwardLeft",
		"mixamo/RFP_SprintForwardRight"],
	# (The pistol pack: walk 2.4 m/s (played down to 1.2), back, strafes 1.0 left / 2.2 right - mirrored for the other
	# sides - run, run back; the sprint is the unarmed one (the gun is lowered). Not the plain walk: its free left arm
	# swung the support hand 12 cm off the gun.)
	"pistol": ["mixamo/PST_PistolIdle", "mixamo/PST_PistolWalk", "mixamo/PST_PistolWalkBackward",
		"mixamo/PST_PistolStrafe", "mirror:mixamo/PST_PistolStrafe", "mixamo/PST_PistolStrafe2", "mirror:mixamo/PST_PistolStrafe2",
		"mixamo/PST_PistolRun", "mixamo/PST_PistolRunBackward", "mixamo/S_Fast"],
	"unarmed_crouch": RFP_CROUCH,
	"rifle_crouch": RFP_CROUCH,
	"pistol_crouch": RFP_CROUCH,
}
## Arms laid over the matched clip (still, moving - blended by speed), per set; none = the clip's own.
const ARMS := {
	"unarmed_crouch": ["Crouch_Idle", "mixamo/N_StdWalk2"],
	"pistol_crouch": ["mixamo/PST_PistolKneelingIdle", "mixamo/PST_PistolKneelingIdle"],
}


## The set for a character now: its stance, crouched or not.
static func key_for(c: UltraCharacter) -> String:
	var st := MarksmanStance.of_item(c.held_def())
	return st + "_crouch" if c.state.stance == MotorState.Stance.CROUCH else st


var character: UltraCharacter
var driver: UltraAnimDriver
var dbs := {}                    ## stance -> MarksmanMMDatabase
var db: MarksmanMMDatabase
var stance := ""
## What plays: clip index in `db`, its time (s), the playback rate.
var clip := -1
var time := 0.0
var rate := 1.0
## The frame playing now (db index) and whether the last update switched clip / time (the driver re-seeks).
var frame := -1
var switched := false
## Last search: its pick's cost and carrying on's (tests, tuning), and searches / switches so far.
var last_cost := 0.0
var last_keep := 0.0
var searches := 0
var switches := 0
## The slowest search so far (microseconds).
var search_us := 0
## The predicted trajectory (world, xz offsets from the body) of the last search - for debug drawing.
var predicted: Array[Vector3] = []

var _t_search := 0.0
var _last_wish := Vector2.ZERO
var _last_speed := 0.0
static var _cache := {}


func _init(c: UltraCharacter, drv: UltraAnimDriver) -> void:
	character = c
	driver = drv


## The database for a stance (built once per skeleton layout and stance, shared by every character).
func database(st: String) -> MarksmanMMDatabase:
	if not SETS.has(st):
		return null
	if dbs.has(st):
		return dbs[st]
	var sk := driver.skeleton
	var key := "%d|%s" % [sk.get_bone_count(), st]
	if not _cache.has(key):
		var list := []
		for name: String in SETS[st]:
			var pn := _player_name(name.trim_prefix("mirror:"))
			if name.begins_with("mirror:"):
				pn = driver._mirrored(pn)
			var a := driver.player.get_animation(pn) if driver.player.has_animation(pn) else null
			if a:
				list.append({"name": pn, "anim": a})
		var d := MarksmanMMDatabase.new()
		d.build(sk, list)
		_cache[key] = d
	dbs[st] = _cache[key]
	return dbs[st]


func has_stance(st: String) -> bool:
	return SETS.has(st)


## Per frame: advance what plays, search when due. Returns true when a new clip / time was picked.
func update(delta: float, st: String) -> bool:
	switched = false
	var d := database(st)
	if d == null or d.size() == 0:
		return false
	if d != db:
		db = d
		stance = st
		clip = -1
		_t_search = 0.0
	if clip >= 0:
		var c: Dictionary = db.clips[clip]
		time += delta * rate
		if c.loop:
			time = fposmod(time, c.length)
		else:
			time = minf(time, c.length)
	var wish := _wish()
	var speed := _target_speed()
	_t_search -= delta
	var force := clip < 0 or (wish - _last_wish).length() > 0.35 or absf(speed - _last_speed) > 0.6
	if force or _t_search <= 0.0:
		_search(wish, speed, force)
		_t_search = SEARCH_EVERY
		_last_wish = wish
		_last_speed = speed
	frame = db.frame_at(clip, time)
	# Rate: the clip's ground speed onto the body's.
	var cs: float = db.clips[clip].speed
	var v := Vector2(character.state.vel.x, character.state.vel.z).length()
	rate = clampf(v / cs, RATE_MIN, RATE_MAX) if cs > 0.1 and v > 0.1 else 1.0
	return switched


## The clip's ground velocity (skeleton space xz) of what plays.
func clip_velocity() -> Vector2:
	return db.clips[clip].vel if db and clip >= 0 else Vector2.ZERO


## Is the foot (0 left, 1 right) planted in the frame playing?
func planted(side: int) -> bool:
	return db != null and frame >= 0 and (db.contact[frame] >> side) & 1 == 1


func _search(wish: Vector2, speed: float, force: bool) -> void:
	var traj := _trajectory(wish, speed)
	var cur := frame if clip >= 0 else 0
	var bv := driver.skeleton.global_transform.basis.orthonormalized().inverse() * Vector3(character.state.vel.x, 0.0, character.state.vel.z)
	var q := db.query_from(cur, traj, Vector2(bv.x, bv.z))
	var t0 := Time.get_ticks_usec()
	var r := db.search(q, clip, time)
	search_us = maxi(search_us, Time.get_ticks_usec() - t0)
	if OS.get_environment("MM_Q") != "" and Engine.get_physics_frames() % 30 < 6:
		var per := {}
		for fi in db.size():
			var cn: String = String(db.clips[db.frame_clip[fi]].name).get_file()
			var cc := db.cost(q, fi)
			if cc < float(per.get(cn, INF)):
				per[cn] = cc
		var keys := per.keys()
		keys.sort_custom(func(a, b): return per[a] < per[b])
		var top := []
		for k in keys.slice(0, 4):
			top.append("%s %.2f" % [k, per[k]])
		print("MMQ t%d traj %s best %s | %s" % [Engine.get_physics_frames(), traj, String(db.clips[db.frame_clip[r[0]]].name).get_file() if r[0] >= 0 else "-", ", ".join(top)])
	searches += 1
	var best: int = r[0]
	if best < 0:
		return
	last_cost = r[1]
	last_keep = db.cost(q, cur) if clip >= 0 else INF
	if clip < 0 or last_cost < last_keep - SWITCH_MARGIN * (0.5 if force else 1.0):
		clip = db.frame_clip[best]
		time = db.frame_time[best]
		switched = true
		switches += 1


## Stick direction (world xz, unit or zero).
func _wish() -> Vector2:
	var inp := character.last_input
	if inp == null or inp.move.length() < 0.05:
		return Vector2.ZERO
	var w := inp.move_world(inp.yaw)
	return Vector2(w.x, w.z).normalized() * minf(inp.move.length(), 1.0)


func _target_speed() -> float:
	if character.motor == null or character.last_input == null:
		return 0.0
	return character.motor.target_ground_speed(character.state.copy(), character.last_input)


## The motor's ground acceleration (UltraMotor.accelerate_ground, without friction / slopes) run forward from the
## body's velocity toward the stick: positions and velocities at TRAJ_T, in the skeleton's space (12 values).
func _trajectory(wish: Vector2, target: float) -> PackedFloat32Array:
	var p := character.profile
	var v := Vector2(character.state.vel.x, character.state.vel.z)
	var pos := Vector2.ZERO
	var out := PackedFloat32Array()
	out.resize(12)
	var dt := 1.0 / 60.0
	var t := 0.0
	var k := 0
	var w := wish.normalized() if wish.length() > 0.01 else Vector2.ZERO
	predicted.clear()
	var sk_inv := driver.skeleton.global_transform.basis.orthonormalized().inverse()
	while k < MarksmanMMDatabase.TRAJ_T.size():
		v = _accelerate(p, v, w, target, dt)
		pos += v * dt
		t += dt
		if t >= MarksmanMMDatabase.TRAJ_T[k] - 1e-4:
			var lp := sk_inv * Vector3(pos.x, 0.0, pos.y)
			var lv := sk_inv * Vector3(v.x, 0.0, v.y)
			out[k * 2] = lp.x
			out[k * 2 + 1] = lp.z
			out[6 + k * 2] = lv.x
			out[6 + k * 2 + 1] = lv.z
			predicted.append(Vector3(pos.x, 0.0, pos.y))
			k += 1
	return out


static func _accelerate(p: MovementProfile, hv: Vector2, wish: Vector2, target: float, dt: float) -> Vector2:
	var speed := hv.length()
	var stop_d := lerpf(p.decel, p.sprint_stop_decel, smoothstep(p.jog_speed, p.sprint_speed * 0.9, speed))
	if target < 0.01 or wish.length_squared() < 0.0001:
		return hv.move_toward(Vector2.ZERO, stop_d * dt)
	if speed > 0.2:
		var dir := hv / speed
		if dir.dot(wish) < -0.35:
			return hv.move_toward(Vector2.ZERO, p.brake_decel * dt)
		var kk := clampf((speed - p.walk_speed) / maxf(p.sprint_speed - p.walk_speed, 0.1), 0.0, 1.0)
		var max_turn := deg_to_rad(lerpf(p.turn_rate_walk, p.turn_rate_sprint, kk)) * dt
		var ang := dir.angle_to(wish)
		dir = dir.rotated(clampf(ang, -max_turn, max_turn))
		speed *= 1.0 - clampf(absf(ang) - max_turn, 0.0, 1.0) * 0.6 * dt * 10.0
		hv = dir * speed
		wish = dir if absf(ang) > max_turn else wish
	var a := p.accel * p.get_accel_mult(speed / maxf(target, 0.01)) if speed < target else stop_d
	return hv.move_toward(wish * target, a * dt)


func _player_name(name: String) -> StringName:
	if name.contains("/") or driver.library_name == &"":
		return StringName(name)
	return StringName("%s/%s" % [driver.library_name, name])


func _anim(name: String) -> Animation:
	if name.contains("/"):
		var parts := name.split("/", true, 1)
		var lib: AnimationLibrary = driver.extra_libraries.get(parts[0])
		return lib.get_animation(parts[1]) if lib and lib.has_animation(parts[1]) else null
	return driver.library.get_animation(name) if driver.library and driver.library.has_animation(name) else null
