class_name UltraActionLayer
extends RefCounted
## Upper-body action state machine, stepped right after the motor with the same InputFrame:
## equip / holster, firearm fire + reload, consumables. All state is in MotorState, so it's
## predicted and replayed exactly like movement. Authority-only side effects (hitscan damage,
## inventory changes) go through `character.authority`; presentation goes out as events.

enum Action { NONE, EQUIPPING, READY, RELOADING, HOLSTERING, USING, MELEE }

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
			elif def and not busy and _melee_start(c, s, i, def, replaying):
				pass
			elif def and def.kind == ItemDefinition.Kind.FIREARM:
				_firearm(c, s, i, def, busy, replaying)
		Action.RELOADING:
			_reload(c, s, i, def, busy, replaying)
		Action.MELEE:
			_melee(c, s, i, def, busy, replaying)


## Game rule (same on every machine): reloads never run out and never use up reserve ammo.
## The demo playground turns it on.
static var infinite_ammo := false


static func reserve_of(c: UltraCharacter, ammo_id: StringName) -> int:
	if infinite_ammo:
		return 9999
	return c.inventory.count_of(ammo_id) if c.inventory else 0


## The item is up in the hands, ready to use (a strike is part of being ready).
static func is_up(action: int) -> bool:
	return action == Action.READY or action == Action.MELEE


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
		var pellets := int(def.stat("pellets", 1))
		if pellets > 1:
			shot["dirs"] = pellet_dirs(c, s, shot.dir, def, pellets)
		c.emit_item_event(&"fire", shot, replaying)
		if c.is_authority() and not replaying:
			if pellets > 1:
				UltraCombat.hitscan_pellets(c, shot.origin, shot.dirs, def)
			else:
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
	return {"origin": shot_origin(eye, i.aim_from, dir), "dir": dir, "seq": s.fire_seq}


## Buckshot: `n` pellet directions in a cone round the shot, seeded by (player, shot, pellet)
## like the spread - every machine sees the same pattern.
static func pellet_dirs(c: UltraCharacter, s: MotorState, dir: Vector3, def: ItemDefinition, n: int) -> Array[Vector3]:
	var cone := deg_to_rad(float(def.stat("pellet_spread_deg", 3.0)))
	var right := dir.cross(Vector3.UP).normalized()
	if right.length() < 0.5:
		right = Vector3.RIGHT
	var up := right.cross(dir).normalized()
	var out: Array[Vector3] = []
	for k in n:
		var rng := RandomNumberGenerator.new()
		rng.seed = hash(Vector3i(c.net_id, s.fire_seq, 100 + k))
		# Even-ish fill: pellet k takes its own slice of the angle, radius random.
		var a := (float(k) + rng.randf()) / n * TAU
		var r := sqrt(rng.randf_range(0.04, 1.0)) * cone
		out.append((dir + (right * cos(a) + up * sin(a)) * tan(r)).normalized())
	return out


## Shots start where the player's camera is (the eye + the frame's aim_from): crosshair, gun
## dot and bullet then agree however close the target. A camera behind the body (third
## person) starts the ray level with the body, so nothing between the camera and us is hit.
static func shot_origin(eye: Vector3, aim_from: Vector3, dir: Vector3) -> Vector3:
	var from := eye + aim_from
	return from + dir * maxf((eye - from).dot(dir), 0.0)


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
			and s.action in [Action.EQUIPPING, Action.READY, Action.RELOADING, Action.MELEE]
	if not armed:
		s.sway = Vector2.ZERO
		s.sway_v = Vector2.ZERO
		s.gun_low = 0.0
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
	# Carried low for a sprint - eased in and out (as a step the free-aim zone snapped the gun,
	# and the arms with it, down in a single tick).
	s.gun_low = move_toward(s.gun_low, 1.0 if sprinting else 0.0, dt * 4.0)
	if s.gun_low > 0.0:
		var side := -1.0 if UltraInjury.weapon_hand(s) == -1 else 1.0
		var k := smoothstep(0.0, 1.0, s.gun_low)
		target += Vector2(deg_to_rad(def.sprint_lower_deg.x) * side, deg_to_rad(def.sprint_lower_deg.y)) * k
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
	if String(def.stat("reload_mode", "")) == "shell":
		_reload_shells(c, s, i, def, busy, replaying, slow)
		return
	var commit := float(def.stat("reload_commit", 1.5)) * slow
	var total := float(def.stat("reload_time", 2.0)) * slow
	# Interrupted before the magazine went in: nothing gained. (Sprinting doesn't interrupt: a
	# reload holds you to a jog.)
	if busy:
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


## A tube magazine, loaded a shell at a time: after `reload_start`, one shell every
## `shell_time` until the tube is full or the shells run out, then `reload_end`. Pulling the
## trigger (with a shell in) stops loading and the gun comes up; so does anything busy.
static func _reload_shells(c: UltraCharacter, s: MotorState, i: InputFrame, def: ItemDefinition, busy: bool, replaying: bool, slow: float) -> void:
	var start := float(def.stat("reload_start", 0.35)) * slow
	var each := float(def.stat("shell_time", 0.55)) * slow
	var end_t := float(def.stat("reload_end", 0.3)) * slow
	var mag_size := int(def.stat("mag_size", 0))
	var ammo_id := StringName(def.stat("ammo", ""))
	if busy or (s.mag > 0 and UltraMotor.pressed_edge(s, i, InputFrame.B_PRIMARY)):
		_set_action(s, Action.READY)
		c.emit_item_event(&"reload_cancel", {}, replaying)
		if not busy:
			_firearm(c, s, i, def, busy, replaying)          # that trigger pull fires
		return
	var t := s.action_t - start
	var dt := c.motor.dt
	# A shell goes in each time the cycle comes round (the hand is at the loading port then).
	var k_now := int(floor(t / each)) if t > 0.0 else 0
	var k_prev := int(floor((t - dt) / each)) if t - dt > 0.0 else 0
	if k_now > k_prev and s.mag < mag_size:
		if reserve_of(c, ammo_id) > 0:
			s.mag += 1
			if c.is_authority() and not replaying and not infinite_ammo:
				c.inventory.take(ammo_id, 1)
				c.inventory_changed_by_server()
			c.emit_item_event(&"shell_in", {}, replaying)
	# Full (or nothing left to load): finish the cycle's last bit and bring the gun up.
	var done := s.mag >= mag_size or reserve_of(c, ammo_id) <= 0
	if done and t >= float(k_now) * each + end_t:
		_set_action(s, Action.READY)
		s.fire_cd = maxf(s.fire_cd, 0.1)


