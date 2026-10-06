class_name UltraNoise
extends RefCounted
## The noise bus: anything loud tells it where and how loud; the AI (a zombie director) listens and
## decides who hears. Emitted only by the AUTHORITY (a server's / offline player's simulation, never a
## replay or a client's prediction), so every machine's zombies get the same events.
##
## Loudness is a radius in metres (how far a shot carries in open air); who hears it is up to the
## listener (floors, walls, doors, the listener's own hearing - see ZombieSenses.hears).
## Footsteps are not events: the director samples players' movement at a few Hz (`step_loudness`).

static var _listeners: Array[Callable] = []
static var emitted := 0                     ## events since the last clear() (stats, tests)
static var last := {}                       ## the last event {pos, loud, kind, source}: debugging


static func listen(cb: Callable) -> void:
	if not _listeners.has(cb):
		_listeners.append(cb)


static func unlisten(cb: Callable) -> void:
	_listeners.erase(cb)


static func clear() -> void:
	_listeners.clear()
	emitted = 0
	last = {}


## `cb(pos: Vector3, loudness: float, kind: StringName, source: int)` for every listener.
static func emit(pos: Vector3, loudness: float, kind: StringName = &"", source := 0) -> void:
	emitted += 1
	last = {"pos": pos, "loud": loudness, "kind": kind, "source": source}
	for cb in _listeners.duplicate():
		if cb.is_valid():
			cb.call(pos, loudness, kind, source)
		else:
			_listeners.erase(cb)


## How far a shot from `def` carries (item stat "noise" in metres, else by weapon).
static func gun_noise(def: ItemDefinition) -> float:
	var n: float = float(def.stat("noise", 0.0))
	if n > 0.0:
		return n
	match String(def.id):
		"pistol":
			return 35.0
		"rifle":
			return 50.0
		"shotgun":
			return 60.0
	return 40.0


## How loud a character's own movement is (m): sprinting 13, jogging 9, walking 4.5, creeping 1.5, still 0.
static func step_loudness(c: UltraCharacter) -> float:
	var s := c.state
	if s.state == MotorState.Id.DEAD or s.state == MotorState.Id.RAGDOLL:
		return 0.0
	var v := Vector2(s.vel.x, s.vel.z).length()
	if v < 0.3 or not s.is_grounded():
		return 0.0
	if s.stance != MotorState.Stance.STAND:
		return 1.5
	if s.has(MotorState.F_SPRINTING) and v > c.profile.jog_speed * 0.9:
		return 13.0
	if v > c.profile.walk_speed * 1.6:
		return 9.0
	return 4.5
