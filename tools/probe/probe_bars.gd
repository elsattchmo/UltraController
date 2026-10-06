extends Node3D
## Renders a few bars with no characters, to see the shader / MultiMesh work on screen.
##   godot --path . --resolution 960x540 res://tools/probe/probe_bars.tscn
func _ready() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.3, 0.35, 0.45)
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var fl := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(20, 20)
	fl.mesh = pm
	add_child(fl)
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(0, 1.6, 5)
	cam.current = true
	var bars := UltraWorldBars.new()
	add_child(bars)
	await get_tree().process_frame
	bars.set_process(false)             # (after _ready: entering the tree turns _process back on)
	for k in 5:
		bars._write(k, Vector3(-2.0 + k * 1.0, 1.0 + 0.2 * k, 0.0), UltraWorldBars.SIZE * 1.5, 1.0 - 0.22 * k, 1.0)
	bars._mm.visible_instance_count = 5
	bars._mm.buffer = bars._buf
	print("PROBE aabb ", bars._mm.get_aabb(), " count ", bars._mm.instance_count, " vis ", bars._mm.visible_instance_count, " buf ", bars._mm.buffer.size())
	# A plain red MultiMesh next to it, standard material: does the MultiMesh itself draw?
	var mm2 := MultiMesh.new()
	mm2.transform_format = MultiMesh.TRANSFORM_3D
	mm2.mesh = QuadMesh.new()
	mm2.instance_count = 1
	mm2.set_instance_transform(0, Transform3D(Basis.IDENTITY.scaled(Vector3(1, 0.3, 1)), Vector3(0, 0.3, 1.0)))
	var mi2 := MultiMeshInstance3D.new()
	mi2.multimesh = mm2
	var sm := StandardMaterial3D.new()
	sm.albedo_color = Color.RED
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi2.material_override = sm
	add_child(mi2)
	# Variants of the bars' MultiMesh, one thing changed each: 
	var variants := [
		["custom data + standard material", true, 96, false],
		["no custom data + trivial shader", false, 96, true],
		["custom data + trivial shader, count 5", true, 5, true],
	]
	for vi in variants.size():
		var v: Array = variants[vi]
		var m := MultiMesh.new()
		m.transform_format = MultiMesh.TRANSFORM_3D
		m.use_custom_data = v[1]
		var qq := QuadMesh.new()
		qq.size = Vector2.ONE
		m.mesh = qq
		m.instance_count = v[2]
		m.set_instance_transform(0, Transform3D(Basis.IDENTITY.scaled(Vector3(1.0, 0.25, 1)), Vector3(-1.5 + vi * 1.5, 2.2, 0.0)))
		var inst := MultiMeshInstance3D.new()
		inst.multimesh = m
		if v[3]:
			var sh := ShaderMaterial.new()
			sh.shader = load("res://addons/ultra_controller/ui/world_bar.gdshader")
			inst.material_override = sh
		else:
			var st := StandardMaterial3D.new()
			st.albedo_color = Color.GREEN
			st.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			inst.material_override = st
		add_child(inst)
		print("PROBE variant ", v[0])
	print("PROBE inst2 ", bars._mm.get_instance_transform(2), " visible ", bars._mmi.is_visible_in_tree(), " mat ", bars._mmi.material_override, " mesh ", bars._mm.mesh, " tf ", bars._mm.transform_format, " custom ", bars._mm.use_custom_data)
	var shots := [
		["a_count_all", func() -> void: bars._mm.visible_instance_count = -1],
		["b_no_margin", func() -> void: bars._mmi.extra_cull_margin = 0.0],
		["c_shadow_default", func() -> void: bars._mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON],
		["d_priority", func() -> void: (bars._mmi.material_override as ShaderMaterial).render_priority = 0],
		["e_no_custom_aabb", func() -> void: bars._mm.custom_aabb = AABB()],
		["f_small_aabb", func() -> void: bars._mm.custom_aabb = AABB(Vector3(-20, -20, -20), Vector3(40, 40, 40))],
	]
	for sh: Array in shots:
		(sh[1] as Callable).call()
		await get_tree().process_frame
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("C:/Dev/verify/ultra/review/zombie_look/probe_bars_%s.png" % sh[0])
	get_tree().quit()
