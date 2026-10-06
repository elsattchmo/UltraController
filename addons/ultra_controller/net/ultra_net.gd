extends Node
## Autoload "UltraNet": the session and the fixed-tick simulation loop.
##
## Every mode runs the same loop. OFFLINE (single-player) is a server with no remote peers:
## local players are AUTHORITY_LOCAL and simulate the tick they're sampled — zero latency,
## no prediction. HOST adds remote clients (AUTHORITY_REMOTE, fed from input queues).
## CLIENT predicts its own players and reconciles against snapshots; everyone else is
## interpolated. DEDICATED is a host without local players.
##
## Transport: our own RPCs with hand-packed bytes (no MultiplayerSynchronizer/Spawner).
##   inputs    client -> server  unreliable_ordered, ch 1, last 4 frames per player (redundant)
##   snapshot  server -> client  unreliable, ch 2, every 2 ticks, tailored per client
##   events    reliable, ch 0 (hello, spawn, despawn, teleport)

enum Mode { NONE, OFFLINE, HOST, CLIENT, DEDICATED }

signal session_started(mode: int)
signal session_ended(reason: String)
signal player_added(p: NetPlayer)
signal player_removed(p: NetPlayer)
signal snapshot_received(server_tick: int)

const SNAPSHOT_EVERY := 2
const INTERP_DELAY_TICKS := 6.0
const MAX_RESEND := 60             ## send every unacknowledged input, up to this many (1 s:
                                   ## an OS stall on the client mustn't leave holes behind)
const TARGET_QUEUE := 2
const MAX_QUEUE := 32
const CORRECTION_EPS := 0.02
const GAP_WAIT_TICKS := 10
const DEFAULT_PORT := 7777

var mode: int = Mode.NONE
var lag := UltraLagSim.new()
## Objects, props, events, inventories, lag compensation.
var world := UltraWorldNet.new(self)
var server_tick: int = 0
var players := {}                         ## id -> NetPlayer
var local_players: Array[NetPlayer] = []
## Game hooks.
var character_factory: Callable           ## (NetPlayer) -> UltraCharacter (not in tree yet)
var spawn_transform: Callable             ## (NetPlayer) -> Transform3D
var local_input_factory: Callable         ## (local_index: int) -> InputSource
var world_root: Node
## Client clock / dilation.
var dilation := 1.0
var server_tick_est := 0.0
var rtt_ms := 0.0
var verbose := false

var _next_player_id := 1
var _acc := 0.0
var _last_snapshot_tick := -1
var _local_count := 1
var _local_names: PackedStringArray = []
var _dt := 1.0 / 60.0


# ================================================================== session control

func is_server() -> bool:
	return mode == Mode.OFFLINE or mode == Mode.HOST or mode == Mode.DEDICATED


func is_active() -> bool:
	return mode != Mode.NONE


func start_offline(local_count := 1, names := PackedStringArray()) -> void:
	stop()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	mode = Mode.OFFLINE
	_begin_server(local_count, names)


func host(port := DEFAULT_PORT, local_count := 1, names := PackedStringArray(), max_clients := 16) -> Error:
	stop()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, max_clients, 3)
	if err != OK:
		session_ended.emit("could not host on port %d (%s)" % [port, error_string(err)])
		return err
	multiplayer.multiplayer_peer = peer
	mode = Mode.DEDICATED if local_count == 0 else Mode.HOST
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	_begin_server(local_count, names)
	return OK


func join(address: String, port := DEFAULT_PORT, local_count := 1, names := PackedStringArray()) -> Error:
	stop()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port, 3)
	if err != OK:
		session_ended.emit("could not connect (%s)" % error_string(err))
		return err
	multiplayer.multiplayer_peer = peer
	mode = Mode.CLIENT
	world.apply_client_mode()
	_local_count = local_count
	_local_names = names
	multiplayer.connected_to_server.connect(_on_connected, CONNECT_ONE_SHOT)
	_dt = 1.0 / Engine.physics_ticks_per_second
	multiplayer.connection_failed.connect(func() -> void: session_ended.emit("connection failed"), CONNECT_ONE_SHOT)
	multiplayer.server_disconnected.connect(func() -> void:
		session_ended.emit("server closed")
		stop(), CONNECT_ONE_SHOT)
	return OK


