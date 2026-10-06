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
const WHIZ_RADIUS := 6.0
const FAR_FROM := 20.0              ## m: the far render (muffled, echoing) comes in from here...
const FAR_FULL := 80.0              ## ... and has it all by here
const NEAR_GONE := 110.0            ## m: the close report has faded out by here
const AUTO_GAP := 0.2               ## s: a round this soon after the last one continues a burst

var listener_override := Vector3.INF     ## (tests: where the listener is)
var _auto := {}                     ## shooter key -> {t, at, prefix, voice, tail_due}

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
	_log(name)
	var list := streams(name)
	if list.is_empty() or not is_inside_tree():
		return
	var s: AudioStream = list[variant % list.size()] if variant >= 0 else list[randi() % list.size()]
	if delay > 0.01:
		get_tree().create_timer(delay).timeout.connect(func() -> void: _start(s, at, volume_db, unit, max_dist, pitch_spread))
	else:
		_start(s, at, volume_db, unit, max_dist, pitch_spread)


func _start(s: AudioStream, at: Vector3, volume_db: float, unit: float, max_dist: float, pitch_spread: float) -> AudioStreamPlayer3D:
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
	return p


## The listener: the current camera (the first local one).
func listener() -> Vector3:
	if listener_override != Vector3.INF:
		return listener_override
	var cam := get_viewport().get_camera_3d() if get_viewport() else null
	return cam.global_position if cam else Vector3.INF


## A shot from a gun at `at` (`key`: whose gun, for automatic fire): the close report and the
## far render, mixed by the distance, late by the speed of sound. A gun with an automatic set
## (prefix_fire_auto / _tail) plays each round's attack alone, cutting the one before, and the
## ring-out once the trigger's let go; others play the whole shot.
func shot(at: Vector3, prefix: String, key := 0, loud := 1.0) -> void:
	var lp := listener()
	var d := at.distance_to(lp) if lp != Vector3.INF else 0.0
	var late := d / SPEED_OF_SOUND
	var near_w := 1.0 - smoothstep(25.0, NEAR_GONE, d)
	var far_w := smoothstep(FAR_FROM, FAR_FULL, d)
	var gain := linear_to_db(maxf(loud, 0.01))
	var auto := not streams(prefix + "_fire_auto").is_empty()
	var now := Time.get_ticks_msec() / 1000.0
	if auto:
		var st: Dictionary = _auto.get(key, {})
		var voice: Variant = st.get("voice")
		if voice != null and is_instance_valid(voice) and now - float(st.get("t", -9.0)) < AUTO_GAP:
			_cut(voice as AudioStreamPlayer3D)           # (the last round's attack: cut short)
		var rounds := int(st.get("rounds", 0)) + 1 if now - float(st.get("t", -9.0)) < AUTO_GAP else 1
		st = {"t": now, "at": at, "prefix": prefix, "late": late, "near": near_w, "far": far_w, "gain": gain, "voice": null, "rounds": rounds}
		_auto[key] = st
		var sfx_name := prefix + "_fire_auto"
		if near_w > 0.01:
			_later(late, func() -> void: st["voice"] = _play_now(sfx_name, at, gain + linear_to_db(near_w), 9.0, 260.0, 0.04))
		if far_w > 0.01:
			_later(late, func() -> void: _play_now(sfx_name.replace("_auto", "_auto_far"), at, gain + linear_to_db(far_w) + 2.0, 80.0, 1400.0, 0.05))
		return
	if near_w > 0.01:
		play(prefix + "_fire", at, gain + linear_to_db(near_w), 9.0, 260.0, 0.04, late)
	if far_w > 0.01:
		play(prefix + "_fire_far", at, gain + linear_to_db(far_w) + 2.0, 80.0, 1400.0, 0.05, late)


func _process(_delta: float) -> void:
	# Bursts that have stopped: their ring-out.
	var now := Time.get_ticks_msec() / 1000.0
	for key: int in _auto.keys():
		var st: Dictionary = _auto[key]
		if now - float(st.t) >= AUTO_GAP:
			_auto.erase(key)
			var pre := String(st.prefix)
			var late := float(st.late)
			# The ring-out: well under the shots, a tap's softer than a long burst's, never the
			# same twice (level and pitch varied).
			var size := lerpf(-5.0, 0.0, clampf((int(st.get("rounds", 1)) - 1) / 6.0, 0.0, 1.0))
			var tail_db := -7.0 + size + randf_range(-2.5, 1.0)
			if float(st.near) > 0.01:
				play(pre + "_fire_tail", st.at, float(st.gain) + linear_to_db(float(st.near)) + tail_db, 9.0, 260.0, 0.09, maxf(late - (now - float(st.t)), 0.0))
			if float(st.far) > 0.01:
				play(pre + "_fire_tail_far", st.at, float(st.gain) + linear_to_db(float(st.far)) + 2.0 + tail_db, 80.0, 1400.0, 0.09, maxf(late - (now - float(st.t)), 0.0))


func _later(delay: float, f: Callable) -> void:
	if delay > 0.01:
		get_tree().create_timer(delay).timeout.connect(f)
	else:
		f.call()


func _play_now(name: String, at: Vector3, volume_db: float, unit: float, max_dist: float, pitch_spread: float) -> AudioStreamPlayer3D:
	_log(name)
	var list := streams(name)
	if list.is_empty() or not is_inside_tree():
		return null
	return _start(list[randi() % list.size()], at, volume_db, unit, max_dist, pitch_spread)


## Cut a voice short with a quick fade (a round's attack giving way to the next).
func _cut(p: AudioStreamPlayer3D) -> void:
	if p == null or not p.playing:
		return
	var tw := create_tween()
	tw.tween_property(p, "volume_db", p.volume_db - 30.0, 0.025)
	tw.tween_callback(p.stop)


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
	whiz_at(closest, miss)


## A round passing the listener at `at`, `miss` m off (`gain_db`: the gun's - a pistol round's
## quieter): the takes graded by how close, each band drawing on its neighbour's too so every
## recording gets used.
func whiz_at(at: Vector3, miss: float, gain_db := 0.0) -> void:
	if miss > WHIZ_RADIUS:
		return
	var band := "whiz_close" if miss < 1.2 else ("whiz_mid" if miss < 3.0 else "whiz_far")
	last_whiz = band
	var pool: Array = streams(band).duplicate()
	pool.append_array(streams("whiz_mid") if band != "whiz_mid" else streams("whiz_close") + streams("whiz_far"))
	if pool.is_empty():
		return
	var vol := -1.0 if band == "whiz_close" else (-5.0 if band == "whiz_mid" else -8.0)
	_log(band)
	_start(pool[randi() % pool.size()], at, vol - miss * 0.5 + gain_db, 4.0, 40.0, 0.07)


var last_whiz := ""                 ## (tests: which set the last fly-by came from)
var played: Array[String] = []      ## (tests: the last sounds asked for, newest last)


func _log(name: String) -> void:
	played.append(name)
	if played.size() > 64:
		played.pop_front()


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
