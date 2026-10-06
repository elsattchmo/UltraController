class_name UltraEffects
extends Node3D
## Cosmetic combat effects for one world: muzzle flashes, ejected shells, tracers, impact
## sparks, blood puffs. Driven by character item events (predicted / remote) and the
## server's impact / hit events. Pooled and cheap; no gameplay state.

const MAX_SHELLS := 40

var _shells: Array[RigidBody3D] = []
var _flash_mat: StandardMaterial3D
var _tracer_mat: StandardMaterial3D
var _spark_mat: StandardMaterial3D
var _blood_mat: StandardMaterial3D
var _shell_mesh: CylinderMesh
var _shell_mat: StandardMaterial3D
## Characters controlled on this machine: their impacts were already predicted.
var local_ids: Array[int] = []
## Droplets, splats on bodies and the ground, pools (UltraBlood).
var blood_fx: UltraBlood

static var _current: UltraEffects


## The effects node of the running world (null in tools / tests without one).
static func instance() -> UltraEffects:
	return _current if is_instance_valid(_current) else null


## Weapon sounds.
var sfx: UltraSfx


## The sound prefix for a gun (stat "sfx", else its id): pistol_fire, rifle_fire...
static func sound_of(def: ItemDefinition) -> String:
	return String(def.stat("sfx", def.id)) if def else "rifle"


func _ready() -> void:
	_current = self
	sfx = UltraSfx.new()
	sfx.name = "Sfx"
	add_child(sfx)
	_flash_mat = _unshaded(Color(1.0, 0.75, 0.35), 4.0)
	_tracer_mat = _unshaded(Color(1.0, 0.85, 0.5), 2.0)
	_spark_mat = _unshaded(Color(1.0, 0.7, 0.3), 3.0)
	_blood_mat = _unshaded(Color(0.45, 0.02, 0.02), 0.0)
	_shell_mesh = CylinderMesh.new()
	_shell_mesh.top_radius = 0.0045
	_shell_mesh.bottom_radius = 0.0045
	_shell_mesh.height = 0.019
	_shell_mat = StandardMaterial3D.new()
	_shell_mat.albedo_color = Color(0.85, 0.65, 0.25)
	_shell_mat.metallic = 0.9
	_shell_mat.roughness = 0.3
	UltraNet.world.on_event(&"impact", _on_impact)
	UltraNet.world.on_event(&"hit", _on_hit)
	blood_fx = UltraBlood.new()
	blood_fx.name = "Blood"
	add_child(blood_fx)


func _exit_tree() -> void:
	UltraNet.world.off_event(&"impact", _on_impact)
	UltraNet.world.off_event(&"hit", _on_hit)


