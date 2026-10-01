extends SceneTree

## UpdateInstaller (round 668) against a filesystem that behaves like
## Windows, and against the real one.
##
## FakeFs models Windows' sharing rules as the installer meets them:
## - "image": a running .exe or a loaded .dll. It can be RENAMED (the loader
##   maps it with FILE_SHARE_DELETE), not overwritten and not deleted, and the
##   lock moves with the file to its new name;
## - "open": a file held open without FILE_SHARE_DELETE (Godot's own
##   _wfsopen(_SH_DENYNO), file_access_windows.cpp:146). It cannot be renamed
##   or deleted, but can be overwritten;
## - "busy:N": refuses the next N renames, then behaves (antivirus scanning);
## - quarantined content: antivirus deletes such a file the first time it is
##   moved or copied, and the operation fails.
## DirAccess.rename on Windows deletes an existing target first
## (dir_access_windows.cpp:301-305), so a rename onto a locked name fails.
## These rules are INFERRED from Windows' documented behaviour; nothing here
## ran on Windows.
##
##   godot4 --headless --path client --script res://scripts/update/update_installer_test.gd

class FakeFs extends UpdateFs:
	var windows := true
	var files := {}
	var perms := {}
	var locks := {}
	var quarantine := {}  # content -> true
	var slept_ms := 0

	func exists(path: String) -> bool:
		return files.has(path)

	func _lock(path: String) -> String:
		return str(locks.get(path, "")) if windows else ""

	func _quarantined(path: String) -> bool:
		if quarantine.has(files.get(path, null)):
			files.erase(path)
			return true
		return false

	func rename(from: String, to: String) -> bool:
		if not files.has(from):
			return false
		var lock := _lock(from)
		if lock.begins_with("busy:"):
			var n := int(lock.substr(5))
			if n > 0:
				locks[from] = "busy:%d" % (n - 1)
				return false
			locks.erase(from)
			lock = ""
		if lock == "open":
			return false
		if _quarantined(from):
			return false
		if files.has(to) and not remove(to):
			return false
		files[to] = files[from]
		files.erase(from)
		if perms.has(from):
			perms[to] = perms[from]
			perms.erase(from)
		if lock == "image":
			locks[to] = "image"
			locks.erase(from)
		return true

	func remove(path: String) -> bool:
		if not files.has(path):
			return false
		var lock := _lock(path)
		if lock == "image" or lock == "open":
			return false
		files.erase(path)
		perms.erase(path)
		return true

	func copy(from: String, to: String) -> bool:
		if not files.has(from) or _quarantined(from):
			return false
		if files.has(to) and _lock(to) == "image":
			return false
		files[to] = files[from]
		return true

	func make_dir(_path: String) -> void:
		pass

	func permissions(path: String) -> int:
		return -1 if windows else int(perms.get(path, 420))

	func set_permissions(path: String, bits: int) -> void:
		if bits >= 0 and not windows:
			perms[path] = bits

	func read_text(path: String) -> String:
		return str(files.get(path, ""))

	func write_text(path: String, text: String) -> bool:
		files[path] = text
		return true

	func sleep_ms(ms: int) -> void:
		slept_ms += ms

const I := "C:/Games/srrevamp"
const S := "C:/Games/srrevamp/srrevamp_update_staging/srrevamp-windows"
const EXE := "srrevamp.exe"
const DLL := "srrevamp_native.dll"
const FILES := ["srrevamp.exe", "srrevamp.console.exe", "srrevamp.pck", "srrevamp_native.dll",
	"THIRD_PARTY_NOTICES.txt", "README.md", "pk2/PUT_YOUR_PK2_FILES_HERE.txt"]

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## An install of the old version, the new version staged, the game running:
## its exe and its DLL image-locked.
func _windows_world() -> FakeFs:
	var fs := FakeFs.new()
	for f in FILES:
		if f != "pk2/PUT_YOUR_PK2_FILES_HERE.txt":
			fs.files[I + "/" + f] = "old " + f
		fs.files[S + "/" + f] = "new " + f
	fs.files[I + "/pk2/Data.pk2"] = "the player's own data"
	fs.locks[I + "/" + EXE] = "image"
	fs.locks[I + "/" + DLL] = "image"
	return fs

