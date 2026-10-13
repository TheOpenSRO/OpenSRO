extends Node
class_name AutoUpdater

## The self-update flow (2026-08-26; rebuilt in round 668): ask this repo's
## GitHub Releases API for a newer tag than this build, download the matching
## platform zip, check it against the SHA-256 the release lists, install it
## over this install from inside the running game (UpdateInstaller: anything in
## use is renamed aside, never overwritten -- opensro_native.dll is loaded by
## this very process), then start the new executable once this process has
## exited, and quit.
##
## Before round 668 the zip was installed by a helper script after the game
## quit: `timeout /t 2` (which needs a console the helper, started with
## CREATE_NO_WINDOW, does not have) then robocopy with its default retry of
## 30 s x 1,000,000, so one file antivirus would not let go of could hold the
## update and the relaunch for ever; on Linux a `cp --exclude` GNU cp does not
## have. Both are gone.
##
## What is tested: UpdateInstaller's file operations against a filesystem that
## behaves like Windows (update_installer_test.gd), and the whole flow on Linux
## with a real exported build and a local release endpoint (round 668's
## WORLD_ISSUES entry). NOT tested: any of it on real Windows.

signal update_available(tag: String, download_url: String)
signal up_to_date
signal check_failed(reason: String)
signal download_progress(fraction: float)
signal update_failed(reason: String)

const RELEASES_API_URL := "https://api.github.com/repos/TheOpenSRO/OpenSRO/releases/latest"
## QA hook (round 668): a different "latest release" endpoint, so the whole
## update can be run against a local server. OURS.
const QA_URL_ENV := "OPENSRO_QA_UPDATE_URL"
const STAGING_DIR := "opensro_update_staging"
const RELAUNCH_BAT := "opensro_update_relaunch.bat"
## How long the relaunch waits for this process to exit before starting the
## new one anyway: 60 polls about a second apart. OURS.
const RELAUNCH_POLLS := 60

var _check_request: HTTPRequest
var _download_request: HTTPRequest
var _pending_asset_name := ""
var _pending_tag := ""
var _pending_digest := ""

func _ready() -> void:
	_check_request = HTTPRequest.new()
	add_child(_check_request)
	_check_request.request_completed.connect(_on_check_completed)

	_download_request = HTTPRequest.new()
	add_child(_download_request)
	_download_request.request_completed.connect(_on_download_completed)
	_download_request.download_file = _download_target_path()
	_download_request.request_completed.connect(func(_r, _c, _h, _b): download_progress.emit(1.0))

static func releases_url() -> String:
	var qa := OS.get_environment(QA_URL_ENV)
	return qa if qa != "" else RELEASES_API_URL

## Headers for a GitHub API/asset request; an Authorization header only when
## a release build embedded UpdateChecker.GITHUB_TOKEN.
static func _auth_headers(extra: Array[String] = []) -> PackedStringArray:
	var headers: Array[String] = ["User-Agent: opensro-client"]
	headers.append_array(extra)
	if UpdateChecker.GITHUB_TOKEN != "":
		headers.append("Authorization: Bearer %s" % UpdateChecker.GITHUB_TOKEN)
	return PackedStringArray(headers)

func check_for_update() -> void:
	var err := _check_request.request(releases_url(), _auth_headers())
	if err != OK:
		check_failed.emit("could not start request: %s" % err)

func _on_check_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		check_failed.emit("HTTP %d (result %d)" % [response_code, result])
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if parsed == null or not (parsed is Dictionary) or not parsed.has("tag_name"):
		check_failed.emit("unexpected response shape from the Releases API")
		return

	var tag: String = parsed["tag_name"]
	if not UpdateChecker.is_newer_version(UpdateChecker.CLIENT_VERSION, tag):
		up_to_date.emit()
		return

	var assets: Array = parsed.get("assets", [])
	var asset_name := UpdateChecker.asset_name_for_os(OS.get_name())
	if asset_name == "":
		check_failed.emit("no build published for this platform (%s)" % OS.get_name())
		return
	# A private repo's browser_download_url does not work unauthenticated; the
	# asset's API "url" (with Authorization and "Accept:
	# application/octet-stream", begin_download) does.
	var url := UpdateChecker.find_asset_api_url(assets, asset_name) if UpdateChecker.GITHUB_TOKEN != "" else ""
	if url == "":
		url = UpdateChecker.find_asset_url(assets, asset_name)
	if url == "":
		check_failed.emit("release %s has no %s asset" % [tag, asset_name])
		return

	_pending_asset_name = asset_name
	_pending_tag = tag
	_pending_digest = UpdateChecker.find_asset_digest(assets, asset_name)
	update_available.emit(tag, url)

