extends UltraTour
## Review tour (round E, effects): melee blocks (machete, bat), a shotgun blast that opens a
## dummy's torso (chunks, wound, guts), a heart shot pumping, then the player's own wounds:
## tunnel vision bleeding, a knockout (blurred / dark), death and the recap.
##   godot --path . --resolution 1280x720 -- --tour=round_e_fx --out=C:/Dev/verify/ultra/review/round_e_fx

var _cam: Camera3D
var _dummy: UltraCharacter
var _dummy2: UltraCharacter
var _look := 0                  ## 0 the player side on, 1 the dummy, 2 the player's own view


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/round_e_fx")
	var F := InputFrame
	steps = [
		{"teleport": "speed_start", "t": 0.6, "yaw": 0, "pitch": -4, "view_tp": true, "slot": 0},
		{"call": _give, "t": 0.3},
		{"call": _side_on, "t": 0.3, "slot": 0},
		{"t": 1.4, "slot": 5, "shot": "machete_ready"},
		{"t": 1.0, "slot": 5, "buttons": F.B_SECONDARY, "shot": "machete_block"},
		{"t": 1.4, "slot": 4, "shot": "bat_ready"},
		{"t": 1.0, "slot": 4, "buttons": F.B_SECONDARY, "shot": "bat_block"},
		{"t": 0.6, "slot": 0},
		{"call": _place_dummies, "t": 1.0, "slot": 0},
		{"call": _blast.bind(1), "t": 0.12, "slot": 0, "shot": "blast_0"},
		{"t": 0.25, "slot": 0, "shot": "blast_1"},
		{"t": 0.6, "slot": 0, "shot": "blast_2"},
		{"t": 1.5, "slot": 0, "shot": "blast_3"},
		{"call": _heart, "t": 0.15, "slot": 0, "shot": "heart_0"},
		{"t": 0.5, "slot": 0, "shot": "heart_1"},
		{"t": 1.5, "slot": 0, "shot": "heart_2"},
		{"call": _view.bind(2), "t": 0.3, "slot": 0},
		{"call": _sever_leg, "t": 2.5, "slot": 0, "shot": "tunnel_0"},
		{"t": 2.5, "slot": 0, "shot": "tunnel_1"},
		{"call": _knockout, "t": 0.6, "slot": 0, "shot": "ko_0"},
		{"t": 2.0, "slot": 0, "shot": "ko_1"},
		{"call": _kill, "t": 0.15, "slot": 0, "shot": "death_0"},
		{"t": 1.2, "slot": 0, "shot": "death_1"},
		{"t": 0.5, "slot": 0},
	]


func _give() -> void:
	for it: Array in [[&"shotgun", 1], [&"ammo_12g", 20], [&"rifle", 1], [&"bat", 1], [&"machete", 1]]:
		if main.player.inventory.count_of(it[0]) == 0:
			UltraItems.give(main.player, it[0], it[1])


func _side_on() -> void:
	_cam = Camera3D.new()
	main.add_child(_cam)
	_cam.fov = 45.0


func _view(k: int) -> void:
	_look = k


func _place_dummies() -> void:
	var c: UltraCharacter = main.player
	var fwd := Vector3(-sin(c.state.body_yaw), 0, -cos(c.state.body_yaw))
	var right := Vector3(cos(c.state.body_yaw), 0, -sin(c.state.body_yaw))
	var p := UltraNet.spawn_bot("Dummy", Transform3D(Basis(Vector3.UP, c.state.body_yaw + PI), c.state.pos + fwd * 3.0))
	(p.character.input_source as BotInputSource).set_steps([{"ticks": 100000}])
	_dummy = p.character
	var p2 := UltraNet.spawn_bot("Dummy", Transform3D(Basis(Vector3.UP, c.state.body_yaw + PI), c.state.pos + fwd * 3.0 + right * 2.0))
	(p2.character.input_source as BotInputSource).set_steps([{"ticks": 100000}])
	_dummy2 = p2.character
	_look = 1


## Buckshot point blank into the dummy's chest.
func _blast(_n: int) -> void:
	var c: UltraCharacter = main.player
	var chest := _dummy.state.pos + Vector3.UP * 1.25
	var from := chest + (c.state.pos - _dummy.state.pos).normalized() * 1.5
	var dirs := []
	for k in 9:
		dirs.append(((chest - from).normalized() + Vector3(randf_range(-0.02, 0.02), randf_range(-0.02, 0.02), randf_range(-0.02, 0.02))).normalized())
	UltraCombat.hitscan_pellets(c, from, dirs, ItemDB.get_def(&"shotgun"))


func _heart() -> void:
	var c: UltraCharacter = main.player
	var h := UltraHitboxes.heart(_dummy2, _dummy2.state.pos)
	var d := (h - (c.state.pos + Vector3.UP * 1.5)).normalized()
	UltraCombat.hitscan(c, h - d * 2.5, d, ItemDB.get_def(&"rifle"))
	_dummy = _dummy2


func _sever_leg() -> void:
	var c: UltraCharacter = main.player
	var d := UltraCombat.DamageInfo.new()
	d.amount = 60.0
	d.region = UltraLimbs.Region.FOREARM_L
	d.kind = &"blade"
	d.dir = Vector3.FORWARD
	d.point = c.state.pos + Vector3.UP * 0.6
	d.attacker_id = _dummy.net_id if _dummy else 0
	c.state.hp = 100.0
	c.apply_damage(d)
	c.state.hp = minf(c.state.hp, 45.0)       # (well down: the tunnel closing in)


func _knockout() -> void:
	var c: UltraCharacter = main.player
	var d := UltraCombat.DamageInfo.new()
	d.amount = 30.0
	d.region = UltraLimbs.Region.HEAD
	d.kind = &"blunt"
	d.dir = Vector3.FORWARD
	d.point = c.state.pos + Vector3.UP * 1.7
	d.attacker_id = _dummy.net_id if _dummy else 0
	c.state.hp = maxf(c.state.hp, 60.0)
	c.apply_damage(d)


func _kill() -> void:
	var c: UltraCharacter = main.player
	var d := UltraCombat.DamageInfo.new()
	d.amount = 200.0
	d.region = UltraLimbs.Region.TORSO
	d.kind = &"bullet"
	d.dir = Vector3.FORWARD
	d.point = c.state.pos + Vector3.UP * 1.3
	d.attacker_id = _dummy.net_id if _dummy else 0
	c.apply_damage(d)


func _process(delta: float) -> void:
	super(delta)
	if _cam == null:
		return
	var c: UltraCharacter = main.player
	if _look == 2:
		_cam.current = false                   # (the player's own camera: the HUD effects)
		return
	_cam.current = true
	var tgt := c if _look == 0 or _dummy == null else _dummy
	var yaw := c.state.body_yaw
	var right := Vector3(cos(yaw), 0, -sin(yaw))
	var fwd := Vector3(-sin(yaw), 0, -cos(yaw))
	var p := tgt.visual_root.global_position + Vector3.UP * 1.0
	_cam.global_position = p - right * 2.6 + fwd * (0.6 if _look == 0 else -0.8) + Vector3.UP * 0.4
	_cam.look_at(p)
