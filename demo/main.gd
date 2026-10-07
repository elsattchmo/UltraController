extends Node
## Demo entry point. With no options it shows the main menu; with options it starts straight
## into a session (see UltraArgs for the full list). Examples:
##   (nothing)                              main menu
##   -- --offline --players=2               split-screen, two local players
##   -- --host                              host a game (port 7777)
##   -- --connect=127.0.0.1 --lag=120       join with a simulated 120 ms network
##   -- --server                            dedicated server (works with --headless)
##   -- --launch=host_client                start a preset of instances and exit
##   -- --tour=m1                           scripted capture tour (single-player bot)
##   -- --map=mansion                       the level (also picked in the main menu)
##   -- --controller=sinew --model=zombie   the local player's controller / model (main menu too)

## The levels the main menu offers (and `--map=<key>`): key, title, one line about it, scene.
const LEVELS := [
	{"key": "playground", "title": "Playground", "blurb": "movement, parkour, water, shooting range, props", "path": "res://demo/maps/playground.tscn"},
	{"key": "mansion", "title": "Zombie Mansion", "blurb": "packs of zombies, doors, stairs, three floors", "path": "res://demo/maps/mansion.tscn"},
]
const PROFILES := {
	"fps": "res://addons/ultra_controller/profiles/fps.tres",
	"adventure": "res://addons/ultra_controller/profiles/adventure.tres",
	"survival": "res://addons/ultra_controller/profiles/survival.tres",
	"tps": "res://addons/ultra_controller/profiles/tps.tres",
}
const BODY := "res://assets/characters/mannequin/mannequin_body_profile.tres"

var args := {}
var map: Node3D
var level := ""                     ## key of the loaded level
var controller := "ultra"           ## local players' controller (CharacterModels.CONTROLLERS)
var model := "mannequin"            ## local players' model (CharacterModels.MODELS)
var locals: UltraLocalPlayers
var menu: CanvasLayer
var player: UltraCharacter          ## first local player (tours, single-player tools)
var effects: UltraEffects
var bars: UltraWorldBars
var sandbox: MansionSandbox
var headless := false
var _title_t := 0.0
var _pause: Node
var _companion: NetPlayer
var _companion_brain: UltraCompanion
var _join_to := {}                  ## where we joined ({address, port, count}), to join again on the host's level
var _rejoined := false

signal level_changed(key: String)


func _ready() -> void:
	args = UltraArgs.all()
	headless = DisplayServer.get_name() == "headless"
	UltraArgs.apply_window()
	UltraInput.apply_user_rebinds()
	UltraActionLayer.infinite_ammo = not UltraArgs.has("limited-ammo")    # test playground
	if args.has("launch"):
		var preset := UltraLauncher.find(String(args["launch"]))
		if preset:
			UltraLauncher.launch(preset)
		else:
			push_error("no launch preset '%s'" % args["launch"])
		get_tree().quit()
		return
	var back_to_menu := Engine.has_meta("ultra_to_menu") and Engine.has_meta("ultra_level")
	_load_level(String(Engine.get_meta("ultra_level")) if back_to_menu else UltraArgs.get_str("map", "playground"))
	set_controller(String(Engine.get_meta("ultra_controller")) if Engine.has_meta("ultra_controller") else UltraArgs.get_str("controller", "ultra"))
	set_model(String(Engine.get_meta("ultra_model")) if Engine.has_meta("ultra_model") else UltraArgs.get_str("model", "mannequin"))
	locals = UltraLocalPlayers.new()
	locals.name = "LocalPlayers"
	locals.join_enabled = args.has("join-screen")
	locals.hud_factory = _make_hud
	add_child(locals)
	UltraNet.world_root = self
	UltraNet.character_factory = _make_character
	UltraNet.spawn_transform = _spawn_transform
	UltraNet.session_info_provider = func() -> Dictionary: return {"level": level}
	UltraNet.session_info_received.connect(_on_session_info)
	UltraNet.verbose = args.has("verbose-net")
	UltraNet.lag.configure(UltraArgs.get_float("lag"), UltraArgs.get_float("jitter"), UltraArgs.get_float("loss"))
	UltraNet.player_added.connect(_on_player_added)
	effects = UltraEffects.new()
	effects.name = "Effects"
	add_child(effects)
	bars = UltraWorldBars.new()
	bars.name = "WorldBars"
	add_child(bars)
	UltraNet.session_ended.connect(func(reason: String) -> void:
		push_warning("session ended: " + reason)
		if args.has("quit-on-end"):
			get_tree().quit(2))
	UltraNet.session_started.connect(func(_m: int) -> void:
		if UltraNet.is_server():
			_stock_range()
			if sandbox and not args.has("no-zombies"):
				sandbox.start(map as Mansion))
	if args.has("bot") or args.has("tour"):
		UltraNet.local_input_factory = _make_bot_input
	if args.has("quit-after"):
		get_tree().create_timer(UltraArgs.get_float("quit-after")).timeout.connect(_quit)
	if args.has("screenshot"):
		# --screenshot=<file.png> --screenshot-at=<seconds>: one capture for reviews.
		get_tree().create_timer(UltraArgs.get_float("screenshot-at", 3.0)).timeout.connect(func() -> void:
			await RenderingServer.frame_post_draw
			var path := UltraArgs.get_str("screenshot")
			DirAccess.make_dir_recursive_absolute(path.get_base_dir())
			get_viewport().get_texture().get_image().save_png(path)
			print("screenshot ", path))
	var to_menu := Engine.has_meta("ultra_to_menu")
	if to_menu:
		Engine.remove_meta("ultra_to_menu")
	if _wants_session() and not to_menu:
		start_from_args()
	elif headless:
		UltraNet.start_offline(1)
	else:
		_show_menu()
		if args.has("menu-pick"):
			# Automation: press a menu entry, e.g. --menu-pick=single | split:2 | host
			var pick := UltraArgs.get_str("menu-pick").split(":")
			get_tree().create_timer(0.5).timeout.connect(func() -> void: menu_start(pick[0], pick[1] if pick.size() > 1 else ""))