func stop() -> void:
	for p: NetPlayer in players.values():
		if is_instance_valid(p.character):
			p.character.queue_free()
	players.clear()
	local_players.clear()
	world.clear_dynamic()
	if multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.disconnect(_on_peer_connected)
	if multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.disconnect(_on_peer_disconnected)
	if multiplayer.multiplayer_peer and not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer):
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	mode = Mode.NONE
	server_tick = 0
	_last_snapshot_tick = -1
	_next_player_id = 1
	dilation = 1.0


func _begin_server(local_count: int, names: PackedStringArray) -> void:
	server_tick = 0
	for i in local_count:
		_server_add_player(multiplayer.get_unique_id(), i, names[i] if i < names.size() else "Player %d" % (i + 1))
	session_started.emit(mode)


## Split-screen: add another local player mid-session (server modes add directly; a client
## asks the server).
func add_local_player(name := "") -> void:
	var idx := local_players.size()
	if is_server():
		_server_add_player(multiplayer.get_unique_id(), idx, name if name != "" else "Player %d" % (idx + 1))
	elif mode == Mode.CLIENT:
		_send_reliable(1, _c2s_add_local, [idx, name])


## Server: add an AI-driven player (companions, scenario bots). Returns it; drive it through
## its BotInputSource (`p.character.input_source`).
## Authority: put a character back at its spawn point, healed.
func respawn_character(c: UltraCharacter) -> void:
	if not is_server():
		return
	var p: NetPlayer = players.get(c.net_id)
	var xf := c.global_transform
	if p and spawn_transform.is_valid() and not p.is_bot:
		xf = spawn_transform.call(p)
	elif p and p.is_bot and c.has_meta("home"):
		xf = c.get_meta("home")
	c.respawn(xf)


func spawn_bot(bot_name := "Helper", at := Transform3D.IDENTITY) -> NetPlayer:
	if not is_server():
		return null
	var p := NetPlayer.new()
	p.id = _next_player_id
	_next_player_id += 1
	p.peer_id = multiplayer.get_unique_id()
	p.local_index = -1
	p.display_name = bot_name
	p.is_bot = true
	p.role = NetPlayer.Role.AUTHORITY_LOCAL
	var c: UltraCharacter = character_factory.call(p)
	c.name = "Bot_%d" % p.id
	c.self_simulate = false
	var src := BotInputSource.new()
	src.name = "InputSource"
	c.add_child(src)
	c.input_source = src
	c.position = at.origin
	c.rotation.y = at.basis.get_euler().y
	c.set_meta("home", at)
	c.net_role = p.role
	c.net_id = p.id
	c.quantize_state = true
	(world_root if world_root else get_tree().current_scene).add_child(c)
	src.body = c
	p.character = c
	c.state.quantize()
	players[p.id] = p
	for peer in _remote_peers():
		_send_reliable(peer, _s2c_spawn, [p.id, p.peer_id, p.local_index, p.display_name, _state_bytes(c.state)])
	player_added.emit(p)
	return p


func despawn_bot(id: int) -> void:
	if is_server() and players.has(id) and (players[id] as NetPlayer).is_bot:
		_server_remove_player(id)


func remove_local_player(local_index: int) -> void:
	for p in local_players:
		if p.local_index == local_index:
			if is_server():
				_server_remove_player(p.id)
			else:
				_send_reliable(1, _c2s_remove_local, [local_index])
			return


# ================================================================== server side

func _on_peer_connected(peer_id: int) -> void:
	if verbose:
		print("[net] peer connected ", peer_id)
	_no_throttle(peer_id)


## ENet's packet throttle drops bursts of unreliable packets whenever round-trip times
## wobble (it saw 20 consecutive input packets go missing on localhost under CPU load).
## Our tick protocol already tolerates loss, so let every packet through.
func _no_throttle(peer_id: int) -> void:
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if enet == null:
		return
	var pp := enet.get_peer(peer_id)
	if pp:
		pp.throttle_configure(5000, ENetPacketPeer.PACKET_THROTTLE_SCALE, 0)   # 5000 ms = ENet default interval


