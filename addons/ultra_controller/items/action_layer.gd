class_name UltraActionLayer
extends RefCounted
## Upper-body action state machine, stepped right after the motor with the same InputFrame:
## equip / holster, firearm fire + reload, consumables. All state is in MotorState, so it's
## predicted and replayed exactly like movement. Authority-only side effects (hitscan damage,
## inventory changes) go through `character.authority`; presentation goes out as events.

enum Action { NONE, EQUIPPING, READY, RELOADING, HOLSTERING, USING }

## States that need both hands: the item in hand is stowed while they last.
const TWO_HANDED: Array[int] = [MotorState.Id.MANTLE, MotorState.Id.VAULT, MotorState.Id.LEDGE_HANG,
	MotorState.Id.LEDGE_CLIMB, MotorState.Id.LADDER, MotorState.Id.WALL_CLIMB, MotorState.Id.ROPE,
	MotorState.Id.SWIM, MotorState.Id.DIVE, MotorState.Id.CRAWL, MotorState.Id.ROOT_MOTION,
	MotorState.Id.RAGDOLL, MotorState.Id.DEAD, MotorState.Id.GET_UP]



static func step(c: UltraCharacter, s: MotorState, i: InputFrame, dt: float, replaying: bool) -> void:
	s.fire_cd = maxf(s.fire_cd - dt, 0.0)
	s.action_t += dt
	UltraGrab.step(c, s, i, dt, replaying)
	var inv := c.inventory
	var want_uid := 0
	if inv and i.want_slot > 0 and s.held_id == 0:      # hands full: weapon stays away
		var it := inv.get_slot(i.want_slot - 1)
		if it and it.def() and it.def().can_equip(ItemDefinition.EquipSlot.MAIN_HAND):
			want_uid = it.uid
	if UltraInjury.weapon_hand(s) == 0:
		want_uid = 0                                     # no working arm to hold it with
	var busy := s.state in [MotorState.Id.GET_UP, MotorState.Id.ROOT_MOTION, MotorState.Id.SLIDE, MotorState.Id.CRAWL, MotorState.Id.MANTLE, MotorState.Id.VAULT, MotorState.Id.LEDGE_HANG, MotorState.Id.LEDGE_CLIMB, MotorState.Id.LADDER, MotorState.Id.WALL_CLIMB, MotorState.Id.ROPE, MotorState.Id.SWIM, MotorState.Id.DIVE, MotorState.Id.RAGDOLL, MotorState.Id.DEAD]
	# Two-handed moves (climbing, hanging, ropes, swimming, crawling, rolling, down on the
	# ground) stow what's in hand straight away; it comes back out once they're over (the
	# selected slot is still wanted).
	if s.state in TWO_HANDED:
		want_uid = 0
		if s.held_uid != 0:
			_store_mag(c, s, replaying)
			s.held_uid = 0
			s.equipped = 0
			s.mag = 0
			_set_action(s, Action.NONE)
	var def := ItemDB.by_index(s.equipped)
	_free_aim(c, s, i, def, dt)
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


## Game rule (same on every machine): reloads never run out and never use up reserve ammo.
## The demo playground turns it on.
static var infinite_ammo := false


static func reserve_of(c: UltraCharacter, ammo_id: StringName) -> int:
	if infinite_ammo:
		return 9999
	return c.inventory.count_of(ammo_id) if c.inventory else 0


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


## A drawn, ready gun fires whenever the trigger is pulled - sprinting, sliding, jumping: the
## shot goes where the gun points (lowered while sprinting). Two-handed moves stow it instead.
static func _firearm(c: UltraCharacter, s: MotorState, i: InputFrame, def: ItemDefinition, busy: bool, replaying: bool) -> void:
	var mag_size := int(def.stat("mag_size", 0))
	var ammo_id := StringName(def.stat("ammo", ""))
	var reserve := reserve_of(c, ammo_id)
	if i.has(InputFrame.B_RELOAD) and s.mag < mag_size and reserve > 0 and not busy:
		_set_action(s, Action.RELOADING)
		c.emit_item_event(&"reload", {}, replaying)
		return
	var edge := UltraMotor.pressed_edge(s, i, InputFrame.B_PRIMARY)
	var pull := edge or (def.fire_mode == ItemDefinition.FireMode.AUTO and i.has(InputFrame.B_PRIMARY) and s.mag > 0)
	if pull and s.fire_cd <= 0.0:
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
		_recoil(c, s, def)
		c.emit_item_event(&"fire", shot, replaying)
		if c.is_authority() and not replaying:
			UltraCombat.hitscan(c, shot.origin, shot.dir, def)


