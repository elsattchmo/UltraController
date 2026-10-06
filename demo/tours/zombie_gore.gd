extends "res://demo/tours/gore_review.gd"
## The gore review on Romero zombies (their own cut set): belly blast, arm, hand / foot, a heart
## shot, the waist, the head, the waist from behind.
##   godot --path . --resolution 1280x720 -- --tour=zombie_gore --out=C:/Dev/verify/ultra/review/zombie_gore


func _build() -> void:
	super()
	out_dir = out_dir.replace("/gore_review", "/zombie_gore")


func _setup() -> void:
	var c: UltraCharacter = main.player
	for k in 7:
		var at := c.state.pos + Vector3(-6.0 + k * 4.0, 0, -6.0)
		var p := UltraNet.spawn_bot(ZombieFactory.name_for(&"walker", k), Transform3D(Basis(Vector3.UP, 0.0), at))
		(p.character.input_source as BotInputSource).set_steps([{"ticks": 100000}])
		_d.append(p.character)
	_cam = Camera3D.new()
	main.add_child(_cam)
	_cam.fov = 40.0
	_look(0, Vector3(0, 1.0, 0), Vector3(1.8, 0.4, -1.6))