func _run(fs: FakeFs) -> Array:
	var inst := UpdateInstaller.new(fs)
	var out := inst.install(S, I, PackedStringArray(FILES), EXE)
	for l in inst.lines:
		print("    | " + l)
	return [inst, out]

func _initialize() -> void:
	_test_order()
	_test_locked_exe_and_dll()
	_test_dll_renamed_off()
	_test_dll_quarantined_in_staging()
	_test_dll_blocked_on_install()
	_test_pck_held_open_rolls_back()
	_test_exe_blocked_rolls_back()
	_test_transient_lock_retried()
	_test_previous_aside_still_locked()
	_test_linux_semantics()
	_test_relaunch_scripts()
	_test_digest()
	_test_real_filesystem()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)

func _test_order() -> void:
	var order := UpdateInstaller.install_order(PackedStringArray(FILES), EXE)
	_check(not order.has("pk2/PUT_YOUR_PK2_FILES_HERE.txt"), "the pk2 folder is never touched")
	_check(order[order.size() - 1] == "srrevamp.pck" and order[order.size() - 2] == EXE and order[order.size() - 3] == DLL,
		"the native library, then the exe, then the .pck go last (got %s)" % [order])
	_check(not UpdateInstaller.install_order(PackedStringArray(["srrevamp_native.dll.old-update", "srrevamp_update.log"]), EXE).size(),
		"moved-aside files and the updater's own files are never installed")

func _test_locked_exe_and_dll() -> void:
	print("-- Windows: the running exe and the loaded DLL are replaced")
	var fs := _windows_world()
	var r: Array = _run(fs)
	var inst: UpdateInstaller = r[0]
	var out: Dictionary = r[1]
	_check(out.ok, "the update installs with the exe running and the DLL loaded")
	for f in FILES:
		if f.begins_with("pk2/"):
			continue
		_check(fs.files.get(I + "/" + f) == "new " + f, "%s is the new version" % f)
	_check(fs.files.get(I + "/pk2/Data.pk2") == "the player's own data", "the player's pk2 is untouched")
	_check(not fs.files.has(I + "/pk2/PUT_YOUR_PK2_FILES_HERE.txt"), "nothing is written into pk2/")
	_check(fs.files.get(I + "/" + DLL + ".old-update") == "old " + DLL, "the loaded DLL was moved aside, not overwritten")
	_check(fs.locks.get(I + "/" + DLL + ".old-update") == "image" and not fs.locks.has(I + "/" + DLL),
		"the new DLL is not the locked file; the lock stayed with the old one")
	_check(Array(out.pending_cleanup) == [I + "/" + DLL + ".old-update", I + "/" + EXE + ".old-update"],
		"the two in-use originals wait for the next start (got %s)" % [out.pending_cleanup])
	_check(not fs.files.has(I + "/srrevamp.pck.old-update") and not fs.files.has(I + "/README.md.old-update"),
		"originals nothing holds are deleted at once")
	_check(fs.slept_ms == 0, "no retry was needed")
	# The game exits; the next start cleans up.
	fs.locks.clear()
	var lines := inst.cleanup(I)
	_check(not fs.files.has(I + "/" + DLL + ".old-update") and not fs.files.has(I + "/" + EXE + ".old-update"),
		"the next start deletes the moved-aside exe and DLL (%s)" % [lines])
	_check(not fs.files.has(I + "/" + UpdateInstaller.CLEANUP_LIST), "and then removes its list")

func _test_dll_renamed_off() -> void:
	print("-- the fallback test: srrevamp_native.dll renamed to .dll.off, then an update")
	var fs := _windows_world()
	fs.locks.erase(I + "/" + DLL)
	fs.files[I + "/" + DLL + ".off"] = fs.files[I + "/" + DLL]
	fs.files.erase(I + "/" + DLL)
	var out: Dictionary = _run(fs)[1]
	_check(out.ok and fs.files.get(I + "/" + DLL) == "new " + DLL, "the update puts srrevamp_native.dll back")
	_check(fs.files.get(I + "/" + DLL + ".off") == "old " + DLL, "the renamed .off copy is left as it was")

