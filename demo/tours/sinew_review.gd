extends UltraTour
## Review tour: the player's body as a Sinew body. Stands (animation), takes a hard shove
## (slow motion: muscled fall onto the level), lies, gets up; then a killing shot (limp).
##   godot --path . --resolution 1280x720 -- --tour=sinew_review --controller=sinew [--model=zombie] --out=<dir>

const SLOW := 0.3

var _cam: Camera3D
var _c: UltraCharacter
var _focus := Vector3.ZERO
var _from := Vector3(2.6, 1.1, 2.6)


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/sinew_review")
	steps = [
		{"teleport": "speed_start", "t": 0.6, "yaw": 0, "pitch": -4, "view_tp": true, "slot": 0},
		{"call": _setup, "t": 1.2, "shot": "stand"},
		{"call": _slow.bind(true), "t": 0.0},
		{"call": _shove, "t": 0.15, "shot": "shove_0"},
	]
	for k in 6:
		steps.append({"t": 0.18, "shot": "shove_%d" % (k + 1)})
	steps += [
		{"call": _slow.bind(false), "t": 1.0, "shot": "down_0"},
		{"t": 1.0, "shot": "down_1"},
		{"t": 0.7, "shot": "getup_0"},
		{"t": 0.7, "shot": "getup_1"},
		{"t": 1.5, "shot": "up"},
		{"call": _slow.bind(true), "t": 0.0},
		{"call": _kill, "t": 0.15, "shot": "dead_0"},
		{"t": 0.25, "shot": "dead_1"},
		{"t": 0.25, "shot": "dead_2"},
		{"call": _slow.bind(false), "t": 2.0, "shot": "dead_3"},
	]


func _setup() -> void:
	_c = main.player
	_cam = Camera3D.new()
	main.add_child(_cam)
	_cam.fov = 45.0
	_cam.current = true
	print("sinew_review: controller %s, ragdoll %s" % [_c.get_class() if _c.get_script() == null else (_c.get_script() as Script).get_global_name(), (_c.ragdoll.get_script() as Script).get_global_name()])


func _slow(on: bool) -> void:
	Engine.time_scale = SLOW if on else 1.0


func _shove() -> void:
	_c.knock_down(Vector3(4.0, 1.5, -1.0))


func _kill() -> void:
	var d := UltraCombat.DamageInfo.new()
	d.amount = 500.0
	d.region = UltraLimbs.Region.TORSO
	d.kind = &"bullet"
	d.dir = Vector3(-1, 0, 0)
	d.point = _c.state.pos + Vector3.UP * 1.2
	_c.apply_damage(d)


func _process(delta: float) -> void:
	super(delta)
	if _cam == null or _c == null:
		return
	_cam.current = true
	var base := _c.visual_root.global_position + Vector3(0, 0.8, 0)
	var r := _c.ragdoll as SinewRagdoll
	if r and r.active and not r.pose_now.is_empty():
		base = r.pose_now[0].origin
	_focus = _focus.lerp(base, 1.0 - exp(-8.0 * delta / maxf(Engine.time_scale, 0.1)))
	_cam.global_position = _focus + _from
	_cam.look_at(_focus)
