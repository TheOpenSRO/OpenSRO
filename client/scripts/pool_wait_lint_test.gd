extends SceneTree

## Round 760: every main-thread wait for a WorkerThreadPool task goes through
## PoolWait, which keeps serving the RenderingServer's queue while it waits
## (Godot 4.7.2's deadlock: a pool task's synchronous RenderingServer call
## waits for the main thread, which waits for the task; PoolWait's header has
## the READ lines). A plain `WorkerThreadPool.wait_for_task_completion` or
## `wait_for_group_task_completion` is allowed only on a line that says why it
## cannot meet the RenderingServer: `# pool-wait: <reason>` (HeightBatch's
## data-only helpers, PoolWait's own waits after the poll).
##
## Scans every script under res://scripts and res://tools except the suites
## (a suite runs on the dummy renderer, which queues nothing). NEGATIVE: the
## detector must flag each bare form of a snippet and pass the allowed ones;
## with one of World3D's cell waits put back as a bare wait, this suite fails.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## Lines (1-based) of `src` that wait on the pool without PoolWait or a reason.
static func bare_waits(src: String) -> PackedInt32Array:
	var out := PackedInt32Array()
	var lines := src.split("\n")
	for i in range(lines.size()):
		var line: String = lines[i]
		var code := line
		var hash_at := line.find("#")
		var note := ""
		if hash_at >= 0:
			code = line.substr(0, hash_at)
			note = line.substr(hash_at)
		if code.find("wait_for_task_completion(") < 0 and code.find("wait_for_group_task_completion(") < 0:
			continue
		if note.find("pool-wait:") >= 0:
			continue
		out.append(i + 1)
	return out

func _test_detector() -> void:
	var banned := [
		"\tWorkerThreadPool.wait_for_task_completion(id)",
		"\tWorkerThreadPool.wait_for_group_task_completion(g)",
		"\tvar e := WorkerThreadPool.wait_for_task_completion(int(t[0])) # waits",
		"\tWorkerThreadPool.wait_for_task_completion(x) # pool wait without the colon",
	]
	var allowed := [
		"\tPoolWait.task(id)",
		"\tPoolWait.group(g)",
		"\tWorkerThreadPool.wait_for_group_task_completion(g) # pool-wait: resource-free",
		"## WorkerThreadPool.wait_for_task_completion(id) in a comment",
		"\tif WorkerThreadPool.is_task_completed(id):",
	]
	for b in banned:
		_check(bare_waits(b).size() == 1, "detector flags: %s" % b.strip_edges())
	for a in allowed:
		_check(bare_waits(a).is_empty(), "detector allows: %s" % a.strip_edges())

func _scripts(dir: String, out: Array) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for sub in d.get_directories():
		_scripts(dir.path_join(sub), out)
	for f in d.get_files():
		if f.ends_with(".gd") and not f.ends_with("_test.gd"):
			out.append(dir.path_join(f))

func _test_tree() -> void:
	var files: Array = []
	_scripts("res://scripts", files)
	_scripts("res://tools", files)
	var bad := 0
	for path in files:
		var src := FileAccess.get_file_as_string(path)
		for ln in bare_waits(src):
			print("  bare pool wait: %s:%d" % [path, ln])
			bad += 1
	_check(files.size() > 300, "scanned %d scripts" % files.size())
	_check(bad == 0, "no bare main-thread pool wait (%d found)" % bad)
	# The waits the round converted are still PoolWait's (the template tasks, the cell prepares).
	var world := FileAccess.get_file_as_string("res://scripts/World3D.gd")
	_check(world.count("PoolWait.task(flight[\"task\"])") == 2, "World3D's cell prepares wait through PoolWait")
	var app := FileAccess.get_file_as_string("res://scripts/ui/character_appearance.gd")
	_check(app.count("PoolWait.task(") == 2, "CharacterAppearance's template tasks wait through PoolWait")

func _initialize() -> void:
	_test_detector()
	_test_tree()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit()
