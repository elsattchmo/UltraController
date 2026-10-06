extends Node
## `--net-report`: collects netcode quality numbers during a run and prints a verdict at exit.
## Client: corrections, max correction, final predicted-vs-server error, input queue depth.
## Server: per-player input misses and processed frames.
## Thresholds (client): mean correction < 3 cm, max < 0.5 m.  Exit code 3 on failure.

var _depths: Array[int] = []
var _final_err := -1.0


func _ready() -> void:
	UltraNet.snapshot_received.connect(_on_snapshot)
	UltraNet.session_ended.connect(func(_r: String) -> void: _finish())
	UltraNet.player_removed.connect(func(p: NetPlayer) -> void: _gone.append(_summ(p)))
	get_tree().auto_accept_quit = false
	get_tree().root.close_requested.connect(_finish)
	var t := UltraArgs.get_float("quit-after", 0.0)
	if t > 0.0:
		get_tree().create_timer(t - 0.2).timeout.connect(_finish)


var _path := {}         # remote id -> distance travelled as seen in snapshots
var _last := {}
var _gone: Array[Dictionary] = []


static func _summ(p: NetPlayer) -> Dictionary:
	var pos := p.character.state.pos if is_instance_valid(p.character) else Vector3.ZERO
	var limbs := UltraLimbs.describe(p.character.state) if is_instance_valid(p.character) else "-"
	return {"id": p.id, "role": p.role, "processed": p.processed, "misses": p.misses, "pos": pos, "limbs": limbs, "name": p.display_name}


var _shots := 0
var _melee_hits := 0                ## predicted blows that struck something
var _remote_ko := {}                ## remote players seen knocked out (name -> true)
var _hooked := {}
var _max_y := -INF                  # highest the (predicted) local player got: traversal checks
var _trav_states := {}
var _states_seen := {}


func _on_snapshot(_tick: int) -> void:
	for p in UltraNet.local_players:
		if not _hooked.has(p.id):
			_hooked[p.id] = true
			p.character.item_event.connect(func(kind: StringName, _d: Dictionary) -> void:
				if kind == &"fire":
					_shots += 1
				elif kind == &"melee_hit" and bool(_d.get("hit", false)):
					_melee_hits += 1)
	for p: NetPlayer in UltraNet.players.values():
		if p.role == NetPlayer.Role.INTERPOLATED and is_instance_valid(p.character) and p.character.state.has(MotorState.F_UNCONSCIOUS):
			_remote_ko[p.display_name] = true
	for p: NetPlayer in UltraNet.players.values():
		if p.role == NetPlayer.Role.INTERPOLATED and not p.snaps.is_empty():
			var pos: Vector3 = p.snaps[p.snaps.size() - 1].pos
			if _last.has(p.id):
				_path[p.id] = float(_path.get(p.id, 0.0)) + pos.distance_to(_last[p.id])
			_last[p.id] = pos
	for p in UltraNet.local_players:
		if p.role == NetPlayer.Role.PREDICTED:
			_depths.append(p.server_queue_depth)
		if is_instance_valid(p.character):
			_max_y = maxf(_max_y, p.character.state.pos.y)
			if p.character.state.state >= MotorState.Id.MANTLE:
				_trav_states[MotorState.Id.keys()[p.character.state.state]] = true
			_states_seen[MotorState.Id.keys()[p.character.state.state]] = true


var _done := false


