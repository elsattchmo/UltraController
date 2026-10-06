class_name UltraWorldBars
extends Node3D
## Health bars over characters' heads: ONE MultiMeshInstance3D for all of them, billboarded in the
## shader (see world_bar.gdshader), so any number cost a single draw call and every camera sees
## them face-on. Reads the replicated MotorState (`hp`), so it shows the same on every machine.
##
## A character gets a bar by carrying the meta `health_bar`: MODE_DAMAGED (bar shows for a few
## seconds after it was hurt, fading) or MODE_ALWAYS. Dead characters' bars fade out.

const MODE_DAMAGED := 1
const MODE_ALWAYS := 2
const CAPACITY := 96
const SHOW_TIME := 4.5                 ## s a bar stays up after the last hp change
const FADE_TIME := 1.0
const SIZE := Vector2(0.62, 0.075)     ## m, at 8 m and nearer (grows with distance beyond that)
const HEIGHT_ABOVE := 0.32             ## m over the top of the capsule

static var _instance: UltraWorldBars

var _mm: MultiMesh
var _mmi: MultiMeshInstance3D
var _buf := PackedFloat32Array()
var _seen := {}                        ## character instance id -> [last hp, time of the last change]
var _now := 0.0
var enabled := true


static func instance() -> UltraWorldBars:
	return _instance


func _ready() -> void:
	_instance = self
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_custom_data = true
	var q := QuadMesh.new()
	q.size = Vector2.ONE
	_mm.mesh = q
	_mm.instance_count = CAPACITY
	_mm.visible_instance_count = 0
	# (The bounds of an instance buffer written in one go aren't worked out: say where they are.)
	_mm.custom_aabb = AABB(Vector3(-2000, -2000, -2000), Vector3(4000, 4000, 4000))
	var mat := ShaderMaterial.new()
	mat.shader = load("res://addons/ultra_controller/ui/world_bar.gdshader")
	mat.render_priority = 10
	_mmi = MultiMeshInstance3D.new()
	_mmi.name = "Bars"
	_mmi.multimesh = _mm
	_mmi.material_override = mat
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mmi.extra_cull_margin = 4096.0
	add_child(_mmi)
	_buf.resize(CAPACITY * 16)


func _exit_tree() -> void:
	if _instance == self:
		_instance = null


## Characters showing a bar right now (tests, HUD).
var shown := 0


func _process(delta: float) -> void:
	_now += delta
	var cam := get_viewport().get_camera_3d()
	var cam_pos := cam.global_position if cam else Vector3.ZERO
	var n := 0
	if enabled:
		for node in get_tree().get_nodes_in_group(&"ultra_character"):
			if n >= CAPACITY:
				break
			var c := node as UltraCharacter
			if c == null or not c.has_meta(&"health_bar") or c.visual_root == null:
				continue
			var mode: int = c.get_meta(&"health_bar")
			var id := c.get_instance_id()
			var hp := c.state.hp
			var rec: Array = _seen.get(id, [hp, -1000.0])
			if absf(float(rec[0]) - hp) > 0.01:
				rec = [hp, _now]
			_seen[id] = rec
			var dead := c.state.state == MotorState.Id.DEAD
			var since := _now - float(rec[1])
			var a := 0.0
			if mode == MODE_ALWAYS:
				a = 1.0
			elif since < SHOW_TIME:
				a = 1.0 - smoothstep(SHOW_TIME - FADE_TIME, SHOW_TIME, since)
			if dead:
				a = 1.0 - smoothstep(0.2, FADE_TIME, since)       # (it goes a moment after the kill)
			if a <= 0.01 or (hp >= 99.99 and mode != MODE_ALWAYS):
				continue
			var feet := c.visual_feet if c.visual_feet != Vector3.ZERO else c.global_position
			var at := feet + Vector3.UP * (c.state.height + HEIGHT_ABOVE)
			var d := at.distance_to(cam_pos)
			var k := clampf(d / 8.0, 1.0, 3.0)
			_write(n, at, SIZE * k, clampf(hp / 100.0, 0.0, 1.0), a)
			n += 1
	shown = n
	_mm.visible_instance_count = n
	if n > 0:
		_mm.buffer = _buf
	# Forget characters that went away.
	if Engine.get_process_frames() % 120 == 0:
		for id in _seen.keys():
			if not is_instance_id_valid(id):
				_seen.erase(id)


func _write(i: int, at: Vector3, size: Vector2, fill: float, alpha: float) -> void:
	var o := i * 16
	# Transform3D rows (basis x, y, z + origin interleaved as the MultiMesh buffer wants): scale
	# on x / y (the shader billboards it), then custom data.
	_buf[o + 0] = size.x
	_buf[o + 1] = 0.0
	_buf[o + 2] = 0.0
	_buf[o + 3] = at.x
	_buf[o + 4] = 0.0
	_buf[o + 5] = size.y
	_buf[o + 6] = 0.0
	_buf[o + 7] = at.y
	_buf[o + 8] = 0.0
	_buf[o + 9] = 0.0
	_buf[o + 10] = 1.0
	_buf[o + 11] = at.z
	_buf[o + 12] = fill
	_buf[o + 13] = alpha
	_buf[o + 14] = 0.0
	_buf[o + 15] = 0.0
