class_name UltraWorldNet
extends RefCounted
## World replication owned by UltraNet: objects, physics props, events, inventories and lag
## compensation. RPC entry points live on the UltraNet node and forward here.

const PROP_BUDGET := 16            ## rigid bodies per snapshot
const LAG_HISTORY := 64            ## ticks of character positions kept for lag compensation
const MAX_REWIND_TICKS := 14

var net: Node                      ## the UltraNet autoload
var objects := {}                  ## id -> NetObject
var _next_dynamic := 0x8000
var _dirty := {}
var _handlers := {}                ## event name -> Array[Callable]
var _history := {}                 ## player id -> PackedVector3Array ring (index tick % LAG_HISTORY)


func _init(p_net: Node) -> void:
	net = p_net


# ------------------------------------------------------------------ registry

func register(o: NetObject) -> void:
	if o.net_id == 0:
		if o.dynamic:
			return                     # the spawner assigns it
		var path := str(net.world_root.get_path_to(o.get_parent())) if net.world_root else str(o.get_parent().get_path())
		var id := (hash(path) & 0x7FFF) | 1
		while objects.has(id):
			id = ((id + 1) & 0x7FFF) | 1
		o.net_id = id
	objects[o.net_id] = o
	var rb := o.rigid()
	if rb and net.mode == net.Mode.CLIENT:
		rb.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		rb.freeze = true


## Clients never simulate replicated rigid bodies: they follow the server's stream.
func apply_client_mode() -> void:
	for o: NetObject in objects.values():
		var rb := o.rigid()
		if rb:
			rb.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
			rb.freeze = true


func clear_dynamic() -> void:
	for id: int in objects.keys():
		var o: NetObject = objects[id]
		if not is_instance_valid(o) or o.dynamic:
			if is_instance_valid(o):
				o.get_parent().queue_free()
			objects.erase(id)
	_dirty.clear()
	_history.clear()


func unregister(o: NetObject) -> void:
	if objects.get(o.net_id) == o:
		objects.erase(o.net_id)


## The character with this net id (players and bots; falls back to a scene search).
func character(net_id: int) -> UltraCharacter:
	var p: NetPlayer = net.players.get(net_id)
	if p and is_instance_valid(p.character):
		return p.character
	for n in net.get_tree().get_nodes_in_group(&"ultra_character"):
		if (n as UltraCharacter).net_id == net_id:
			return n
	return null


func get_object(id: int) -> NetObject:
	return objects.get(id)


func object_dirty(o: NetObject) -> void:
	_dirty[o.net_id] = o


## Server: spawn a scene for everyone (dropped items, thrown props). Returns the instance.
func spawn(scene_path: String, xf: Transform3D, extra := {}, vel := Vector3.ZERO) -> Node3D:
	var n := _instantiate(scene_path, xf, extra)
	var o := n.find_child("NetObject", false, false) as NetObject
	if o == null:
		o = NetObject.new()
		o.name = "NetObject"
		n.add_child(o)
	o.dynamic = true
	o.net_id = _next_dynamic
	_next_dynamic += 1
	o.spawn_info = {"scene": scene_path, "extra": extra}
	(net.world_root if net.world_root else net.get_tree().current_scene).add_child(n)
	n.global_transform = xf
	objects[o.net_id] = o
	if n is RigidBody3D and vel != Vector3.ZERO:
		(n as RigidBody3D).linear_velocity = vel
	for peer in net._remote_peers():
		net._send_reliable(peer, net._s2c_spawn_object, [o.net_id, scene_path, xf, extra, o.net_state()])
	return n


func despawn(id: int) -> void:
	var o: NetObject = objects.get(id)
	if o == null:
		return
	objects.erase(id)
	o.get_parent().queue_free()
	if net.is_server():
		for peer in net._remote_peers():
			net._send_reliable(peer, net._s2c_despawn_object, [id])


func _instantiate(scene_path: String, _xf: Transform3D, extra: Dictionary) -> Node3D:
	var n := (load(scene_path) as PackedScene).instantiate() as Node3D
	for k: String in extra:
		if k in n:
			n.set(k, extra[k])
	return n