func _finish() -> void:
	if _done:
		return
	_done = true
	var ok := true
	print("NETREPORT mode=%s" % UltraNet.Mode.keys()[UltraNet.mode])
	if UltraNet.mode == UltraNet.Mode.CLIENT:
		if UltraNet.local_players.is_empty():
			print("NETREPORT FAIL no local players were spawned (never joined?)")
			ok = false
		for p in UltraNet.local_players:
			var mean := p.correction_sum / maxf(p.corrections, 1)
			var ticks := p.client_tick
			var corr_rate := float(p.corrections) / maxf(ticks / 2.0, 1.0)
			_depths.sort()
			var med_depth := _depths[_depths.size() / 2] if not _depths.is_empty() else -1
			print("NETREPORT player=%d ticks=%d corrections=%d rate=%.3f mean=%.4f max=%.4f queue_median=%d dilation=%.3f rtt=%.0f" % [p.id, ticks, p.corrections, corr_rate, mean, p.correction_max, med_depth, UltraNet.dilation, UltraNet.rtt_ms])
			if ticks < 300:
				print("NETREPORT FAIL too few ticks simulated")
				ok = false
			if p.corrections > 0 and mean > 0.03:
				print("NETREPORT FAIL mean correction %.3f m" % mean)
				ok = false
			var max_ok := UltraArgs.get_float("max-correction", 0.5)
			if p.correction_max > max_ok:
				print("NETREPORT FAIL max correction %.3f m (limit %.3f)" % [p.correction_max, max_ok])
				ok = false
			if UltraArgs.has("expect-no-corrections") and p.corrections > 0:
				print("NETREPORT FAIL expected an exact match with the server, got %d corrections" % p.corrections)
				ok = false
		var want_shots := UltraArgs.get_int("expect-shots", 0)
		if want_shots > 0:
			for p in UltraNet.local_players:
				print("NETREPORT shots_seen=%d mag=%d inventory_rev=%d" % [_shots, p.character.state.mag, p.character.inventory.revision])
				if _shots < want_shots:
					print("NETREPORT FAIL only %d predicted shots (want %d)" % [_shots, want_shots])
					ok = false
				if p.character.inventory.count_of(&"pistol") != 1:
					print("NETREPORT FAIL client never received its inventory")
					ok = false
		var want_melee := UltraArgs.get_int("expect-melee-hits", 0)
		if want_melee > 0:
			print("NETREPORT melee hits=%d" % _melee_hits)
			if _melee_hits < want_melee:
				print("NETREPORT FAIL only %d predicted melee hits (want %d)" % [_melee_hits, want_melee])
				ok = false
		var climb := UltraArgs.get_float("expect-climb", 0.0)
		if climb > 0.0:
			print("NETREPORT climb max_y=%.2f states=%s" % [_max_y, ",".join(_trav_states.keys())])
			if _max_y < climb or _trav_states.is_empty():
				print("NETREPORT FAIL never got up (max y %.2f, want %.2f)" % [_max_y, climb])
				ok = false
		var want_states := UltraArgs.get_str("expect-states", "")
		if want_states != "":
			print("NETREPORT states %s" % ",".join(_states_seen.keys()))
			for st in want_states.split(","):
				if not _states_seen.has(st):
					print("NETREPORT FAIL never entered %s" % st)
					ok = false
		if UltraArgs.has("expect-remote-ko"):
			print("NETREPORT remote knockouts: %s" % (", ".join(_remote_ko.keys()) if not _remote_ko.is_empty() else "none"))
			if _remote_ko.is_empty():
				print("NETREPORT FAIL never saw anyone knocked out")
				ok = false
		if UltraArgs.has("expect-remote-injury"):
			var hurt: Array[String] = []
			for rp: NetPlayer in UltraNet.players.values():
				if rp.role == NetPlayer.Role.INTERPOLATED and is_instance_valid(rp.character) and not UltraLimbs.is_whole(rp.character.state):
					hurt.append("%s: %s" % [rp.display_name, UltraLimbs.describe(rp.character.state)])
			print("NETREPORT remote injuries: %s" % ("; ".join(hurt) if not hurt.is_empty() else "none"))
			if hurt.is_empty():
				print("NETREPORT FAIL no injury reached this client")
				ok = false
		var want_level := UltraArgs.get_str("expect-level", "")
		if want_level != "":
			var lv := String(get_parent().get("level"))
			print("NETREPORT level=%s" % lv)
			if lv != want_level:
				print("NETREPORT FAIL on level '%s', expected the host's '%s'" % [lv, want_level])
				ok = false
		var want_remotes := UltraArgs.get_int("expect-remotes", 0)
		var seen := 0
		for id: int in _path:
			var moved := float(_path[id])
			print("NETREPORT remote=%d travelled=%.1f m" % [id, moved])
			if moved > 1.0:
				seen += 1
		if seen < want_remotes:
			print("NETREPORT FAIL saw %d moving remote players, expected %d" % [seen, want_remotes])
			ok = false
	else:
		var everyone: Array[Dictionary] = []
		for g in _gone:
			everyone.append(g.merged({"gone": true}))
		for p: NetPlayer in UltraNet.players.values():
			everyone.append(_summ(p))
		if everyone.is_empty() and UltraNet.mode != UltraNet.Mode.OFFLINE:
			print("NETREPORT FAIL server never had players")
			ok = false
		for e in everyone:
			print("NETREPORT player=%d role=%s processed=%d misses=%d pos=%s %s (%s)" % [e.id, NetPlayer.Role.keys()[e.role], e.processed, e.misses, (e.pos as Vector3).snappedf(0.001), e.get("name", ""), e.get("limbs", "")])
			var dropped_ok: bool = UltraArgs.has("allow-dropped") and bool(e.get("gone", false))      # (a client that went away to join again elsewhere)
			if e.role == NetPlayer.Role.AUTHORITY_REMOTE and int(e.processed) < 300 and not dropped_ok:
				print("NETREPORT FAIL server processed too few frames for player %d" % e.id)
				ok = false
	print("NETREPORT %s" % ("PASS" if ok else "FAIL"))
	get_tree().quit(0 if ok else 3)