func _wants_session() -> bool:
	for k in ["offline", "host", "server", "connect", "players", "bot", "tour", "profile", "spawn", "view"]:
		if args.has(k):
			return true
	return false


func start_from_args() -> void:
	_rejoined = false
	var n := maxi(UltraArgs.get_int("players", 1), 0)
	_reserve_devices(n)
	var port := UltraArgs.get_int("port", UltraNet.DEFAULT_PORT)
	var names := PackedStringArray([UltraArgs.get_str("name", "Player")])
	if args.has("server"):
		UltraNet.host(port, 0)
	elif args.has("host"):
		UltraNet.host(port, n, names)
	elif args.has("connect"):
		var addr := UltraArgs.get_str("connect", "127.0.0.1")
		var parts := addr.split(":")
		_join_to = {"address": parts[0], "port": int(parts[1]) if parts.size() > 1 else port, "count": n, "names": names}
		UltraNet.join(parts[0], int(parts[1]) if parts.size() > 1 else port, n, names)
	else:
		UltraNet.start_offline(n, names)
	if args.has("tour"):
		var tour: Node = (load("res://demo/tours/%s.gd" % args["tour"]) as Script).new()
		tour.set("main", self)
		add_child(tour)
	if args.has("net-report"):
		var rep: Node = (load("res://demo/net_report.gd") as Script).new()
		add_child(rep)


## Split-screen device assignment: one player = any device; more = keyboard for P1 and a
## pad each for the rest (P2 = pad 0 ...). P1 also gets the next pad after those, so with a
## pad per player nobody's controller is left unclaimed (an unclaimed pad's Start - the
## pause button - would hot-join a stray extra player).
func _reserve_devices(n: int) -> void:
	if n <= 1:
		locals.reserve([[]])
		return
	var claims := [["kbm", "joy%d" % (n - 1)]]
	for i in range(1, n):
		claims.append(["joy%d" % (i - 1)])
	locals.reserve(claims)


func _make_character(np: NetPlayer) -> UltraCharacter:
	if ZombieFactory.is_zombie(np):
		return ZombieFactory.make(np, not headless)
	# The menu's Character pick is for players only: dummies and the companion stay as they are.
	var c := CharacterModels.make(controller) if not np.is_bot else UltraCharacter.new()
	c.profile = (load(PROFILES.get(UltraArgs.get_str("profile", "fps"), PROFILES["fps"])) as MovementProfile).duplicate(true)
	c.body_profile = CharacterModels.body_profile(model) if not np.is_bot else load(BODY)
	c.build_visuals = not headless
	return c


func _make_bot_input(local_index: int) -> InputSource:
	var b := BotInputSource.new()
	if args.has("bot"):
		b.set_steps(UltraBotCourses.get_course(UltraArgs.get_str("bot")))
		b.loop = true
	return b


