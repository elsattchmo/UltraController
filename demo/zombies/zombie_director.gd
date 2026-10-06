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


func _physics_process(delta: float) -> void:
	now = Engine.get_physics_frames() / float(Engine.physics_ticks_per_second)
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
		b.next_think = now + _interval(b, tg)


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


## Strike permission (attack tokens come in stage 4): always for now.
func attack_blocked(_b: ZombieBrain) -> bool:
	return false


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
