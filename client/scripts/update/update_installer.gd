extends RefCounted
class_name UpdateInstaller

## Puts a downloaded update's files over the install, from INSIDE the running
## game, before it relaunches itself (round 668; docs/NATIVE_ON_WINDOWS.md).
##
## Why in-process, and why "move aside": Windows will not let a running .exe
## or a loaded .dll be overwritten or deleted, but it does let one be RENAMED
## -- the loader maps the file with FILE_SHARE_DELETE (the standard Windows
## self-update technique; INFERRED from Windows' documented sharing rules, not
## run on Windows here). So for each file: move the current one aside to
## "<name>.old-update", move the new one into its place, and delete the old
## one when nothing holds it any more -- at once on Linux, on the next launch
## on Windows (cleanup()). srrevamp_native.dll is loaded by this very process,
## so it is exactly that case. On Linux a rename gives the new file a new
## inode and the running process keeps the old one mapped.
##
## The rules:
## - every rename and copy is retried a bounded number of times (RETRIES x
##   RETRY_MS, 1 s at most per step), so one stuck file can never hang the
##   update;
## - the executable and the .pck are critical: if either cannot be installed,
##   every file installed so far is put back and the update reports failure,
##   so the old version still starts;
## - any other file (the native library included) failing is logged and
##   skipped, with its previous version restored. A missing or refused native
##   library only means the GDScript readers run (NativeAssets);
## - files the new version does not have are left alone, and so is "pk2/".

const ASIDE_SUFFIX := ".old-update"
## Moved-aside files that could not be deleted yet, one absolute path a line,
## next to the executable. cleanup() works through it at the next start.
const CLEANUP_LIST := "srrevamp_update_cleanup.txt"
## What the last update did, next to the executable: written by the old
## process, printed into the new process's log by take_summary() and removed,
## so a tester's log of the first run after an update says what happened.
const SUMMARY_FILE := "srrevamp_update.log"
const NATIVE_LIBRARIES := ["srrevamp_native.dll", "libsrrevamp_native.so"]
## Names the updater itself makes; never installed, never overwritten.
const OWN_FILES := ["srrevamp_update.zip", "srrevamp_update_relaunch.bat", CLEANUP_LIST, SUMMARY_FILE]
const RETRIES := 5
const RETRY_MS := 200

var fs: UpdateFs
## Human-readable outcome lines, in order, for the log.
var lines := PackedStringArray()

func _init(p_fs: UpdateFs = null) -> void:
	fs = p_fs if p_fs != null else UpdateFs.new()

static func is_native_library(rel: String) -> bool:
	return rel.get_file() in NATIVE_LIBRARIES

static func is_critical(rel: String, exe_rel: String) -> bool:
	return rel == exe_rel or rel.get_extension().to_lower() == "pck"

static func is_skipped(rel: String) -> bool:
	return rel == "pk2" or rel.begins_with("pk2/") or rel in OWN_FILES or rel.get_file().contains(ASIDE_SUFFIX)

## Everything else first, then the native library, then the executable, the
## .pck last: the files most likely to be in use go last, and the .pck is
## the one the running game still reads by name.
static func install_order(files: PackedStringArray, exe_rel: String) -> PackedStringArray:
	var rest: Array[String] = []
	var native: Array[String] = []
	var exe: Array[String] = []
	var pck: Array[String] = []
	for rel in files:
		if is_skipped(rel):
			continue
		if rel == exe_rel:
			exe.append(rel)
		elif rel.get_extension().to_lower() == "pck":
			pck.append(rel)
		elif is_native_library(rel):
			native.append(rel)
		else:
			rest.append(rel)
	rest.sort()
	var out := PackedStringArray(rest)
	out.append_array(PackedStringArray(native))
	out.append_array(PackedStringArray(exe))
	out.append_array(PackedStringArray(pck))
	return out

## Installs `files` (paths relative to staged_root, "/"-separated) into
## install_dir. Returns {ok, reason, failed, pending_cleanup}.
func install(staged_root: String, install_dir: String, files: PackedStringArray, exe_rel: String) -> Dictionary:
	var done: Array[Dictionary] = []
	var failed := PackedStringArray()
	for rel in install_order(files, exe_rel):
		var r := _put(staged_root.path_join(rel), install_dir.path_join(rel), rel == exe_rel)
		if r.error == "":
			done.append(r)
			lines.append("installed %s%s" % [rel, r.note])
			continue
		if is_critical(rel, exe_rel):
			lines.append("could not install %s: %s -- putting back the %d file(s) already installed" % [rel, r.error, done.size()])
			_rollback(done)
			return {"ok": false, "reason": "%s %s" % [rel, r.error], "failed": PackedStringArray([rel]), "pending_cleanup": PackedStringArray()}
		failed.append(rel)
		if is_native_library(rel):
			lines.append("NOT installed %s: %s -- kept the previous one; the client checks it at startup and uses the GDScript readers if it cannot use it" % [rel, r.error])
		else:
			lines.append("NOT installed %s: %s -- kept the previous one" % [rel, r.error])
	var pending := PackedStringArray()
	for r in done:
		if r.aside != "" and not fs.remove(r.aside):
			pending.append(r.aside)
			lines.append("%s is still in use; it is deleted at the next start" % r.aside.get_file())
	_add_to_cleanup_list(install_dir, pending)
	return {"ok": true, "reason": "", "failed": failed, "pending_cleanup": pending}

