class_name ZombieDirector
extends Node
## Runs the zombies' minds. Owns every ZombieBrain, thinks them when they are due (a brain near its
## prey ten times a second, a far idle one once a second, spread over the frames so no frame does
## them all), tells them about noises (UltraNoise events, and players' footsteps sampled at 5 Hz),
## hands out door-bashing places and alerts packs. Server / offline only: zombies are server-side bots.

const STEP_RATE := 0.2                 ## s between footstep samples
const PACK_ALERT_RANGE := 20.0

var brains: Array[ZombieBrain] = []
var now := 0.0
var _targets: Array[UltraCharacter] = []
var _targets_frame := -1
var _bashers := {}                      ## door -> [brain, ...]
var _step_t := 0.0
var _by_id := {}
var thinks := 0                         ## thinks run (stats, tests)
var max_thinks_per_frame := 12


func _ready() -> void:
	UltraNoise.listen(_on_noise)


func _exit_tree() -> void:
	UltraNoise.unlisten(_on_noise)


## Give `c` (a spawned zombie bot) a brain.
func add(c: UltraCharacter) -> ZombieBrain:
	var arch := ZombieArchetype.get_arch(c.get_meta("zombie", &"walker"))
	var b := ZombieBrain.new()
	b.setup(c, arch, self)
	b.next_think = now + randf() * 0.3
	brains.append(b)
	_by_id[c.net_id] = c
	return b


func remove(b: ZombieBrain) -> void:
	brains.erase(b)
	_by_id.erase(b.c.net_id)


## Living, non-zombie characters: what zombies hunt (rebuilt once a physics frame).
func targets() -> Array[UltraCharacter]:
	var f := Engine.get_physics_frames()
	if f != _targets_frame:
		_targets_frame = f
		_targets = []
		for p: NetPlayer in UltraNet.players.values():
			var ch := p.character
			if ch != null and is_instance_valid(ch) and not ZombieFactory.is_zombie(p) and ch.state.state != MotorState.Id.DEAD:
				_targets.append(ch)
	return _targets


func character_by_id(id: int) -> UltraCharacter:
	var p: NetPlayer = UltraNet.players.get(id)
	return p.character if p != null and is_instance_valid(p.character) else null


## --- presentation LOD (windowed only): what a zombie costs follows how much of it can be seen.
##   0  within LOD_NEAR m and in view: everything (foot IK within FOOT_IK_RANGE)
##   1  within LOD_MID m and in view: the animation steps at ~15 Hz, no foot IK / injury modifier, no shadow
##   2  further or out of view: the animation is frozen, no modifiers; out of view it is not drawn at all
## and a far sleeper is left out of the simulation (sim_skip) altogether.
const LOD_NEAR := 16.0
const LOD_MID := 40.0
const FOOT_IK_RANGE := 9.0
const SLEEP_SKIP := 38.0
const LOD_STEP := 1.0 / 15.0
const LOD_BATCH := 3                    ## zombies re-tiered per physics tick (each one ~4-5 times a second)
## A zombie standing still (dormant / idle) is simulated every IDLE_STRIDE-th tick: it has nothing to do.
const IDLE_STRIDE := 4
var lod_enabled := DisplayServer.get_name() != "headless"
var _lod_i := 0
var _viewers: Array[Camera3D] = []
var _viewers_t := 0.0


func _viewer_cameras() -> Array[Camera3D]:
	_viewers_t -= get_process_delta_time()
	if _viewers_t <= 0.0:
		_viewers_t = 1.0
		_viewers = []
		var vc := get_viewport().get_camera_3d()
		if vc:
			_viewers.append(vc)
		for r in get_tree().root.find_children("*", "UltraCameraRig", true, false):
			var cam := (r as UltraCameraRig).camera
			if cam and cam.is_inside_tree() and not _viewers.has(cam):
				_viewers.append(cam)
	return _viewers


var _dmin := 1e9                        ## nearest camera, left by _tier_of