static func _unshaded(c: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	m.emission_enabled = energy > 0.0
	m.emission = c
	m.emission_energy_multiplier = energy
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m


## Hook a character's item events (call for every character with visuals).
func watch(c: UltraCharacter) -> void:
	c.item_event.connect(func(kind: StringName, data: Dictionary) -> void: _on_item(c, kind, data))


func _on_item(c: UltraCharacter, kind: StringName, data: Dictionary) -> void:
	if kind == &"melee_hit":
		_melee_fx(c, data)
		return
	if kind != &"fire":
		return
	var eq := c.get_node_or_null("Equipment") as UltraEquipmentVisual
	var muzzle := eq.muzzle_transform() if eq else c.visual_root.global_transform
	flash(muzzle)
	var def := c.held_def()
	smoke(muzzle, float(def.stat("smoke", 0.6)) if def else 0.6)
	sfx.shot(muzzle.origin, sound_of(def), c.get_instance_id())
	if eq and not eq.pumps():          # (a pump-action throws its shell when it's racked)
		shell(eq.eject_transform(), eq.eject_side(), String(def.stat("shell", "9mm")) if def else "9mm")
	var own := c.net_id in local_ids
	# Rounds that fly (speed, drop, drag): this machine's picture of them - a tracer down the
	# arc, the whiz as one goes past, the shooter's own impacts when they arrive.
	if UltraBallistics.flies(def):
		var dirs: Array = data.dirs if data.has("dirs") else ([data.dir] if data.has("origin") else [-muzzle.basis.z])
		var from: Vector3 = data.origin if data.has("origin") else muzzle.origin
		var axis := Vector3.ZERO
		for d: Vector3 in dirs:
			axis += d
		axis = axis.normalized()
		for d: Vector3 in dirs:
			_fly(c, muzzle.origin, from, d, axis if dirs.size() > 1 else Vector3.ZERO, def, own)
		return
	if data.has("dirs"):
		sfx.whiz(data.origin, (data.dirs as Array)[0], 70.0, own)
	elif data.has("origin"):
		sfx.whiz(data.origin, data.dir, 120.0, own)
	else:
		sfx.whiz(muzzle.origin, -muzzle.basis.z, 120.0, own)
	# Buckshot: a tracer and a predicted impact per pellet.
	if data.has("dirs"):
		for d: Vector3 in data.dirs:
			_shot_fx(c, muzzle, data.origin, d, 70.0)
		return
	# Tracer + predicted impact for shots this machine simulated (data carries the ray).
	if data.has("origin"):
		var space := get_world_3d().direct_space_state
		var to: Vector3 = data.origin + (data.dir as Vector3) * 120.0
		var ex: Array[RID] = [c.get_rid()]
		if c.hit_volume:
			ex.append(c.hit_volume.get_rid())
		var q := PhysicsRayQueryParameters3D.create(data.origin, to, UltraCombat.MASK, ex)
		var hit := UltraCombat._cast(space, q, data.origin, data.dir)   # same limb test as the server
		var end: Vector3 = hit.position if not hit.is_empty() else to
		tracer(muzzle.origin, end)
		if not hit.is_empty():
			var who := UltraCharacter.of_collider(hit.collider)
			sfx.impact(hit.position, who != null)
			if who:
				if who.damage_profile.blood_on():
					blood(hit.position, hit.normal, who, data.dir, 30.0)
			else:
				sparks(hit.position, hit.normal)
	else:
		tracer(muzzle.origin, muzzle.origin + (-muzzle.basis.z) * 40.0)


## A melee blow landing (as this machine saw it): a club leaves a little blood, a blade a lot;
## a wall or a prop takes sparks / a knock.
func _melee_fx(c: UltraCharacter, data: Dictionary) -> void:
	if not data.get("hit", false):
		return
	var who := UltraNet.world.character(int(data.get("character", 0))) if int(data.get("character", 0)) != 0 else null
	var def := c.held_def()
	var sw := UltraActionLayer.melee_swing(def, c.state.melee_combo & 0x3F) if def else {}
	var blade := StringName(sw.get("kind", &"blunt")) == &"blade"
	if who:
		if who.damage_profile.blood_on() and blood_fx:
			blood_fx.wound(who, data.point, data.dir, 30.0 if blade else 8.0)
	else:
		sparks(data.point, data.normal)


func _shot_fx(c: UltraCharacter, muzzle: Transform3D, origin: Vector3, dir: Vector3, reach: float) -> void:
	var space := get_world_3d().direct_space_state
	var to := origin + dir * reach
	var ex: Array[RID] = [c.get_rid()]
	if c.hit_volume:
		ex.append(c.hit_volume.get_rid())
	var q := PhysicsRayQueryParameters3D.create(origin, to, UltraCombat.MASK, ex)
	var hit := UltraCombat._cast(space, q, origin, dir)
	tracer(muzzle.origin, hit.position if not hit.is_empty() else to)
	if not hit.is_empty():
		var who := UltraCharacter.of_collider(hit.collider)
		if randf() < 0.4:
			sfx.impact(hit.position, who != null)            # (a few of the pellets)
		if who:
			if who.damage_profile.blood_on():
				blood(hit.position, hit.normal, who, dir, 14.0)
		else:
			sparks(hit.position, hit.normal)


func _on_impact(pos: Vector3, normal: Vector3, kind: StringName, shooter_id: int) -> void:
	if shooter_id in local_ids:
		return
	sfx.impact(pos, kind == &"flesh")
	if kind == &"flesh":
		blood(pos, normal)
	else:
		sparks(pos, normal)


func _on_hit(target_id: int, pos: Vector3, dir: Vector3, amount: float, attacker_id: int, region := -1, kind := &"bullet") -> void:
	var c := UltraNet.world.character(target_id)
	if c:
		c.react_to_hit(region, dir, amount, kind)
	if kind == &"blocked":
		sparks(pos, -dir)                 # (weapon on weapon)
		return
	if attacker_id in local_ids or kind == &"impact" or kind == &"drown" or kind == &"bleed":
		return
	if c == null or c.damage_profile.blood_on():
		blood(pos, -dir, c, dir, amount)


# ---------------------------------------------------------------- rounds in flight (presentation)

var _rounds: Array[Dictionary] = []
const MAX_ROUNDS := 80


## A round as this machine sees it: it leaves the muzzle and closes onto the true path from
## `origin` along `dir` (the eye's ray the server flies) within ~12 m, then flies like the
## server's (UltraBallistics): gravity, drag, bloom for buckshot (`axis` = the load's middle).
func _fly(c: UltraCharacter, muzzle: Vector3, origin: Vector3, dir: Vector3, axis: Vector3, def: ItemDefinition, own: bool) -> void:
	if _rounds.size() >= MAX_ROUNDS:
		var old: Dictionary = _rounds.pop_front()
		if is_instance_valid(old.streak):
			(old.streak as Node).queue_free()
	var speed := float(def.stat("muzzle_velocity", 800.0))
	var aim := (origin + dir * 12.0 - muzzle).normalized()
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.008, 0.008, 2.5)
	mi.mesh = bm
	mi.material_override = _tracer_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visible = false
	add_child(mi)
	var ex: Array[RID] = [c.get_rid()]
	if c.hit_volume:
		ex.append(c.hit_volume.get_rid())
	_rounds.append({"pos": muzzle, "vel": aim * speed, "true_dir": dir, "def": def, "dist": 0.0, "t": 0.0,
		"axis": axis, "bloomed": false, "own": own, "ex": ex, "streak": mi, "whizzed": false, "pellet": axis != Vector3.ZERO})