## One file. Returns {error ("" on success), dst, aside, created, note}.
func _put(src: String, dst: String, executable: bool) -> Dictionary:
	var r := {"error": "", "dst": dst, "aside": "", "note": ""}
	if not fs.exists(src):
		r.error = "missing from the downloaded update (removed by antivirus?)"
		return r
	fs.make_dir(dst.get_base_dir())
	var perms := -1
	if fs.exists(dst):
		perms = fs.permissions(dst)
		var aside := _free_aside_name(dst)
		if aside == "":
			r.error = "no free name to move the old file aside"
			return r
		if not _retry(func() -> bool: return fs.rename(dst, aside)):
			r.error = "in use, and could not be moved aside"
			return r
		r.aside = aside
		r.note = " (the old one was moved aside to %s)" % aside.get_file()
	if not _retry(func() -> bool: return fs.rename(src, dst)) and not fs.copy(src, dst):
		if fs.exists(dst):
			fs.remove(dst)
		if r.aside != "":
			fs.rename(r.aside, dst)
		r.error = "could not be written (blocked by antivirus?)"
		return r
	if executable:
		perms = (perms if perms >= 0 else 420) | 73  # 0644 | 0111: rwx for everyone who could read it
	fs.set_permissions(dst, perms)
	return r

func _free_aside_name(dst: String) -> String:
	for i in range(10):
		var name := dst + ASIDE_SUFFIX + ("" if i == 0 else "-%d" % i)
		if not fs.exists(name) or fs.remove(name):
			return name
	return ""

func _retry(step: Callable) -> bool:
	for i in range(RETRIES):
		if step.call():
			return true
		if i < RETRIES - 1:
			fs.sleep_ms(RETRY_MS)
	return false

func _rollback(done: Array[Dictionary]) -> void:
	for i in range(done.size() - 1, -1, -1):
		var r: Dictionary = done[i]
		fs.remove(r.dst)
		if r.aside != "":
			if fs.rename(r.aside, r.dst):
				lines.append("put back %s" % r.dst.get_file())
			else:
				lines.append("could NOT put back %s (the old copy is %s)" % [r.dst.get_file(), r.aside.get_file()])

func _add_to_cleanup_list(install_dir: String, paths: PackedStringArray) -> void:
	if paths.is_empty():
		return
	var list := install_dir.path_join(CLEANUP_LIST)
	var existing := fs.read_text(list).strip_edges()
	var text := (existing + "\n" if existing != "" else "") + "\n".join(paths)
	fs.write_text(list, text + "\n")

## At startup: delete the moved-aside files a previous update could not
## (their process has exited by now). Only names inside install_dir carrying
## ASIDE_SUFFIX are ever deleted. Returns log lines.
func cleanup(install_dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	var list := install_dir.path_join(CLEANUP_LIST)
	if not fs.exists(list):
		return out
	var left := PackedStringArray()
	for line in fs.read_text(list).split("\n", false):
		var path := line.strip_edges()
		if path == "" or not path.begins_with(install_dir) or not path.get_file().contains(ASIDE_SUFFIX):
			continue
		if not fs.exists(path) or fs.remove(path):
			out.append("removed %s, left over from the last update" % path.get_file())
		else:
			left.append(path)
			out.append("%s is still in use; trying again next start" % path.get_file())
	if left.is_empty():
		fs.remove(list)
	else:
		fs.write_text(list, "\n".join(left) + "\n")
	return out

func write_summary(install_dir: String, summary: PackedStringArray) -> void:
	fs.write_text(install_dir.path_join(SUMMARY_FILE), "\n".join(summary) + "\n")

## The last update's summary, once: read and removed.
func take_summary(install_dir: String) -> PackedStringArray:
	var path := install_dir.path_join(SUMMARY_FILE)
	if not fs.exists(path):
		return PackedStringArray()
	var text := fs.read_text(path)
	fs.remove(path)
	return text.split("\n", false)
