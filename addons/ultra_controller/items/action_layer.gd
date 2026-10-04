class_name UltraActionLayer
extends RefCounted
## Upper-body action state machine, stepped right after the motor with the same InputFrame:
## equip / holster, firearm fire + reload, consumables. All state is in MotorState, so it's
## predicted and replayed exactly like movement. Authority-only side effects (hitscan damage,
## inventory changes) go through `character.authority`; presentation goes out as events.

enum Action { NONE, EQUIPPING, READY, RELOADING, HOLSTERING, USING }



static func step(c: UltraCharacter, s: MotorState, i: InputFrame, dt: float, replaying: bool) -> void:
	s.fire_cd = maxf(s.fire_cd - dt, 0.0)
	s.action_t += dt
	var inv := c.inventory
	var want_uid := 0
	if inv and i.want_slot > 0:
		var it := inv.get_slot(i.want_slot - 1)
		if it and it.def() and it.def().can_equip(ItemDefinition.EquipSlot.MAIN_HAND):
			want_uid = it.uid
	# Traversal / ragdoll / swimming states put the item away.
	var busy := s.state in [MotorState.Id.ROOT_MOTION, MotorState.Id.SLIDE, MotorState.Id.CRAWL, MotorState.Id.MANTLE, MotorState.Id.VAULT, MotorState.Id.LEDGE_HANG, MotorState.Id.LEDGE_CLIMB, MotorState.Id.LADDER, MotorState.Id.WALL_CLIMB, MotorState.Id.ROPE, MotorState.Id.SWIM, MotorState.Id.DIVE, MotorState.Id.RAGDOLL, MotorState.Id.DEAD]
	var def := ItemDB.by_index(s.equipped)
	match s.action:
		Action.NONE:
			if want_uid != 0 and want_uid != s.held_uid:
				_begin_equip(c, s, want_uid)
		Action.EQUIPPING:
			if want_uid != s.held_uid:
				_set_action(s, Action.HOLSTERING)
			elif def and s.action_t >= def.equip_time:
				_set_action(s, Action.READY)
		Action.HOLSTERING:
			var t := (def.equip_time if def else 0.3) * 0.7
			if s.action_t >= t:
				_store_mag(c, s, replaying)
				s.held_uid = 0
				s.equipped = 0
				s.mag = 0
				_set_action(s, Action.NONE)
				if want_uid != 0:
					_begin_equip(c, s, want_uid)
		Action.READY:
			if want_uid != s.held_uid:
				_set_action(s, Action.HOLSTERING)
			elif def and def.kind == ItemDefinition.Kind.FIREARM:
				_firearm(c, s, i, def, busy, replaying)
		Action.RELOADING:
			_reload(c, s, i, def, busy, replaying)
	if busy and s.action == Action.READY and def and def.kind == ItemDefinition.Kind.FIREARM:
		pass   # stays drawn but can't fire (lowered); animation handles the pose


static func _set_action(s: MotorState, a: int) -> void:
	s.action = a
	s.action_t = 0.0


static func _begin_equip(c: UltraCharacter, s: MotorState, uid: int) -> void:
	var slot := c.inventory.find_uid(uid) if c.inventory else -1
	var it := c.inventory.get_slot(slot) if slot >= 0 else null
	if it == null:
		return
	s.held_uid = uid
	s.equipped = ItemDB.index_of(it.def_id)
	s.mag = int(it.data.get("mag", 0))
	_set_action(s, Action.EQUIPPING)


static func _store_mag(c: UltraCharacter, s: MotorState, replaying: bool) -> void:
	if replaying or c.inventory == null or s.held_uid == 0:
		return
	var slot := c.inventory.find_uid(s.held_uid)
	var it := c.inventory.get_slot(slot)
	if it and it.def() and it.def().kind == ItemDefinition.Kind.FIREARM:
		it.data["mag"] = s.mag