func _process(delta: float) -> void:
	if _rounds.is_empty():
		return
	var space := get_world_3d().direct_space_state if get_world_3d() else null
	var lp := sfx.listener() if sfx else Vector3.INF
	var keep: Array[Dictionary] = []
	for r in _rounds:
		if _fly_step(r, delta, space, lp):
			keep.append(r)
		elif is_instance_valid(r.streak):
			(r.streak as Node).queue_free()
	_rounds = keep


func _fly_step(r: Dictionary, dt: float, space: PhysicsDirectSpaceState3D, lp: Vector3) -> bool:
	var def: ItemDefinition = r.def
	var v0: Vector3 = r.vel
	# Off the muzzle the round turns onto the eye's line (the first ~12 m), then flies free.
	if float(r.dist) < 12.0:
		var want: Vector3 = (r.true_dir as Vector3) * v0.length()
		v0 = v0.lerp(want, clampf(dt * 25.0, 0.0, 1.0))
	var v1 := (v0 + Vector3.DOWN * UltraBallistics.GRAVITY * dt) * exp(-float(def.stat("drag", 0.0)) * dt)
	var step := (v0 + v1) * 0.5 * dt
	var from: Vector3 = r.pos
	var to := from + step
	var seg := step.length()
	if seg < 1e-5 or space == null:
		return false
	var dir := step / seg
	# The whiz: the stretch of flight that goes past the listener (not the shooter's own).
	if not r.own and not r.whizzed and lp != Vector3.INF:
		var tt := (lp - from).dot(dir)
		if tt > 0.0 and tt <= seg and float(r.dist) + tt > 3.0:
			var closest := from + dir * tt
			r.whizzed = true
			if not r.pellet or randf() < 0.35:
				sfx.whiz_at(closest, closest.distance_to(lp))
	var q := PhysicsRayQueryParameters3D.create(from, to, UltraCombat.MASK, r.ex)
	var hit := UltraCombat._cast(space, q, from, dir)
	var streak := r.streak as MeshInstance3D
	if not hit.is_empty():
		if r.own:
			var who := UltraCharacter.of_collider(hit.collider)
			if not r.pellet or randf() < 0.4:
				sfx.impact(hit.position, who != null)
			if who:
				if who.damage_profile.blood_on():
					blood(hit.position, hit.normal, who, dir, 14.0 if r.pellet else 30.0)
			else:
				sparks(hit.position, hit.normal)
		return false
	r.pos = to
	r.vel = v1
	r.dist = float(r.dist) + seg
	r.t = float(r.t) + dt
	if r.pellet and not r.bloomed and float(r.dist) >= float(def.stat("pellet_bloom_from", 6.0)):
		r.bloomed = true
		var bloom := deg_to_rad(float(def.stat("pellet_bloom_deg", 0.0)))
		var axis: Vector3 = r.axis
		var vd := v1.normalized()
		var off := vd - axis * vd.dot(axis)
		if bloom > 0.0 and off.length() > 1e-4:
			r.vel = (vd + off.normalized() * tan(bloom)).normalized() * v1.length()
			r.true_dir = (r.vel as Vector3).normalized()
	# The streak: its head at the round, along the flight.
	if is_instance_valid(streak):
		var len := minf(2.5, float(r.dist))
		streak.visible = len > 0.4
		var b := Basis.looking_at(dir, Vector3.UP if absf(dir.y) < 0.99 else Vector3.RIGHT)
		streak.global_transform = Transform3D(b, to - dir * len * 0.5)
		streak.scale = Vector3(1, 1, len / 2.5)
	return float(r.dist) < float(def.stat("range", 300.0)) and float(r.t) < UltraBallistics.MAX_LIFE


