class_name ZombieBrain
extends RefCounted
## One zombie's mind: modes, senses, path following, doors, strikes. Owned by the ZombieDirector, which
## calls `think()` when it is due (a few to ten times a second, by mode and distance); `drive()` is the
## per-tick part - it only turns toward `want_yaw` (rate limited) and walks - and is what the
## character's BotInputSource asks for its InputFrame. Never reads animation, skeleton or render state:
## it decides from MotorState, physics queries and UltraNav, so the same brain runs on a server and
## offline.
##
##   DORMANT     stands (or lies) still; wakes to sight / sound / being hurt
##   IDLE        stands, now and then wanders; WANDER ambles to a point round home
##   INVESTIGATE goes to where it heard or last saw something, looks about, gives up
##   CHASE       goes for its target (sees it or the last place it did), strikes when in reach
##   ATTACK      a swing (claw clip, hit at its contact time); STAGGER: stopped by a hit
##   OPEN_DOOR   reaches a shut door on its path, opens it; BASH_DOOR: a locked / barricaded one is battered
##   DOWNED      knocked over / getting up; DEAD

enum Mode { DORMANT, IDLE, WANDER, INVESTIGATE, CHASE, ATTACK, STAGGER, OPEN_DOOR, BASH_DOOR, DOWNED, DEAD }
const MODE_NAMES := ["dormant", "idle", "wander", "investigate", "chase", "attack", "stagger", "open_door", "bash_door", "downed", "dead"]

const STAGGER_MIN := 3.0             ## region-weighted damage that stops it in its tracks
const HIT_FROM := 0.45               ## s from the swing's start to its contact
const SWING_LEN := 1.0               ## s of a swing (contact at HIT_FROM, then recovery)
const DOOR_REACH := 1.25             ## m from a door's link end at which it deals with the door
const ARRIVE := 0.5

var c: UltraCharacter
var arch: ZombieArchetype
var director: ZombieDirector
var mode: int = Mode.IDLE
var rng := RandomNumberGenerator.new()

var target: UltraCharacter
var awareness := 0.0
var last_seen := Vector3.INF
var last_seen_t := -1000.0
var heard := Vector3.INF
var heard_t := -1000.0

var path := PackedVector3Array()
var path_types := PackedInt32Array()
var path_owners := PackedInt64Array()
var path_i := 0
var goal := Vector3.INF
var home := Vector3.ZERO

var want_yaw := 0.0
var move_mag := 0.0
var sprint := false
var next_think := 0.0                ## (the director's schedule)

var _now := 0.0
var _last_think := 0.0
var _until := 0.0
var _resume: int = Mode.IDLE
var _door: UltraDoor
var _door_phase := 0
var _cleared: UltraDoor              ## the door it just dealt with (don't stop for it again)
var _atk := {}
var _atk_ready := 0.0
var _repath_at := 0.0
var _stuck_pos := Vector3.INF
var _stuck_t := 0.0
var _stuck_n := 0
var _side_until := 0.0
var _side_dir := 0.0
var _back_until := 0.0
var _looking := false
var _look_sign := 1.0
var lod := 0                         ## presentation tier (ZombieDirector's pass): 0 full, 1 mid, 2 far / off screen
var lod_accum := 0.0
var lod_step := -1.0                 ## animation step (s) when it isn't every frame; 0 = every frame, -1 = unset
var lod_idle := false                ## hidden: its presentation nodes are not processing
var pack := ""                       ## the sandbox pack it belongs to
var home_spawn := Vector3.ZERO       ## where it started (a reset sends it back)
var kills := 0
var strikes := 0                     ## swings that landed (stats, tests)


func setup(p_char: UltraCharacter, p_arch: ZombieArchetype, p_director: ZombieDirector) -> void:
	c = p_char
	arch = p_arch
	director = p_director
	home = c.state.pos
	want_yaw = c.state.body_yaw
	rng.seed = hash(c.net_id) ^ 0x5eed
	var src := c.input_source as BotInputSource
	src.live_yaw = c.state.body_yaw
	src.driver = drive
	c.damaged.connect(_on_damaged)
	c.died.connect(func() -> void: _enter(Mode.DEAD))