## Deterministic shot: eye from the simulated capsule, direction from where the GUN points
## (absolute aim + the free-aim offset) plus a spread seeded by (player, shot number) so client
## prediction and server agree.
static func aim_ray(c: UltraCharacter, s: MotorState, i: InputFrame, def: ItemDefinition) -> Dictionary:
	var eye := s.pos + Vector3.UP * (s.height - 0.16)
	var dir := gun_dir(i.yaw, i.pitch, s.sway)
	var ads := i.has(InputFrame.B_SECONDARY)
	var spread := deg_to_rad(float(def.stat("ads_spread_deg" if ads else "spread_deg", 0.5)))
	var moving := Vector2(s.vel.x, s.vel.z).length() / maxf(c.profile.jog_speed, 0.1)
	spread *= 1.0 + moving * (0.5 if ads else 1.5) + (0.0 if s.is_grounded() else 2.0)
	spread *= UltraInjury.aim_mult(s, c.damage_profile)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector2i(c.net_id, s.fire_seq))
	var a := rng.randf() * TAU
	var r := sqrt(rng.randf()) * spread
	var right := dir.cross(Vector3.UP).normalized()
	var up := right.cross(dir).normalized()
	dir = (dir + (right * cos(a) + up * sin(a)) * tan(r)).normalized()
	return {"origin": eye, "dir": dir, "seq": s.fire_seq}


## Where the gun points: the aim turned by the free-aim offset (x = yaw, y = pitch).
static func gun_dir(yaw: float, pitch: float, sway: Vector2) -> Vector3:
	var y := yaw + sway.x
	var p := clampf(pitch + sway.y, -1.55, 1.55)
	return Vector3(-sin(y) * cos(p), sin(p), -cos(y) * cos(p))


## Rotation (world) that turns the aim direction onto the gun direction.
static func sway_basis(yaw: float, pitch: float, sway: Vector2) -> Basis:
	var aim := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch)
	var gun := Basis(Vector3.UP, yaw + sway.x) * Basis(Vector3.RIGHT, clampf(pitch + sway.y, -1.55, 1.55))
	return gun * aim.inverse()