func _test_dll_quarantined_in_staging() -> void:
	print("-- antivirus removed the new DLL from the staging folder")
	var fs := _windows_world()
	fs.files.erase(S + "/" + DLL)
	var out: Dictionary = _run(fs)[1]
	_check(out.ok, "the rest of the update still installs")
	_check(Array(out.failed) == [DLL], "the DLL is reported as not installed (got %s)" % [out.failed])
	_check(fs.files.get(I + "/" + DLL) == "old " + DLL, "the previous DLL stays in place")
	_check(fs.files.get(I + "/" + EXE) == "new " + EXE and fs.files.get(I + "/srrevamp.pck") == "new srrevamp.pck",
		"the exe and the .pck are the new version")

func _test_dll_blocked_on_install() -> void:
	print("-- antivirus quarantines the new DLL as it is moved into place")
	var fs := _windows_world()
	fs.quarantine["new " + DLL] = true
	var out: Dictionary = _run(fs)[1]
	_check(out.ok and Array(out.failed) == [DLL], "the update carries on without the DLL")
	_check(fs.files.get(I + "/" + DLL) == "old " + DLL and not fs.files.has(I + "/" + DLL + ".old-update"),
		"the previous DLL is moved back under its own name")
	_check(fs.files.get(I + "/" + EXE) == "new " + EXE, "the exe is still the new version")

func _test_pck_held_open_rolls_back() -> void:
	print("-- the .pck is held open: nothing changes")
	var fs := _windows_world()
	fs.locks[I + "/srrevamp.pck"] = "open"
	var out: Dictionary = _run(fs)[1]
	_check(not out.ok, "the update reports failure")
	for f in FILES:
		if f.begins_with("pk2/"):
			continue
		_check(fs.files.get(I + "/" + f) == "old " + f, "%s is the old version again" % f)
	_check(not fs.files.keys().any(func(k): return str(k).contains(".old-update")), "no moved-aside file is left behind")
	_check(fs.slept_ms <= UpdateInstaller.RETRIES * UpdateInstaller.RETRY_MS,
		"a stuck file costs at most %d ms of retries (%d)" % [UpdateInstaller.RETRIES * UpdateInstaller.RETRY_MS, fs.slept_ms])

func _test_exe_blocked_rolls_back() -> void:
	print("-- antivirus blocks the new exe: nothing changes")
	var fs := _windows_world()
	fs.quarantine["new " + EXE] = true
	var out: Dictionary = _run(fs)[1]
	_check(not out.ok, "the update reports failure")
	_check(fs.files.get(I + "/" + EXE) == "old " + EXE and fs.locks.get(I + "/" + EXE) == "image",
		"the running exe is back under its own name")
	_check(fs.files.get(I + "/" + DLL) == "old " + DLL, "the DLL installed before it is put back too")

func _test_transient_lock_retried() -> void:
	print("-- the old DLL is busy for two tries (antivirus scanning)")
	var fs := _windows_world()
	fs.locks[I + "/" + DLL] = "busy:2"
	var out: Dictionary = _run(fs)[1]
	_check(out.ok and fs.files.get(I + "/" + DLL) == "new " + DLL, "the retry gets it")
	_check(fs.slept_ms == 2 * UpdateInstaller.RETRY_MS, "after two short waits (%d ms)" % fs.slept_ms)

func _test_previous_aside_still_locked() -> void:
	print("-- an earlier update's moved-aside DLL is still in use")
	var fs := _windows_world()
	fs.files[I + "/" + DLL + ".old-update"] = "older " + DLL
	fs.locks[I + "/" + DLL + ".old-update"] = "image"
	var out: Dictionary = _run(fs)[1]
	_check(out.ok and fs.files.get(I + "/" + DLL) == "new " + DLL, "the DLL is still replaced")
	_check(fs.files.get(I + "/" + DLL + ".old-update-1") == "old " + DLL, "under the next free aside name")

func _test_linux_semantics() -> void:
	print("-- Linux: nothing is locked; the exe keeps its x bit")
	var fs := _windows_world()
	fs.windows = false
	fs.perms[I + "/" + EXE] = 493
	var out: Dictionary = _run(fs)[1]
	_check(out.ok and fs.files.get(I + "/" + DLL) == "new " + DLL, "installs")
	_check(Array(out.pending_cleanup).is_empty() and not fs.files.keys().any(func(k): return str(k).contains(".old-update")),
		"every original is deleted at once")
	_check(int(fs.perms.get(I + "/" + EXE, 0)) & 73 == 73, "the new executable is executable (%o)" % int(fs.perms.get(I + "/" + EXE, 0)))