func _tier_of(b: ZombieBrain, cams: Array[Camera3D]) -> int:
	var p := b.c.state.pos + Vector3.UP * 0.9
	var dmin := 1e9
	for cam in cams:
		dmin = minf(dmin, cam.global_position.distance_to(p))
	_dmin = dmin
	var in_view := false
	if dmin < LOD_MID:
		var space := b.c.get_world_3d().direct_space_state
		var ex: Array[RID] = [b.c.get_rid()]
		for cam in cams:
			if cam.is_position_in_frustum(p) or cam.is_position_in_frustum(p + Vector3.UP * 0.8):
				# In the frustum is not seen: a wall in between hides it (one ray to its middle and one to its head).
				if ZombieSenses.clear_line(space, cam.global_position, p, ex) or ZombieSenses.clear_line(space, cam.global_position, p + Vector3.UP * 0.7, ex):
					in_view = true
					break
	if dmin < 3.5:
		in_view = true                          # (right on top of the camera: the frustum test is shaky)
	if b.c.state.state in [MotorState.Id.RAGDOLL, MotorState.Id.GET_UP, MotorState.Id.DEAD] and dmin < LOD_MID:
		return 0 if in_view else 2
	if in_view and dmin < LOD_NEAR:
		return 0
	if in_view and dmin < LOD_MID:
		return 1
	return 2


## A zombie beyond LOD_MID that is still in the frustum with a clear line: drawn frozen rather than hidden.
func _far_visible(b: ZombieBrain, cams: Array[Camera3D]) -> bool:
	var p := b.c.state.pos + Vector3.UP * 0.9
	var space := b.c.get_world_3d().direct_space_state
	var ex: Array[RID] = [b.c.get_rid()]
	for cam in cams:
		if cam.is_position_in_frustum(p) and ZombieSenses.clear_line(space, cam.global_position, p, ex):
			return true
	return false


func _apply_tier(b: ZombieBrain, tier: int, near: bool, in_view_far: bool) -> void:
	var c := b.c
	var anim := c.anim as UltraLiteAnimDriver
	if anim == null or anim.tree == null:
		return
	if tier != b.lod:
		b.lod = tier
		match tier:
			0:
				anim.tree.active = true
				anim.tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE
				if c.body_fx and c.body_fx.injury:
					c.body_fx.injury.active = true
				if c.body_mesh():
					c.body_mesh().cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
				c.visual_root.visible = true
			1:
				anim.tree.active = true
				anim.tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
				b.lod_accum = randf() * LOD_STEP
				if c.body_fx and c.body_fx.injury:
					c.body_fx.injury.active = false
				if c.body_mesh():
					c.body_mesh().cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				c.visual_root.visible = true
			2:
				anim.tree.active = false
				if c.body_fx and c.body_fx.injury:
					c.body_fx.injury.active = false
				if c.body_mesh():
					c.body_mesh().cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if tier == 2:
		c.visual_root.visible = in_view_far
	# Hidden altogether (out of view or behind a wall): none of its presentation needs to run.
	var idle := tier == 2 and not in_view_far
	if idle != b.lod_idle:
		b.lod_idle = idle
		c.set_process(not idle)
		anim.set_process(not idle)
		if c.body_fx:
			c.body_fx.set_process(not idle)
	if anim.foot_ik:
		anim.foot_ik.active = tier == 0 and near


func _lod_pass() -> void:
	var n := brains.size()
	if n == 0:
		return
	var cams := _viewer_cameras()
	if cams.is_empty():
		return
	var tg := targets()
	var batch := mini(n, LOD_BATCH)
	for k in batch:
		_lod_i = (_lod_i + 1) % n
		var b := brains[_lod_i]
		if not is_instance_valid(b.c):
			continue
		var tier := _tier_of(b, cams)
		var dmin := _dmin
		# (Drawn only if it is a tier 0 / 1 zombie, or a far one in plain view: a tier-2 one was found hidden or out of range.)
		_apply_tier(b, tier, dmin < FOOT_IK_RANGE, tier < 2 or _far_visible(b, cams))
		b.c.live_hit_capture = tier == 0
		# A far sleeper isn't simulated at all.
		var near_target := 1e9
		for t in tg:
			near_target = minf(near_target, t.state.pos.distance_to(b.c.state.pos))
		b.c.sim_skip = b.mode in [ZombieBrain.Mode.DORMANT, ZombieBrain.Mode.IDLE, ZombieBrain.Mode.WANDER] and near_target > SLEEP_SKIP and dmin > SLEEP_SKIP


func _process(delta: float) -> void:
	if not lod_enabled:
		return
	for b in brains:
		if b.lod == 1 and is_instance_valid(b.c) and b.c.anim != null and b.c.anim.tree != null:
			b.lod_accum += delta
			if b.lod_accum >= LOD_STEP:
				b.c.anim.tree.advance(b.lod_accum)
				b.lod_accum = 0.0


