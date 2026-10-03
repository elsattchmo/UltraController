class_name UltraTour
extends Node
## Scripted capture tour: drives the player through a BotInputSource and saves screenshots.
## Subclasses fill `steps` in _build(): each step is a Dictionary with optional keys
##   "t": seconds to hold this step   "move": Vector2   "yaw"/"pitch": degrees (absolute)
##   "buttons": int   "tap": int   "view_tp": bool   "teleport": marker name
##   "shot": file name (captured at the END of the step)   "call": Callable
## Real-time based (not frame counts), so it behaves the same at any frame rate.

var main: Node
var steps: Array = []
var out_dir := "C:/Dev/verify/ultra/review/m1"

var _i := -1
var _t0 := 0.0
var _bot: BotInputSource


func _ready() -> void:
	out_dir = String(main.args.get("out", out_dir))
	DirAccess.make_dir_recursive_absolute(out_dir)
	_bot = main.player.input_source as BotInputSource
	_bot.driver = _drive
	_build()
	_next()


func _build() -> void:
	pass


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _next() -> void:
	_i += 1
	_t0 = _now()
	if _i >= steps.size():
		print("TOUR DONE ", out_dir)
		get_tree().quit()
		return
	var s: Dictionary = steps[_i]
	if s.has("teleport"):
		var m := main.map.call("marker", s["teleport"]) as Marker3D
		if m:
			main.player.teleport(m.global_position, m.global_rotation.y)
	if s.has("view_tp"):
		_bot.view_tp = bool(s["view_tp"])
	if s.has("yaw"):
		_bot.live_yaw = deg_to_rad(float(s["yaw"]))
	if s.has("pitch"):
		_bot.live_pitch = deg_to_rad(float(s["pitch"]))
	if s.has("call"):
		(s["call"] as Callable).call()


func _drive(tick: int, _src: BotInputSource) -> InputFrame:
	var f := InputFrame.new()
	f.tick = tick
	f.yaw = _bot.live_yaw
	f.pitch = _bot.live_pitch
	if _i < steps.size():
		var s: Dictionary = steps[_i]
		f.move = s.get("move", Vector2.ZERO)
		f.buttons = int(s.get("buttons", 0))
		if s.has("tap") and _now() - _t0 < 0.05:
			f.buttons |= int(s["tap"])
		_bot.live_yaw += deg_to_rad(float(s.get("yaw_rate", 0.0))) / Engine.physics_ticks_per_second
	if _bot.view_tp:
		f.buttons |= InputFrame.B_VIEW_TP
	return f


func _process(_delta: float) -> void:
	if _i < 0 or _i >= steps.size():
		return
	var s: Dictionary = steps[_i]
	if _now() - _t0 >= float(s.get("t", 0.5)):
		if s.has("shot"):
			await RenderingServer.frame_post_draw
			var img := get_viewport().get_texture().get_image()
			var path := out_dir.path_join(String(s["shot"]) + ".png")
			img.save_png(path)
			print("shot ", path)
		_next()