func _test_relaunch_scripts() -> void:
	var bat := AutoUpdater.windows_relaunch_script(4242, "C:/Games/srrevamp/srrevamp.exe")
	_check(bat.contains("tasklist /FI \"PID eq 4242\""), "the Windows relaunch polls the old process by its PID")
	_check(not bat.contains("timeout") and not bat.contains("robocopy"), "with no `timeout` and no robocopy")
	_check(bat.contains("if %n% GEQ 60 goto start"), "and gives up waiting after 60 polls")
	_check(bat.contains("start \"\" /D \"C:\\Games\\srrevamp\" \"C:\\Games\\srrevamp\\srrevamp.exe\""), "then starts the exe from its folder")
	var args := AutoUpdater.linux_relaunch_args(4242, "/home/a b/srrevamp.x86_64")
	_check(args[0] == "-c" and args[3] == "4242" and args[4] == "/home/a b/srrevamp.x86_64" and not args[1].contains("a b"),
		"the Linux relaunch passes the PID and path as parameters, not spliced into the script")
	_check(not args[1].contains("--exclude"), "and has no cp --exclude")

func _test_digest() -> void:
	var assets := [{"name": "srrevamp-windows.zip", "digest": "sha256:47015B26D5C7CCBF8D74A2BFC867BA9852A048C6CD237D16183E3148A881C838"},
		{"name": "srrevamp-linux.zip"}]
	var d := UpdateChecker.find_asset_digest(assets, "srrevamp-windows.zip")
	_check(d == "47015b26d5c7ccbf8d74a2bfc867ba9852a048c6cd237d16183e3148a881c838", "reads the asset's sha256 digest")
	_check(UpdateChecker.find_asset_digest(assets, "srrevamp-linux.zip") == "", "an asset without one gives none")
	_check(UpdateChecker.digest_problem(d, d) == "", "a matching download passes")
	_check(UpdateChecker.digest_problem("00" + d.substr(2), d) != "", "a different download is refused")

## The real DirAccess/FileAccess on this machine (Linux on the box and CI).
func _test_real_filesystem() -> void:
	print("-- the real filesystem")
	var root := OS.get_user_data_dir().path_join("update_installer_test")
	AutoUpdater.remove_tree(root)
	var inst_dir := root.path_join("install")
	var staged := root.path_join("staging/srrevamp-linux")
	DirAccess.make_dir_recursive_absolute(inst_dir.path_join("pk2"))
	DirAccess.make_dir_recursive_absolute(staged.path_join("docs"))
	var put := func(p: String, t: String) -> void:
		var f := FileAccess.open(p, FileAccess.WRITE)
		f.store_string(t)
		f.close()
	put.call(inst_dir.path_join("game.x86_64"), "old exe")
	FileAccess.set_unix_permissions(inst_dir.path_join("game.x86_64"), 493)
	put.call(inst_dir.path_join("libsrrevamp_native.so"), "old so")
	put.call(inst_dir.path_join("pk2/Data.pk2"), "data")
	put.call(staged.path_join("game.x86_64"), "new exe")
	put.call(staged.path_join("game.pck"), "new pck")
	put.call(staged.path_join("libsrrevamp_native.so"), "new so")
	put.call(staged.path_join("docs/a.md"), "doc")
	var inst := UpdateInstaller.new()
	var out := inst.install(staged, inst_dir, AutoUpdater.list_files(staged), "game.x86_64")
	_check(out.ok, "installs on the real filesystem")
	_check(FileAccess.get_file_as_string(inst_dir.path_join("libsrrevamp_native.so")) == "new so"
		and FileAccess.get_file_as_string(inst_dir.path_join("game.pck")) == "new pck"
		and FileAccess.get_file_as_string(inst_dir.path_join("docs/a.md")) == "doc", "every file is the new one, subfolders too")
	_check(int(FileAccess.get_unix_permissions(inst_dir.path_join("game.x86_64"))) & 73 == 73, "the executable stays executable")
	_check(FileAccess.get_file_as_string(inst_dir.path_join("pk2/Data.pk2")) == "data", "pk2 untouched")
	_check(not FileAccess.file_exists(inst_dir.path_join("libsrrevamp_native.so.old-update")), "no leftovers on Linux")
	AutoUpdater.remove_tree(root)
