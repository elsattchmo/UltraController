class_name UltraBallistics
extends Node
## Rounds in flight (the authority's): every bullet / pellet leaves the gun at its
## `muzzle_velocity` (m/s), falls with gravity and slows with air drag (`drag`, 1/s: v *= e^-k t)
## and is swept one segment per physics tick - lag-compensated like a hitscan (the other players
## put back where the shooter saw them). A hit resolves like a hitscan's (UltraCombat
## .resolve_bullet, damage falloff by the distance flown); a shot's pellets landing in the same
## tick are summed per body region (UltraCombat.apply_pellets). Buckshot opens up past
## `pellet_bloom_from` m (each pellet turned out by `pellet_bloom_deg`). A round is dropped past
## the gun's `range` or after MAX_LIFE s.
## Every machine flies its own picture of the shot (UltraEffects: tracer, the whiz going by, the
## shooter's predicted impact); only this decides damage.

const GRAVITY := 9.81
const MAX_LIFE := 4.0

var _rounds: Array[Dictionary] = []
var _groups := {}                  ## shot id -> {shooter, def, origin, n, hits}
var _next := 1

static var _current: UltraBallistics


## The flight node of the running world (made on first use, under the current scene).
static func instance(tree: SceneTree) -> UltraBallistics:
	if is_instance_valid(_current) and _current.is_inside_tree():
		return _current
	_current = UltraBallistics.new()
	_current.name = "Ballistics"
	_current.process_physics_priority = 150          # (after the characters' ticks)
	var root: Node = tree.current_scene if tree.current_scene else tree.root
	root.add_child(_current)
	return _current


## Rounds fly with gravity (everything with a muzzle velocity).
static func flies(def: ItemDefinition) -> bool:
	return def != null and float(def.stat("muzzle_velocity", 0.0)) > 0.0


## A shot from `shooter`: one round per direction (several = one load of pellets).
func fire(shooter: UltraCharacter, origin: Vector3, dirs: Array, def: ItemDefinition) -> void:
	var speed := float(def.stat("muzzle_velocity", 800.0))
	var group := 0
	var axis := Vector3.ZERO
	if dirs.size() > 1:
		group = _next
		_next += 1
		_groups[group] = {"shooter": shooter, "def": def, "origin": origin, "n": dirs.size(), "hits": [], "live": dirs.size()}
		for d: Vector3 in dirs:
			axis += d
		axis = axis.normalized()
	for d: Vector3 in dirs:
		_rounds.append({"shooter": shooter, "def": def, "pos": origin, "vel": d.normalized() * speed,
			"dist": 0.0, "t": 0.0, "group": group, "axis": axis, "bloomed": false})


## How many are flying (tests).
func in_flight() -> int:
	return _rounds.size()


func _physics_process(delta: float) -> void:
	if _rounds.is_empty():
		return
	var keep: Array[Dictionary] = []
	for r in _rounds:
		if _advance(r, delta):
			keep.append(r)
	_rounds = keep
	# Loads whose pellets have all landed / gone: dealt as one blast.
	for g: int in _groups.keys():
		var gr: Dictionary = _groups[g]
		if int(gr.live) <= 0:
			var sh: Variant = gr.shooter
			if is_instance_valid(sh) and not (gr.hits as Array).is_empty():
				UltraCombat.apply_pellets(sh as UltraCharacter, gr.origin, gr.hits, gr.def, int(gr.n))
			_groups.erase(g)


## One tick of flight for round `r`; false once it's done (hit, out of range, too old).
func _advance(r: Dictionary, dt: float) -> bool:
	var shooter: UltraCharacter = r.shooter if is_instance_valid(r.shooter) else null
	var def: ItemDefinition = r.def
	var group := int(r.group)
	if shooter == null or not shooter.is_inside_tree():
		_done(group)
		return false
	var v0: Vector3 = r.vel
	var v1 := (v0 + Vector3.DOWN * GRAVITY * dt) * exp(-float(def.stat("drag", 0.0)) * dt)
	var step := (v0 + v1) * 0.5 * dt
	var from: Vector3 = r.pos
	var to := from + step
	var seg := step.length()
	if seg < 1e-5:
		_done(group)
		return false
	var dir := step / seg
	var space := shooter.get_world_3d().direct_space_state
	var excl: Array[RID] = [shooter.get_rid()]
	if shooter.hit_volume:
		excl.append(shooter.hit_volume.get_rid())
	var q := PhysicsRayQueryParameters3D.create(from, to, UltraCombat.MASK, excl)
	var hit: Dictionary = UltraNet.world.rewound(shooter, func() -> Dictionary: return UltraCombat._cast(space, q, from, dir))
	if not hit.is_empty():
		var flown := float(r.dist) + from.distance_to(hit.position)
		if group > 0 and _groups.has(group):
			hit["dir"] = dir
			hit["dist"] = flown
			(_groups[group].hits as Array).append(hit)
		else:
			UltraCombat.resolve_bullet(shooter, hit, dir, def, flown)
		_done(group)
		return false
	r.pos = to
	r.vel = v1
	r.dist = float(r.dist) + seg
	r.t = float(r.t) + dt
	# Buckshot: the pattern opens up past the bloom distance.
	if group > 0 and not r.bloomed and float(r.dist) >= float(def.stat("pellet_bloom_from", 6.0)):
		r.bloomed = true
		var bloom := deg_to_rad(float(def.stat("pellet_bloom_deg", 0.0)))
		var axis: Vector3 = r.axis
		var vd := v1.normalized()
		var off := vd - axis * vd.dot(axis)
		if bloom > 0.0 and off.length() > 1e-4:
			r.vel = (vd + off.normalized() * tan(bloom)).normalized() * v1.length()
	if float(r.dist) > float(def.stat("range", 300.0)) or float(r.t) > MAX_LIFE:
		_done(group)
		return false
	return true


func _done(group: int) -> void:
	if group > 0 and _groups.has(group):
		_groups[group].live = int(_groups[group].live) - 1
