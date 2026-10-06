class_name MansionSandbox
extends Node
## The endless zombie sandbox: packs lie about the mansion (MansionLayout.PACKS), wake as the player
## enters their rooms or makes a noise they hear, and hunt; there is no way to win. A WAVE button in
## the foyer (also F11) wakes everything near and brings fresh zombies in from outside (corpses recycled:
## player ids are never reused); a RESET button (F12) puts it all back. Kills are counted. Server /
## offline only: call `start(map)` once the session runs.

signal wave_started(woke: int, arrivals: int)
signal reset_done
signal kills_changed(n: int)

const SPAWNS_PER_TICK := 2
const WAVE_ENTRANCES := [Vector3(28, 0.05, 52), Vector3(22, 0.05, 56), Vector3(34, 0.05, 56), Vector3(48, 0.05, 46), Vector3(8, 0.05, 46), Vector3(-6, 0.05, 20), Vector3(62, 0.05, 20)]

var map: Mansion
var director: ZombieDirector
var debug: ZombieDebug
var hud: ZombieHud
var kills := 0
var packs := {}                         ## pack name -> {"def": Dictionary, "brains": Array[ZombieBrain], "woken": bool}
var spawned := 0
var ready_to_play := false              ## the first zombies are all in
var waves := 0

var _queue: Array = []                  ## [pack name, archetype, Transform3D, mode]
var _rng := RandomNumberGenerator.new()
var _watch_t := 0.0
var _count := 0
var _items: Array[Node] = []
var _switches: Array[Node] = []
var started := false


func start(p_map: Mansion) -> void:
	if started:
		return
	started = true
	map = p_map
	_rng.seed = 2026
	director = ZombieDirector.new()
	director.name = "Director"
	add_child(director)
	debug = ZombieDebug.new()
	debug.director = director
	add_child(debug)
	hud = ZombieHud.new()
	hud.sandbox = self
	add_child(hud)
	await UltraNav.wait_ready(get_tree())
	_plan()
	_place_buttons()
	_stock()


# ------------------------------------------------------------------ the packs

func _plan() -> void:
	for pd: Dictionary in MansionLayout.PACKS:
		packs[pd.n] = {"def": pd, "brains": [], "woken": false}
		var pts := _points(pd)
		for k in pts.size():
			var arch := _pick_arch(pd.mix)
			var yaw := _rng.randf() * TAU
			_queue.append([pd.n, arch, Transform3D(Basis(Vector3.UP, yaw), pts[k]), ZombieBrain.Mode.DORMANT if pd.wake == "room" else ZombieBrain.Mode.IDLE])


func _pick_arch(mix: Dictionary) -> StringName:
	var total := 0.0
	for k in mix:
		total += float(mix[k])
	var r := _rng.randf() * total
	for k: StringName in mix:
		r -= float(mix[k])
		if r <= 0.0:
			return k
	return &"walker"


## `count` spots for a pack: inside its rooms (or given outright), on the navmesh at floor level, clear of
## furniture and each other.
func _points(pd: Dictionary) -> Array[Vector3]:
	var out: Array[Vector3] = []
	if pd.has("at"):
		for a: Array in pd.at:
			out.append(Vector3(a[0], 0.05, a[1]))
		return out
	var rects: Array = []
	for rn: String in pd.rooms:
		var r := MansionLayout.room(rn)
		if not r.is_empty():
			rects.append([MansionLayout.rect_of(r).grow(-0.9), MansionLayout.floor_y(int(r[1]))])
	if rects.is_empty():
		return out
	var tries := 0
	while out.size() < int(pd.count) and tries < 400:
		tries += 1
		var rr: Array = rects[_rng.randi() % rects.size()]
		var rect: Rect2 = rr[0]
		var fy: float = rr[1]
		if rect.size.x <= 0.0 or rect.size.y <= 0.0:
			continue
		var p := Vector3(rect.position.x + _rng.randf() * rect.size.x, fy + 0.1, rect.position.y + _rng.randf() * rect.size.y)
		var q := UltraNav.snap(p)
		if q == Vector3.INF or Vector2(q.x - p.x, q.z - p.z).length() > 0.25 or absf(q.y - p.y) > 0.4:
			continue
		var too_close := false
		for o in out:
			if Vector2(o.x - p.x, o.z - p.z).length() < 1.7 and absf(o.y - fy) < 1.0:
				too_close = true
		if too_close:
			continue
		out.append(Vector3(p.x, fy + 0.05, p.z))
	return out