func _on_peer_disconnected(peer_id: int) -> void:
	for p: NetPlayer in players.values().duplicate():
		if p.peer_id == peer_id:
			_server_remove_player(p.id)


@rpc("any_peer", "reliable", "call_remote", 0)
func _c2s_hello(local_count: int, names: PackedStringArray) -> void:
	if not is_server():
		return
	var peer := multiplayer.get_remote_sender_id()
	if verbose:
		print("[net] hello from ", peer, " players ", local_count)
	# Late join: tell the newcomer about everyone already here.
	for p: NetPlayer in players.values():
		_send_reliable(peer, _s2c_spawn, [p.id, p.peer_id, p.local_index, p.display_name, _state_bytes(p.character.state)])
	world.send_world_to(peer)
	for i in clampi(local_count, 0, 4):
		_server_add_player(peer, i, names[i] if i < names.size() else "Player %d.%d" % [peer % 1000, i + 1])


@rpc("any_peer", "reliable", "call_remote", 0)
func _c2s_add_local(local_index: int, name: String) -> void:
	if is_server():
		_server_add_player(multiplayer.get_remote_sender_id(), local_index, name)


@rpc("any_peer", "reliable", "call_remote", 0)
func _c2s_remove_local(local_index: int) -> void:
	var peer := multiplayer.get_remote_sender_id()
	for p: NetPlayer in players.values():
		if p.peer_id == peer and p.local_index == local_index:
			_server_remove_player(p.id)
			return


func _server_add_player(peer_id: int, local_index: int, pname: String) -> NetPlayer:
	var p := NetPlayer.new()
	p.id = _next_player_id
	_next_player_id += 1
	p.peer_id = peer_id
	p.local_index = local_index
	p.display_name = pname
	p.role = NetPlayer.Role.AUTHORITY_LOCAL if peer_id == multiplayer.get_unique_id() else NetPlayer.Role.AUTHORITY_REMOTE
	_make_character(p)
	p.character.state.quantize()                 # clients start from these exact bits
	p.character.inventory_dirty.connect(func() -> void: world.send_inventory(p))
	players[p.id] = p
	if p.role == NetPlayer.Role.AUTHORITY_LOCAL:
		local_players.append(p)
	for peer in _remote_peers():
		_send_reliable(peer, _s2c_spawn, [p.id, p.peer_id, p.local_index, p.display_name, _state_bytes(p.character.state)])
	player_added.emit(p)
	world.send_inventory(p)
	return p


func _server_remove_player(id: int) -> void:
	var p: NetPlayer = players.get(id)
	if p == null:
		return
	players.erase(id)
	local_players.erase(p)
	player_removed.emit(p)
	if is_instance_valid(p.character):
		p.character.queue_free()
	for peer in _remote_peers():
		_send_reliable(peer, _s2c_despawn, [id])


func _remote_peers() -> PackedInt32Array:
	if mode == Mode.OFFLINE or multiplayer.multiplayer_peer == null:
		return PackedInt32Array()
	return multiplayer.get_peers()


@rpc("any_peer", "unreliable", "call_remote", 1)
func _c2s_inputs(bytes: PackedByteArray) -> void:
	if not is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	var b := StreamPeerBuffer.new()
	b.data_array = bytes
	var n := b.get_u8()
	for k in n:
		var id := b.get_u8()
		var count := b.get_u8()
		var p: NetPlayer = players.get(id)

		for j in count:
			var f := InputFrame.decode(b)
			if p == null or p.peer_id != sender:
				continue
			# Packets may arrive out of order: keep any frame we haven't simulated yet, in
			# tick order, once.
			if f.tick <= p.last_processed_tick:
				continue
			if verbose and p.queue.size() > 0 and f.tick < p.queue[0].tick and f.tick < 40:
				print("[srv] p%d late frame t%d (queue head t%d, processed t%d)" % [p.id, f.tick, p.queue[0].tick, p.last_processed_tick])
			var at := p.queue.size()
			var dup := false
			for qi in range(p.queue.size() - 1, -1, -1):
				var qt := p.queue[qi].tick
				if qt == f.tick:
					dup = true
					break
				if qt < f.tick:
					break
				at = qi
			if dup:
				continue
			p.queue.insert(at, f)
			p.last_received_tick = maxi(p.last_received_tick, f.tick)
		if p and p.queue.size() > MAX_QUEUE:
			p.queue = p.queue.slice(p.queue.size() - MAX_QUEUE)



