class_name UltraSfx
extends Node3D
## Weapon sounds (presentation, a child of UltraEffects). Streams come from
## assets/audio/weapons (made by tools/audio/prepare_sfx.py from assets/audio/source): a name
## plays one of its variants (name_0, name_1 ...) at random, a little pitch spread.
##   - shots: the close report near the gun and the "far" render (muffled, a reverb tail) taking
##     over with distance from the listener, both late by the speed of sound;
##   - a bullet passing within WHIZ_RADIUS of a listener (not the shooter's own) whizzes by;
##   - impacts, spent cases landing, magazine out / in, a pistol's slide, shells into a tube,
##     the pump racked.
## Players come from a pool (MAX_VOICES; the oldest is cut).

const DIR := "res://assets/audio/weapons/"
const MAX_VOICES := 40
const SPEED_OF_SOUND := 343.0
const WHIZ_RADIUS := 4.0
const FAR_FROM := 35.0              ## m: the far render starts here...
const FAR_FULL := 120.0             ## ... and has it all by here

var _variants := {}                 ## name -> Array[AudioStream]
var _pool: Array[AudioStreamPlayer3D] = []
var _next := 0


func _ready() -> void:
	for i in MAX_VOICES:
		var p := AudioStreamPlayer3D.new()
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		p.bus = &"Master"
		add_child(p)
		_pool.append(p)


## The streams for `name` (its numbered variants, or just itself).
func streams(name: String) -> Array:
	if _variants.has(name):
		return _variants[name]
	var out: Array = []
	var k := 0
	while ResourceLoader.exists(DIR + "%s_%d.wav" % [name, k]):
		out.append(load(DIR + "%s_%d.wav" % [name, k]))
		k += 1
	if out.is_empty() and ResourceLoader.exists(DIR + name + ".wav"):
		out.append(load(DIR + name + ".wav"))
	_variants[name] = out
	return out


## Play `name` at `at`. `unit` = the distance (m) it's at full volume; `max_dist` where it's gone.
func play(name: String, at: Vector3, volume_db := 0.0, unit := 6.0, max_dist := 80.0, pitch_spread := 0.05, delay := 0.0, variant := -1) -> void:
	var list := streams(name)
	if list.is_empty() or not is_inside_tree():
		return
	var s: AudioStream = list[variant % list.size()] if variant >= 0 else list[randi() % list.size()]
	if delay > 0.01:
		get_tree().create_timer(delay).timeout.connect(func() -> void: _start(s, at, volume_db, unit, max_dist, pitch_spread))
	else:
		_start(s, at, volume_db, unit, max_dist, pitch_spread)


func _start(s: AudioStream, at: Vector3, volume_db: float, unit: float, max_dist: float, pitch_spread: float) -> void:
	var p := _pool[_next]
	_next = (_next + 1) % _pool.size()
	p.stop()
	p.stream = s
	p.volume_db = volume_db
	p.unit_size = unit
	p.max_distance = max_dist
	p.pitch_scale = 1.0 + randf_range(-pitch_spread, pitch_spread)
	p.global_position = at
	p.play()


## The listener: the current camera (the first local one).
func listener() -> Vector3:
	var cam := get_viewport().get_camera_3d() if get_viewport() else null
	return cam.global_position if cam else Vector3.INF


## A shot from `c`'s gun at `at`: the close report and the far one, mixed by the distance.
func shot(at: Vector3, prefix: String, loud := 1.0) -> void:
	var lp := listener()
	var d := at.distance_to(lp) if lp != Vector3.INF else 0.0
	var late := d / SPEED_OF_SOUND
	var k := smoothstep(FAR_FROM, FAR_FULL, d)
	var gain := linear_to_db(maxf(loud, 0.01))
	if k < 0.99:
		play(prefix + "_fire", at, gain + linear_to_db(maxf(1.0 - k, 0.001)), 9.0, 260.0, 0.04, late)
	if k > 0.01:
		play(prefix + "_fire_far", at, gain + linear_to_db(maxf(k, 0.001)) + 6.0, 60.0, 1400.0, 0.06, late)


## A round flying from `origin` along `dir` (to `reach`): a listener it passes close by (not its
## own shooter) hears it go past.
func whiz(origin: Vector3, dir: Vector3, reach: float, shooter_is_listener: bool) -> void:
	var lp := listener()
	if lp == Vector3.INF or shooter_is_listener:
		return
	var d := dir.normalized()
	var t := clampf((lp - origin).dot(d), 0.0, reach)
	if t < 3.0:
		return                                        # (behind the gun / at the muzzle)
	var closest := origin + d * t
	var miss := closest.distance_to(lp)
	if miss > WHIZ_RADIUS:
		return
	play("whiz", closest, linear_to_db(clampf(1.2 - miss / WHIZ_RADIUS, 0.2, 1.0)), 3.0, 30.0, 0.08)


func impact(at: Vector3, flesh: bool) -> void:
	play("impact", at, -2.0 if flesh else 0.0, 4.0, 60.0, 0.12 if not flesh else 0.06)


## A spent case clinking down (`delay` s after it's thrown): a short random stretch of the
## brass recording (an MP3 of many cases falling - played from somewhere in it, cut short).
func shell_drop(at: Vector3, delay := 0.45) -> void:
	if _brass == null and ResourceLoader.exists(DIR + "brass_shells.mp3"):
		_brass = load(DIR + "brass_shells.mp3")
	if _brass == null or not is_inside_tree():
		return
	get_tree().create_timer(delay).timeout.connect(func() -> void:
		var p := _pool[_next]
		_next = (_next + 1) % _pool.size()
		p.stop()
		p.stream = _brass
		p.volume_db = -10.0
		p.unit_size = 2.0
		p.max_distance = 20.0
		p.pitch_scale = randf_range(0.9, 1.15)
		p.global_position = at + Vector3.DOWN * 0.8
		p.play(randf_range(0.0, maxf(_brass.get_length() - 1.0, 0.0)))
		get_tree().create_timer(0.55).timeout.connect(func() -> void:
			if p.stream == _brass:
				p.stop()))


var _brass: AudioStream