func _spawn_transform(np: NetPlayer) -> Transform3D:
	var names := ["spawn", "spawn_2", "spawn_3", "spawn_4"]
	var want := UltraArgs.get_str("spawn", "")
	# Humans in join order (bots such as the yard's dummies take ids too).
	var human := 0
	for other: NetPlayer in UltraNet.players.values():
		if not other.is_bot and other.id < np.id:
			human += 1
	var m: Marker3D = null
	if want != "" and human == 0:
		m = map.call("marker", want)
	if m == null:
		m = map.call("marker", names[human % names.size()])
	return m.global_transform if m else Transform3D.IDENTITY


func _make_hud(c: UltraCharacter) -> Node:
	var o := UltraDebugOverlay.new()
	o.character = c
	return o


func _on_player_added(p: NetPlayer) -> void:
	if p.character.build_visuals:
		effects.watch(p.character)
	if p.is_local():
		effects.local_ids.append(p.id)
	if ZombieFactory.is_zombie(p):
		ZombieFactory.dress(p.character)
	elif UltraNet.is_server():
		_give_starting_kit(p.character)
	if p.is_local() and player == null:
		player = p.character
	if p.is_local() and args.get("view", "") == "tp" and p.character.input_source:
		p.character.input_source.view_tp = true
	if p.is_local() and p.character.input_source is BotInputSource:
		(p.character.input_source as BotInputSource).body = p.character
	if menu:
		menu.queue_free()
		menu = null


## Playground loadout: a pistol (slot 1), the carbine (2), the shotgun (3), a bat (4), a machete
## (5) and ammo (the server
## grants it; owners get it replicated).
func _give_starting_kit(c: UltraCharacter) -> void:
	if args.has("no-kit"):
		return
	UltraItems.give(c, &"pistol", 1)
	UltraItems.give(c, &"rifle", 1)
	if ItemDB.get_def(&"shotgun"):
		UltraItems.give(c, &"shotgun", 1)
	for mw: StringName in [&"bat", &"machete"]:
		if ItemDB.get_def(mw):
			UltraItems.give(c, mw, 1)
	UltraItems.give(c, &"ammo_9mm", 36)
	UltraItems.give(c, &"ammo_556", 90)
	if ItemDB.get_def(&"ammo_12g"):
		UltraItems.give(c, &"ammo_12g", 30)
	UltraItems.give(c, &"medkit", 1)


## The shooting range bench also has a carbine and a box of 5.56 on it (server-spawned
## pickups, replicated like any dropped item), next to the pistol the map places.
func _stock_range() -> void:
	var r := map.find_child("ShootingRange", true, false) as Node3D if map else null
	if r == null or ItemDB.get_def(&"rifle") == null:
		return
	var on_side := Basis(Vector3.UP, PI * 0.5) * Basis(Vector3.BACK, PI * 0.5)     # barrel along the bench
	UltraNet.world.spawn("res://assets/items/rifle/rifle_world.tscn", r.global_transform * Transform3D(on_side, Vector3(1.6, 1.08, 1.0)), {"item_id": &"rifle", "count": 1})
	UltraNet.world.spawn("res://assets/items/ammo/ammo_556_world.tscn", r.global_transform * Transform3D(Basis(), Vector3(-1.4, 1.1, 1.0)), {"item_id": &"ammo_556", "count": 60})
	if ResourceLoader.exists("res://assets/items/shotgun/shotgun_world.tscn"):
		UltraNet.world.spawn("res://assets/items/shotgun/shotgun_world.tscn", r.global_transform * Transform3D(on_side, Vector3(0.6, 1.08, 1.0)), {"item_id": &"shotgun", "count": 1})
		UltraNet.world.spawn("res://assets/items/ammo/ammo_12g_world.tscn", r.global_transform * Transform3D(Basis(), Vector3(-0.6, 1.1, 1.0)), {"item_id": &"ammo_12g", "count": 24})


func _process(delta: float) -> void:
	_title_t -= delta
	if _title_t <= 0.0 and not headless:
		_title_t = 0.5
		DisplayServer.window_set_title("UltraController — " + UltraNet.stats_line())


func _unhandled_input(event: InputEvent) -> void:
	if menu or (_pause and is_instance_valid(_pause)):
		return
	if event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event.is_action_pressed(UltraInput.action(&"pause")) and _pause == null:
		_pause = (load("res://demo/ui/pause_menu.gd") as Script).new()
		_pause.resumed.connect(func() -> void: _pause = null)
		add_child(_pause)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(UltraInput.action(&"companion")):
		toggle_companion()
	elif event.is_action_pressed(UltraInput.action(&"debug_slowmo")):
		Engine.time_scale = 0.25 if Engine.time_scale > 0.5 else 1.0