func _physics_process(delta: float) -> void:
	now = Engine.get_physics_frames() / float(Engine.physics_ticks_per_second)
	if lod_enabled:
		_lod_pass()
	var tg := targets()
	# Footsteps: each player's movement is a small, steady noise.
	_step_t -= delta
	if _step_t <= 0.0:
		_step_t = STEP_RATE
		for t in tg:
			var loud := UltraNoise.step_loudness(t)
			if loud > 0.0:
				_broadcast(t.state.pos, loud, &"step")
	var budget := max_thinks_per_frame
	for b in brains:
		if b.next_think > now or budget <= 0:
			continue
		budget -= 1
		thinks += 1
		b.think(now)
		b.c.sim_period = _stride_of(b)
		b.next_think = now + _interval(b, tg)


## Standing still with nothing in mind: simulated every IDLE_STRIDE-th tick (anything stirring puts it back
## to 1: the brain's mode changes, damage, a shove).
func _stride_of(b: ZombieBrain) -> int:
	if b.mode != ZombieBrain.Mode.DORMANT and b.mode != ZombieBrain.Mode.IDLE:
		return 1
	var s := b.c.state
	if s.state != MotorState.Id.IDLE or not s.is_grounded() or s.platform_id != 0:
		return 1
	if s.vel.length_squared() > 0.01 or absf(s.turn_v) > 0.01 or absf(angle_difference(s.body_yaw, b.want_yaw)) > 0.05:
		return 1
	return IDLE_STRIDE


## How soon this brain thinks again: by what it's doing and how close prey is.
func _interval(b: ZombieBrain, tg: Array[UltraCharacter]) -> float:
	var near := 99.0
	for t in tg:
		near = minf(near, b.c.state.pos.distance_to(t.state.pos))
	var base := 0.1
	match b.mode:
		ZombieBrain.Mode.CHASE, ZombieBrain.Mode.ATTACK, ZombieBrain.Mode.BASH_DOOR, ZombieBrain.Mode.OPEN_DOOR, ZombieBrain.Mode.STAGGER:
			base = 0.1 if near < 25.0 else 0.2
		ZombieBrain.Mode.INVESTIGATE:
			base = 0.2
		ZombieBrain.Mode.IDLE, ZombieBrain.Mode.WANDER:
			base = 0.35 if near < 30.0 else 1.0
		ZombieBrain.Mode.DORMANT:
			base = 0.5 if near < 30.0 else 2.0
		ZombieBrain.Mode.DOWNED:
			base = 0.25
		ZombieBrain.Mode.DEAD:
			base = 5.0
	return base * randf_range(0.9, 1.1)


# ------------------------------------------------------------------ noise, alerts

func _on_noise(pos: Vector3, loud: float, kind: StringName, _source: int) -> void:
	_broadcast(pos, loud, kind)


func _broadcast(pos: Vector3, loud: float, kind: StringName) -> void:
	for b in brains:
		var reach := loud * b.arch.hearing + 1.0
		if b.c.state.pos.distance_to(pos) <= reach + 24.0:      # (walls add up to 15 m, floors 6 each)
			b.hear(pos, loud, kind)


## `from` saw prey at `pos`: every pack-mate within range that isn't busy comes to look.
func alert_pack(from: ZombieBrain, pos: Vector3) -> void:
	for b in brains:
		if b == from or b.mode not in [ZombieBrain.Mode.DORMANT, ZombieBrain.Mode.IDLE, ZombieBrain.Mode.WANDER]:
			continue
		if b.c.state.pos.distance_to(from.c.state.pos) <= PACK_ALERT_RANGE:
			b._begin_investigate(pos)


## Attack tokens: at most `max_attackers` zombies swing at one target at a time; the rest wait their turn
## (they crowd round it, facing it, and step in as a swinger dies, staggers or recovers).
var max_attackers := 4


func attack_blocked(b: ZombieBrain) -> bool:
	var n := 0
	for x in brains:
		if x != b and x.mode == ZombieBrain.Mode.ATTACK and x.target == b.target:
			n += 1
	return n >= max_attackers


