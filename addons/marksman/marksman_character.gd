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