func flash(at: Transform3D) -> void:
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.75, 0.4)
	light.light_energy = 3.0
	light.omni_range = 4.0
	light.shadow_enabled = false
	add_child(light)
	light.global_position = at.origin
	var quad := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(0.09, 0.09)
	quad.mesh = qm
	quad.material_override = _flash_mat
	quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(quad)
	quad.global_transform = Transform3D(at.basis.rotated(at.basis.z.normalized(), randf() * TAU), at.origin + (-at.basis.z) * 0.03)
	var t := create_tween()
	t.tween_property(light, "light_energy", 0.0, 0.06)
	t.parallel().tween_property(quad, "scale", Vector3.ONE * 1.6, 0.05)
	t.tween_callback(light.queue_free)
	t.tween_callback(quad.queue_free)


## Spent cases by kind: [length, radius, hull colour, head length] (m). "12g" = a red plastic
## shotgun hull with a brass head; the others are brass.
const SHELLS := {
	"9mm": [0.019, 0.0045, Color(0.85, 0.65, 0.25), 0.0],
	"556": [0.045, 0.0048, Color(0.85, 0.65, 0.25), 0.0],
	"12g": [0.068, 0.0105, Color(0.62, 0.07, 0.05), 0.016],
}
var _shell_parts := {}


## A spent case thrown out of the ejection port `at` (its basis is the gun's: -Z the barrel)
## toward `out` (the side the port is on): out, up, a little back, tumbling.
func shell(at: Transform3D, out: Vector3, kind := "9mm") -> void:
	if not SHELLS.has(kind):
		kind = "9mm"
	var spec: Array = SHELLS[kind]
	var rb: RigidBody3D
	for k in range(_shells.size() - 1, -1, -1):
		if not is_instance_valid(_shells[k]):
			_shells.remove_at(k)
	if _shells.size() >= MAX_SHELLS:
		rb = _shells.pop_front()
		rb.queue_free()
	rb = RigidBody3D.new()
	rb.collision_layer = 0
	rb.collision_mask = UltraLayers.WORLD_STATIC
	rb.mass = 0.012 if kind != "12g" else 0.03
	var len: float = spec[0]
	var rad: float = spec[1]
	if not _shell_parts.has(kind):
		var hull := CylinderMesh.new()
		hull.top_radius = rad
		hull.bottom_radius = rad
		hull.height = len
		hull.radial_segments = 10
		var hm := StandardMaterial3D.new()
		hm.albedo_color = spec[2]
		hm.metallic = 0.9 if spec[3] == 0.0 else 0.0
		hm.roughness = 0.3 if spec[3] == 0.0 else 0.55
		var parts := [hull, hm]
		if spec[3] > 0.0:
			var head := CylinderMesh.new()
			head.top_radius = rad * 1.04
			head.bottom_radius = rad * 1.08
			head.height = spec[3]
			head.radial_segments = 10
			parts.append(head)
		_shell_parts[kind] = parts
	var parts: Array = _shell_parts[kind]
	var mi := MeshInstance3D.new()
	mi.mesh = parts[0]
	mi.material_override = parts[1]
	rb.add_child(mi)
	if parts.size() > 2:
		var hd := MeshInstance3D.new()
		hd.mesh = parts[2]
		hd.material_override = _shell_mat
		hd.position = Vector3(0, len * 0.5 - float(spec[3]) * 0.5 + 0.001, 0)      # (+Y: the back)
		rb.add_child(hd)
	var cs := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = rad
	cyl.height = len
	cs.shape = cyl
	rb.add_child(cs)
	add_child(rb)
	_shells.append(rb)
	var gb := at.basis.orthonormalized()
	var gun_right := out.normalized() if out.length() > 0.01 else gb.x
	var gun_up := gb.y
	var gun_back := gb.z
	# Lying in the port along the bore (the case's axis = the cylinder's Y), head to the back.
	var axis_x := gun_back.cross(gun_right.cross(gun_back)).normalized()      # (perpendicular to the bore)
	rb.global_transform = Transform3D(Basis(axis_x, gun_back, axis_x.cross(gun_back)), at.origin + gun_right * rad)
	var big := kind == "12g"
	rb.linear_velocity = gun_right * randf_range(2.0, 2.8) * (1.15 if big else 1.0) + gun_up * randf_range(1.6, 2.4) + gun_back * randf_range(0.2, 0.6)
	rb.angular_velocity = gun_up * randf_range(-14, -8) + gun_right * randf_range(-6, 6)
	get_tree().create_timer(12.0).timeout.connect(rb.queue_free)
	sfx.shell_drop(at.origin, randf_range(0.4, 0.6))


