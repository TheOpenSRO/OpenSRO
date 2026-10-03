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
	## Bytes the disk can still take (-1: unlimited). A write or copy that does
	## not fit is cut short, and reports nothing -- like store_buffer.
	var capacity := -1
	## What space_left() answers (-1: report capacity, or a lot).
	var reported_space := -1
	## A copy that silently ends short (a full disk under the copy fallback).
	var short_copies := false

	func _used() -> int:
		var n := 0
		for k in files:
			n += _len(files[k])
		return n

	static func _len(v) -> int:
		return v.size() if v is PackedByteArray else str(v).length()

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
		var v = files[from]
		if short_copies:
			v = str(v).substr(0, maxi(0, _len(v) / 2))
		files[to] = v
		return true

	func size(path: String) -> int:
		return _len(files[path]) if files.has(path) else -1

	func space_left(_dir: String) -> int:
		if reported_space >= 0:
			return reported_space
		return 1 << 40 if capacity < 0 else maxi(0, capacity - _used())

	func write_file(path: String, data: PackedByteArray) -> bool:
		if quarantine.has(data.get_string_from_utf8()):
			return false
		var room := data.size() if capacity < 0 else mini(data.size(), maxi(0, capacity - _used()))
		files[path] = data.slice(0, room)
		return true  # like store_buffer: a short write reports nothing

	func remove_tree(path: String) -> void:
		for k in files.keys():
			if str(k).begins_with(path + "/"):
				files.erase(k)

	func list_files(root: String, _prefix: String = "") -> PackedStringArray:
		var out := PackedStringArray()
		for k in files:
			if str(k).begins_with(root + "/"):
				out.append(str(k).substr(root.length() + 1))
		return out

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

