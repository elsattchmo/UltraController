class_name MarksmanCharacter
extends SinewCharacter
## The third controller: Sinew's physics body and gait, built around the Mixamo rifle / pistol packs.
## Full 8-way locomotion per stance (unarmed / rifle / pistol; standing, crouched, prone), guns held and
## aimed by the body itself (one body for both views: the first-person camera is the head's eye),
## one-handed holding with either hand, Insurgency: Sandstorm-style gunplay. Plan: stages V0-V8 in
## addons/marksman/README.md. Movement, weapons, input, net and HUD are the UltraCharacter's, untouched.


func _new_anim_driver() -> SinewAnimDriver:
	return MarksmanAnimDriver.new()


func _new_ragdoll() -> SinewRagdoll:
	return MarksmanRagdoll.new()


func _default_anim_set() -> String:
	return "res://addons/marksman/marksman_animset.tres"


func _new_equipment() -> UltraEquipmentVisual:
	return MarksmanEquipment.new()


## The body-true first-person eye (MarksmanEye), added beside the camera rig that follows this character - the
## rig is made by the local player manager, not the character, so it's looked for until it's there.
var eye: MarksmanEye


func _process(delta: float) -> void:
	super._process(delta)
	if (eye == null or not is_instance_valid(eye)) and Engine.get_process_frames() % 30 == 0 and is_inside_tree():
		for n in get_tree().root.find_children("*", "UltraCameraRig", true, false):
			var r := n as UltraCameraRig
			if r.character == self:
				eye = MarksmanEye.new(self, r)
				r.add_child(eye)
				break
