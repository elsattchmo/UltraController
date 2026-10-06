@tool
class_name UltraLauncher
extends RefCounted
## Starts several game instances side by side for multiplayer testing. Every instance gets
## its own user folder (--user-dir) and a tiled window. PIDs are remembered so "Kill all"
## works even from a later editor session.

const PRESET_DIR := "res://addons/ultra_controller/session/presets/"
const PID_FILE := "user://ultra_launched_pids.txt"


static func presets() -> Array[UltraLaunchPreset]:
	var out: Array[UltraLaunchPreset] = []
	if not DirAccess.dir_exists_absolute(PRESET_DIR):
		return out
	var files := DirAccess.get_files_at(PRESET_DIR)
	files.sort()
	for f in files:
		if f.ends_with(".tres"):
			var p := load(PRESET_DIR + f) as UltraLaunchPreset
			if p:
				p.resource_name = f.get_basename()
				out.append(p)
	return out


static func find(name: String) -> UltraLaunchPreset:
	for p in presets():
		if p.resource_name == name:
			return p
	return null


## Launch every instance of a preset. Returns the PIDs. `extra` ("--map=mansion") goes to every instance
## that doesn't set that option itself.
static func launch(preset: UltraLaunchPreset, exe := "", extra := PackedStringArray()) -> PackedInt32Array:
	var pids := PackedInt32Array()
	if exe == "":
		exe = OS.get_executable_path()
	var project := ProjectSettings.globalize_path("res://")
	var i := 0
	for entry in preset.instances:
		var parts := entry.split("|", true, 1)
		var window := parts[0].strip_edges()
		var user_args := parts[1].strip_edges().split(" ", false) if parts.size() > 1 else PackedStringArray()
		for e in extra:
			var key := e.split("=", true, 1)[0] + "="
			var has := false
			for u in user_args:
				has = has or u.begins_with(key)
			if not has:
				user_args.append(e)
		var args := PackedStringArray(["--path", project])
		if window == "headless":
			args.append("--headless")
		args.append("--")
		args.append_array(user_args)
		if window != "headless":
			args.append("--window=" + window)
		args.append("--user-dir=inst%d" % i)
		var pid := OS.create_process(exe, args, window == "headless")
		if pid > 0:
			pids.append(pid)
		print("UltraLauncher: [%d] %s %s" % [pid, exe.get_file(), " ".join(args)])
		i += 1
	_remember(pids)
	return pids


static func _remember(pids: PackedInt32Array) -> void:
	var f := FileAccess.open(PID_FILE, FileAccess.READ_WRITE if FileAccess.file_exists(PID_FILE) else FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	for p in pids:
		f.store_line(str(p))


static func kill_all() -> int:
	if not FileAccess.file_exists(PID_FILE):
		return 0
	var n := 0
	for line in FileAccess.get_file_as_string(PID_FILE).split("\n", false):
		var pid := int(line)
		if pid > 0 and OS.is_process_running(pid):
			OS.kill(pid)
			n += 1
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PID_FILE))
	return n
