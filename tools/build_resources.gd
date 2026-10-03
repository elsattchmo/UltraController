extends SceneTree
## One-shot project setup: Input Map defaults, input tunables, layer names, movement profile
## presets and the mannequin BodyProfile. Safe to re-run (never overwrites user bindings).
## Run: godot --headless --path . --script res://tools/build_resources.gd

const PHYS_LAYERS := ["world_static", "world_dynamic", "character", "hitbox", "ragdoll", "held_prop", "interactable", "climbable", "ladder", "no_traverse", "water"]


func _init() -> void:
	var added := UltraInputDefaults.install_missing(false)
	UltraInputSettings.register(false)
	for i in PHYS_LAYERS.size():
		ProjectSettings.set_setting("layer_names/3d_physics/layer_%d" % (i + 1), PHYS_LAYERS[i])
	ProjectSettings.set_setting("layer_names/3d_render/layer_1", "world")
	for p in 4:
		ProjectSettings.set_setting("layer_names/3d_render/layer_%d" % (11 + p), "own_head_p%d" % (p + 1))
	ProjectSettings.save()
	print("input actions added: ", added)
	_profiles()
	_body()
	quit()


func _profiles() -> void:
	var dir := "res://addons/ultra_controller/profiles/"
	var fps := MovementProfile.new()
	fps.default_view = MovementProfile.View.FIRST_PERSON
	fps.tp_rotation = MovementProfile.Rotation.FACE_MOVE_UNTIL_AIM
	fps.accel = 11.0
	fps.brake_decel = 20.0
	fps.turn_rate_sprint = 220.0
	fps.camera = UltraCameraProfile.new()
	ResourceSaver.save(fps, dir + "fps.tres")

	var adv := MovementProfile.new()
	adv.default_view = MovementProfile.View.THIRD_PERSON
	adv.tp_rotation = MovementProfile.Rotation.FACE_MOVE
	adv.accel = 7.0
	adv.decel = 9.0
	adv.brake_decel = 13.0
	adv.turn_rate_sprint = 120.0
	adv.body_turn_rate = 420.0
	adv.camera = UltraCameraProfile.new()
	adv.camera.tp_distance = 3.6
	adv.camera.tp_shoulder = Vector3(0.0, 0.25, 0)
	ResourceSaver.save(adv, dir + "adventure.tres")

	var surv := MovementProfile.new()
	surv.default_view = MovementProfile.View.FIRST_PERSON
	surv.accel = 7.5
	surv.decel = 9.5
	surv.brake_decel = 14.0
	surv.sprint_speed = 5.6
	surv.jump_height = 0.85
	surv.turn_rate_sprint = 130.0
	surv.camera = UltraCameraProfile.new()
	surv.camera.fp_head_follow = 0.45
	surv.camera.fp_bob_amount = 1.0
	ResourceSaver.save(surv, dir + "survival.tres")

	var tps := MovementProfile.new()
	tps.default_view = MovementProfile.View.THIRD_PERSON
	tps.tp_rotation = MovementProfile.Rotation.FACE_MOVE_UNTIL_AIM
	tps.camera = UltraCameraProfile.new()
	tps.camera.tp_distance = 2.6
	tps.camera.tp_shoulder = Vector3(0.55, 0.15, 0)
	ResourceSaver.save(tps, dir + "tps.tres")
	print("profiles saved")


func _body() -> void:
	var b := BodyProfile.new()
	b.body_scene = load("res://assets/characters/mannequin/mannequin.glb")
	b.anim_set = load("res://assets/characters/mannequin/mannequin_animset.tres")
	b.library = load("res://assets/characters/mannequin/anims/ual.res")
	var err := ResourceSaver.save(b, "res://assets/characters/mannequin/mannequin_body_profile.tres")
	print("body profile saved err=", err)