## Where `b` should head round `t` so a crowd doesn't pile onto one spot: a place on a ring at its reach,
## taking its own bearing unless a nearer chaser has it (then the next free 40 deg either side).
func ring_dest(b: ZombieBrain, t: UltraCharacter) -> Vector3:
	var radius := b.arch.reach * 0.85
	var mine := atan2(b.c.state.pos.x - t.state.pos.x, b.c.state.pos.z - t.state.pos.z)
	var taken: Array[float] = []
	var my_d := b.c.state.pos.distance_squared_to(t.state.pos)
	for x in brains:
		if x == b or x.target != t or x.mode not in [ZombieBrain.Mode.CHASE, ZombieBrain.Mode.ATTACK]:
			continue
		var xd := x.c.state.pos.distance_squared_to(t.state.pos)
		if xd < my_d or (xd == my_d and x.c.net_id < b.c.net_id):
			taken.append(atan2(x.c.state.pos.x - t.state.pos.x, x.c.state.pos.z - t.state.pos.z))
	var a := mine
	var step := deg_to_rad(40.0)
	for k in 8:
		var clash := false
		for o in taken:
			if absf(angle_difference(a, o)) < step * 0.9:
				clash = true
				break
		if not clash:
			break
		a = mine + step * (float(k / 2 + 1) * (1.0 if k % 2 == 0 else -1.0))
	return t.state.pos + Vector3(sin(a), 0.0, cos(a)) * radius


## Zombies in a hunting mode (what `max_awake` caps).
func awake_count() -> int:
	var n := 0
	for b in brains:
		if b.mode in [ZombieBrain.Mode.CHASE, ZombieBrain.Mode.ATTACK, ZombieBrain.Mode.INVESTIGATE, ZombieBrain.Mode.BASH_DOOR, ZombieBrain.Mode.OPEN_DOOR, ZombieBrain.Mode.STAGGER]:
			n += 1
	return n


var max_awake := 24


## Wake up to `n` of the nearest sleepers within `radius` of `pos`: they go and look (`hunt` false) or know where
## the target is (`hunt` true). The cap (`max_awake`) holds. Returns how many woke.
func wake_near(pos: Vector3, radius: float, n: int, t: UltraCharacter, hunt: bool) -> int:
	var sleepers: Array[ZombieBrain] = []
	for b in brains:
		if b.mode in [ZombieBrain.Mode.DORMANT, ZombieBrain.Mode.IDLE, ZombieBrain.Mode.WANDER] and b.c.state.pos.distance_to(pos) <= radius:
			sleepers.append(b)
	sleepers.sort_custom(func(a: ZombieBrain, c: ZombieBrain) -> bool: return a.c.state.pos.distance_squared_to(pos) < c.c.state.pos.distance_squared_to(pos))
	var woke := 0
	for b in sleepers:
		if woke >= n or awake_count() >= max_awake:
			break
		if hunt and t != null:
			b._alert(t, now)
		else:
			b._begin_investigate(pos)
		woke += 1
	return woke


## Bring corpses back as fresh zombies at `spawns` (Transform3D), hunting `t`: the farthest from the target
## first, none within 12 m of any target. Returns how many came back. (Player ids are never reused: a
## dead zombie is recycled, not replaced.)
func recycle(n: int, spawns: Array, t: UltraCharacter) -> int:
	var dead: Array[ZombieBrain] = []
	var tg := targets()
	for b in brains:
		if b.mode != ZombieBrain.Mode.DEAD:
			continue
		var near := false
		for p in tg:
			if p.state.pos.distance_to(b.c.state.pos) < 12.0:
				near = true
		if not near:
			dead.append(b)
	dead.sort_custom(func(a: ZombieBrain, c: ZombieBrain) -> bool: return t != null and a.c.state.pos.distance_squared_to(t.state.pos) > c.c.state.pos.distance_squared_to(t.state.pos))
	var k := 0
	for b in dead:
		if k >= n or spawns.is_empty():
			break
		revive(b, spawns[k % spawns.size()], t)
		k += 1
	return k


func revive(b: ZombieBrain, xf: Transform3D, t: UltraCharacter) -> void:
	b.c.set_meta("home", xf)
	UltraNet.respawn_character(b.c)
	ZombieFactory.dress(b.c, true)
	b.reset(ZombieBrain.Mode.CHASE if t != null else ZombieBrain.Mode.IDLE, t)
	b.next_think = now


## At most two zombies batter a door at once.
func request_bash(door: UltraDoor, b: ZombieBrain) -> bool:
	var list: Array = _bashers.get_or_add(door, [])
	list = list.filter(func(x: ZombieBrain) -> bool: return x.mode == ZombieBrain.Mode.BASH_DOOR)
	_bashers[door] = list
	if b in list:
		return true
	if list.size() >= 2:
		return false
	list.append(b)
	return true


func release_bash(door: UltraDoor, b: ZombieBrain) -> void:
	if _bashers.has(door):
		(_bashers[door] as Array).erase(b)