func _server_step(dt: float) -> void:
	server_tick += 1
	TickPlatform.set_all(server_tick)
	for p: NetPlayer in players.values():
		if not is_instance_valid(p.character):
			continue
		if p.role == NetPlayer.Role.AUTHORITY_LOCAL:
			var period := p.character.sim_period
			if p.character.sim_skip or (period > 1 and (server_tick + p.id) % period != 0):
				p.last_processed_tick = server_tick
				p.character.stride_wait += 1
				continue
			var f := p.character.input_source.sample(server_tick) if p.character.input_source else p.last_input.copy()
			p.character.platform_tick = server_tick
			p.character.simulate(f, dt * period)
			p.last_processed_tick = server_tick
			p.processed += 1
		else:
			# Consume queued client frames; catch up (2 per tick) when the queue runs long.
			# An empty queue means "wait" rather than guessing an input: the client's own
			# prediction stays exact and the dilation loop refills the buffer.
			var steps := 2 if p.queue.size() > TARGET_QUEUE + 3 else 1
			for s in steps:
				if p.queue.is_empty():
					p.misses += 1
					break
				# A hole (a frame still in flight): wait a few ticks for it before giving up.
				var head := p.queue[0]
				if p.last_processed_tick >= 0 and head.tick > p.last_processed_tick + 1 and p.gap_wait < GAP_WAIT_TICKS:
					p.gap_wait += 1
					p.misses += 1
					break
				if verbose and p.last_processed_tick >= 0 and head.tick > p.last_processed_tick + 1:
					print("[srv] p%d SKIP t%d..t%d after waiting %d" % [p.id, p.last_processed_tick + 1, head.tick - 1, p.gap_wait])
				p.gap_wait = 0
				var f: InputFrame = p.queue.pop_front()
				p.last_input = f
				p.character.platform_tick = server_tick
				p.character.simulate(f, dt)
				p.last_processed_server_tick = server_tick

				p.last_processed_tick = f.tick
				p.processed += 1
	var holders: Array = []
	for p: NetPlayer in players.values():
		if is_instance_valid(p.character) and p.character.state.held_id != 0:
			holders.append(p.character)
	if not holders.is_empty():
		UltraGrab.server_tick(holders, dt)
	UltraGrab.impacts(get_tree().get_nodes_in_group(&"ultra_character"), dt)
	world.record_history(server_tick)
	world.flush_dirty()
	if server_tick % SNAPSHOT_EVERY == 0:
		for peer in _remote_peers():
			_send_unreliable(peer, _s2c_snapshot, [_build_snapshot(peer)])