## Free aim (Arma / Insurgency style weapon inertia). The gun's offset from the aim is a damped
## spring: turning leaves it behind (`sway_inertia` of each turn), moving makes it bob with the
## gait (more at a jog, a lot sprinting, most in the air), sprinting carries it low, crouching /
## aiming down sights / standing still calm it, a hurt arm shakes it, and it can't drift out of
## the free-aim zone. Only (state, input, dt) go in: predicted and replayed exactly.
static func _free_aim(c: UltraCharacter, s: MotorState, i: InputFrame, def: ItemDefinition, dt: float) -> void:
	var dyaw := angle_difference(s.aim_prev_yaw, i.yaw)
	var dpitch := i.pitch - s.aim_prev_pitch
	s.aim_prev_yaw = i.yaw
	s.aim_prev_pitch = i.pitch
	var armed := def != null and def.kind == ItemDefinition.Kind.FIREARM and s.held_uid != 0 \
			and s.action in [Action.EQUIPPING, Action.READY, Action.RELOADING]
	if not armed:
		s.sway = Vector2.ZERO
		s.sway_v = Vector2.ZERO
		return
	# A snap of the aim (spawn, teleport, respawn) isn't a turn.
	if absf(dyaw) > 0.5 or absf(dpitch) > 0.5:
		dyaw = 0.0
		dpitch = 0.0
	var ads := i.has(InputFrame.B_SECONDARY) and s.action == Action.READY
	var calm := def.ads_sway_mult if ads else 1.0
	if s.stance != MotorState.Stance.STAND:
		calm *= 0.6
	var shaky := UltraInjury.aim_mult(s, c.damage_profile)
	var speed := Vector2(s.vel.x, s.vel.z).length()
	var air := not s.is_grounded()
	var sprinting := s.has(MotorState.F_SPRINTING) and speed > c.profile.jog_speed * 0.9 and not ads
	# Gait phase: breathing when still, the step cadence when moving (cycles per second).
	var cadence := lerpf(0.22, 0.55 + speed * 0.17, smoothstep(0.1, 1.0, speed))
	s.sway_phase = fposmod(s.sway_phase + dt * TAU * cadence, TAU)
	# Sway amplitude (degrees): breathing, then walk ~0.6, jog ~1.9, sprint ~3.8; more airborne.
	var amp := 0.12 + speed * 0.35 + maxf(speed - 4.0, 0.0) * 0.4
	if air:
		amp = amp * 1.6 + 1.0
	amp = deg_to_rad(amp) * def.sway_amount * calm * shaky
	var ph := s.sway_phase
	var target := Vector2(sin(ph) * amp * 0.8, (0.5 - absf(cos(ph))) * amp * 0.7)
	if speed < 0.1:
		target = Vector2(sin(ph * 0.5) * amp * 0.5, sin(ph) * amp)      # slow breathing figure
	if sprinting:
		var side := -1.0 if UltraInjury.weapon_hand(s) == -1 else 1.0
		target += Vector2(deg_to_rad(def.sprint_lower_deg.x) * side, deg_to_rad(def.sprint_lower_deg.y))
	# Inertia: the gun doesn't follow all of this tick's turn straight away.
	var lag := def.sway_inertia * (calm if ads else 1.0) * clampf(shaky, 1.0, 2.0)
	s.sway -= Vector2(dyaw, dpitch) * lag
	# Damped spring toward the target (semi-implicit Euler: stable at 60 Hz).
	var w := TAU * def.sway_return_hz
	var acc := (target - s.sway) * w * w - s.sway_v * (2.0 * def.sway_damping * w)
	s.sway_v += acc * dt
	s.sway += s.sway_v * dt
	# Free-aim zone around the target: past it the gun drags along (and loses its swing).
	var zone := deg_to_rad(def.free_aim_deg) * (calm if ads else 1.0) * clampf(shaky, 1.0, 1.5)
	var d := s.sway - target
	for k in 2:
		if absf(d[k]) > zone:
			d[k] = signf(d[k]) * zone
			if s.sway_v[k] * d[k] > 0.0:
				s.sway_v[k] = 0.0
	s.sway = target + d
	s.sway.y = clampf(s.sway.y, -0.9, 0.9)


## Recoil: kick the gun up (and a little sideways); the spring brings it back. Seeded by the
## shot number like the spread, so every machine kicks the same way.
static func _recoil(c: UltraCharacter, s: MotorState, def: ItemDefinition) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(c.net_id, s.fire_seq, 7))
	var w := TAU * def.sway_return_hz
	var kick := deg_to_rad(def.recoil_gun_deg) * w * 1.8
	s.sway_v += Vector2(rng.randf_range(-0.35, 0.35) * kick, kick)


static func _reload(c: UltraCharacter, s: MotorState, i: InputFrame, def: ItemDefinition, busy: bool, replaying: bool) -> void:
	if def == null:
		_set_action(s, Action.NONE)
		return
	var slow := UltraInjury.reload_mult(s, c.damage_profile)
	var commit := float(def.stat("reload_commit", 1.5)) * slow
	var total := float(def.stat("reload_time", 2.0)) * slow
	# Interrupted before the magazine went in: nothing gained.
	if busy or (s.has(MotorState.F_SPRINTING) and s.action_t < commit):
		_set_action(s, Action.READY)
		c.emit_item_event(&"reload_cancel", {}, replaying)
		return
	if s.action_t >= commit and s.action_t - c.motor.dt < commit:
		var mag_size := int(def.stat("mag_size", 0))
		var ammo_id := StringName(def.stat("ammo", ""))
		var reserve := reserve_of(c, ammo_id)
		var need := mini(mag_size - s.mag, reserve)
		s.mag += need
		# Only the authority's inventory really changes; the owner gets it replicated.
		if c.is_authority() and not replaying and need > 0 and not infinite_ammo:
			c.inventory.take(ammo_id, need)
			c.inventory_changed_by_server()
		c.emit_item_event(&"mag_in", {}, replaying)
	if s.action_t >= total:
		_set_action(s, Action.READY)
