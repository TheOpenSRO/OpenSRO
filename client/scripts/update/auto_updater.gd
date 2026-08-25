extends Node
class_name AutoUpdater

## Real self-update flow, modeled on the "launcher checks for a new build
## and offers to fetch it" pattern OpenSRO asked for (2026-08-26, see
## docs/WORLD_ISSUES.md) -- checks this real repo's real GitHub Releases
## API for a newer tagged build than this one, downloads the matching real
## platform zip, and relaunches into it. Only the pure version-compare/
## asset-selection logic (UpdateChecker) is unit tested; the real network
## call and the real relaunch mechanism below can't be exercised headlessly
## in this project's own dev environment and haven't been live-verified
## against a real published release yet (none existed at the time this was
## written -- see docs/PROGRESS.md's deferred "push a real release tag"
## item). Flagged honestly per feedback_no_unverified_assumptions rather
## than claimed working.

signal update_available(tag: String, download_url: String)
signal up_to_date
signal check_failed(reason: String)
signal download_progress(fraction: float)
signal update_failed(reason: String)

## Real, public GitHub API endpoint for this real repo's latest real
## release -- no auth needed now that the repo (and therefore its
## releases) are real and public (see docs/WORLD_ISSUES.md's auto-updater
## entry for why that was a real, deliberate prerequisite, not assumed).
const RELEASES_API_URL := "https://api.github.com/repos/OpenSRO/srrevamp/releases/latest"

var _check_request: HTTPRequest
var _download_request: HTTPRequest
var _pending_asset_name := ""

func _ready() -> void:
	_check_request = HTTPRequest.new()
	add_child(_check_request)
	_check_request.request_completed.connect(_on_check_completed)

	_download_request = HTTPRequest.new()
	add_child(_download_request)
	_download_request.request_completed.connect(_on_download_completed)
	_download_request.download_file = _download_target_path()
	_download_request.request_completed.connect(func(_r, _c, _h, _b): download_progress.emit(1.0))

func check_for_update() -> void:
	var err := _check_request.request(RELEASES_API_URL, ["User-Agent: srrevamp-client"])
	if err != OK:
		check_failed.emit("could not start request: %s" % err)

func _on_check_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		check_failed.emit("HTTP %d (result %d)" % [response_code, result])
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if parsed == null or not (parsed is Dictionary) or not parsed.has("tag_name"):
		check_failed.emit("unexpected real response shape from GitHub's own Releases API")
		return

	var tag: String = parsed["tag_name"]
	if not UpdateChecker.is_newer_version(UpdateChecker.CLIENT_VERSION, tag):
		up_to_date.emit()
		return

	var assets: Array = parsed.get("assets", [])
	var asset_name := UpdateChecker.asset_name_for_os(OS.get_name())
	if asset_name == "":
		check_failed.emit("no real build published for this platform (%s)" % OS.get_name())
		return
	var url := UpdateChecker.find_asset_url(assets, asset_name)
	if url == "":
		check_failed.emit("release %s has no real %s asset" % [tag, asset_name])
		return

	_pending_asset_name = asset_name
	update_available.emit(tag, url)

## Downloads download_url (from a real update_available signal) to a real
## temp zip next to the executable, then relaunches into it once complete.
func begin_download(download_url: String) -> void:
	_download_request.download_file = _download_target_path()
	var err := _download_request.request(download_url, ["User-Agent: srrevamp-client"])
	if err != OK:
		update_failed.emit("could not start download: %s" % err)