func _physics_process(delta: float) -> void:
	if not started or director == null:
		return
	for k in SPAWNS_PER_TICK:
		if _queue.is_empty():
			break
		_spawn(_queue.pop_front())
		if _queue.is_empty():
			ready_to_play = true
	_watch_t -= delta
	if _watch_t <= 0.0:
		_watch_t = 0.2
		_watch_rooms()


func _spawn(e: Array) -> void:
	var pn: String = e[0]
	var arch: StringName = e[1]
	var xf: Transform3D = e[2]
	var p := UltraNet.spawn_bot(ZombieFactory.name_for(arch, _count), xf)
	_count += 1
	if p == null:
		return
	ZombieFactory.dress(p.character)
	var b := director.add(p.character)
	b.mode = e[3]
	if e[3] == ZombieBrain.Mode.DORMANT:
		b.next_think = director.now + _rng.randf() * 2.0
	(packs[pn].brains as Array).append(b)
	b.pack = pn
	b.home_spawn = xf.origin
	p.character.died.connect(_on_died)
	spawned += 1


func _on_died() -> void:
	kills += 1
	kills_changed.emit(kills)


## A pack whose room the player walks into comes to look.
func _watch_rooms() -> void:
	for t in director.targets():
		var room := map.room_at(t.state.pos)
		if room == "":
			continue
		for pn: String in packs:
			var pk: Dictionary = packs[pn]
			if pk.woken or pk.def.wake != "room" or room not in pk.def.rooms:
				continue
			pk.woken = true
			for b: ZombieBrain in pk.brains:
				if b.mode in [ZombieBrain.Mode.DORMANT, ZombieBrain.Mode.IDLE, ZombieBrain.Mode.WANDER]:
					b._begin_investigate(t.state.pos)


# ------------------------------------------------------------------ waves, reset

func _player() -> UltraCharacter:
	var tg := director.targets()
	return tg[0] if not tg.is_empty() else null


## Wake everything within reach (they know where you are) and bring corpses back in at the gates.
func trigger_wave(count := 10) -> void:
	var t := _player()
	if t == null:
		return
	waves += 1
	var woke := director.wake_near(t.state.pos, 70.0, 99, t, true)
	var spawns: Array = []
	for pos: Vector3 in WAVE_ENTRANCES:
		spawns.append(Transform3D(Basis(Vector3.UP, _rng.randf() * TAU), pos))
	spawns.shuffle()
	var back := director.recycle(count, spawns, t)
	wave_started.emit(woke, back)


## Everything back as it was at the start: zombies home and dormant, doors repaired, the player healed
## and back at the gate, the count at zero.
func reset() -> void:
	map.reset_doors()
	for pn: String in packs:
		packs[pn].woken = false
	var i := 0
	for pn: String in packs:
		for b: ZombieBrain in packs[pn].brains:
			b.c.set_meta("home", Transform3D(Basis(Vector3.UP, _rng.randf() * TAU), b.home_spawn))
			UltraNet.respawn_character(b.c)
			ZombieFactory.dress(b.c, true)
			b.reset(ZombieBrain.Mode.DORMANT if packs[pn].def.wake == "room" else ZombieBrain.Mode.IDLE)
			b.next_think = director.now + float(i % 20) * 0.05
			i += 1
	for t in director.targets():
		UltraNet.respawn_character(t)
	kills = 0
	kills_changed.emit(kills)
	_stock()
	reset_done.emit()


# ------------------------------------------------------------------ buttons, pickups