## Back to a fresh zombie in `m` (a respawn): forget everything, optionally already hunting `t`.
func reset(m: int, t: UltraCharacter = null) -> void:
	if mode == Mode.BASH_DOOR and _door != null and director != null:
		director.release_bash(_door, self)
	_door = null
	_cleared = null
	_atk = {}
	path = PackedVector3Array()
	goal = Vector3.INF
	heard = Vector3.INF
	awareness = 0.0
	target = null
	last_seen = Vector3.INF
	last_seen_t = -1000.0
	_atk_ready = 0.0
	_stuck_pos = Vector3.INF
	_stuck_n = 0
	_side_until = 0.0
	_back_until = 0.0
	_looking = false
	home = c.state.pos
	want_yaw = c.state.body_yaw
	if c.input_source:
		(c.input_source as BotInputSource).live_yaw = c.state.body_yaw
	mode = m
	c.sim_period = 1
	_halt()
	if t != null:
		target = t
		awareness = 1.2
		last_seen = t.state.pos
		last_seen_t = _now
	if m == Mode.IDLE:
		_until = _now + rng.randf_range(1.0, 4.0)


func mode_name() -> String:
	return MODE_NAMES[mode]


# ------------------------------------------------------------------ per tick

## The character's input this tick: turn toward `want_yaw` (slowly: zombies pivot), walk when roughly facing it.
func drive(tick: int, src: BotInputSource) -> InputFrame:
	var f := InputFrame.new()
	f.tick = tick
	var dt := float(c.sim_period) / float(Engine.physics_ticks_per_second)       # (a strided step covers several ticks)
	var err := angle_difference(src.live_yaw, want_yaw)
	src.live_yaw += clampf(err, -arch.turn_rate * dt, arch.turn_rate * dt)
	f.yaw = src.live_yaw
	f.pitch = 0.0
	if move_mag > 0.01 and c.state.state not in [MotorState.Id.DEAD, MotorState.Id.RAGDOLL, MotorState.Id.GET_UP]:
		var facing := clampf(1.0 - (absf(angle_difference(src.live_yaw, want_yaw)) - 0.4) / 0.9, 0.0, 1.0)
		var y := move_mag * facing
		var x := 0.0
		if _now < _side_until:
			x = _side_dir * 0.8                     # (a stuck zombie shuffles sideways a moment)
		if _now < _back_until:
			y = -0.7                                # ... or backs off
		f.move = Vector2(x, y)
		if sprint and facing > 0.9:
			f.buttons |= InputFrame.B_SPRINT
	return f


# ------------------------------------------------------------------ the mind

func think(now: float) -> void:
	var dt := clampf(now - _last_think, 0.0, 1.0)
	_last_think = now
	_now = now
	var Id := MotorState.Id
	var st := c.state.state
	if st == Id.DEAD:
		if mode != Mode.DEAD:
			_enter(Mode.DEAD)
		_halt()
		return
	if st == Id.RAGDOLL or st == Id.GET_UP or c.state.has(MotorState.F_UNCONSCIOUS):
		if mode != Mode.DOWNED:
			_atk = {}
			_enter(Mode.DOWNED)
		_halt()
		return
	if mode == Mode.DOWNED:
		_enter(Mode.CHASE if target != null and now - last_seen_t < arch.memory else Mode.IDLE)
	_sense(now, dt)
	match mode:
		Mode.DORMANT:
			_halt()
		Mode.IDLE:
			_think_idle(now)
		Mode.WANDER:
			_think_wander(now)
		Mode.INVESTIGATE:
			_think_investigate(now)
		Mode.CHASE:
			_think_chase(now)
		Mode.ATTACK:
			_think_attack(now)
		Mode.STAGGER:
			_halt()
			if now >= _until:
				_enter(Mode.CHASE if target != null else Mode.IDLE)
		Mode.OPEN_DOOR:
			_think_open_door(now)
		Mode.BASH_DOOR:
			_think_bash_door(now)
	if mode in [Mode.WANDER, Mode.INVESTIGATE, Mode.CHASE] and move_mag > 0.0:
		_check_stuck(now)


