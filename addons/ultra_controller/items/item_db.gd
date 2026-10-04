@tool
class_name ItemDB
extends RefCounted
## Registry of ItemDefinitions. Each definition gets a stable numeric index (sorted by id) so
## the net layer can send a u16 instead of a string. Folders scanned: res://assets/items and
## res://demo/items (recursively) for *_item.tres.

const ROOTS := ["res://assets/items", "res://demo/items"]

static var _by_id := {}
static var _list: Array[ItemDefinition] = []
static var _loaded := false


static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	var found: Array[ItemDefinition] = []
	for r in ROOTS:
		_scan(r, found)
	found.sort_custom(func(a: ItemDefinition, b: ItemDefinition) -> bool: return String(a.id) < String(b.id))
	_list = [null]               # index 0 = "nothing"
	for d in found:
		_by_id[d.id] = d
		_list.append(d)


static func _scan(dir: String, out: Array[ItemDefinition]) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for f in DirAccess.get_files_at(dir):
		if f.ends_with("_item.tres"):
			var d := load(dir.path_join(f)) as ItemDefinition
			if d and d.id != &"":
				out.append(d)
	for sub in DirAccess.get_directories_at(dir):
		_scan(dir.path_join(sub), out)


static func get_def(id: StringName) -> ItemDefinition:
	_ensure()
	return _by_id.get(id)


static func index_of(id: StringName) -> int:
	_ensure()
	var d: ItemDefinition = _by_id.get(id)
	return _list.find(d) if d else 0


static func by_index(i: int) -> ItemDefinition:
	_ensure()
	return _list[i] if i > 0 and i < _list.size() else null


static func all() -> Array[ItemDefinition]:
	_ensure()
	return _list.slice(1)


static func reload() -> void:
	_loaded = false
	_by_id.clear()
	_list.clear()
