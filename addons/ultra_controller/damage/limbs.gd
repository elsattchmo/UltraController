class_name UltraLimbs
extends RefCounted
## Body regions for per-limb damage, injuries and dismemberment. Region health lives in
## MotorState (`limb_hp`: percent per region, `severed`: bitmask) so the movement effects of an
## injury predict exactly like everything else; the server is the only one that changes them.

enum Region { HEAD, TORSO, ARM_L, FOREARM_L, ARM_R, FOREARM_R, THIGH_L, SHIN_L, THIGH_R, SHIN_R,
	HAND_L, HAND_R, FOOT_L, FOOT_R }      ## (hands and feet appended: older indices unchanged)
enum Status { HEALTHY, INJURED, CRIPPLED, SEVERED }

const COUNT := 14
const NAMES: Array[String] = ["head", "torso", "upper arm L", "forearm L", "upper arm R", "forearm R",
	"thigh L", "shin L", "thigh R", "shin R", "hand L", "hand R", "foot L", "foot R"]
const STATUS_NAMES: Array[String] = ["ok", "hurt", "crippled", "severed"]

## Humanoid bones owned by each region. The first is the region's root: where it's cut off.
const BONES := {
	Region.HEAD: ["Head"],
	Region.TORSO: ["Hips", "Spine", "Chest", "UpperChest", "Neck"],
	Region.ARM_L: ["LeftUpperArm"],
	Region.FOREARM_L: ["LeftLowerArm"],
	Region.ARM_R: ["RightUpperArm"],
	Region.FOREARM_R: ["RightLowerArm"],
	Region.THIGH_L: ["LeftUpperLeg"],
	Region.SHIN_L: ["LeftLowerLeg"],
	Region.THIGH_R: ["RightUpperLeg"],
	Region.SHIN_R: ["RightLowerLeg"],
	Region.HAND_L: ["LeftHand"],
	Region.HAND_R: ["RightHand"],
	Region.FOOT_L: ["LeftFoot", "LeftToes"],
	Region.FOOT_R: ["RightFoot", "RightToes"],
}
## Losing a region takes the rest of the chain with it.
const BELOW := {
	Region.ARM_L: [Region.FOREARM_L, Region.HAND_L],
	Region.FOREARM_L: [Region.HAND_L],
	Region.ARM_R: [Region.FOREARM_R, Region.HAND_R],
	Region.FOREARM_R: [Region.HAND_R],
	Region.THIGH_L: [Region.SHIN_L, Region.FOOT_L],
	Region.SHIN_L: [Region.FOOT_L],
	Region.THIGH_R: [Region.SHIN_R, Region.FOOT_R],
	Region.SHIN_R: [Region.FOOT_R],
}


static func status(s: MotorState, r: int) -> int:
	if s.severed & (1 << r):
		return Status.SEVERED
	var hp := s.limb_hp[r]
	if hp == 0:
		return Status.CRIPPLED
	if hp <= 50:
		return Status.INJURED
	return Status.HEALTHY


## Worst status along a leg / arm.
static func leg(s: MotorState, left: bool) -> int:
	return maxi(maxi(status(s, Region.THIGH_L if left else Region.THIGH_R), status(s, Region.SHIN_L if left else Region.SHIN_R)),
		status(s, Region.FOOT_L if left else Region.FOOT_R))


static func arm(s: MotorState, left: bool) -> int:
	return maxi(maxi(status(s, Region.ARM_L if left else Region.ARM_R), status(s, Region.FOREARM_L if left else Region.FOREARM_R)),
		status(s, Region.HAND_L if left else Region.HAND_R))


static func is_whole(s: MotorState) -> bool:
	if s.severed != 0:
		return false
	for r in COUNT:
		if s.limb_hp[r] < 100:
			return false
	return true


## Severing `r` also severs what hangs off it. Returns the full mask.
static func sever_mask(r: int) -> int:
	var m := 1 << r
	for c: int in BELOW.get(r, []):
		m |= 1 << c
	return m


## 2 bits per region, for remote players' snapshots.
static func pack(s: MotorState) -> int:
	var bits := 0
	for r in COUNT:
		bits |= status(s, r) << (r * 2)
	return bits


## Remote players only see statuses: rebuild representative region health from them.
static func unpack_into(s: MotorState, bits: int) -> void:
	s.severed = 0
	for r in COUNT:
		match (bits >> (r * 2)) & 3:
			Status.HEALTHY:
				s.limb_hp[r] = 100
			Status.INJURED:
				s.limb_hp[r] = 40
			Status.CRIPPLED:
				s.limb_hp[r] = 0
			Status.SEVERED:
				s.limb_hp[r] = 0
				s.severed |= 1 << r


static func full_health() -> PackedByteArray:
	var a := PackedByteArray()
	a.resize(COUNT)
	a.fill(100)
	return a


static func describe(s: MotorState) -> String:
	var parts: Array[String] = []
	for r in COUNT:
		var st := status(s, r)
		if st != Status.HEALTHY:
			parts.append("%s %s" % [NAMES[r], STATUS_NAMES[st]])
	return ", ".join(parts) if not parts.is_empty() else "unhurt"