func _enter(m: int) -> void:
	if mode == m:
		return
	if mode == Mode.BASH_DOOR and _door != null:
		director.release_bash(_door, self)
	mode = m
	c.sim_period = 1
	_until = 0.0
	if m in [Mode.IDLE, Mode.DORMANT, Mode.DOWNED, Mode.DEAD, Mode.STAGGER]:
		_halt()
	if m == Mode.IDLE:
		_until = _now + rng.randf_range(2.5, 7.0)


func _halt() -> void:
	move_mag = 0.0
	sprint = false


# ------------------------------------------------------------------ senses

func _sense(now: float, dt: float) -> void:
	var space := c.get_world_3d().direct_space_state
	var best: UltraCharacter = null
	var best_v := 0.0
	var reach := arch.sight_range * 1.45 + 2.0
	for t: UltraCharacter in director.targets():
		if c.state.pos.distance_to(t.state.pos) > reach:
			continue
		var v := ZombieSenses.sight(c, arch, t, space)
		if v > best_v:
			best_v = v
			best = t
	if best != null:
		var d := _flat_dist(best.state.pos)
		var rate := 4.0 if d < arch.close_sense * 2.0 else lerpf(2.4, 0.8, clampf(d / arch.sight_range, 0.0, 1.0))
		awareness = minf(awareness + rate * dt, 1.2)
		target = best
		last_seen = best.state.pos
		last_seen_t = now
	else:
		awareness = maxf(awareness - 0.25 * dt, 0.0)
	if mode in [Mode.DORMANT, Mode.IDLE, Mode.WANDER, Mode.INVESTIGATE] and target != null:
		if awareness >= 1.0:
			_alert(target, now)
		elif awareness >= 0.35 and mode != Mode.INVESTIGATE:
			_begin_investigate(last_seen)


## A noise at `pos` (the director found it within a rough radius): does it carry to here?
func hear(pos: Vector3, loud: float, _kind: StringName) -> void:
	if mode in [Mode.DEAD, Mode.DOWNED, Mode.ATTACK, Mode.CHASE, Mode.STAGGER, Mode.BASH_DOOR, Mode.OPEN_DOOR]:
		return
	if not ZombieSenses.hears(c, arch, pos, loud, c.get_world_3d().direct_space_state):
		return
	heard = pos
	heard_t = _now
	if mode == Mode.INVESTIGATE:
		goal = Vector3.INF               # (re-aim at the new sound)
	_begin_investigate(pos)


func _alert(t: UltraCharacter, now: float) -> void:
	target = t
	awareness = 1.2
	last_seen = t.state.pos
	last_seen_t = now
	_enter(Mode.CHASE)
	goal = Vector3.INF
	director.alert_pack(self, t.state.pos)


func _begin_investigate(pos: Vector3) -> void:
	heard = pos
	goal = Vector3.INF
	_enter(Mode.INVESTIGATE)
	_until = _now + arch.memory * 0.7
	_looking = false


func _lose_target(now: float) -> void:
	target = null
	awareness = 0.0
	if last_seen != Vector3.INF:
		_begin_investigate(last_seen)
	else:
		_enter(Mode.IDLE)


# ------------------------------------------------------------------ modes

func _think_idle(now: float) -> void:
	_halt()
	if now >= _until:
		if rng.randf() < 0.6:
			_enter(Mode.WANDER)
		else:
			_until = now + rng.randf_range(2.5, 7.0)


func _think_wander(now: float) -> void:
	if goal == Vector3.INF:
		var p := UltraNav.snap(home + Vector3(rng.randf_range(-6.0, 6.0), 0.0, rng.randf_range(-6.0, 6.0)))
		if p == Vector3.INF or absf(p.y - home.y) > 1.0 or not _set_goal(p, now):
			_enter(Mode.IDLE)
			return
		_until = now + 25.0
	move_mag = 0.55
	sprint = false
	if _follow(now) or now >= _until:
		_enter(Mode.IDLE)
		goal = Vector3.INF