func client_spawn(id: int, scene_path: String, xf: Transform3D, extra: Dictionary, state: Dictionary) -> void:
	if objects.has(id):
		return
	var n := _instantiate(scene_path, xf, extra)
	var o := n.find_child("NetObject", false, false) as NetObject
	if o == null:
		o = NetObject.new()
		o.name = "NetObject"
		n.add_child(o)
	o.dynamic = true
	o.net_id = id
	(net.world_root if net.world_root else net.get_tree().current_scene).add_child(n)
	n.global_transform = xf
	objects[id] = o
	if n is RigidBody3D:
		(n as RigidBody3D).freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		(n as RigidBody3D).freeze = true
	if not state.is_empty():
		o.apply_state(state)


## Late joiners: every dynamic object and every object's discrete state.
func send_world_to(peer: int) -> void:
	for o: NetObject in objects.values():
		if o.dynamic:
			net._send_reliable(peer, net._s2c_spawn_object, [o.net_id, o.spawn_info.get("scene", ""), o.body().global_transform, o.spawn_info.get("extra", {}), o.net_state()])
		else:
			var st := o.net_state()
			if not st.is_empty():
				net._send_reliable(peer, net._s2c_object_state, [o.net_id, st])


func flush_dirty() -> void:
	if _dirty.is_empty():
		return
	for id: int in _dirty:
		var o: NetObject = _dirty[id]
		if not is_instance_valid(o):
			continue
		var st := o.net_state()
		for peer in net._remote_peers():
			net._send_reliable(peer, net._s2c_object_state, [id, st])
		emit_local(&"object_state", [id, st])
	_dirty.clear()


# ------------------------------------------------------------------ physics props stream

func write_props(b: StreamPeerBuffer) -> void:
	var list: Array[NetObject] = []
	for o: NetObject in objects.values():
		var rb := o.rigid()
		if rb == null or not is_instance_valid(rb):
			continue
		var moving := not rb.sleeping and not rb.freeze
		o._prio += 4.0 if moving else 0.05
		list.append(o)
	list.sort_custom(func(a: NetObject, c: NetObject) -> bool: return a._prio > c._prio)
	var n := mini(list.size(), PROP_BUDGET)
	b.put_u8(n)
	for i in n:
		var o := list[i]
		o._prio = 0.0
		var rb := o.rigid()
		var xf := rb.global_transform
		var q := xf.basis.get_rotation_quaternion()
		b.put_u16(o.net_id)
		b.put_float(xf.origin.x); b.put_float(xf.origin.y); b.put_float(xf.origin.z)
		b.put_16(int(q.x * 32767.0)); b.put_16(int(q.y * 32767.0)); b.put_16(int(q.z * 32767.0)); b.put_16(int(q.w * 32767.0))
		var v := rb.linear_velocity
		b.put_16(clampi(int(v.x * 100.0), -32767, 32767)); b.put_16(clampi(int(v.y * 100.0), -32767, 32767)); b.put_16(clampi(int(v.z * 100.0), -32767, 32767))


func read_props(b: StreamPeerBuffer, tick: int) -> void:
	if b.get_available_bytes() < 1:
		return
	var n := b.get_u8()
	for i in n:
		var id := b.get_u16()
		var pos := Vector3(b.get_float(), b.get_float(), b.get_float())
		var q := Quaternion(b.get_16() / 32767.0, b.get_16() / 32767.0, b.get_16() / 32767.0, b.get_16() / 32767.0).normalized()
		var vel := Vector3(b.get_16() / 100.0, b.get_16() / 100.0, b.get_16() / 100.0)
		var o: NetObject = objects.get(id)
		if o:
			o.snaps.append({"tick": tick, "pos": pos, "rot": q, "vel": vel})
			if o.snaps.size() > 30:
				o.snaps.pop_front()


## Client: place kinematic props at the interpolation time.
func interpolate_props(render_tick: float) -> void:
	for o: NetObject in objects.values():
		if o.snaps.is_empty():
			continue
		var rb := o.rigid()
		if rb == null or o.get_meta("held_locally", false):
			continue
		var a: Dictionary = o.snaps[0]
		var c: Dictionary = a
		for i in range(o.snaps.size() - 1, -1, -1):
			if float(o.snaps[i].tick) <= render_tick:
				a = o.snaps[i]
				c = o.snaps[mini(i + 1, o.snaps.size() - 1)]
				break
		var t := 0.0
		if c.tick != a.tick:
			t = clampf((render_tick - float(a.tick)) / float(c.tick - a.tick), 0.0, 1.0)
		var pos: Vector3 = (a.pos as Vector3).lerp(c.pos, t)
		var rot: Quaternion = (a.rot as Quaternion).slerp(c.rot, t)
		rb.global_transform = Transform3D(Basis(rot), pos)


