class_name UltraTestSuite
extends Node
## Base for test suites: assertions, frame waits, and a playground + character fixture.

var current := ""
var failed := false
var map: Node3D
var chars: Array[UltraCharacter] = []


func before_each() -> void:
	pass


func after_each() -> void:
	for c in chars:
		if is_instance_valid(c):
			c.queue_free()
	chars.clear()
	if map:
		map.queue_free()
		map = null
	await get_tree().physics_frame


# ------------------------------------------------------------------ assertions

func check(cond: bool, msg: String) -> bool:
	if not cond:
		failed = true
		print("   ✗ ", msg)
	return cond


func near(a: float, b: float, tol: float, msg: String) -> bool:
	return check(absf(a - b) <= tol, "%s: got %.4f expected %.4f ±%.4f" % [msg, a, b, tol])


func info(msg: String) -> void:
	print("   · ", msg)


# ------------------------------------------------------------------ fixtures

func load_playground() -> Node3D:
	map = (load("res://demo/maps/playground.tscn") as PackedScene).instantiate()
	add_child(map)
	return map


## Any map scene (a mansion, a test arena): freed with the suite fixtures.
func load_map(path: String) -> Node3D:
	map = (load(path) as PackedScene).instantiate()
	add_child(map)
	return map


func marker(n: String) -> Marker3D:
	return map.call("marker", n) as Marker3D


func spawn(at: String, profile_path := "res://addons/ultra_controller/profiles/fps.tres", with_body := true) -> UltraCharacter:
	var c := UltraCharacter.new()
	c.profile = (load(profile_path) as MovementProfile).duplicate(true)
	c.body_profile = load("res://assets/characters/mannequin/mannequin_body_profile.tres")
	c.build_visuals = with_body
	var bot := BotInputSource.new()
	bot.name = "InputSource"
	c.add_child(bot)
	c.input_source = bot
	var m := marker(at)
	if m:
		c.position = m.global_position
		c.rotation.y = m.global_rotation.y
	add_child(c)
	bot.body = c
	chars.append(c)
	return c


func bot(c: UltraCharacter) -> BotInputSource:
	return c.input_source as BotInputSource


## Wait `n` physics ticks.
func ticks(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


## Hold an input for `n` ticks.
func hold(c: UltraCharacter, n: int, move := Vector2.ZERO, buttons := 0, yaw := NAN, pitch := 0.0) -> void:
	var b := bot(c)
	b.set_steps([{"ticks": n, "move": move, "buttons": buttons, "pitch": pitch}])
	if not is_nan(yaw):
		b.live_yaw = yaw
		b.steps[0]["yaw"] = yaw
	await ticks(n)


func hspeed(c: UltraCharacter) -> float:
	return Vector2(c.state.vel.x, c.state.vel.z).length()