func _think_investigate(now: float) -> void:
	sprint = false
	if heard == Vector3.INF:
		_enter(Mode.IDLE)
		return
	if not _looking:
		if goal == Vector3.INF and not _set_goal(UltraNav.snap(heard), now):
			_enter(Mode.IDLE)
			return
		move_mag = 0.85
		if _follow(now):
			_looking = true                  # (arrived: look about a while)
			_until = maxf(_until, now + 2.2)
			_look_sign = 1.0 if rng.randf() < 0.5 else -1.0
		elif now > _until + 20.0:
			_enter(Mode.IDLE)
		return
	_halt()
	want_yaw += 0.05 * _look_sign * (1.0 if int((_until - now) * 1.5) % 2 == 0 else -1.0)
	if now >= _until:
		heard = Vector3.INF
		goal = Vector3.INF
		_enter(Mode.IDLE)


func _arrived() -> bool:
	return path.is_empty() or (path_i >= path.size() - 1 and _flat_dist(path[path.size() - 1]) < ARRIVE + 0.2)


func _think_chase(now: float) -> void:
	if target == null or not is_instance_valid(target) or target.state.state == MotorState.Id.DEAD:
		_lose_target(now)
		return
	var visible := now - last_seen_t < 0.4
	var dest := target.state.pos if visible else last_seen
	var d := _flat_dist(target.state.pos)
	if visible and d < 7.0 and d > arch.reach + 1.4:
		dest = director.ring_dest(self, target)           # (fan out round it instead of queueing on one spot; the last step is straight in)
	if visible and d <= arch.reach + 0.25 and absf(target.state.pos.y - c.state.pos.y) < 1.5 and now >= _atk_ready and not director.attack_blocked(self):
		_begin_attack(now)
		return
	if not visible and now - last_seen_t > arch.memory:
		_lose_target(now)
		return
	# At its prey's side but waiting its turn to strike (or recovering): face it, stand.
	if visible and d <= arch.reach + 0.25 and absf(target.state.pos.y - c.state.pos.y) < 1.5:
		want_yaw = _yaw_to(target.state.pos)
		_halt()
		return
	if not visible and _flat_dist(last_seen) < 1.0:
		_halt()
		return
	_goto(dest, now, 0.3)
	move_mag = 1.0
	sprint = arch.run_speed > 0.0 and d > 2.5
	_follow(now)


func _begin_attack(now: float) -> void:
	var role: StringName = arch.attacks[rng.randi() % arch.attacks.size()]
	var spec: Dictionary = ZombieArchetype.CLIPS[role]
	_atk = {"role": role, "t0": now, "hit_at": now + HIT_FROM, "end": now + SWING_LEN, "done": false}
	_enter(Mode.ATTACK)
	_halt()
	want_yaw = _yaw_to(target.state.pos)
	if c.anim is UltraLiteAnimDriver:
		(c.anim as UltraLiteAnimDriver).play_attack(role, spec.seg, spec.contact, HIT_FROM, c.state.state == MotorState.Id.CRAWL)


func _think_attack(now: float) -> void:
	_halt()
	if target != null and is_instance_valid(target):
		want_yaw = _yaw_to(target.state.pos)
	if not bool(_atk.get("done", true)) and now >= float(_atk.hit_at):
		_atk.done = true
		_strike()
	if now >= float(_atk.get("end", 0.0)):
		_atk_ready = float(_atk.get("t0", now)) + arch.interval * rng.randf_range(0.9, 1.2)
		_atk = {}
		_enter(Mode.CHASE)