func _build_snapshot(peer: int) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.put_u32(server_tick)
	b.put_u8(players.size())
	for p: NetPlayer in players.values():
		var s := p.character.state
		b.put_u8(p.id)
		if p.peer_id == peer and p.last_processed_tick < 0:
			b.put_u8(2)                          # owned, but no input processed yet
		elif p.peer_id == peer:
			b.put_u8(1)
			b.put_u32(p.last_processed_tick)
			b.put_u32(p.last_processed_server_tick)
			b.put_u8(clampi(p.queue.size(), 0, 255))
			s.encode(b)
		else:
			b.put_u8(0)
			b.put_float(s.pos.x); b.put_float(s.pos.y); b.put_float(s.pos.z)
			b.put_16(clampi(int(s.vel.x * 100.0), -32767, 32767))
			b.put_16(clampi(int(s.vel.y * 100.0), -32767, 32767))
			b.put_16(clampi(int(s.vel.z * 100.0), -32767, 32767))
			b.put_u16(int(roundf(fposmod(s.body_yaw, TAU) / TAU * 65536.0)) % 65536)
			var li := p.character.last_input
			b.put_u16(int(roundf(fposmod(li.yaw, TAU) / TAU * 65536.0)) % 65536)
			b.put_16(int(roundf(clampf(li.pitch, -1.55, 1.55) * 20000.0)))
			b.put_u8(s.state)
			b.put_u8(s.stance)
			b.put_u16(s.flags)
			b.put_u16(int(roundf(s.height * 1000.0)))
			b.put_8(s.rm_clip)
			b.put_16(clampi(int(s.land_impact * 100.0), -32767, 32767))
			b.put_u32(li.buttons)
			b.put_u16(s.platform_id)
			b.put_u16(s.equipped)
			b.put_u8(s.action)
			b.put_u8(s.fire_seq)
			b.put_u8(s.melee_seq & 255)
			b.put_u8(s.melee_combo & 0x3F)
			b.put_u16(clampi(int(s.hp * 10.0), 0, 65535))
			b.put_u32(UltraLimbs.pack(s))
	world.write_props(b)
	return b.data_array


# ================================================================== client side

func _on_connected() -> void:
	if verbose:
		print("[net] connected as peer ", multiplayer.get_unique_id())
	_no_throttle(1)
	_send_reliable(1, _c2s_hello, [_local_count, _local_names])
	session_started.emit(mode)


@rpc("authority", "reliable", "call_remote", 0)
func _s2c_spawn(id: int, peer_id: int, local_index: int, pname: String, state: PackedByteArray) -> void:
	if players.has(id):
		return
	var p := NetPlayer.new()
	p.id = id
	p.peer_id = peer_id
	p.local_index = local_index
	p.display_name = pname
	p.role = NetPlayer.Role.PREDICTED if peer_id == multiplayer.get_unique_id() else NetPlayer.Role.INTERPOLATED
	if verbose:
		print("[net] spawn p%d peer %d (me %d) as %s" % [id, peer_id, multiplayer.get_unique_id(), NetPlayer.Role.keys()[p.role]])
	_make_character(p)
	var b := StreamPeerBuffer.new()
	b.data_array = state
	p.character.state.decode(b)
	p.character.teleport(p.character.state.pos, p.character.state.body_yaw)
	p.character.global_position = p.character.state.pos
	players[id] = p
	if p.role == NetPlayer.Role.PREDICTED:
		local_players.append(p)
	player_added.emit(p)


@rpc("authority", "reliable", "call_remote", 0)
func _s2c_despawn(id: int) -> void:
	var p: NetPlayer = players.get(id)
	if p == null:
		return
	players.erase(id)
	local_players.erase(p)
	player_removed.emit(p)
	if is_instance_valid(p.character):
		p.character.queue_free()


func _client_step(dt: float) -> void:
	_acc += dilation
	var ran := 0
	while _acc >= 1.0 and ran < 3:
		_acc -= 1.0
		ran += 1
		for p in local_players:
			if p.role != NetPlayer.Role.PREDICTED or not is_instance_valid(p.character):
				continue
			var t := p.client_tick
			var f := p.character.input_source.sample(t)
			f.tick = t
			TickPlatform.set_all(t + p.server_tick_offset)
			p.character.platform_tick = t + p.server_tick_offset
			p.character.simulate(f, dt)
			p.record(t, f, p.character.state.copy())

			p.client_tick += 1
	if ran > 0:
		_send_inputs()


func _send_inputs() -> void:
	var b := StreamPeerBuffer.new()
	var mine: Array[NetPlayer] = []
	for p in local_players:
		if p.role == NetPlayer.Role.PREDICTED:
			mine.append(p)
	if mine.is_empty():
		return
	b.put_u8(mine.size())
	for p in mine:
		b.put_u8(p.id)
		# Everything the server hasn't confirmed yet: a burst of lost packets is refilled by
		# the very next one.
		var frames: Array[InputFrame] = []
		# Keep the datagram under ~1.1 KB with several local players (no fragmentation).
		var cap := clampi(MAX_RESEND / mine.size(), 24, MAX_RESEND)
		var from := maxi(p.last_acked + 1, p.client_tick - cap)
		for t in range(from, p.client_tick):
			var f := p.history_input(t)
			if f:
				frames.append(f)
		b.put_u8(frames.size())
		for f in frames:
			f.encode(b)

	_send_unreliable(1, _c2s_inputs, [b.data_array])


