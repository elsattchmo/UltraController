class_name MarksmanCharacter
extends SinewCharacter
## The third controller: Sinew's physics body and gait, built around the Mixamo rifle / pistol packs.
## Full 8-way locomotion per stance (unarmed / rifle / pistol; standing, crouched, prone), guns held and
## aimed by the body itself (one body for both views: the first-person camera is the head's eye),
## one-handed holding with either hand, Insurgency: Sandstorm-style gunplay. Plan: stages V0-V8 in
## addons/marksman/README.md. Movement, weapons, input, net and HUD are the UltraCharacter's, untouched.


## Motion matching for the standing legs (a spike: MarksmanMotionMatcher, MarksmanMMPass) instead of Sinew's gait.
## On for every Marksman made while `motion_matching_on()`: the main menu's toggle / `--mm` (kept in Engine meta
## MM_META across Pause > Main menu).
@export var motion_matching := false
const MM_META := &"marksman_mm"


static func motion_matching_on() -> bool:
	if not Engine.has_meta(MM_META):
		Engine.set_meta(MM_META, "--mm" in OS.get_cmdline_user_args())
	return bool(Engine.get_meta(MM_META))


func _ready() -> void:
	if motion_matching_on():
		motion_matching = true
	super._ready()


## A push under motion matching: the legs go to Sinew's gait for the stumble (its catching steps under physical
## motion, the trip rule), then back to the matcher (MarksmanRagdoll.stumble_start).
func receive_push(dv: Vector3) -> bool:
	var r := ragdoll as MarksmanRagdoll
	var offline := UltraNet.mode == UltraNet.Mode.NONE or UltraNet.mode == UltraNet.Mode.OFFLINE
	if not _motion_on and r != null and r.mm_legs() and physical_motion and offline and is_authority() \
			and state.is_grounded() and state.state in MOTION_STATES and state.platform_id == 0:
		r.stumble_start()
		if r.gait_walking():
			_motion_on = true
			_motion_vel = Vector3(state.vel.x, 0.0, state.vel.z)
	return super.receive_push(dv)


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