## The blow lands (or misses): the target still in front of it and within a little more than reach.
func _strike() -> void:
	if target == null or not is_instance_valid(target) or target.state.state == MotorState.Id.DEAD:
		return
	var d := _flat_dist(target.state.pos)
	var ang := absf(angle_difference(c.state.body_yaw, _yaw_to(target.state.pos)))
	if d > arch.reach * 1.2 + 0.2 or ang > deg_to_rad(75.0) or absf(target.state.pos.y - c.state.pos.y) > 1.6:
		return
	var info := UltraCombat.DamageInfo.new()
	info.amount = arch.damage * rng.randf_range(0.85, 1.15)
	info.kind = &"claw"
	info.melee = true
	var dir := target.state.pos - c.state.pos
	dir.y = 0.0
	info.dir = dir.normalized()
	var side := Vector3(-info.dir.z, 0.0, info.dir.x) * rng.randf_range(-0.2, 0.2)
	info.point = target.state.pos + Vector3.UP * rng.randf_range(0.75, 1.45) + side
	info.attacker_id = c.net_id
	info.shove = info.dir * 1.4
	target.apply_damage(info)
	strikes += 1


func _think_open_door(now: float) -> void:
	_halt()
	if _door == null or not is_instance_valid(_door) or _door.broken:
		_leave_door()
		return
	want_yaw = _yaw_to(_door.global_position)
	if _door_phase == 0 and now >= _until:
		if _door.is_blocked():
			_enter(Mode.BASH_DOOR)
			return
		_door.ai_open(c.state.pos)
		_door_phase = 1
		_until = now + 0.9
	elif _door_phase == 1 and now >= _until:
		_leave_door()


func _think_bash_door(now: float) -> void:
	_halt()
	if _door == null or not is_instance_valid(_door) or _door.broken or _door.is_open or not _door.is_blocked():
		if _door != null and is_instance_valid(_door) and not _door.is_blocked() and not _door.is_open:
			_enter(Mode.OPEN_DOOR)
			_door_phase = 0
			_until = now + 0.3
			return
		_leave_door()
		return
	want_yaw = _yaw_to(_door.global_position)
	if not director.request_bash(_door, self):
		return                              # (two bashers at most: wait your turn)
	if _atk.is_empty() and now >= _until:
		var spec: Dictionary = ZombieArchetype.CLIPS[&"atk_swipe"]
		_atk = {"hit_at": now + HIT_FROM, "end": now + 1.3, "done": false}
		if c.anim is UltraLiteAnimDriver:
			(c.anim as UltraLiteAnimDriver).play_attack(&"atk_swipe", spec.seg, spec.contact, HIT_FROM, c.state.state == MotorState.Id.CRAWL)
	elif not _atk.is_empty():
		if not bool(_atk.done) and now >= float(_atk.hit_at):
			_atk.done = true
			_door.bash(arch.damage * 1.4, c.state.pos)
		if now >= float(_atk.end):
			_atk = {}
			_until = now + 0.15


func _leave_door() -> void:
	_cleared = _door
	_door = null
	_atk = {}
	_enter(_resume if _resume != Mode.BASH_DOOR and _resume != Mode.OPEN_DOOR else Mode.CHASE)


# ------------------------------------------------------------------ hurt

func _on_damaged(info: UltraCombat.DamageInfo) -> void:
	if mode == Mode.DEAD:
		return
	var att := director.character_by_id(info.attacker_id)
	if att != null and not ZombieFactory.is_zombie(UltraNet.players.get(att.net_id)):
		target = att
		awareness = 1.2
		last_seen = att.state.pos
		last_seen_t = _now
		if mode in [Mode.DORMANT, Mode.IDLE, Mode.WANDER, Mode.INVESTIGATE]:
			_alert(att, _now)
	if mode in [Mode.DOWNED, Mode.DEAD]:
		return
	var r := clampi(info.region, 0, c.damage_profile.region_mult.size() - 1)
	var eff := info.amount * c.damage_profile.region_mult[r]
	if info.region == UltraLimbs.Region.HEAD:
		eff *= 1.6
	if eff >= STAGGER_MIN and mode != Mode.STAGGER:
		_atk = {}
		if c.anim is UltraLiteAnimDriver:
			(c.anim as UltraLiteAnimDriver).stop_attack()
		_enter(Mode.STAGGER)
		_until = _now + clampf(0.25 + eff * 0.035, 0.35, 1.2)