# ---------------------------------------------------------------- melee

const COMBO_QUEUED := 0x80
## This swing's blow has been dealt. (action_t is quantized to the millisecond: a "just
## crossed the hit time" test could step right over it.)
const COMBO_LANDED := 0x40


## A strike with what's in hand: gun-butt (a firearm, the melee button) or a melee weapon's
## swing (the attack button). Starts Action.MELEE; true if it did.
static func _melee_start(c: UltraCharacter, s: MotorState, i: InputFrame, def: ItemDefinition, replaying: bool) -> bool:
	var go := false
	if def.kind == ItemDefinition.Kind.FIREARM:
		go = UltraMotor.pressed_edge(s, i, InputFrame.B_MELEE)
	elif def.kind == ItemDefinition.Kind.MELEE:
		go = UltraMotor.pressed_edge(s, i, InputFrame.B_PRIMARY) or UltraMotor.pressed_edge(s, i, InputFrame.B_MELEE)
	if not go or s.fire_cd > 0.0:
		return false
	s.melee_combo = 0
	_begin_swing(c, s, replaying)
	return true


static func _begin_swing(c: UltraCharacter, s: MotorState, replaying: bool) -> void:
	_set_action(s, Action.MELEE)
	s.melee_seq = (s.melee_seq + 1) & 255
	c.emit_item_event(&"melee", {"combo": s.melee_combo & 0x3F}, replaying)


## Swing `k` of the item's combo: {time, hit_from, hit_to, reach, damage, kind, knockback, impulse}.
## Melee weapons list theirs in stats "melee" (one Dictionary per swing); a firearm without one
## swings its stock (long guns) or whips (pistols).
static func melee_swing(def: ItemDefinition, k: int) -> Dictionary:
	var list: Variant = def.stat("melee", null) if def else null
	if list is Array and not (list as Array).is_empty():
		var a := list as Array
		return a[clampi(k, 0, a.size() - 1)]
	# Gun-butts. clip / seg / contact are presentation (AnimDriver.play_swing, third person):
	# Mixamo "Advancing And Punching With Butt Of A Rifle" (a step in, the stock driven forward,
	# a step back) and "Overhand Strike With Pistol"; contact frames measured.
	if def and def.equip_slots & ItemDefinition.EquipSlot.BACK:          # a long gun: the stock
		return {"time": 0.72, "hit_from": 0.45, "hit_to": 0.55, "reach": 1.6, "damage": 20.0, "kind": &"blunt", "knockback": 4.2, "impulse": 14.0,
			"clip": &"butt_long", "seg": Vector2(0.15, 2.3), "contact": 1.05}
	return {"time": 0.56, "hit_from": 0.36, "hit_to": 0.44, "reach": 1.35, "damage": 14.0, "kind": &"blunt", "knockback": 3.0, "impulse": 9.0,
		"clip": &"butt_pistol", "seg": Vector2(0.25, 1.6), "contact": 0.93}


static func combo_length(def: ItemDefinition) -> int:
	var list: Variant = def.stat("melee", null) if def else null
	return (list as Array).size() if list is Array else 1


static func _melee(c: UltraCharacter, s: MotorState, i: InputFrame, def: ItemDefinition, busy: bool, replaying: bool) -> void:
	if def == null or busy:
		s.melee_combo = 0
		_set_action(s, Action.READY)
		c.emit_item_event(&"melee_cancel", {}, replaying)
		return
	var k := s.melee_combo & 0x3F
	var sw := melee_swing(def, k)
	var t := s.action_t
	# The blow lands as the swing reaches its hit window (once).
	if t >= float(sw.hit_from) and not (s.melee_combo & COMBO_LANDED):
		s.melee_combo |= COMBO_LANDED
		var res := UltraCombat.melee_sweep(c, s, i, sw, c.is_authority() and not replaying)
		c.emit_item_event(&"melee_hit", res, replaying)
	# Another press late in the swing chains the next one (melee weapons).
	if def.kind == ItemDefinition.Kind.MELEE and t > float(sw.time) * 0.45 \
			and (UltraMotor.pressed_edge(s, i, InputFrame.B_PRIMARY) or UltraMotor.pressed_edge(s, i, InputFrame.B_MELEE)):
		s.melee_combo |= COMBO_QUEUED
	if t >= float(sw.time):
		if s.melee_combo & COMBO_QUEUED and k + 1 < combo_length(def):
			s.melee_combo = k + 1
			_begin_swing(c, s, replaying)
		else:
			s.melee_combo = 0
			_set_action(s, Action.READY)
			s.fire_cd = maxf(s.fire_cd, 0.08)
