extends Node
## Headless test runner. Usage (after `--`): --suite=m1[,m2...] [--only=test_name]
## Runs every tests/suites/<suite>_*.gd (UltraTestSuite subclasses), each `test_*` method in
## order, awaiting coroutines. Exit code = number of failures. Run with --fixed-fps 60 so a
## simulated second is 60 frames regardless of machine speed.

var failures := 0
var passes := 0


func _ready() -> void:
	UltraDummyPost.auto_spawn = false            # suites spawn the characters they need
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "true"
	var suite: String = args.get("suite", "m1")
	var only: String = args.get("only", "")
	var files: Array[String] = []
	var wanted := suite.split(",")                      # (--suite=z2,z3 runs both in one process: order effects show)
	for f in DirAccess.get_files_at("res://tests/suites"):
		if not f.ends_with(".gd"):
			continue
		for w in wanted:
			if f.begins_with(w + "_") or f == w + ".gd" or w == "all":
				files.append(f)
				break
	files.sort()
	print("== UltraController tests: suite=%s files=%s" % [suite, files])
	for f in files:
		var scr := load("res://tests/suites/" + f) as Script
		if scr == null or not scr.can_instantiate():
			print("FAIL %s (does not compile)" % f)
			failures += 1
			continue
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
