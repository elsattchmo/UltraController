class_name UltraBlood
extends Node3D
## Blood as a fluid, cheaply: droplets are thrown (sprays from wounds, spurts from stumps,
## exit spatter), fly ballistically with a little drag, and where one lands it leaves a wet
## splat - on the ground and walls (world decals that merge and grow into pools) or on a
## character (decals riding the bone they landed on, so the blood stays on the body). Lying
## bleeders grow pools under them. Presentation only; no gameplay state.

const MAX_DROPS := 900
const MAX_WORLD_SPLATS := 420
const MAX_BODY_SPLATS := 28                ## per character
const GRAVITY := 9.8
const DRAG := 0.6                           ## 1/s air drag on a droplet
const MASK := UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC | UltraLayers.CHARACTER

var _pos := PackedVector3Array()
var _vel := PackedVector3Array()
var _size := PackedFloat32Array()           ## droplet radius (m)
var _age := PackedFloat32Array()
var _skip: Array = []                       ## per droplet: RID it can't splat on yet (its source body)
var _mm: MultiMeshInstance3D
var _splats: Array[Decal] = []              ## world splats, oldest first
var _splat_size := PackedFloat32Array()
var _tex: Array[Texture2D] = []
var _orm: Texture2D
var _drop_mat: StandardMaterial3D


func _ready() -> void:
	_drop_mat = StandardMaterial3D.new()
	_drop_mat.albedo_color = Color(0.32, 0.01, 0.015)
	_drop_mat.roughness = 0.12
	_drop_mat.metallic_specular = 0.7
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 6
	sm.rings = 3
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = sm
	mm.instance_count = MAX_DROPS
	mm.visible_instance_count = 0
	_mm = MultiMeshInstance3D.new()
	_mm.multimesh = mm
	_mm.material_override = _drop_mat
	_mm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mm.top_level = true
	_mm.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF     # (moved every frame)
	add_child(_mm)
	for k in 4:
		_tex.append(_splat_texture(k))
	_orm = _wet_orm()


# ---------------------------------------------------------------- emitting

## Throw `n` droplets from `at` in a cone (`cone_deg`) around `dir` at about `speed` m/s.
## `source`: a body the droplets leave from (they won't splat back on its capsule at once).
func spray(at: Vector3, dir: Vector3, n: int, speed: float, cone_deg := 35.0, size := 0.006, source: Object = null) -> void:
	dir = dir.normalized() if dir.length() > 0.001 else Vector3.UP
	var side := dir.cross(Vector3.UP)
	if side.length() < 0.1:
		side = dir.cross(Vector3.RIGHT)
	side = side.normalized()
	var up := side.cross(dir).normalized()
	var rid: Variant = (source as CollisionObject3D).get_rid() if source is CollisionObject3D else null
	for i in n:
		if _pos.size() >= MAX_DROPS:
			_kill(0)
		var a := randf() * TAU
		var r := tan(deg_to_rad(cone_deg) * sqrt(randf()))
		var d := (dir + (side * cos(a) + up * sin(a)) * r).normalized()
		_pos.append(at)
		_vel.append(d * speed * randf_range(0.45, 1.15))
		_size.append(size * randf_range(0.5, 1.6))
		_age.append(0.0)
		_skip.append(rid)


## A shot through a body: a spray back out of the entry, more out of the exit behind, and
## splats on the body round the wound.
func wound(c: UltraCharacter, at: Vector3, shot_dir: Vector3, amount: float) -> void:
	var k := clampf(amount / 30.0, 0.3, 3.0)
	spray(at, -shot_dir + Vector3.UP * 0.3, int(10 * k), 2.0, 40.0, 0.007, c)
	spray(at + shot_dir * 0.15, shot_dir + Vector3.UP * 0.15, int(30 * k), 4.5 + k, 22.0, 0.008, c)
	if c:
		# Down the body from the wound.
		for i in int(3 + k * 2):
			splat_body(c, at + Vector3(randf_range(-0.08, 0.08), randf_range(-0.25, 0.06), randf_range(-0.08, 0.08)), 0.09 + 0.05 * k)


# ---------------------------------------------------------------- simulation