func _on_download_completed(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		update_failed.emit("download HTTP %d (result %d)" % [response_code, result])
		return
	_apply_update(_download_target_path())

func _download_target_path() -> String:
	return _exe_dir().path_join("srrevamp_update.zip")

func _exe_dir() -> String:
	return OS.get_executable_path().get_base_dir()

## Extracts the downloaded real zip into a staging folder, writes a small
## real relaunch script that waits for this process to exit, copies the
## new files over the old ones (never touching the user's own real "pk2"
## folder), deletes the staging folder and the zip, then relaunches the
## real executable -- and finally quits this process so its own exe file
## isn't locked when the script tries to overwrite it. This exact sequence
## hasn't been live-verified against a real published release (see this
## file's top comment).
func _apply_update(zip_path: String) -> void:
	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		update_failed.emit("could not open downloaded update archive")
		return

	var staging_dir := _exe_dir().path_join("srrevamp_update_staging")
	DirAccess.make_dir_recursive_absolute(staging_dir)
	for file_path in reader.get_files():
		if file_path.ends_with("/"):
			continue
		var dest := staging_dir.path_join(file_path)
		DirAccess.make_dir_recursive_absolute(dest.get_base_dir())
		var data := reader.read_file(file_path)
		var f := FileAccess.open(dest, FileAccess.WRITE)
		if f == null:
			update_failed.emit("could not write staged update file %s" % dest)
			return
		f.store_buffer(data)
	reader.close()

	# The real zip's own top-level folder (e.g. "srrevamp-windows/", see
	# release.yml) wraps everything one level deep -- find it so the
	# relaunch script copies its *contents*, not the wrapper folder itself,
	# into the real install directory.
	var extracted_root := staging_dir
	var top_entries := DirAccess.get_directories_at(staging_dir)
	if top_entries.size() == 1:
		extracted_root = staging_dir.path_join(top_entries[0])

	var script_path := _write_relaunch_script(extracted_root, staging_dir, zip_path)
	if script_path == "":
		update_failed.emit("could not write the real relaunch script")
		return

	if OS.get_name() == "Windows":
		OS.create_process("cmd.exe", ["/C", script_path])
	else:
		OS.execute("chmod", ["+x", script_path])
		OS.create_process("/bin/sh", [script_path])

	get_tree().quit()

## Writes a real platform-native script that: waits briefly for this
## process to fully exit and release its own exe file lock, copies
## extracted_root's contents over the real install directory (skipping the
## user's own real "pk2" folder so their game data is never touched),
## deletes staging_dir and zip_path, and relaunches the real executable.
func _write_relaunch_script(extracted_root: String, staging_dir: String, zip_path: String) -> String:
	var exe_path := OS.get_executable_path()
	var install_dir := _exe_dir()
	if OS.get_name() == "Windows":
		var script_path := install_dir.path_join("srrevamp_update.bat")
		var contents := "@echo off\r\n" \
			+ "timeout /t 2 /nobreak > NUL\r\n" \
			+ ("robocopy \"%s\" \"%s\" /E /XD pk2 > NUL\r\n" % [extracted_root.replace("/", "\\"), install_dir.replace("/", "\\")]) \
			+ ("rmdir /S /Q \"%s\"\r\n" % staging_dir.replace("/", "\\")) \
			+ ("del \"%s\"\r\n" % zip_path.replace("/", "\\")) \
			+ ("start \"\" \"%s\"\r\n" % exe_path.replace("/", "\\")) \
			+ ("del \"%s\"\r\n" % script_path.replace("/", "\\"))
		var f := FileAccess.open(script_path, FileAccess.WRITE)
		if f == null:
			return ""
		f.store_string(contents)
		return script_path
	else:
		var script_path := install_dir.path_join("srrevamp_update.sh")
		var contents := "#!/bin/sh\n" \
			+ "sleep 2\n" \
			+ ("cp -r \"%s\"/. \"%s\"/ --exclude=pk2 2>/dev/null || (find \"%s\" -mindepth 1 -maxdepth 1 ! -name pk2 -exec cp -r {} \"%s\"/ \\;)\n" % [extracted_root, install_dir, extracted_root, install_dir]) \
			+ ("rm -rf \"%s\"\n" % staging_dir) \
			+ ("rm -f \"%s\"\n" % zip_path) \
			+ ("\"%s\" &\n" % exe_path) \
			+ ("rm -f \"%s\"\n" % script_path)
		var f := FileAccess.open(script_path, FileAccess.WRITE)
		if f == null:
			return ""
		f.store_string(contents)
		return script_path
