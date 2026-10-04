extends Node
## Headless test runner. Usage (after `--`): --suite=m1 [--only=test_name]
## Runs every tests/suites/<suite>_*.gd (UltraTestSuite subclasses), each `test_*` method in
## order, awaiting coroutines. Exit code = number of failures. Run with --fixed-fps 60 so a
## simulated second is 60 frames regardless of machine speed.

var failures := 0
var passes := 0


func _ready() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "true"
	var suite: String = args.get("suite", "m1")
	var only: String = args.get("only", "")
	var files: Array[String] = []
	for f in DirAccess.get_files_at("res://tests/suites"):
		if f.ends_with(".gd") and (f.begins_with(suite + "_") or f == suite + ".gd" or suite == "all"):
			files.append(f)
	files.sort()
	print("== UltraController tests: suite=%s files=%s" % [suite, files])
	for f in files:
		var scr := load("res://tests/suites/" + f) as Script
		var t: UltraTestSuite = scr.new()
		t.name = f.get_basename()
		add_child(t)
		for m in t.get_method_list():
			var mn: String = m.name
			if not mn.begins_with("test_") or (only != "" and mn != only):
				continue
			t.current = "%s.%s" % [t.name, mn]
			t.failed = false
			await t.before_each()
			await t.call(mn)
			await t.after_each()
			if t.failed:
				failures += 1
				print("FAIL ", t.current)
			else:
				passes += 1
				print("ok   ", t.current)
		t.queue_free()
		await get_tree().process_frame
	print("== %d passed, %d failed" % [passes, failures])
	print("RESULT ", "GREEN" if failures == 0 else "RED")
	get_tree().quit(failures)
