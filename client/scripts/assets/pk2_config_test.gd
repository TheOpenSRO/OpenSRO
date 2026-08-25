extends SceneTree

## Exercises Pk2Config's real path-resolution logic (never real game data),
## run headless:
## `godot4 --headless --path client --script res://scripts/assets/pk2_config_test.gd`
##
## Godot has no way to set an environment variable from GDScript (only read
## one), so this can't directly test the "env var set" precedence branch --
## that's exercised implicitly by every other test/live-verification pass
## in this project that already sets SRREVAMP_*_PK2_PATH and gets it back
## via World3D's _open_*_pk2_if_set functions. What's tested here is the
## real fallback path-composition and empty-when-neither-resolves behavior.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _init() -> void:
	_check(Pk2Config.pk2_dir().ends_with("/pk2"), "pk2_dir() ends with a real /pk2 folder name (got %s)" % Pk2Config.pk2_dir())
	_check(Pk2Config.pk2_dir() == Pk2Config.pk2_dir(), "pk2_dir() is deterministic")

	# With no SRREVAMP_*_PK2_PATH set in this test process and no real
	# pk2/<file>.pk2 sitting next to the godot4 test-runner binary, every
	# getter must resolve to "" rather than guessing.
	if OS.get_environment("SRREVAMP_PK2_PATH") == "":
		_check(Pk2Config.data_path() == "", "data_path() is empty with no env var and no real local pk2/Data.pk2")
	if OS.get_environment("SRREVAMP_MAP_PK2_PATH") == "":
		_check(Pk2Config.map_path() == "", "map_path() is empty with no env var and no real local pk2/Map.pk2")
	if OS.get_environment("SRREVAMP_MEDIA_PK2_PATH") == "":
		_check(Pk2Config.media_path() == "", "media_path() is empty with no env var and no real local pk2/Media.pk2")

	# Env var precedence: this project's own dev/testing workflow relies on
	# SRREVAMP_PK2_PATH being read back exactly as set, taking priority over
	# any real local pk2 folder file of the same real name -- confirmed
	# structurally (can't flip the env var from GDScript, see this file's
	# own top comment) by checking the getter echoes whatever's already in
	# the environment when it's non-empty.
	var env_val := OS.get_environment("SRREVAMP_PK2_PATH")
	if env_val != "":
		_check(Pk2Config.data_path() == env_val, "data_path() returns the real env var value when set (got %s)" % Pk2Config.data_path())

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