@rpc("authority", "unreliable", "call_remote", 2)
func _s2c_snapshot(bytes: PackedByteArray) -> void:
	var b := StreamPeerBuffer.new()
	b.data_array = bytes
	var st := b.get_u32()
	if st <= _last_snapshot_tick:
		return
	_last_snapshot_tick = st
	var err := float(st) - server_tick_est
	if absf(err) > 20.0:
		server_tick_est = float(st)
	else:
		server_tick_est += err * 0.1
	var n := b.get_u8()
	for k in n:
		var id := b.get_u8()
		var p: NetPlayer = players.get(id)
		var kind := b.get_u8()
		var owned := kind == 1
		if kind == 2:
			continue
		if owned:
			var ack := b.get_u32()
			var ack_server := b.get_u32()
			var depth := b.get_u8()
			var s := MotorState.new()
			s.decode(b)
			if p:
				if p.synced_from < 0:
					p.synced_from = p.client_tick
				p.server_tick_offset = ack_server - ack
				_reconcile(p, ack, depth, s)
		else:
			var e := {"tick": st}
			e.pos = Vector3(b.get_float(), b.get_float(), b.get_float())
			e.vel = Vector3(b.get_16() / 100.0, b.get_16() / 100.0, b.get_16() / 100.0)
			e.yaw = b.get_u16() / 65536.0 * TAU
			e.aim_yaw = b.get_u16() / 65536.0 * TAU
			e.pitch = b.get_16() / 20000.0
			e.state = b.get_u8()
			e.stance = b.get_u8()
			e.flags = b.get_u16()
			e.height = b.get_u16() / 1000.0
			e.rm_clip = b.get_8()
			e.land_impact = b.get_16() / 100.0
			e.buttons = b.get_u32()
			e.platform = b.get_u16()
			e.equipped = b.get_u16()
			e.action = b.get_u8()
			e.fire_seq = b.get_u8()
			e.melee_seq = b.get_u8()
			e.melee_combo = b.get_u8()
			e.hp = b.get_u16() / 10.0
			e.limbs = b.get_u32()
			if p:
				p.snaps.append(e)
				if p.snaps.size() > 40:
					p.snaps.pop_front()
	world.read_props(b, st)
	snapshot_received.emit(st)


func _reconcile(p: NetPlayer, ack: int, depth: int, server: MotorState) -> void:
	p.server_queue_depth = depth
	p.last_acked = maxi(p.last_acked, ack)
	# Keep the server's input queue about TARGET_QUEUE deep by running our clock a hair
	# faster or slower (never by changing dt: the sim stays bit-identical).
	var want := 1.0
	if depth < 1:
		want = 1.05
	elif depth > TARGET_QUEUE + 2:
		want = 0.95
	elif depth > TARGET_QUEUE:
		want = 0.985
	dilation = lerpf(dilation, want, 0.25)
	var predicted := p.history_state(ack)
	if predicted == null or p.history_input(ack) == null:
		return
	var err := predicted.diff(server)
	if err <= CORRECTION_EPS:
		return
	if verbose:
		print("[net]   ack %d predicted %s v%s st%d | server %s v%s st%d" % [ack, predicted.pos, predicted.vel, predicted.state, server.pos, server.vel, server.state])
	var c := p.character
	var before := c.state.pos
	c.state.copy_from(server)
	p.state_history[ack % NetPlayer.HISTORY] = server.copy()
	for t in range(ack + 1, p.client_tick):
		var f := p.history_input(t)
		if f == null:
			break
		TickPlatform.set_all(t + p.server_tick_offset)
		c.platform_tick = t + p.server_tick_offset
		c.simulate(f, _dt, true)
		p.state_history[t % NetPlayer.HISTORY] = c.state.copy()
	TickPlatform.set_all(p.client_tick - 1 + p.server_tick_offset)
	var jump := before - c.state.pos
	# Ticks predicted before the first ack ran on a guessed server clock (a moving platform
	# anywhere): the first rebase onto the server is a sync, not a misprediction.
	if ack < p.synced_from:
		c.visual_offset += jump if jump.length() < 1.0 else Vector3.ZERO
		return
	p.corrections += 1
	p.last_correction = jump.length()
	p.correction_sum += jump.length()
	p.correction_max = maxf(p.correction_max, jump.length())
	if jump.length() < 1.0:
		c.visual_offset += jump          # glide, don't pop
	else:
		c.teleport(c.state.pos)
	if verbose:
		print("[net] correction p%d ack %d err %.3f moved %.3f" % [p.id, ack, err, jump.length()])