func begin_download(download_url: String) -> void:
	_download_request.download_file = _download_target_path()
	var err := _download_request.request(download_url, _auth_headers(["Accept: application/octet-stream"]))
	if err != OK:
		update_failed.emit("could not start download: %s" % err)

func _on_download_completed(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		update_failed.emit("download HTTP %d (result %d)" % [response_code, result])
		return
	var zip_path := _download_target_path()
	var actual := FileAccess.get_sha256(zip_path)
	var problem := UpdateChecker.digest_problem(actual, _pending_digest)
	if problem != "":
		DirAccess.remove_absolute(zip_path)
		update_failed.emit("the download is damaged or not the release's file (%s)" % problem)
		return
	if _pending_digest == "":
		print("OpenSRO update: %s downloaded, NOT verified (the release lists no SHA-256), sha256 %s" % [_pending_asset_name, actual])
	else:
		print("OpenSRO update: %s downloaded and verified, sha256 %s" % [_pending_asset_name, actual])
	_apply_update(zip_path)

func _download_target_path() -> String:
	return _exe_dir().path_join("opensro_update.zip")

func _exe_dir() -> String:
	return OS.get_executable_path().get_base_dir()

## Extract into a staging folder next to the executable, install over the
## install (UpdateInstaller), then relaunch and quit -- or, if the executable
## or the .pck could not be installed, put everything back and carry on with
## this version.
func _apply_update(zip_path: String) -> void:
	# A run from the editor or a source checkout would "install" a release zip
	# over the Godot editor's own folder.
	if not OS.has_feature("template"):
		update_failed.emit("only an exported build can update itself")
		return
	# Read once, before anything is renamed: on Linux the path of a running
	# executable follows a rename (/proc/self/exe).
	var exe_path := OS.get_executable_path()
	var install_dir := exe_path.get_base_dir()
	var staging_dir := install_dir.path_join(STAGING_DIR)
	remove_tree(staging_dir)

	# Unpack and check every file whole BEFORE the install is touched
	# (UpdateStager; the review's H1: a full disk staged truncated files and
	# the installer then put them in place).
	var stager := UpdateStager.new()
	var staged := stager.stage(zip_path, staging_dir, install_dir)
	for line in stager.lines:
		print("OpenSRO update: " + line)
	if not staged.ok:
		DirAccess.remove_absolute(zip_path)
		update_failed.emit("could not unpack %s, nothing was changed (%s)" % [_pending_tag, staged.reason])
		return

	# The zip wraps everything in one folder ("opensro-windows/", release.yml).
	var extracted_root := staging_dir
	var top_dirs := DirAccess.get_directories_at(staging_dir)
	if top_dirs.size() == 1 and DirAccess.get_files_at(staging_dir).is_empty():
		extracted_root = staging_dir.path_join(top_dirs[0])

	var installer := UpdateInstaller.new()
	var outcome := installer.install(extracted_root, install_dir, list_files(extracted_root), exe_path.get_file())
	for line in installer.lines:
		print("OpenSRO update: " + line)
	remove_tree(staging_dir)
	DirAccess.remove_absolute(zip_path)

	var summary := PackedStringArray(["%s -> %s: %s" % [UpdateChecker.CLIENT_VERSION, _pending_tag,
		"installed" if outcome.ok else "NOT installed, kept %s (%s)" % [UpdateChecker.CLIENT_VERSION, outcome.reason]]])
	summary.append_array(installer.lines)
	installer.write_summary(install_dir, summary)
	if not outcome.ok:
		update_failed.emit("could not install %s (%s); this version is unchanged" % [_pending_tag, outcome.reason])
		return

	var pid := _relaunch(exe_path, install_dir)
	print("OpenSRO update: installed %s, %s" % [_pending_tag,
		"restarting (the new client starts as soon as this one has exited)" if pid > 0 else "start the game again (could not start it)"])
	get_tree().quit()

## Starts the newly installed executable once this process has exited, so the
## two never write the same log file. Best effort: the files are already
## installed, so a relaunch that fails only means starting the game by hand.
## Returns the helper's process id, or -1 (OS.create_process returns a PID).
func _relaunch(exe_path: String, install_dir: String) -> int:
	var pid := OS.get_process_id()
	if OS.get_name() == "Windows":
		var bat := install_dir.path_join(RELAUNCH_BAT)
		var f := FileAccess.open(bat, FileAccess.WRITE)
		if f == null:
			return -1
		f.store_string(windows_relaunch_script(pid, exe_path))
		f.close()
		return OS.create_process("cmd.exe", windows_relaunch_args(bat))
	return OS.create_process("/bin/sh", linux_relaunch_args(pid, exe_path))

## A batch file that polls until process `pid` is gone (at most RELAUNCH_POLLS
## polls, ~1 s apart: `ping -n 2` to localhost, because `timeout` needs a
## console this script does not have), starts the executable and deletes
## itself.
## - It holds NO install path (the review's M2): cmd.exe reads a batch file in
##   the OEM code page, so a UTF-8 path such as C:\Users\José\... would be
##   mangled. Every path is relative to the script's own folder, %~dp0, which
##   cmd keeps as UTF-16. Only the executable's NAME is written, and only when
##   it is plain ASCII (otherwise "OpenSRO.exe", release.yml's name).
## - `tasklist /FO CSV` prints `"name","<pid>",...` for a live process; the
##   quoted PID is matched (`find """<pid>"""`), not just any comma (L4).
## v0.1.464's own batch file has the OEM problem too (PRE-EXISTING): an install
## under a non-ASCII path probably never auto-updated, and will not get this
## release automatically either.
static func windows_relaunch_script(pid: int, exe_path: String) -> String:
	var exe_name := exe_path.get_file()
	if not _is_ascii(exe_name):
		exe_name = "OpenSRO.exe"
	return "\r\n".join(PackedStringArray([
		"@echo off",
		"set /a n=0",
		":wait",
		"tasklist /FI \"PID eq %d\" /NH /FO CSV 2>NUL | find \"\"\"%d\"\"\" >NUL" % [pid, pid],
		"if errorlevel 1 goto start",
		"set /a n+=1",
		"if %%n%% GEQ %d goto start" % RELAUNCH_POLLS,
		"ping -n 2 127.0.0.1 >NUL",
		"goto wait",
		":start",
		"start \"\" /D \"%%~dp0.\" \"%%~dp0%s\"" % exe_name,
		"(goto) 2>NUL & del \"%~f0\"",
		""]))

static func _is_ascii(text: String) -> bool:
	for i in range(text.length()):
		if text.unicode_at(i) > 126 or text.unicode_at(i) < 32:
			return false
	return true

## cmd.exe arguments that run `bat` whatever its path holds. Godot quotes an
## argument only when it contains a space or one of & ( ) [ ] { } ^ = ; ! ' + , ` ~
## (os_windows.cpp:656-663, READ), and `cmd /C "<path>"` keeps those quotes
## only when the path has no & ( ) @ ^ | in it; otherwise it strips them and
## splits the command at the &. With /S, cmd always strips exactly the outer
## pair, so the path goes in wrapped in its own quotes: the inner pair
## survives, special characters and all (the review's L3).
static func windows_relaunch_args(bat: String) -> PackedStringArray:
	return PackedStringArray(["/D", "/S", "/C", "\"" + bat.replace("/", "\\") + "\""])

## /bin/sh arguments that poll until process `pid` is gone (at most
## RELAUNCH_POLLS x 0.5 s), then exec the executable. The pid and path are
## positional parameters, never spliced into the script.
static func linux_relaunch_args(pid: int, exe_path: String) -> PackedStringArray:
	var script := "i=0; while kill -0 \"$1\" 2>/dev/null && [ \"$i\" -lt %d ]; do sleep 0.5; i=$((i+1)); done; cd \"$(dirname \"$2\")\" && exec \"$2\"" % RELAUNCH_POLLS
	return PackedStringArray(["-c", script, "opensro-relaunch", str(pid), exe_path])

## At startup in an exported build: finish the last update's cleanup and put
## its summary into this log.
static func after_update_startup() -> void:
	if not OS.has_feature("template"):
		return
	var install_dir := OS.get_executable_path().get_base_dir()
	var installer := UpdateInstaller.new()
	for line in installer.take_summary(install_dir):
		print("OpenSRO update (last run): " + line)
	for line in installer.cleanup(install_dir):
		print("OpenSRO update: " + line)
	var bat := install_dir.path_join(RELAUNCH_BAT)
	if FileAccess.file_exists(bat):
		DirAccess.remove_absolute(bat)
	UpdateFs.new().remove_tree(install_dir.path_join(STAGING_DIR))

## Every file under root, relative to it, "/"-separated.
static func list_files(root: String, prefix: String = "") -> PackedStringArray:
	var out := PackedStringArray()
	var here := root.path_join(prefix) if prefix != "" else root
	for f in DirAccess.get_files_at(here):
		out.append(prefix.path_join(f) if prefix != "" else f)
	for d in DirAccess.get_directories_at(here):
		out.append_array(list_files(root, prefix.path_join(d) if prefix != "" else d))
	return out

static func remove_tree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	for d in DirAccess.get_directories_at(path):
		remove_tree(path.path_join(d))
	DirAccess.remove_absolute(path)