static func _firearm(c: UltraCharacter, s: MotorState, i: InputFrame, def: ItemDefinition, busy: bool, replaying: bool) -> void:
	var sprinting := s.has(MotorState.F_SPRINTING) and Vector2(s.vel.x, s.vel.z).length() > c.profile.jog_speed * 0.9
	var can_shoot := not busy and not sprinting
	var mag_size := int(def.stat("mag_size", 0))
	var ammo_id := StringName(def.stat("ammo", ""))
	var reserve := c.inventory.count_of(ammo_id) if c.inventory else 0
	if i.has(InputFrame.B_RELOAD) and s.mag < mag_size and reserve > 0 and not busy:
		_set_action(s, Action.RELOADING)
		c.emit_item_event(&"reload", {}, replaying)
		return
	if UltraMotor.pressed_edge(s, i, InputFrame.B_PRIMARY) and can_shoot and s.fire_cd <= 0.0:
		if s.mag <= 0:
			c.emit_item_event(&"dry_fire", {}, replaying)
			s.fire_cd = 0.25
			if reserve > 0:
				_set_action(s, Action.RELOADING)
				c.emit_item_event(&"reload", {}, replaying)
			return
		s.mag -= 1
		s.fire_seq = (s.fire_seq + 1) & 255
		s.fire_cd = float(def.stat("fire_interval", 0.15))
		var shot := aim_ray(c, s, i, def)
		c.emit_item_event(&"fire", shot, replaying)
		if c.is_authority() and not replaying:
			UltraCombat.hitscan(c, shot.origin, shot.dir, def)


## Deterministic shot: eye from the simulated capsule, direction from the absolute aim plus
## a spread seeded by (player, shot number) so client prediction and server agree.
static func aim_ray(c: UltraCharacter, s: MotorState, i: InputFrame, def: ItemDefinition) -> Dictionary:
	var eye := s.pos + Vector3.UP * (s.height - 0.16)
	var dir := Vector3(-sin(i.yaw) * cos(i.pitch), sin(i.pitch), -cos(i.yaw) * cos(i.pitch))
	var ads := i.has(InputFrame.B_SECONDARY)
	var spread := deg_to_rad(float(def.stat("ads_spread_deg" if ads else "spread_deg", 0.5)))
	var moving := Vector2(s.vel.x, s.vel.z).length() / maxf(c.profile.jog_speed, 0.1)
	spread *= 1.0 + moving * (0.5 if ads else 1.5) + (0.0 if s.is_grounded() else 2.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector2i(c.net_id, s.fire_seq))
	var a := rng.randf() * TAU
	var r := sqrt(rng.randf()) * spread
	var right := dir.cross(Vector3.UP).normalized()
	var up := right.cross(dir).normalized()
	dir = (dir + (right * cos(a) + up * sin(a)) * tan(r)).normalized()
	return {"origin": eye, "dir": dir, "seq": s.fire_seq}


static func _reload(c: UltraCharacter, s: MotorState, i: InputFrame, def: ItemDefinition, busy: bool, replaying: bool) -> void:
	if def == null:
		_set_action(s, Action.NONE)
		return
	var commit := float(def.stat("reload_commit", 1.5))
	var total := float(def.stat("reload_time", 2.0))
	# Interrupted before the magazine went in: nothing gained.
	if busy or (s.has(MotorState.F_SPRINTING) and s.action_t < commit):
		_set_action(s, Action.READY)
		c.emit_item_event(&"reload_cancel", {}, replaying)
		return
	if s.action_t >= commit and s.action_t - c.motor.dt < commit:
		var mag_size := int(def.stat("mag_size", 0))
		var ammo_id := StringName(def.stat("ammo", ""))
		var reserve := c.inventory.count_of(ammo_id) if c.inventory else 0
		var need := mini(mag_size - s.mag, reserve)
		s.mag += need
		# Only the authority's inventory really changes; the owner gets it replicated.
		if c.is_authority() and not replaying and need > 0:
			c.inventory.take(ammo_id, need)
			c.inventory_changed_by_server()
		c.emit_item_event(&"mag_in", {}, replaying)
	if s.action_t >= total:
		_set_action(s, Action.READY)
