extends SceneTree

## UserDataMigration (round 704): a player's user:// files are copied once
## from the old SRRevamp folder into the OpenSRO one.
##
## `godot4 --headless --path client --script res://scripts/setting/user_data_migration_test.gd`

var _failures := 0
var _root := ""

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_root = OS.get_user_data_dir().path_join("user_data_migration_test_%d" % OS.get_process_id())
	_names()
	_copies_once()
	_keeps_existing_settings()
	_nothing_to_move()
	_remove_tree(_root)
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES %d" % _failures)
	quit(1 if _failures > 0 else 0)

func _put(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()

func _remove_tree(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_remove_tree(dir.path_join(d))
	DirAccess.remove_absolute(dir)

func _names() -> void:
	_check(ProjectSettings.get_setting("application/config/name") == "OpenSRO", "config/name is OpenSRO")
	_check(not bool(ProjectSettings.get_setting("application/config/use_custom_user_dir", false)),
		"no custom user folder: the folder is keyed by config/name")
	_check(OS.get_user_data_dir().get_file() == "OpenSRO", "this run's user folder is .../OpenSRO (%s)" % OS.get_user_data_dir())
	_check(UserDataMigration.old_dir_for("/home/p/.local/share/godot/app_userdata/OpenSRO") == "/home/p/.local/share/godot/app_userdata/SRRevamp",
		"the old folder is the SRRevamp sibling (Linux)")
	_check(UserDataMigration.old_dir_for("C:/Users/p/AppData/Roaming/Godot/app_userdata/OpenSRO") == "C:/Users/p/AppData/Roaming/Godot/app_userdata/SRRevamp",
		"the old folder is the SRRevamp sibling (Windows)")
	_check(ProjectSettings.get_setting("autoload/UserDataMigrator", "") == "*res://scripts/setting/user_data_migration.gd",
		"registered as an autoload")
	var first := ""
	for p in ProjectSettings.get_property_list():
		var n := str(p["name"])
		if n.begins_with("autoload/"):
			first = n
			break
	_check(first == "autoload/UserDataMigrator", "and it is the first autoload, before Audio reads settings.cfg (%s)" % first)

func _copies_once() -> void:
	var old := _root.path_join("a/SRRevamp")
	var new := _root.path_join("a/OpenSRO")
	_put(old.path_join("settings.cfg"), "[server]\nusername=\"p\"\n")
	_put(old.path_join("quickslots.cfg"), "q")
	_put(old.path_join("screenshots/SRO1.jpg"), "jpg")
	_put(old.path_join("logs/srrevamp.log"), "old log")
	_put(old.path_join("shader_cache/x.bin"), "cache")
	_put(old.path_join("vulkan/pipe.cache"), "cache")
	# The new log is already open when the migration runs.
	_put(new.path_join("logs/opensro.log"), "new log")
	var out := UserDataMigration.migrate(old, new)
	_check(out["copied"] == 3 and out["failed"] == 0, "three files copied: %s" % [out])
	_check(FileAccess.get_file_as_string(new.path_join("settings.cfg")).contains("username=\"p\""), "settings.cfg copied")
	_check(FileAccess.get_file_as_string(new.path_join("quickslots.cfg")) == "q", "quickslots.cfg copied")
	_check(FileAccess.file_exists(new.path_join("screenshots/SRO1.jpg")), "subfolders copied (screenshots)")
	_check(not FileAccess.file_exists(new.path_join("logs/srrevamp.log")), "the old logs are not copied")
	_check(FileAccess.get_file_as_string(new.path_join("logs/opensro.log")) == "new log", "the new log is untouched")
	_check(not DirAccess.dir_exists_absolute(new.path_join("shader_cache")) and not DirAccess.dir_exists_absolute(new.path_join("vulkan")),
		"the engine caches are not copied")
	_check(FileAccess.file_exists(new.path_join(UserDataMigration.MARKER)), "the marker is written")
	_check(FileAccess.file_exists(old.path_join("settings.cfg")), "the old folder is left as it was")
	# Once only: even with settings.cfg deleted, a second start copies nothing.
	DirAccess.remove_absolute(new.path_join("settings.cfg"))
	out = UserDataMigration.migrate(old, new)
	_check(out["copied"] == 0 and out["reason"] == "already migrated", "a second start copies nothing: %s" % [out])
	_check(not FileAccess.file_exists(new.path_join("settings.cfg")), "and does not bring a deleted settings.cfg back")

func _keeps_existing_settings() -> void:
	var old := _root.path_join("b/SRRevamp")
	var new := _root.path_join("b/OpenSRO")
	_put(old.path_join("settings.cfg"), "old")
	_put(old.path_join("quickslots.cfg"), "old q")
	_put(new.path_join("settings.cfg"), "new")
	var out := UserDataMigration.migrate(old, new)
	_check(out["copied"] == 0, "a new folder already in use is not copied into: %s" % [out])
	_check(FileAccess.get_file_as_string(new.path_join("settings.cfg")) == "new", "its settings.cfg is kept")
	_check(not FileAccess.file_exists(new.path_join("quickslots.cfg")), "nothing else is mixed in")
	_check(FileAccess.file_exists(new.path_join(UserDataMigration.MARKER)), "and it is marked, so it is not asked again")

func _nothing_to_move() -> void:
	var new := _root.path_join("c/OpenSRO")
	var out := UserDataMigration.migrate(_root.path_join("c/SRRevamp"), new)
	_check(out["copied"] == 0 and out["reason"] == "no old user folder", "a fresh install has nothing to move: %s" % [out])
	_check(not FileAccess.file_exists(new.path_join(UserDataMigration.MARKER)), "and writes no marker")
	out = UserDataMigration.migrate("", new)
	_check(out["copied"] == 0, "a custom user folder (old_dir_for gives \"\") moves nothing")
