extends Node
## Demo entry point. Parses command-line options (everything after `--`):
##   --map=playground        --profile=fps|adventure|survival|tps     --spawn=<marker>
##   --view=fp|tp            --bot=<course>     --tour=<name> --out=<dir> (scripted captures)
##   --quit-after=<seconds>  --slowmo=<scale>
## Multiplayer / split-screen options arrive with the session layer (M2).

const MAPS := {"playground": "res://demo/maps/playground.tscn"}
const PROFILES := {
	"fps": "res://addons/ultra_controller/profiles/fps.tres",
	"adventure": "res://addons/ultra_controller/profiles/adventure.tres",
	"survival": "res://addons/ultra_controller/profiles/survival.tres",
	"tps": "res://addons/ultra_controller/profiles/tps.tres",
}
const BODY := "res://assets/characters/mannequin/mannequin_body_profile.tres"

var args := {}
var map: Node3D
var player: UltraCharacter
var rig: UltraCameraRig
var overlay: UltraDebugOverlay


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "true"
	UltraInput.apply_user_rebinds()
	map = (load(MAPS.get(args.get("map", "playground"), MAPS["playground"])) as PackedScene).instantiate()
	add_child(map)
	player = spawn_player(args.get("profile", "fps"), args.get("spawn", "spawn"))
	if args.has("quit-after"):
		get_tree().create_timer(float(args["quit-after"])).timeout.connect(get_tree().quit)
	if args.has("tour"):
		var tour_script := load("res://demo/tours/%s.gd" % args["tour"]) as Script
		var tour: Node = tour_script.new()
		tour.set("main", self)
		add_child(tour)


func spawn_player(profile_name: String, spawn: String) -> UltraCharacter:
	var c := UltraCharacter.new()
	c.name = "Player"
	c.profile = (load(PROFILES.get(profile_name, PROFILES["fps"])) as MovementProfile).duplicate(true)
	c.body_profile = load(BODY)
	c.view_index = 0
	var src: InputSource
	if args.has("bot") or args.has("tour"):
		src = BotInputSource.new()
	else:
		src = LocalInputSource.new()
	src.name = "InputSource"
	if args.get("view", "") == "tp":
		src.view_tp = true
	c.add_child(src)
	c.input_source = src
	var m := map.call("marker", spawn) as Marker3D
	if m:
		c.position = m.global_position
		c.rotation.y = m.global_rotation.y
	add_child(c)
	if src is BotInputSource:
		(src as BotInputSource).body = c
	if src.view_tp == false and c.profile.default_view == MovementProfile.View.THIRD_PERSON:
		src.view_tp = true
	rig = UltraCameraRig.new()
	rig.name = "CameraRig"
	rig.view_index = 0
	add_child(rig)
	rig.attach(c)
	overlay = UltraDebugOverlay.new()
	overlay.character = c
	add_child(overlay)
	return c


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event.is_action_pressed(UltraInput.action(&"pause")):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event.is_action_pressed(UltraInput.action(&"debug_slowmo")):
		Engine.time_scale = 0.25 if Engine.time_scale > 0.5 else 1.0