func _process(delta: float) -> void:
	var n := _pos.size()
	if n == 0:
		_mm.multimesh.visible_instance_count = 0
		return
	var space := get_world_3d().direct_space_state
	var dt := minf(delta, 1.0 / 30.0)
	var i := 0
	var q := PhysicsRayQueryParameters3D.new()
	q.collision_mask = MASK
	q.hit_back_faces = false
	while i < _pos.size():
		var p := _pos[i]
		var v := _vel[i]
		v.y -= GRAVITY * dt
		v *= 1.0 - DRAG * dt
		var np := p + v * dt
		_age[i] += dt
		q.from = p
		q.to = np
		var ex: Array[RID] = []
		if _skip[i] != null and _age[i] < 0.12:
			ex.append(_skip[i])
		q.exclude = ex
		var hit := space.intersect_ray(q)
		if not hit.is_empty():
			_land(hit, _size[i], v)
			_kill(i)
			continue
		if _age[i] > 3.0:
			_kill(i)
			continue
		_pos[i] = np
		_vel[i] = v
		i += 1
	# Draw: little spheres stretched along their velocity.
	var mm := _mm.multimesh
	var count := mini(_pos.size(), MAX_DROPS)
	mm.visible_instance_count = count
	for j in count:
		var v := _vel[j]
		var r := _size[j]
		var sp := v.length()
		var b := Basis.from_scale(Vector3(r, r, r))
		if sp > 0.5:
			var y := v / sp
			var x := y.cross(Vector3.UP if absf(y.y) < 0.95 else Vector3.RIGHT).normalized()
			var z := x.cross(y)
			b = Basis(x * r, y * r * (1.0 + minf(sp * 0.35, 3.0)), z * r)
		mm.set_instance_transform(j, Transform3D(b, _pos[j]))


func _kill(i: int) -> void:
	var last := _pos.size() - 1
	_pos[i] = _pos[last]
	_vel[i] = _vel[last]
	_size[i] = _size[last]
	_age[i] = _age[last]
	_skip[i] = _skip[last]
	_pos.resize(last)
	_vel.resize(last)
	_size.resize(last)
	_age.resize(last)
	_skip.resize(last)


func _land(hit: Dictionary, r: float, v: Vector3) -> void:
	var who := UltraCharacter.of_collider(hit.collider)
	# Splat size from the drop and how hard it hit (a fast drop smears wider).
	var s := clampf(r * 13.0 * (1.0 + v.length() * 0.08), 0.05, 0.22)
	if who:
		splat_body(who, hit.position, s)
	else:
		splat_world(hit.position, hit.normal, s)


# ---------------------------------------------------------------- splats

## A wet splat on the world at `at` (surface normal `n`), `s` m across. Lands near an older
## one and they run together into a bigger stain (a pool, where a lot falls on one spot).
func splat_world(at: Vector3, n: Vector3, s: float) -> void:
	for k in range(_splats.size() - 1, maxi(_splats.size() - 60, 0) - 1, -1):
		var d := _splats[k]
		if not is_instance_valid(d):
			continue
		var cur := _splat_size[k]
		if d.global_position.distance_to(at) < cur * 0.35 and (d.global_basis.y.normalized()).dot(n) > 0.8:
			# Area adds: the stain grows (to a pool, at most ~1.6 m).
			var ns := minf(sqrt(cur * cur + s * s * 0.6), 1.6)
			_splat_size[k] = ns
			d.size = Vector3(ns, d.size.y, ns)
			return
	var dec := _make_decal(s)
	add_child(dec)
	dec.global_transform = Transform3D(_basis_up(n), at)
	_splats.append(dec)
	_splat_size.append(s)
	while _splats.size() > MAX_WORLD_SPLATS:
		var old: Decal = _splats.pop_front()
		_splat_size.remove_at(0)
		if is_instance_valid(old):
			old.queue_free()


## A pool spreading on the ground under `at` (a lying bleeder): grows the splat there.
func pool(at: Vector3, grow: float) -> void:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 0.3, at + Vector3.DOWN * 1.5, UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC)
	var hit := space.intersect_ray(q)
	if hit.is_empty() or (hit.normal as Vector3).y < 0.6:
		return
	splat_world(hit.position, hit.normal, grow)