## A spent magazine dropped out of a gun: a copy of the gun's Magazine mesh on a small rigid
## body (falls, bounces, lies there for MAG_LIFE s; oldest go first past MAX_MAGS).
const MAX_MAGS := 16
const MAG_LIFE := 30.0
var _mags: Array[RigidBody3D] = []


func drop_mag(src: MeshInstance3D, at: Transform3D, vel: Vector3) -> void:
	if src == null or src.mesh == null:
		return
	for k in range(_mags.size() - 1, -1, -1):
		if not is_instance_valid(_mags[k]):
			_mags.remove_at(k)
	if _mags.size() >= MAX_MAGS:
		_mags.pop_front().queue_free()
	var rb := RigidBody3D.new()
	rb.collision_layer = 0
	rb.collision_mask = UltraLayers.WORLD_STATIC
	rb.mass = 0.25
	var mi := MeshInstance3D.new()
	mi.mesh = src.mesh
	mi.material_override = src.material_override
	for i in src.get_surface_override_material_count():
		mi.set_surface_override_material(i, src.get_surface_override_material(i))
	rb.add_child(mi)
	var ab := src.get_aabb()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = ab.size.max(Vector3.ONE * 0.01)
	cs.shape = box
	cs.position = ab.get_center()
	rb.add_child(cs)
	add_child(rb)
	_mags.append(rb)
	rb.global_transform = at.orthonormalized()
	rb.linear_velocity = vel
	rb.angular_velocity = Vector3(randf_range(-4, 4), randf_range(-2, 2), randf_range(-4, 4))
	get_tree().create_timer(MAG_LIFE).timeout.connect(rb.queue_free)


# ---------------------------------------------------------------- smoke

var _smoke_mat: StandardMaterial3D


## Billboard smoke material (soft round sprite, coloured and faded by the particles).
## (GPU particles: CPUParticles3D drew its newest particle as an opaque black quad with a
## colour ramp - a black disc at every muzzle.)
func _smoke_material() -> StandardMaterial3D:
	if _smoke_mat == null:
		var g := Gradient.new()
		g.offsets = PackedFloat32Array([0.0, 1.0])
		g.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
		var gt := GradientTexture2D.new()
		gt.gradient = g
		gt.fill = GradientTexture2D.FILL_RADIAL
		gt.fill_from = Vector2(0.5, 0.5)
		gt.fill_to = Vector2(0.5, 0.0)
		gt.width = 64
		gt.height = 64
		_smoke_mat = StandardMaterial3D.new()
		_smoke_mat.albedo_texture = gt
		_smoke_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_smoke_mat.vertex_color_use_as_albedo = true
		_smoke_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		_smoke_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_smoke_mat.proximity_fade_enabled = true
		_smoke_mat.proximity_fade_distance = 0.4
	return _smoke_mat


