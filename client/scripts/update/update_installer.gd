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
## on Windows (cleanup(), which finds them by name). srrevamp_native.dll is loaded by this very process,
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
## Round 668's first cut listed the moved-aside files here; cleanup() now finds
## them by name instead (the review's L2: a run killed mid-install never wrote
## the list). An old list is still read and removed.
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
	if not _retry(func() -> bool: return fs.rename(src, dst)) and not _copy_whole(src, dst):
		if fs.exists(dst):
			fs.remove(dst)
		if r.aside != "":
			_restore(r.aside, dst)
		r.error = "could not be written whole (blocked by antivirus, or the disk is full?)"
		return r
	if executable:
		perms = (perms if perms >= 0 else 420) | 73  # 0644 | 0111: rwx for everyone who could read it
	fs.set_permissions(dst, perms)
	return r

## The copy fallback, with the length read back: a copy onto a full disk can
## end short without an error reaching GDScript (UpdateStager's header).
func _copy_whole(src: String, dst: String) -> bool:
	if not fs.copy(src, dst):
		return false
	var want := fs.size(src)
	return want >= 0 and fs.size(dst) == want

## Puts a moved-aside original back under its own name, retried like every
## other step; a failure is logged loudly, naming where the original is.
func _restore(aside: String, dst: String) -> bool:
	if fs.exists(dst):
		fs.remove(dst)
	if _retry(func() -> bool: return fs.rename(aside, dst)):
		lines.append("put back %s" % dst.get_file())
		return true
	lines.append("COULD NOT PUT BACK %s: the previous version is still at %s -- rename it back by hand if the game does not start" % [dst.get_file(), aside])
	return false

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
		if r.aside != "":
			_restore(r.aside, r.dst)
		else:
			fs.remove(r.dst)

## At startup: every "<name>.old-update[-N]" under install_dir (pk2/ aside)
## is a previous update's leftover. If <name> itself is missing -- a run
## killed between its two renames -- the leftover is put back; otherwise it is
## deleted (its process has exited by now; a still-locked one waits for the
## next start). Only names carrying ASIDE_SUFFIX are ever deleted. Returns log
## lines. A missing exe or .pck cannot be repaired this way, since the game
## needs them to start at all: docs/NATIVE_ON_WINDOWS.md says how by hand.
func cleanup(install_dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	var list := install_dir.path_join(CLEANUP_LIST)
	if fs.exists(list):
		fs.remove(list)
	var asides: Array[String] = []
	for rel in fs.list_files(install_dir):
		if not (rel == "pk2" or rel.begins_with("pk2/")) and rel.get_file().contains(ASIDE_SUFFIX):
			asides.append(rel)
	# Newest aside first: "x.old-update-1" was made after "x.old-update" (which
	# was still locked then), so it is the one to put back.
	asides.sort()
	asides.reverse()
	for rel in asides:
		var path := install_dir.path_join(rel)
		var original := path.substr(0, path.rfind(ASIDE_SUFFIX))
		if not fs.exists(original):
			if _retry(func() -> bool: return fs.rename(path, original)):
				out.append("put back %s from %s: an update was interrupted" % [original.get_file(), rel.get_file()])
			else:
				out.append("COULD NOT PUT BACK %s from %s" % [original.get_file(), rel.get_file()])
		elif fs.remove(path):
			out.append("removed %s, left over from the last update" % rel.get_file())
		else:
			out.append("%s is still in use; trying again next start" % rel.get_file())
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