## Blood on a character's body at `at` (world): a decal on the nearest bone of its body.
func splat_body(c: UltraCharacter, at: Vector3, s: float) -> void:
	if c == null or c.skeleton == null:
		return
	var sk := c.skeleton
	var best := -1
	var best_d := INF
	for r in UltraLimbs.BONES:
		if (c.state.severed >> int(r)) & 1:
			continue
		for bn: String in UltraLimbs.BONES[r]:
			var b := sk.find_bone(bn)
			if b < 0:
				continue
			var d := (sk.global_transform * sk.get_bone_global_pose(b).origin).distance_to(at)
			if d < best_d:
				best_d = d
				best = b
	if best < 0 or best_d > 0.6:
		return
	var atts: Dictionary = c.get_meta(&"blood_att", {})
	var att: BoneAttachment3D = atts.get(best)
	if att == null or not is_instance_valid(att):
		att = BoneAttachment3D.new()
		att.bone_idx = best
		sk.add_child(att)
		atts[best] = att
		c.set_meta(&"blood_att", atts)
	var bone_pos := att.global_position
	var out := at - bone_pos
	out = out.normalized() if out.length() > 0.01 else Vector3.UP
	var dec := _make_decal(s)
	dec.size.y = 0.3                         # deep enough to reach the skin from the capsule
	dec.cull_mask = 0xFFFFF
	att.add_child(dec)
	dec.global_transform = Transform3D(_basis_up(out), bone_pos + out * 0.06)
	var list: Array = c.get_meta(&"blood_splats", [])
	list.append(dec)
	while list.size() > MAX_BODY_SPLATS:
		var old: Node = list.pop_front()
		if is_instance_valid(old):
			old.queue_free()
	c.set_meta(&"blood_splats", list)


func _make_decal(s: float) -> Decal:
	var dec := Decal.new()
	dec.size = Vector3(s, 0.1, s)
	dec.texture_albedo = _tex[randi() % _tex.size()]
	dec.texture_orm = _orm
	dec.modulate = Color(0.55, 0.03, 0.03).lerp(Color(0.32, 0.01, 0.01), randf())
	dec.albedo_mix = 1.0
	dec.normal_fade = 0.35
	dec.upper_fade = 0.15
	dec.lower_fade = 0.25
	dec.distance_fade_enabled = true
	dec.distance_fade_begin = 35.0
	dec.distance_fade_length = 10.0
	return dec


static func _basis_up(n: Vector3) -> Basis:
	n = n.normalized()
	var x := n.cross(Vector3.FORWARD if absf(n.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT).normalized()
	var b := Basis(x, n, x.cross(n))
	return b.rotated(n, randf() * TAU)


## A splat: a blob with a ragged rim and a few satellite droplets (alpha = coverage).
static func _splat_texture(seed: int) -> Texture2D:
	var size := 96
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var noise := FastNoiseLite.new()
	noise.seed = 1234 + seed * 97
	noise.frequency = 0.035
	var rng := RandomNumberGenerator.new()
	rng.seed = 77 + seed
	var c := Vector2(48, 48)
	var blobs := [[c, 25.0 + rng.randf() * 6.0]]
	for i in 7 + seed * 2:
		var a := rng.randf() * TAU
		var d := rng.randf_range(27.0, 43.0)
		blobs.append([c + Vector2(cos(a), sin(a)) * d, rng.randf_range(1.5, 5.0)])
	for y in size:
		for x in size:
			var p := Vector2(x, y)
			var cov := 0.0
			for b: Array in blobs:
				var rr: float = b[1] * (1.0 + noise.get_noise_2d(x, y) * 0.45)
				cov = maxf(cov, clampf((rr - p.distance_to(b[0])) / 3.0, 0.0, 1.0))
			# Darker, thicker middle.
			var shade := 1.0 - 0.35 * clampf(1.0 - p.distance_to(c) / 30.0, 0.0, 1.0)
			img.set_pixel(x, y, Color(shade, shade, shade, cov))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


## Wet: low roughness everywhere the splat covers.
static func _wet_orm() -> Texture2D:
	var img := Image.create(4, 4, false, Image.FORMAT_RGB8)
	img.fill(Color(1.0, 0.08, 0.0))
	return ImageTexture.create_from_image(img)