## Smoke particles: rising, slowing, spreading, fading. `peak_alpha` at the start of life.
func smoke_particles(amount: int, life: float, peak_alpha: float, size: float, grow: float) -> GPUParticles3D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.07, 1.0])
	g.colors = PackedColorArray([Color(0.8, 0.8, 0.78, 0.0), Color(0.8, 0.8, 0.78, peak_alpha), Color(0.74, 0.74, 0.74, 0.0)])
	var gt := GradientTexture1D.new()
	gt.gradient = g
	var sc := Curve.new()
	sc.add_point(Vector2(0, 1.0 / grow))
	sc.add_point(Vector2(1, 1.0))
	var sct := CurveTexture.new()
	sct.curve = sc
	var pm := ParticleProcessMaterial.new()
	pm.color_ramp = gt
	pm.scale_curve = sct
	pm.scale_min = 0.7
	pm.scale_max = 1.2
	pm.gravity = Vector3(0, 0.35, 0)
	pm.angle_min = -180.0
	pm.angle_max = 180.0
	var p := GPUParticles3D.new()
	p.amount = maxi(amount, 1)
	p.lifetime = life
	p.local_coords = false
	p.process_material = pm
	var qm := QuadMesh.new()
	qm.size = Vector2(size * grow, size * grow)
	qm.material = _smoke_material()
	p.draw_pass_1 = qm
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.visibility_aabb = AABB(Vector3(-3, -3, -3), Vector3(6, 6, 6))
	return p


## A puff of gun smoke at the muzzle `at`, blown out along the barrel then rising and
## spreading; `strength` 0.1 (pistol, a wisp) .. 1.26 (shotgun). It scales how much smoke there
## is and how thick it is.
func smoke(at: Transform3D, strength := 1.0) -> void:
	if strength <= 0.0:
		return
	var life := 1.2 + 0.8 * minf(strength, 1.5)
	var thick := 0.26 * clampf(strength, 0.25, 1.0)
	var p := smoke_particles(int(clampf(10 * strength, 2, 30)), life, thick, 0.18 * (0.7 + 0.3 * strength), 3.0)
	p.one_shot = true
	p.explosiveness = 0.85
	var pm := p.process_material as ParticleProcessMaterial
	pm.direction = Vector3(0, 0, -1)
	pm.spread = 18.0
	pm.initial_velocity_min = 0.8 * strength
	pm.initial_velocity_max = 3.0 * strength
	pm.damping_min = 3.0
	pm.damping_max = 5.0
	add_child(p)
	p.global_transform = Transform3D(at.basis.orthonormalized(), at.origin)
	p.emitting = true
	get_tree().create_timer(life + 0.3).timeout.connect(p.queue_free)


func tracer(from: Vector3, to: Vector3) -> void:
	var len := from.distance_to(to)
	if len < 0.5:
		return
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.008, 0.008, minf(len, 3.0))
	mi.mesh = bm
	mi.material_override = _tracer_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	var dir := (to - from) / len
	var basis := Basis.looking_at(dir, Vector3.UP if absf(dir.y) < 0.99 else Vector3.RIGHT)
	mi.global_transform = Transform3D(basis, from + dir * minf(len, 3.0) * 0.5)
	var t := create_tween()
	t.tween_property(mi, "global_position", to - dir * minf(len, 3.0) * 0.5, clampf(len / 300.0, 0.02, 0.4))
	t.tween_callback(mi.queue_free)


func sparks(at: Vector3, normal: Vector3) -> void:
	_burst(at, normal, _spark_mat, 10, 3.0, 0.25)


var _splash_mat: StandardMaterial3D
var _ring_mat: StandardMaterial3D


