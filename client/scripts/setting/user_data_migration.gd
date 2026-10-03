extends Node
class_name UserDataMigration

## Round 704: the project was called srrevamp until 2026-10-03, and its
## Godot `config/name` was "SRRevamp". Godot keys the user:// folder by that
## name (no `use_custom_user_dir` is set), so renaming the project to OpenSRO
## moves it: Windows `%APPDATA%\Godot\app_userdata\SRRevamp` becomes
## `...\OpenSRO`, Linux `~/.local/share/godot/app_userdata/SRRevamp` becomes
## `.../OpenSRO`, and macOS `~/Library/Application Support/Godot/app_userdata/`
## likewise. A player's settings.cfg (the remembered server and account
## name, the UI scale, the Option window), quickslots.cfg and screenshots
## would be left behind.
##
## So on a start whose user folder has no settings.cfg, the old folder's
## files are copied over ONCE (never overwriting a file already there), and
## a marker file records that it happened, so a later start never copies
## again even if the player deletes settings.cfg. The marker is written only
## when every file copied: a copy that failed (a full disk, a locked file)
## leaves PENDING_MARKER instead, and the next start copies what is still
## missing, even though settings.cfg may have arrived the first time. The
## old folder is left as it was: the player can delete it.
##
## Not copied: logs/ (the old program's logs; the new log is already open
## under logs/), shader_cache/ and vulkan/ (the engine's caches: the shader
## cache alone was 70 MB on the box, and rebuilding it once costs a slower
## first start, nothing else).
##
## Not affected by the rename, so not handled here: override.cfg (the
## renderer choice, RendererChoice) and setting/config.yaml (ClientConfig)
## live BESIDE the executable, not in user://. config.yaml's old
## `type: srrevamp` is read by ClientConfig.OLD_TYPE_NAME.
##
## This script is the project's FIRST autoload (project.godot), so it runs
## before the Audio autoload reads its options from settings.cfg and before
## Boot. OURS.

## The folder name Godot used before round 704 (the old config/name).
const OLD_APP_NAME := "SRRevamp"
## Written into the new folder once the copy has been made (or found
## unnecessary because the new folder already had settings).
const MARKER := "migrated_from_srrevamp.txt"
## Written when a copy began but some file failed; the next start resumes.
const PENDING_MARKER := "migrating_from_srrevamp.txt"
## The file whose presence means the new folder is already in use.
const SETTINGS_FILE := "settings.cfg"
## Top-level folders not copied (engine caches and the old logs).
const SKIPPED_DIRS := ["logs", "shader_cache", "vulkan"]

func _init() -> void:
	run()

## The old user folder beside `new_dir` (`<base>/app_userdata/SRRevamp`), or
## "" when the project uses a custom user folder (then the folder is not
## keyed by the name and nothing moved).
static func old_dir_for(new_dir: String) -> String:
	if bool(ProjectSettings.get_setting("application/config/use_custom_user_dir", false)):
		return ""
	return new_dir.simplify_path().get_base_dir().path_join(OLD_APP_NAME)

## Runs the migration for this install's user folder and logs the outcome.
static func run() -> Dictionary:
	var new_dir := OS.get_user_data_dir()
	var out := migrate(old_dir_for(new_dir), new_dir)
	if not (out["reason"] in ["no old user folder", "already migrated"]):
		print("UserData: %s" % out["reason"])
	return out

## Copies `old_dir`'s files into `new_dir` once. Returns {copied, failed,
## reason}: `copied` files written, `failed` files that could not be.
static func migrate(old_dir: String, new_dir: String) -> Dictionary:
	var out := {"copied": 0, "failed": 0, "reason": ""}
	if old_dir == "" or not DirAccess.dir_exists_absolute(old_dir):
		out["reason"] = "no old user folder"
		return out
	if old_dir.simplify_path().to_lower() == new_dir.simplify_path().to_lower():
		out["reason"] = "the old and new user folders are the same"
		return out
	if FileAccess.file_exists(new_dir.path_join(MARKER)):
		out["reason"] = "already migrated"
		return out
	DirAccess.make_dir_recursive_absolute(new_dir)
	var resuming := FileAccess.file_exists(new_dir.path_join(PENDING_MARKER))
	if not resuming and FileAccess.file_exists(new_dir.path_join(SETTINGS_FILE)):
		_write_marker(new_dir, "not copied: %s already had %s" % [new_dir, SETTINGS_FILE])
		out["reason"] = "the new user folder already has settings"
		return out
	_copy_tree(old_dir, new_dir, true, out)
	out["reason"] = "copied %d file(s) from %s to %s (the client was called SRRevamp before round 704)%s" % [
		out["copied"], old_dir, new_dir,
		"" if out["failed"] == 0 else ", %d could not be copied -- retried at the next start" % out["failed"]]
	if out["failed"] == 0:
		_write_marker(new_dir, out["reason"])
		DirAccess.remove_absolute(new_dir.path_join(PENDING_MARKER))
	else:
		var f := FileAccess.open(new_dir.path_join(PENDING_MARKER), FileAccess.WRITE)
		if f != null:
			f.store_string(out["reason"] + "\n")
	return out

static func _copy_tree(from_dir: String, to_dir: String, top: bool, out: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(to_dir)
	for f in DirAccess.get_files_at(from_dir):
		if top and (f == MARKER or f == PENDING_MARKER):
			continue
		var dst := to_dir.path_join(f)
		if FileAccess.file_exists(dst):
			continue
		if DirAccess.copy_absolute(from_dir.path_join(f), dst) == OK:
			out["copied"] += 1
		else:
			out["failed"] += 1
			if FileAccess.file_exists(dst):
				DirAccess.remove_absolute(dst)   # no half-written file to be skipped next time
	for d in DirAccess.get_directories_at(from_dir):
		if top and d in SKIPPED_DIRS:
			continue
		_copy_tree(from_dir.path_join(d), to_dir.path_join(d), false, out)

static func _write_marker(new_dir: String, text: String) -> void:
	var f := FileAccess.open(new_dir.path_join(MARKER), FileAccess.WRITE)
	if f != null:
		f.store_string(text + "\n")