const I := "C:/Games/opensro"
const S := "C:/Games/opensro/opensro_update_staging/opensro-windows"
const EXE := "OpenSRO.exe"
const DLL := "opensro_native.dll"
const FILES := ["OpenSRO.exe", "OpenSRO.console.exe", "OpenSRO.pck", "opensro_native.dll",
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
	_test_relaunch_unicode_and_specials()
	_test_copy_fallback_short()
	_test_restore_retried()
	_test_cleanup_scan()
	_test_stage()
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
	_check(order[order.size() - 1] == "OpenSRO.pck" and order[order.size() - 2] == EXE and order[order.size() - 3] == DLL,
		"the native library, then the exe, then the .pck go last (got %s)" % [order])
	_check(not UpdateInstaller.install_order(PackedStringArray(["opensro_native.dll.old-update", "opensro_update.log"]), EXE).size(),
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
	_check(not fs.files.has(I + "/OpenSRO.pck.old-update") and not fs.files.has(I + "/README.md.old-update"),
		"originals nothing holds are deleted at once")
	_check(fs.slept_ms == 0, "no retry was needed")
	# The game exits; the next start cleans up.
	fs.locks.clear()
	var lines := inst.cleanup(I)
	_check(not fs.files.has(I + "/" + DLL + ".old-update") and not fs.files.has(I + "/" + EXE + ".old-update"),
		"the next start deletes the moved-aside exe and DLL (%s)" % [lines])
	_check(not fs.files.keys().any(func(k): return str(k).contains(".old-update")), "and nothing is left over")

func _test_dll_renamed_off() -> void:
	print("-- the fallback test: opensro_native.dll renamed to .dll.off, then an update")
	var fs := _windows_world()
	fs.locks.erase(I + "/" + DLL)
	fs.files[I + "/" + DLL + ".off"] = fs.files[I + "/" + DLL]
	fs.files.erase(I + "/" + DLL)
	var out: Dictionary = _run(fs)[1]
	_check(out.ok and fs.files.get(I + "/" + DLL) == "new " + DLL, "the update puts opensro_native.dll back")
	_check(fs.files.get(I + "/" + DLL + ".off") == "old " + DLL, "the renamed .off copy is left as it was")

func _test_dll_quarantined_in_staging() -> void:
	print("-- antivirus removed the new DLL from the staging folder")
	var fs := _windows_world()
	fs.files.erase(S + "/" + DLL)
	var out: Dictionary = _run(fs)[1]
	_check(out.ok, "the rest of the update still installs")
	_check(Array(out.failed) == [DLL], "the DLL is reported as not installed (got %s)" % [out.failed])
	_check(fs.files.get(I + "/" + DLL) == "old " + DLL, "the previous DLL stays in place")
	_check(fs.files.get(I + "/" + EXE) == "new " + EXE and fs.files.get(I + "/OpenSRO.pck") == "new OpenSRO.pck",
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
	fs.locks[I + "/OpenSRO.pck"] = "open"
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
	var bat := AutoUpdater.windows_relaunch_script(4242, "C:/Games/opensro/OpenSRO.exe")
	_check(bat.contains("tasklist /FI \"PID eq 4242\""), "the Windows relaunch polls the old process by its PID")
	_check(not bat.contains("timeout") and not bat.contains("robocopy"), "with no `timeout` and no robocopy")
	_check(bat.contains("if %n% GEQ 60 goto start"), "and gives up waiting after 60 polls")
	_check(bat.contains("start \"\" /D \"%~dp0.\" \"%~dp0OpenSRO.exe\""), "then starts the exe from the script's own folder")
	var args := AutoUpdater.linux_relaunch_args(4242, "/home/a b/OpenSRO.x86_64")
	_check(args[0] == "-c" and args[3] == "4242" and args[4] == "/home/a b/OpenSRO.x86_64" and not args[1].contains("a b"),
		"the Linux relaunch passes the PID and path as parameters, not spliced into the script")
	_check(not args[1].contains("--exclude"), "and has no cp --exclude")

func _test_digest() -> void:
	var assets := [{"name": "opensro-windows.zip", "digest": "sha256:47015B26D5C7CCBF8D74A2BFC867BA9852A048C6CD237D16183E3148A881C838"},
		{"name": "opensro-linux.zip"}]
	var d := UpdateChecker.find_asset_digest(assets, "opensro-windows.zip")
	_check(d == "47015b26d5c7ccbf8d74a2bfc867ba9852a048c6cd237d16183e3148a881c838", "reads the asset's sha256 digest")
	_check(UpdateChecker.find_asset_digest(assets, "opensro-linux.zip") == "", "an asset without one gives none")
	_check(UpdateChecker.digest_problem(d, d) == "", "a matching download passes")
	_check(UpdateChecker.digest_problem("00" + d.substr(2), d) != "", "a different download is refused")

## The real DirAccess/FileAccess on this machine (Linux on the box and CI).
func _test_real_filesystem() -> void:
	print("-- the real filesystem")
	var root := OS.get_user_data_dir().path_join("update_installer_test")
	AutoUpdater.remove_tree(root)
	var inst_dir := root.path_join("install")
	var staged := root.path_join("staging/opensro-linux")
	DirAccess.make_dir_recursive_absolute(inst_dir.path_join("pk2"))
	DirAccess.make_dir_recursive_absolute(staged.path_join("docs"))
	var put := func(p: String, t: String) -> void:
		var f := FileAccess.open(p, FileAccess.WRITE)
		f.store_string(t)
		f.close()
	put.call(inst_dir.path_join("game.x86_64"), "old exe")
	FileAccess.set_unix_permissions(inst_dir.path_join("game.x86_64"), 493)
	put.call(inst_dir.path_join("libopensro_native.so"), "old so")
	put.call(inst_dir.path_join("pk2/Data.pk2"), "data")
	put.call(staged.path_join("game.x86_64"), "new exe")
	put.call(staged.path_join("game.pck"), "new pck")
	put.call(staged.path_join("libopensro_native.so"), "new so")
	put.call(staged.path_join("docs/a.md"), "doc")
	var inst := UpdateInstaller.new()
	var out := inst.install(staged, inst_dir, AutoUpdater.list_files(staged), "game.x86_64")
	_check(out.ok, "installs on the real filesystem")
	_check(FileAccess.get_file_as_string(inst_dir.path_join("libopensro_native.so")) == "new so"
		and FileAccess.get_file_as_string(inst_dir.path_join("game.pck")) == "new pck"
		and FileAccess.get_file_as_string(inst_dir.path_join("docs/a.md")) == "doc", "every file is the new one, subfolders too")
	_check(int(FileAccess.get_unix_permissions(inst_dir.path_join("game.x86_64"))) & 73 == 73, "the executable stays executable")
	_check(FileAccess.get_file_as_string(inst_dir.path_join("pk2/Data.pk2")) == "data", "pk2 untouched")
	_check(not FileAccess.file_exists(inst_dir.path_join("libopensro_native.so.old-update")), "no leftovers on Linux")
	AutoUpdater.remove_tree(root)

## The review's M2/L3/L4: the batch file must hold no install path (cmd reads
## it in the OEM code page), must match the quoted PID, and must reach cmd
## intact whatever the path holds.
func _test_relaunch_unicode_and_specials() -> void:
	var exe := "C:/Users/José/Games (x) & y/OpenSRO.exe"
	var bat := AutoUpdater.windows_relaunch_script(4242, exe)
	_check(not bat.contains("José") and not bat.contains("Games (x)"), "the batch file holds no install path")
	var ascii := true
	for i in range(bat.length()):
		ascii = ascii and bat.unicode_at(i) < 127
	_check(ascii, "the batch file is plain ASCII, so the OEM code page cannot mangle it")
	_check(bat.contains("find \"\"\"4242\"\"\""), "it matches the quoted PID, not any comma")
	_check(AutoUpdater.windows_relaunch_script(1, "C:/G/jogo-ação.exe").contains("%~dp0OpenSRO.exe"),
		"a non-ASCII executable name falls back to OpenSRO.exe")
	var args := AutoUpdater.windows_relaunch_args("C:/Users/José/Games (x) & y/opensro_update_relaunch.bat")
	_check(args.size() == 4 and args[2] == "/C" and args[1] == "/S" and args[3] == "\"C:\\Users\\José\\Games (x) & y\\opensro_update_relaunch.bat\"",
		"cmd gets /S /C and the path in its own quotes (got %s)" % [args])

## The review's H1, in the installer: the copy fallback ending short.
func _test_copy_fallback_short() -> void:
	print("-- the copy fallback ends short (disk full)")
	var fs := _windows_world()
	fs.locks[S + "/" + DLL] = "open"  # the staged DLL cannot be renamed, so it is copied
	fs.short_copies = true
	var out: Dictionary = _run(fs)[1]
	_check(out.ok and Array(out.failed) == [DLL], "a short copy is a failure, not an install")
	_check(fs.files.get(I + "/" + DLL) == "old " + DLL, "and the previous DLL is back")

## The review's L1: putting an original back is retried like every step.
func _test_restore_retried() -> void:
	print("-- putting the old DLL back meets a transient lock")
	var fs2 := FakeFs.new()
	fs2.files["C:/g/a.dll.old-update"] = "old"
	fs2.locks["C:/g/a.dll.old-update"] = "busy:2"
	var inst2 := UpdateInstaller.new(fs2)
	_check(inst2._restore("C:/g/a.dll.old-update", "C:/g/a.dll") and fs2.files.get("C:/g/a.dll") == "old",
		"a moved-aside original busy for two tries is still put back")
	var fs3 := FakeFs.new()
	fs3.files["C:/g/a.dll.old-update"] = "old"
	fs3.locks["C:/g/a.dll.old-update"] = "open"
	var inst3 := UpdateInstaller.new(fs3)
	_check(not inst3._restore("C:/g/a.dll.old-update", "C:/g/a.dll") and inst3.lines[-1].begins_with("COULD NOT PUT BACK a.dll"),
		"one that never lets go is reported loudly, naming where the original is")

## The review's L2: leftovers are found by name, and a missing original is put back.
func _test_cleanup_scan() -> void:
	print("-- leftovers from an interrupted update")
	var fs := FakeFs.new()
	fs.files[I + "/README.md"] = "new"
	fs.files[I + "/README.md.old-update"] = "old"
	fs.files[I + "/" + DLL + ".old-update"] = "older"
	fs.files[I + "/" + DLL + ".old-update-1"] = "old"
	fs.files[I + "/docs/a.md.old-update"] = "old doc"
	fs.files[I + "/pk2/Data.pk2.old-update"] = "the player's own"
	var lines := UpdateInstaller.new(fs).cleanup(I)
	for l in lines:
		print("    | " + l)
	_check(not fs.files.has(I + "/README.md.old-update") and fs.files.get(I + "/README.md") == "new", "a leftover beside its file is deleted")
	_check(fs.files.get(I + "/" + DLL) == "old", "a file killed between its two renames is put back, from the newest aside")
	_check(fs.files.get(I + "/docs/a.md") == "old doc", "in subfolders too")
	_check(fs.files.has(I + "/pk2/Data.pk2.old-update"), "pk2/ is never touched")

## The review's H1: nothing is installed unless every file was unpacked whole.
func _test_stage() -> void:
	print("-- unpacking: free space, short writes, damaged entries")
	var root := OS.get_user_data_dir().path_join("update_stager_test")
	UpdateFs.new().remove_tree(root)
	DirAccess.make_dir_recursive_absolute(root)
	var zip := root.path_join("u.zip")
	var packer := ZIPPacker.new()
	packer.open(zip)
	var payload := {"opensro-linux/OpenSRO.x86_64": "exe".repeat(4000), "opensro-linux/OpenSRO.pck": "pck".repeat(3000),
		"opensro-linux/libopensro_native.so": "lib".repeat(2000), "opensro-linux/docs/a.md": "doc"}
	for name in payload:
		packer.start_file(name)
		packer.write_file(payload[name].to_utf8_buffer())
		packer.close_file()
	packer.close()
	var sizes := UpdateStager.zip_entry_sizes(zip)
	_check(sizes.size() == 4 and int(sizes["opensro-linux/OpenSRO.x86_64"]) == 12000, "the central directory gives every entry's size (%s)" % [sizes])
	var total := 12000 + 9000 + 6000 + 3

	# Real filesystem, enough room.
	var st := UpdateStager.new()
	var out := st.stage(zip, root.path_join("staging"), root)
	_check(out.ok and FileAccess.get_file_as_string(root.path_join("staging/opensro-linux/OpenSRO.pck")) == payload["opensro-linux/OpenSRO.pck"],
		"a whole archive is unpacked (%s)" % out.reason)

	# Not enough room: refused before writing anything.
	var fs := FakeFs.new()
	fs.reported_space = total + UpdateStager.SPACE_MARGIN - 1
	var st2 := UpdateStager.new(fs)
	out = st2.stage(zip, "/x/staging", "/x")
	_check(not out.ok and out.reason.begins_with("not enough disk space") and fs.files.is_empty(), "too little free space is refused up front: " + out.reason)

	# The disk fills mid-way (the free-space answer was wrong, or someone else
	# wrote meanwhile): the short write is caught and the staging folder goes.
	fs = FakeFs.new()
	fs.reported_space = 1 << 40
	fs.capacity = 15000
	var st3 := UpdateStager.new(fs)
	out = st3.stage(zip, "/x/staging", "/x")
	_check(not out.ok and out.reason.contains("whole") and fs.files.is_empty(),
		"a write the disk cut short is refused and nothing is left staged: " + out.reason)

	# A damaged entry: ZIPReader hands back an empty array on a CRC or zlib
	# error. Flip a byte inside the .pck entry's compressed data (past its
	# local header: 30 bytes, the name, the extra field).
	var bytes := FileAccess.get_file_as_bytes(zip)
	var name_at := _find_bytes(bytes, "opensro-linux/OpenSRO.pck".to_utf8_buffer())
	var data_at := name_at + "opensro-linux/OpenSRO.pck".length() + bytes.decode_u16(name_at - 2) + 2
	var corrupt := bytes.duplicate()
	corrupt[data_at] = corrupt[data_at] ^ 0x5A
	var bad := root.path_join("bad.zip")
	var w := FileAccess.open(bad, FileAccess.WRITE)
	w.store_buffer(corrupt)
	w.close()
	fs = FakeFs.new()
	var st4 := UpdateStager.new(fs)
	out = st4.stage(bad, "/x/staging", "/x")
	_check(not out.ok and out.reason.contains("OpenSRO.pck came out of the archive as"), "a damaged entry is refused: " + out.reason)

	# Antivirus refuses the new native library: the rest is still staged.
	fs = FakeFs.new()
	fs.quarantine[payload["opensro-linux/libopensro_native.so"]] = true
	var st5 := UpdateStager.new(fs)
	out = st5.stage(zip, "/x/staging", "/x")
	_check(out.ok and not fs.files.has("/x/staging/opensro-linux/libopensro_native.so") and fs.files.has("/x/staging/opensro-linux/OpenSRO.pck"),
		"a refused native library is skipped and the rest staged")
	UpdateFs.new().remove_tree(root)

static func _find_bytes(hay: PackedByteArray, needle: PackedByteArray) -> int:
	for i in range(hay.size() - needle.size() + 1):
		if hay[i] == needle[0] and hay.slice(i, i + needle.size()) == needle:
			return i
	return -1