func _interpolate_remotes(delta: float) -> void:
	server_tick_est += delta * Engine.physics_ticks_per_second
	var rt := server_tick_est - INTERP_DELAY_TICKS
	for p: NetPlayer in players.values():
		if p.role != NetPlayer.Role.INTERPOLATED or p.snaps.is_empty() or not is_instance_valid(p.character):
			continue
		var a: Dictionary = p.snaps[0]
		var b: Dictionary = a
		for i in range(p.snaps.size() - 1, -1, -1):
			if float(p.snaps[i].tick) <= rt:
				a = p.snaps[i]
				b = p.snaps[mini(i + 1, p.snaps.size() - 1)]
				break
		var pos: Vector3
		var vel: Vector3 = b.vel
		var yaw: float
		if a == b:
			# Starved: extrapolate a little, then hold.
			var ahead := clampf((rt - float(a.tick)) / 60.0, 0.0, 0.15)
			pos = a.pos + a.vel * ahead
			yaw = a.yaw
		else:
			var span := float(b.tick - a.tick)
			var t := clampf((rt - float(a.tick)) / span, 0.0, 1.0)
			var dur := span / 60.0
			pos = _hermite(a.pos, a.vel * dur, b.pos, b.vel * dur, t)
			vel = (a.vel as Vector3).lerp(b.vel, t)
			yaw = lerp_angle(a.yaw, b.yaw, t)
			# Riding a platform: interpolate in the platform's frame and place the result on
			# the platform as it is shown now, so remote riders stay glued to it.
			var plat := TickPlatform.find(int(a.platform)) if int(a.platform) != 0 and a.platform == b.platform else null
			if plat:
				var la: Vector3 = plat.pose_at(int(a.tick)).affine_inverse() * a.pos
				var lb: Vector3 = plat.pose_at(int(b.tick)).affine_inverse() * b.pos
				pos = plat.global_transform * la.lerp(lb, t)
		var src: Dictionary = b if rt >= float(b.tick) - 1.0 else a
		p.character.apply_remote(pos, vel, yaw, src)


static func _hermite(p0: Vector3, m0: Vector3, p1: Vector3, m1: Vector3, t: float) -> Vector3:
	var t2 := t * t
	var t3 := t2 * t
	return p0 * (2 * t3 - 3 * t2 + 1) + m0 * (t3 - 2 * t2 + t) + p1 * (-2 * t3 + 3 * t2) + m1 * (t3 - t2)


# ================================================================== shared

func _make_character(p: NetPlayer) -> void:
	assert(character_factory.is_valid(), "UltraNet.character_factory not set")
	var c: UltraCharacter = character_factory.call(p)
	c.name = "Player_%d" % p.id
	c.self_simulate = false
	if p.role == NetPlayer.Role.AUTHORITY_LOCAL or p.role == NetPlayer.Role.PREDICTED:
		if local_input_factory.is_valid():
			var src: InputSource = local_input_factory.call(p.local_index)
			src.name = "InputSource"
			c.add_child(src)
			c.input_source = src
	if spawn_transform.is_valid() and is_server():
		var xf: Transform3D = spawn_transform.call(p)
		c.position = xf.origin
		c.rotation.y = xf.basis.get_euler().y
	c.net_role = p.role
	c.net_id = p.id
	c.quantize_state = true
	(world_root if world_root else get_tree().current_scene).add_child(c)
	p.character = c


