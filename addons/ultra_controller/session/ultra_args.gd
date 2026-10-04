@tool
class_name UltraArgs
extends RefCounted
## Command-line options (everything after `--`), parsed once. Also owns the per-instance
## user folder so two windows on one PC never share saves or input overrides.
##
##   --offline | --host | --server | --connect=IP[:PORT]   --port=7777
##   --players=N   --name=Alex   --lag=MS --jitter=MS --loss=PCT   --bot=<course>
##   --map=<name>  --spawn=<marker>  --profile=<preset>  --view=fp|tp
##   --window=left|right|top|bottom|tl|tr|bl|br|full   --monitor=N   --user-dir=<name>
##   --launch=<preset>   --join-screen   --verbose-net

static var _args := {}
static var _parsed := false


static func all() -> Dictionary:
	if not _parsed:
		_parsed = true
		for a in OS.get_cmdline_user_args():
			var kv := a.trim_prefix("--").split("=", true, 1)
			_args[kv[0]] = kv[1] if kv.size() > 1 else "true"
	return _args


static func has(k: String) -> bool:
	return all().has(k)


static func get_str(k: String, def := "") -> String:
	return String(all().get(k, def))


static func get_int(k: String, def := 0) -> int:
	return int(all().get(k, def))


static func get_float(k: String, def := 0.0) -> float:
	return float(all().get(k, def))


## user:// path for this instance (user://inst_<name>/... when --user-dir is given).
static func user_path(file: String) -> String:
	var d := get_str("user-dir", "")
	if d == "":
		return "user://" + file
	var dir := "user://inst_%s" % d.validate_filename()
	DirAccess.make_dir_recursive_absolute(dir)
	return dir.path_join(file)


## Place and size this window from --window / --monitor.
static func apply_window() -> void:
	var slot := get_str("window", "")
	if slot == "" or DisplayServer.get_name() == "headless":
		return
	var mon := clampi(get_int("monitor", DisplayServer.window_get_current_screen()), 0, DisplayServer.get_screen_count() - 1)
	var r := DisplayServer.screen_get_usable_rect(mon)
	var title_h := 32
	var rects := {
		"full": Rect2i(r.position, r.size),
		"left": Rect2i(r.position, Vector2i(r.size.x / 2, r.size.y)),
		"right": Rect2i(r.position + Vector2i(r.size.x / 2, 0), Vector2i(r.size.x / 2, r.size.y)),
		"top": Rect2i(r.position, Vector2i(r.size.x, r.size.y / 2)),
		"bottom": Rect2i(r.position + Vector2i(0, r.size.y / 2), Vector2i(r.size.x, r.size.y / 2)),
		"tl": Rect2i(r.position, r.size / 2),
		"tr": Rect2i(r.position + Vector2i(r.size.x / 2, 0), r.size / 2),
		"bl": Rect2i(r.position + Vector2i(0, r.size.y / 2), r.size / 2),
		"br": Rect2i(r.position + r.size / 2, r.size / 2),
	}
	if not rects.has(slot):
		return
	var rr: Rect2i = rects[slot]
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(rr.size - Vector2i(0, title_h))
	DisplayServer.window_set_position(rr.position + Vector2i(0, title_h))
