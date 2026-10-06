class_name ZombieFactory
extends RefCounted
## Makes a zombie character from a NetPlayer whose display name is "Z:<archetype>:<n>" (the name
## travels with the player, so every machine builds the same kind). A zombie is an ordinary bot:
## UltraNet.spawn_bot -> this factory -> a server-simulated UltraCharacter driven by a brain through
## its BotInputSource. Player ids are never reused, so zombies are pooled (parked, respawned in
## place), never spawned and despawned over and over.

const PREFIX := "Z:"
const DIR := "res://assets/characters/zombie/"

static var _body := {}              ## gait role -> BodyProfile (a clip-role variant of the shared body)
static var _tint_mats := {}         ## [material, tint] -> tinted copy
## The Romero albedo is dark (mean ~0.3 sRGB on the skin, 0.2 on the clothes); lit like the
## playground it reads black. Every zombie's material is lifted by this much, then tinted.
const BRIGHTEN := 1.8


static func is_zombie(np: NetPlayer) -> bool:
	return np != null and np.display_name.begins_with(PREFIX)


static func name_for(arch_id: StringName, index: int) -> String:
	return "%s%s:%02d" % [PREFIX, arch_id, index]


static func archetype_of(np: NetPlayer) -> ZombieArchetype:
	var parts := np.display_name.split(":")
	return ZombieArchetype.get_arch(StringName(parts[1]) if parts.size() > 1 else &"walker")


## The character, not in the tree yet. `visuals` false: simulation only (headless servers, tests).
static func make(np: NetPlayer, visuals := true) -> UltraCharacter:
	var arch := archetype_of(np)
	var c := UltraCharacter.new()
	c.profile = (load(DIR + "zombie_movement.tres") as MovementProfile).duplicate(true)
	c.profile.walk_speed = arch.walk_speed
	c.profile.sprint_speed = maxf(arch.run_speed, arch.walk_speed * 1.5)
	c.damage_profile = _damage(arch)
	# (Crawling is always on ruined legs: the damage profile's crippled-leg slowdown applies, so the
	# profile's crawl speed is what the archetype wants before it.)
	c.profile.crawl_speed = arch.crawl_speed / maxf(c.damage_profile.crippled_leg_speed, 0.1)
	c.body_profile = _body_for(arch)
	c.build_visuals = visuals
	c.auto_respawn_after = 0.0            # (the director decides when a zombie comes back)
	c.kill_height = -60.0
	c.set_meta("zombie", arch.id)
	c.set_meta(&"health_bar", UltraWorldBars.MODE_DAMAGED)
	return c


static func _damage(arch: ZombieArchetype) -> DamageProfile:
	var d := (load(DIR + "zombie_damage.tres") as DamageProfile).duplicate(true) as DamageProfile
	if arch.hp_mult != 1.0:
		var hp := d.region_hp.duplicate()
		for i in hp.size():
			hp[i] *= arch.hp_mult
		d.region_hp = hp
	d.shove_knockdown = arch.shove_knockdown
	return d


## The shared body with this gait's clip as `walk_f`.
static func _body_for(arch: ZombieArchetype) -> BodyProfile:
	if _body.has(arch.gait_role):
		return _body[arch.gait_role]
	var base := load(DIR + "zombie_body_profile.tres") as BodyProfile
	if arch.gait_role == &"walk_f":
		_body[arch.gait_role] = base
		return base
	var bp := base.duplicate() as BodyProfile
	bp.anim_set = base.anim_set.duplicate() as AnimationSet
	# (Resource.duplicate shares a Dictionary property with the original: writing into it re-clipped every walker.)
	bp.anim_set.roles = base.anim_set.roles.duplicate()
	bp.anim_set.roles[&"walk_f"] = base.anim_set.roles[arch.gait_role]
	_body[arch.gait_role] = bp
	return bp


## Once the character is in the tree: the maimed spawn state (the lame leg, no legs), tint and scale.
static func dress(c: UltraCharacter, force := false) -> void:
	if c.has_meta(&"dressed") and not force:
		return
	c.set_meta(&"dressed", true)
	# Nobody predicts a zombie: its state needn't be snapped to the wire format every tick, nor its floor re-probed.
	c.quantize_state = false
	c.motor.cache_floor = true
	var arch := ZombieArchetype.get_arch(c.get_meta("zombie", &"walker"))
	var R := UltraLimbs.Region
	if arch.legs_gone:
		var cut := UltraLimbs.sever_mask(R.THIGH_L) | UltraLimbs.sever_mask(R.THIGH_R)
		c.state.severed |= cut
		for k in UltraLimbs.COUNT:
			if cut & (1 << k):
				c.state.limb_hp[k] = 0
	elif arch.bad_leg != 0:
		c.state.limb_hp[R.SHIN_R if arch.bad_leg > 0 else R.SHIN_L] = 0
		c.state.limb_hp[R.THIGH_R if arch.bad_leg > 0 else R.THIGH_L] = 20
	if c.body_node == null:
		return
	if arch.body_scale != 1.0:
		c.body_node.scale = Vector3.ONE * arch.body_scale
	if true:
		var mi := c.body_mesh()
		if mi and mi.mesh:
			for si in mi.mesh.get_surface_count():
				var m := mi.get_active_material(si) as BaseMaterial3D
				if m:
					mi.set_surface_override_material(si, _tinted(m, arch.tint))


static func _tinted(m: BaseMaterial3D, tint: Color) -> BaseMaterial3D:
	var key := [m, tint]
	if _tint_mats.has(key):
		return _tint_mats[key]
	var t := m.duplicate() as BaseMaterial3D
	t.albedo_color = m.albedo_color * tint * BRIGHTEN
	_tint_mats[key] = t
	return t