func _state_bytes(s: MotorState) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	s.encode(b)
	return b.data_array


func _send_reliable(peer: int, fn: Callable, args: Array) -> void:
	var call_args: Array = [peer, StringName(fn.get_method())] + args
	lag.send(func() -> void: callv("rpc_id", call_args), true)


func _send_unreliable(peer: int, fn: Callable, args: Array) -> void:
	var call_args: Array = [peer, StringName(fn.get_method())] + args
	lag.send(func() -> void: callv("rpc_id", call_args), false)


func _physics_process(dt: float) -> void:
	_dt = dt
	lag.flush()
	match mode:
		Mode.OFFLINE, Mode.HOST, Mode.DEDICATED:
			_server_step(dt)
		Mode.CLIENT:
			_client_step(dt)
	_update_rtt()


func _process(delta: float) -> void:
	if mode == Mode.CLIENT:
		_interpolate_remotes(delta)
		world.interpolate_props(server_tick_est - INTERP_DELAY_TICKS)


func peer_rtt_ms(peer_id: int) -> float:
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if enet == null:
		return 0.0
	var pp := enet.get_peer(peer_id)
	return pp.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME) + lag.latency_ms if pp else 0.0


## Ask the server to change our inventory (move/split/drop/use). Applied at once on a server.
func request_inventory(player_id: int, op: String, args: Array) -> void:
	var p: NetPlayer = players.get(player_id)
	if p == null:
		return
	if is_server():
		world.inventory_op(p, op, args)
	else:
		_send_reliable(1, _c2s_inventory_op, [player_id, op, args])


@rpc("any_peer", "reliable", "call_remote", 0)
func _c2s_inventory_op(player_id: int, op: String, args: Array) -> void:
	var p: NetPlayer = players.get(player_id)
	if p and p.peer_id == multiplayer.get_remote_sender_id():
		world.inventory_op(p, op, args)


@rpc("authority", "reliable", "call_remote", 0)
func _s2c_inventory(player_id: int, bytes: PackedByteArray) -> void:
	var p: NetPlayer = players.get(player_id)
	if p and is_instance_valid(p.character):
		p.character.inventory.from_bytes(bytes)


@rpc("authority", "reliable", "call_remote", 0)
func _s2c_spawn_object(id: int, scene_path: String, xf: Transform3D, extra: Dictionary, state: Dictionary) -> void:
	world.client_spawn(id, scene_path, xf, extra, state)


@rpc("authority", "reliable", "call_remote", 0)
func _s2c_despawn_object(id: int) -> void:
	world.despawn(id)


@rpc("authority", "reliable", "call_remote", 0)
func _s2c_object_state(id: int, state: Dictionary) -> void:
	var o := world.get_object(id)
	if o:
		o.apply_state(state)
	world.emit_local(&"object_state", [id, state])


@rpc("authority", "unreliable", "call_remote", 2)
func _s2c_event(event_name: StringName, args: Array) -> void:
	world.emit_local(event_name, args)


func _update_rtt() -> void:
	if mode != Mode.CLIENT or not (multiplayer.multiplayer_peer is ENetMultiplayerPeer):
		return
	var peer := (multiplayer.multiplayer_peer as ENetMultiplayerPeer).get_peer(1)
	if peer:
		rtt_ms = peer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME) + lag.latency_ms


func stats_line() -> String:
	var parts := PackedStringArray()
	parts.append("%s tick %d" % [Mode.keys()[mode], server_tick if is_server() else int(server_tick_est)])
	if mode == Mode.CLIENT:
		parts.append("rtt %.0fms dil %.3f" % [rtt_ms, dilation])
	for p in local_players:
		if p.role == NetPlayer.Role.PREDICTED:
			parts.append("p%d q%d corr %d (max %.2fm)" % [p.id, p.server_queue_depth, p.corrections, p.correction_max])
	if lag.active():
		parts.append("lagsim %.0f±%.0fms %.0f%%" % [lag.latency_ms, lag.jitter_ms, lag.loss_pct])
	return "  ".join(parts)