# ------------------------------------------------------------------ events

func on_event(name: StringName, cb: Callable) -> void:
	if not _handlers.has(name):
		_handlers[name] = []
	(_handlers[name] as Array).append(cb)


func off_event(name: StringName, cb: Callable) -> void:
	if _handlers.has(name):
		(_handlers[name] as Array).erase(cb)


func emit_local(name: StringName, args: Array) -> void:
	for cb: Callable in _handlers.get(name, []):
		if cb.is_valid():
			cb.callv(args)


## Server: tell everyone (including our own screen). `exclude_peer` skips one client (e.g.
## the shooter, who already predicted the effect).
func broadcast(name: StringName, args: Array, reliable := false, exclude_peer := 0) -> void:
	if not net.is_server():
		return
	for peer in net._remote_peers():
		if peer == exclude_peer:
			continue
		if reliable:
			net._send_reliable(peer, net._s2c_event, [name, args])
		else:
			net._send_unreliable(peer, net._s2c_event, [name, args])
	emit_local(name, args)


# ------------------------------------------------------------------ inventories

func send_inventory(p: NetPlayer) -> void:
	if p.role == NetPlayer.Role.AUTHORITY_REMOTE:
		net._send_reliable(p.peer_id, net._s2c_inventory, [p.id, p.character.inventory.to_bytes()])


## Server: validate and apply an inventory request from the owner.
func inventory_op(p: NetPlayer, op: String, args: Array) -> void:
	var c := p.character
	var inv := c.inventory
	match op:
		"move":
			inv.move(int(args[0]), int(args[1]))
		"split":
			inv.split(int(args[0]))
		"drop":
			var slot := int(args[0])
			var it := inv.get_slot(slot)
			if it == null or it.uid == c.state.held_uid:
				return
			var taken := inv.remove_slot(slot, int(args[1]) if args.size() > 1 else -1)
			if taken:
				UltraItems.drop_into_world(c, taken, Vector3.ZERO)
		"use":
			UltraItems.use_item(c, int(args[0]))
	c.inventory_changed_by_server()


# ------------------------------------------------------------------ lag compensation

func record_history(tick: int) -> void:
	for p: NetPlayer in net.players.values():
		if not is_instance_valid(p.character):
			continue
		var ring: PackedVector3Array = _history.get(p.id, PackedVector3Array())
		if ring.size() != LAG_HISTORY:
			ring.resize(LAG_HISTORY)
		ring[tick % LAG_HISTORY] = p.character.state.pos
		_history[p.id] = ring


## Move every other character to where `shooter` saw them, run `query`, put them back.
func rewound(shooter: UltraCharacter, query: Callable) -> Variant:
	var back := 0
	if shooter.net_role == NetPlayer.Role.AUTHORITY_REMOTE and net.is_server():
		var sp: NetPlayer = net.players.get(shooter.net_id)
		var rtt: float = net.peer_rtt_ms(sp.peer_id) if sp else 0.0
		back = clampi(int(rtt * 0.5 / 1000.0 * Engine.physics_ticks_per_second + net.INTERP_DELAY_TICKS + 1), 0, MAX_REWIND_TICKS)
	if back == 0:
		return query.call()
	var view_tick: int = net.server_tick - back
	var moved := []
	for p: NetPlayer in net.players.values():
		var c := p.character
		if c == shooter or not is_instance_valid(c) or not _history.has(p.id):
			continue
		var old := c.global_transform
		var past: Vector3 = (_history[p.id] as PackedVector3Array)[view_tick % LAG_HISTORY]
		var xf := Transform3D(old.basis, past)
		PhysicsServer3D.body_set_state(c.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, xf)
		if c.hit_volume:
			PhysicsServer3D.body_set_state(c.hit_volume.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, xf)
		moved.append([c, old])
	var r: Variant = query.call()
	for m: Array in moved:
		var mc := m[0] as UltraCharacter
		PhysicsServer3D.body_set_state(mc.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, m[1])
		if mc.hit_volume:
			PhysicsServer3D.body_set_state(mc.hit_volume.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, m[1])
	return r
