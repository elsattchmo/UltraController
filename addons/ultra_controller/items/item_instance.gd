class_name ItemInstance
extends RefCounted
## A stack of one item kind plus its own data (ammo in the magazine, durability, notes).

static var _next_uid := 1

var uid: int = 0
var def_id: StringName
var count: int = 1
var data: Dictionary = {}


static func make(id: StringName, n := 1, d := {}) -> ItemInstance:
	var it := ItemInstance.new()
	it.uid = _next_uid
	_next_uid += 1
	it.def_id = id
	it.count = n
	it.data = d.duplicate()
	var def := ItemDB.get_def(id)
	if def and def.kind == ItemDefinition.Kind.FIREARM and not it.data.has("mag"):
		it.data["mag"] = int(def.stat("mag_size", 0))
	return it


func def() -> ItemDefinition:
	return ItemDB.get_def(def_id)


func mass() -> float:
	var d := def()
	return (d.mass if d else 0.0) * count


func to_dict() -> Dictionary:
	return {"u": uid, "i": String(def_id), "n": count, "d": data}


static func from_dict(d: Dictionary) -> ItemInstance:
	var it := ItemInstance.new()
	it.uid = int(d.get("u", 0))
	it.def_id = StringName(d.get("i", ""))
	it.count = int(d.get("n", 1))
	it.data = d.get("d", {})
	_next_uid = maxi(_next_uid, it.uid + 1)
	return it