## Something hit the water at `at` (on the surface); strength ~0.2 (a pebble) .. 1.2 (a dive).
func splash(at: Vector3, strength := 1.0) -> void:
	if _splash_mat == null:
		_splash_mat = StandardMaterial3D.new()
		_splash_mat.albedo_color = Color(0.85, 0.94, 1.0, 0.85)
		_splash_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_splash_mat.roughness = 0.1
		_ring_mat = StandardMaterial3D.new()
		_ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_ring_mat.albedo_color = Color(0.92, 0.97, 1.0, 0.7)
		_ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Droplets thrown up and out.
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.emitting = false
	p.amount = int(lerpf(16, 70, clampf(strength, 0.0, 1.0)))
	p.lifetime = 0.9
	p.explosiveness = 0.92
	p.direction = Vector3.UP
	p.spread = 32.0
	p.initial_velocity_min = 1.5 * strength + 0.5
	p.initial_velocity_max = 4.5 * strength + 1.0
	p.gravity = Vector3(0, -9.8, 0)
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_RING
	p.emission_ring_axis = Vector3.UP
	p.emission_ring_radius = 0.25 + 0.2 * strength
	p.emission_ring_inner_radius = 0.05
	p.emission_ring_height = 0.0
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.6
	var m := SphereMesh.new()
	m.radius = 0.025
	m.height = 0.05
	m.radial_segments = 6
	m.rings = 3
	p.mesh = m
	p.material_override = _splash_mat
	add_child(p)
	p.global_position = at + Vector3.UP * 0.02
	p.emitting = true
	get_tree().create_timer(1.3).timeout.connect(p.queue_free)
	# A column of spray for big entries.
	if strength > 0.5:
		var col := p.duplicate() as CPUParticles3D
		col.amount = 30
		col.spread = 8.0
		col.emission_ring_radius = 0.12
		col.initial_velocity_min = 3.0 * strength
		col.initial_velocity_max = 5.5 * strength
		add_child(col)
		col.global_position = at
		col.emitting = true
		get_tree().create_timer(1.5).timeout.connect(col.queue_free)
	# A ring spreading out on the surface.
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.42
	tm.outer_radius = 0.5
	tm.rings = 24
	tm.ring_segments = 4
	ring.mesh = tm
	ring.material_override = _ring_mat.duplicate()
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ring)
	ring.global_position = at + Vector3.UP * 0.01
	ring.scale = Vector3(0.5, 0.05, 0.5)
	var grow := 1.5 + 2.5 * strength
	var tw := create_tween()
	tw.tween_property(ring, "scale", Vector3(grow, 0.05, grow), 1.2).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tw.parallel().tween_property(ring.material_override, "albedo_color:a", 0.0, 1.2)
	tw.tween_callback(ring.queue_free)


## Blood where a shot struck (`dir`: the shot, if known - spatter flies out behind; `who`: the
## body, which gets splashed round the wound).
## Splinters and dust (something wooden smashing), `size` m across.
func dust(at: Vector3, size := 0.6) -> void:
	if _dust_mat == null:
		_dust_mat = StandardMaterial3D.new()
		_dust_mat.albedo_color = Color(0.55, 0.42, 0.28)
		_dust_mat.roughness = 1.0
	_burst(at, Vector3.UP, _dust_mat, int(clampf(size * 30.0, 10, 40)), 3.0, 0.8)


var _dust_mat: StandardMaterial3D


func blood(at: Vector3, normal: Vector3, who: UltraCharacter = null, dir := Vector3.ZERO, amount := 20.0) -> void:
	if blood_fx == null:
		_burst(at, normal, _blood_mat, 14, 1.8, 0.45)
		return
	if dir != Vector3.ZERO:
		blood_fx.wound(who, at, dir.normalized(), amount)
	else:
		blood_fx.spray(at, normal, 12, 2.0, 45.0, 0.006, who)


func _burst(at: Vector3, normal: Vector3, mat: Material, n: int, speed: float, life: float) -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.emitting = false
	p.amount = n
	p.lifetime = life
	p.explosiveness = 1.0
	p.direction = normal
	p.spread = 55.0
	p.initial_velocity_min = speed * 0.5
	p.initial_velocity_max = speed
	p.gravity = Vector3(0, -9.8, 0)
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.2
	var m := SphereMesh.new()
	m.radius = 0.012
	m.height = 0.024
	m.radial_segments = 4
	m.rings = 2
	p.mesh = m
	p.material_override = mat
	add_child(p)
	p.global_position = at + normal * 0.01
	p.emitting = true
	get_tree().create_timer(life + 0.2).timeout.connect(p.queue_free)