func _place_buttons() -> void:
	var specs := [["WAVE", "Call a wave of zombies", Vector3(16.35, 1.3, 33.4)], ["RESET", "Reset the sandbox", Vector3(16.35, 1.3, 30.4)]]
	for sp: Array in specs:
		var sw := UltraSwitch.new()
		sw.kind = UltraSwitch.Kind.BUTTON
		sw.label = sp[0]
		sw.prompt = sp[1]
		sw.position = sp[2]
		sw.basis = Basis(Vector3.UP, PI * 0.5)
		sw.hold_time = 0.4
		map.add_child(sw)
		var what: String = sp[0]
		sw.changed.connect(func(on: bool) -> void:
			if not on:
				return
			if what == "WAVE":
				trigger_wave()
			else:
				reset())
		_switches.append(sw)


const ITEM := {
	"ammo_9mm": ["res://assets/items/ammo/ammo_9mm_world.tscn", 30], "ammo_556": ["res://assets/items/ammo/ammo_556_world.tscn", 40],
	"ammo_12g": ["res://assets/items/ammo/ammo_12g_world.tscn", 12], "medkit": ["res://assets/items/medkit/medkit_world.tscn", 1],
	"key_red": ["res://assets/items/keys/key_red_world.tscn", 1], "key_green": ["res://assets/items/keys/key_green_world.tscn", 1],
}
## [item, where]: ammo and medkits about the house, the study key on the dining table's end, the gun
## room's key upstairs in the master bedroom.
const STOCK := [
	["medkit", Vector3(21.0, 0.4, 31.0)], ["ammo_9mm", Vector3(22.5, 0.4, 31.0)], ["ammo_9mm", Vector3(35.0, 0.4, 31.0)],
	["medkit", Vector3(36.5, 0.4, 31.0)], ["ammo_556", Vector3(12.0, 0.4, 33.0)], ["ammo_12g", Vector3(6.0, 0.4, 4.0)],
	["key_red", Vector3(54.5, 0.4, 12.5)], ["medkit", Vector3(48.0, 0.4, 24.5)], ["ammo_9mm", Vector3(44.0, 0.4, 25.0)],
	["key_green", Vector3(54.0, 4.1, 14.0)], ["medkit", Vector3(44.0, 4.1, 5.0)], ["ammo_12g", Vector3(26.0, 4.1, 3.0)],
	["ammo_556", Vector3(53.0, 0.4, 3.0)], ["medkit", Vector3(45.0, -2.9, 6.0)], ["ammo_9mm", Vector3(52.0, -2.9, 20.0)],
]


func _stock() -> void:
	for n in _items:
		if is_instance_valid(n):
			n.queue_free()
	_items.clear()
	if UltraNet.world == null:
		return
	for s: Array in STOCK:
		var spec: Array = ITEM[s[0]]
		var scene: String = spec[0]
		if not ResourceLoader.exists(scene):
			continue
		var extra := {"item_id": StringName(String(s[0])), "count": int(spec[1])}
		var node := UltraNet.world.spawn(scene, Transform3D(Basis(), s[1]), extra)
		if node:
			_items.append(node)


# ------------------------------------------------------------------ numbers for the HUD

func alive() -> int:
	var n := 0
	for b in director.brains:
		if b.mode != ZombieBrain.Mode.DEAD:
			n += 1
	return n


func hunting() -> int:
	var n := 0
	for b in director.brains:
		if b.mode in [ZombieBrain.Mode.CHASE, ZombieBrain.Mode.ATTACK, ZombieBrain.Mode.BASH_DOOR, ZombieBrain.Mode.OPEN_DOOR]:
			n += 1
	return n


func _unhandled_input(event: InputEvent) -> void:
	if not started or not UltraNet.is_server():
		return
	if event.is_action_pressed(UltraInput.action(&"zombie_wave")):
		trigger_wave()
	elif event.is_action_pressed(UltraInput.action(&"zombie_reset")):
		reset()
