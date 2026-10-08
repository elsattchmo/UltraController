class_name MarksmanStance
extends RefCounted
## Which stance and posture a character is in - a pure function of its replicated state (every machine
## agrees): "unarmed" / "rifle" / "pistol", "stand" / "crouch" / "prone".


## The stance its held item puts it in: a firearm with a stock (it shoulders: `fp_ads_eye` set) = rifle, any
## other firearm = pistol, item stat "stance" overrides; nothing / anything else = unarmed.
static func of_item(def: ItemDefinition) -> String:
	if def == null or def.kind != ItemDefinition.Kind.FIREARM:
		return "unarmed"
	if def.stats.has("stance"):
		return String(def.stats.stance)
	return "rifle" if def.fp_ads_eye != Vector3.ZERO else "pistol"


static func of(c: UltraCharacter) -> String:
	return of_item(c.held_def())


static func posture(c: UltraCharacter) -> String:
	match c.state.state:
		MotorState.Id.CROUCH:
			return "crouch"
		MotorState.Id.CRAWL:
			return "prone"
	return "stand"