## Summon / dismiss a helper bot that follows you and takes the other end of heavy things.
func toggle_companion() -> void:
	if not UltraNet.is_server() or player == null:
		return
	if _companion:
		UltraNet.despawn_bot(_companion.id)
		_companion = null
		return
	var at := player.global_transform.translated(player.global_basis * Vector3(1.5, 0, 1.5))
	_companion = UltraNet.spawn_bot("Helper", at)
	if _companion:
		_companion_brain = UltraCompanion.new(_companion.character, player)


func _quit() -> void:
	get_tree().quit(0)


# ------------------------------------------------------------------ main menu

func _show_menu() -> void:
	menu = (load("res://demo/ui/main_menu.gd") as Script).new()
	menu.set("main", self)
	add_child(menu)


func menu_start(kind: String, value := "") -> void:
	_rejoined = false
	match kind:
		"single":
			_reserve_devices(1)
			UltraNet.start_offline(1)
		"split":
			locals.join_enabled = true
			var n := int(value)
			_reserve_devices(n)
			UltraNet.start_offline(n)
		"host":
			_reserve_devices(1)
			UltraNet.host(UltraNet.DEFAULT_PORT, 1)
		"join":
			_reserve_devices(1)
			var parts := value.split(":")
			_join_to = {"address": parts[0], "port": int(parts[1]) if parts.size() > 1 else UltraNet.DEFAULT_PORT, "count": 1, "names": PackedStringArray()}
			UltraNet.join(parts[0], int(parts[1]) if parts.size() > 1 else UltraNet.DEFAULT_PORT, 1)
		"host_and_client":
			_reserve_devices(1)
			UltraNet.host(UltraNet.DEFAULT_PORT, 1)
			var p := UltraLaunchPreset.new()
			p.instances = PackedStringArray(["right|--connect=127.0.0.1 --map=" + level])
			UltraLauncher.launch(p)
			UltraArgs.all()["window"] = "left"
			UltraArgs.apply_window()


# ------------------------------------------------------------------ character

func controller_list() -> Array:
	return CharacterModels.CONTROLLERS


func model_list() -> Array:
	return CharacterModels.MODELS


## The local player's controller / model, picked in the main menu (not while a session runs:
## the players are already built). Kept across Pause > Main menu like the level.
func set_controller(key: String) -> void:
	if UltraNet.is_active() or not CharacterModels.has_controller(key):
		return
	controller = key
	Engine.set_meta("ultra_controller", key)


func set_model(key: String) -> void:
	if UltraNet.is_active() or not CharacterModels.has_model(key):
		return
	model = key
	Engine.set_meta("ultra_model", key)


# ------------------------------------------------------------------ levels

func level_list() -> Array:
	return LEVELS


func level_def(key: String) -> Dictionary:
	for d: Dictionary in LEVELS:
		if d.key == key:
			return d
	return {}


## Swap the level behind the main menu (not while a session runs: players are standing in the old one).
func set_level(key: String) -> void:
	if (key == level and map != null) or UltraNet.is_active() or level_def(key).is_empty():
		return
	_load_level(key)


func _load_level(key: String) -> void:
	var def := level_def(key)
	if def.is_empty():
		def = LEVELS[0]
	# Out of the tree at once (not queue_free alone): a mansion tears its navigation down on exit, which
	# must not land after the next level's setup.
	if sandbox:
		remove_child(sandbox)
		sandbox.queue_free()
		sandbox = null
	if map:
		remove_child(map)
		map.queue_free()
		map = null
	map = (load(def.path) as PackedScene).instantiate()
	add_child(map)
	move_child(map, 0)
	level = def.key
	Engine.set_meta("ultra_level", level)
	if map is Mansion:
		sandbox = MansionSandbox.new()
		sandbox.name = "Sandbox"
		add_child(sandbox)
	level_changed.emit(level)


## A client learns which level the host runs: if it isn't ours, load it and join again.
func _on_session_info(info: Dictionary) -> void:
	var key := String(info.get("level", ""))
	if key == "" or key == level or level_def(key).is_empty() or _rejoined or _join_to.is_empty():
		return
	_rejoined = true
	_rejoin_on.call_deferred(key)


func _rejoin_on(key: String) -> void:
	UltraNet.stop()
	_load_level(key)
	_reserve_devices(int(_join_to.count))
	UltraNet.join(String(_join_to.address), int(_join_to.port), int(_join_to.count), _join_to.names)
