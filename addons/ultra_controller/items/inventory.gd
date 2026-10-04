class_name Inventory
extends RefCounted
## Slot-based inventory with a weight budget. Slots 0..8 are the hotbar. Pure data: the
## server owns the real one and sends it to its owner; the owner's copy is display + prediction.

signal changed

const HOTBAR := 9

var slots: Array = []                 ## ItemInstance or null
var capacity_kg := 30.0
var revision := 0


func _init(size := 24, cap := 30.0) -> void:
	slots.resize(size)
	capacity_kg = cap


func size() -> int:
	return slots.size()


func get_slot(i: int) -> ItemInstance:
	return slots[i] if i >= 0 and i < slots.size() else null


func total_mass() -> float:
	var m := 0.0
	for it: ItemInstance in slots:
		if it:
			m += it.mass()
	return m


func count_of(id: StringName) -> int:
	var n := 0
	for it: ItemInstance in slots:
		if it and it.def_id == id:
			n += it.count
	return n


func find_uid(uid: int) -> int:
	for i in slots.size():
		if slots[i] and (slots[i] as ItemInstance).uid == uid:
			return i
	return -1


func find_key(key: StringName) -> int:
	for i in slots.size():
		var it: ItemInstance = slots[i]
		if it and it.def() and it.def().kind == ItemDefinition.Kind.KEY and it.def().key_id == key:
			return i
	return -1


## Room for `it` by weight?
func fits(it: ItemInstance) -> bool:
	return total_mass() + it.mass() <= capacity_kg + 0.0001


## Add (stacking first). Returns how many could NOT be added.
func add(it: ItemInstance) -> int:
	var def := it.def()
	if def == null:
		return it.count
	var left := it.count
	var unit := def.mass
	var room_kg := capacity_kg - total_mass()
	var by_weight := int(floor(room_kg / unit + 0.0001)) if unit > 0.0 else left
	left = mini(left, by_weight)
	var refused := it.count - left
	if def.max_stack > 1:
		for s: ItemInstance in slots:
			if left <= 0:
				break
			if s and s.def_id == it.def_id and s.count < def.max_stack:
				var k := mini(def.max_stack - s.count, left)
				s.count += k
				left -= k
	while left > 0:
		var free := slots.find(null)
		if free < 0:
			break
		var k := mini(def.max_stack, left)
		# A single unstackable item keeps its identity (uid, magazine contents...).
		var put := it if (def.max_stack == 1 and it.count == 1 and not slots.has(it)) else ItemInstance.make(it.def_id, k, it.data)
		slots[free] = put
		left -= k
	if left != it.count - refused:
		_touch()
	return left + refused


## Remove `n` of an item kind (any slots). Returns how many were removed.
func take(id: StringName, n: int) -> int:
	var got := 0
	for i in range(slots.size() - 1, -1, -1):
		var s: ItemInstance = slots[i]
		if s and s.def_id == id and got < n:
			var k := mini(s.count, n - got)
			s.count -= k
			got += k
			if s.count <= 0:
				slots[i] = null
	if got > 0:
		_touch()
	return got


func remove_slot(i: int, n := -1) -> ItemInstance:
	var s: ItemInstance = get_slot(i)
	if s == null:
		return null
	if n < 0 or n >= s.count:
		slots[i] = null
		_touch()
		return s
	s.count -= n
	_touch()
	return ItemInstance.make(s.def_id, n, s.data)


func move(from: int, to: int) -> bool:
	if from == to or get_slot(from) == null or to < 0 or to >= slots.size():
		return false
	var a: ItemInstance = slots[from]
	var b: ItemInstance = slots[to]
	if b and b.def_id == a.def_id and a.def().max_stack > 1:
		var k := mini(a.def().max_stack - b.count, a.count)
		b.count += k
		a.count -= k
		if a.count <= 0:
			slots[from] = null
	else:
		slots[from] = b
		slots[to] = a
	_touch()
	return true


func split(from: int) -> bool:
	var a := get_slot(from)
	var free := slots.find(null)
	if a == null or a.count < 2 or free < 0:
		return false
	var half := a.count / 2
	a.count -= half
	slots[free] = ItemInstance.make(a.def_id, half, a.data)
	_touch()
	return true


func _touch() -> void:
	revision += 1
	changed.emit()


func to_bytes() -> PackedByteArray:
	var arr := []
	for s: ItemInstance in slots:
		arr.append(s.to_dict() if s else null)
	return var_to_bytes({"r": revision, "c": capacity_kg, "s": arr})


func from_bytes(b: PackedByteArray) -> void:
	var d: Dictionary = bytes_to_var(b)
	revision = int(d.get("r", 0))
	capacity_kg = float(d.get("c", capacity_kg))
	var arr: Array = d.get("s", [])
	slots.resize(arr.size())
	for i in arr.size():
		slots[i] = ItemInstance.from_dict(arr[i]) if arr[i] is Dictionary else null
	changed.emit()
