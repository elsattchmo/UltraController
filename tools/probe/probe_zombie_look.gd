extends SceneTree
## Renders the zombie body four ways (as imported / no normal map / albedo only unshaded / brightened)
## to see why it reads black. godot --path . --script res://tools/probe/probe_zombie_look.gd
func _init() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.45, 0.5, 0.6)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.5, 0.55)
	env.ambient_light_energy = 0.8
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, -30, 0)
	root.add_child(sun)
	var scene := load("res://assets/characters/zombie/zombie.glb") as PackedScene
	var lib := load("res://assets/characters/mannequin/anims/mixamo.res") as AnimationLibrary
	for k in 4:
		var inst := scene.instantiate() as Node3D
		root.add_child(inst)
		inst.position = Vector3(-2.25 + k * 1.5, 0, 0)
		var sk := inst.find_child("GeneralSkeleton", true, false) as Skeleton3D
		var Measure := preload("res://tools/anim_measure.gd")
		Measure.pose(lib.get_animation("Z_Idle1"), sk, 0.0)
		var mi := inst.find_child("BodyMesh", true, false) as MeshInstance3D
		for si in mi.mesh.get_surface_count():
			var m := (mi.mesh.surface_get_material(si) as BaseMaterial3D).duplicate() as BaseMaterial3D
			match k:
				1: m.normal_enabled = false
				2: m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				3: m.albedo_color = Color(2.2, 2.2, 2.2)
			mi.set_surface_override_material(si, m)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.position = Vector3(0, 1.0, 5.0)
	cam.fov = 35
	cam.current = true
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_viewport().get_texture().get_image().save_png("C:/Dev/verify/ultra/review/zombie_look/probe_materials.png")
	quit()