# ------------------------------------------------------------------ paths

func _set_goal(p: Vector3, now: float) -> bool:
	goal = p
	return _repath(now)


func _goto(dest: Vector3, now: float, interval: float) -> void:
	if goal == Vector3.INF or now >= _repath_at or goal.distance_to(dest) > 2.0:
		goal = dest
		_repath(now)
		_repath_at = now + interval


func _repath(now: float) -> bool:
	_repath_at = now + 0.3
	var r := UltraNav.query(c.state.pos, goal)
	if r.path.size() < 2:
		path = PackedVector3Array()
		return false
	path = r.path.duplicate()
	path_types = r.path_types.duplicate()
	path_owners = r.path_owner_ids.duplicate()
	path_i = 1
	_skip_passed()
	return true


## Waypoints already behind us (we are further along their segment than they are): a fresh path from a
## spot just past a door's link start would send us back to it.
func _skip_passed() -> void:
	while path_i < path.size() - 1:
		var door := _door_at(path_i)
		if door != null and not door.is_open and not door.broken:
			return
		var a := path[path_i]
		var along := path[path_i + 1] - a
		along.y = 0.0
		if (_flat(c.state.pos - a)).dot(along) > 0.0 and _flat(c.state.pos - a).length() < 2.5:
			path_i += 1
		else:
			return


func _door_at(i: int) -> UltraDoor:
	if i < path_types.size() and path_types[i] == NavigationPathQueryResult3D.PATH_SEGMENT_TYPE_LINK and i < path_owners.size():
		var id := int(path_owners[i])
		if id != 0 and is_instance_id_valid(id):
			return instance_from_id(id) as UltraDoor
	return null


## Walk the path: steer at the next waypoint, deal with a door in the way. True once there.
func _follow(now: float) -> bool:
	if path.is_empty():
		move_mag = 0.0
		return false
	var pos := c.state.pos
	while path_i < path.size():
		var wp0 := path[path_i]
		var d0 := _flat(wp0 - pos).length()
		var door := _door_at(path_i)
		if door != null and not door.is_open and not door.broken and door != _cleared:
			if d0 < DOOR_REACH:
				_resume = mode
				_door = door
				_door_phase = 0
				_atk = {}
				_halt()
				if door.is_blocked():
					_enter(Mode.BASH_DOOR)
				else:
					_enter(Mode.OPEN_DOOR)
					_until = now + 0.5
				return false
			break                              # (walk up to it first)
		if d0 < ARRIVE and path_i < path.size() - 1:
			path_i += 1
			continue
		break
	if _door_at(path_i) == null:
		_cleared = null                        # (past it)
	var wp := path[path_i]
	var dist := _flat(wp - pos).length()
	if path_i >= path.size() - 1 and dist < ARRIVE:
		move_mag = 0.0
		return true
	want_yaw = _yaw_to(wp)
	return false


func _check_stuck(now: float) -> void:
	if _stuck_pos == Vector3.INF:
		_stuck_pos = c.state.pos
		_stuck_t = now
		return
	if now - _stuck_t < 1.4:
		return
	var moved := _flat_dist(_stuck_pos)
	_stuck_pos = c.state.pos
	_stuck_t = now
	if moved > 0.25:
		_stuck_n = 0
		return
	_stuck_n += 1
	if _stuck_n == 1:
		goal = Vector3.INF                 # (repath)
	elif _stuck_n == 2:
		_side_dir = 1.0 if rng.randf() < 0.5 else -1.0
		_side_until = now + 0.8
	elif _stuck_n == 3:
		_back_until = now + 1.0
		goal = Vector3.INF
	else:
		_side_dir = -_side_dir
		_side_until = now + 1.2
		goal = Vector3.INF
		_stuck_n = 1


# ------------------------------------------------------------------ small helpers

static func _flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)


func _flat_dist(p: Vector3) -> float:
	return _flat(p - c.state.pos).length()


func _yaw_to(p: Vector3) -> float:
	var d := p - c.state.pos
	return atan2(-d.x, -d.z)
