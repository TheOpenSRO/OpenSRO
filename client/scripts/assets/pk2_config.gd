extends RefCounted
class_name Pk2Config

## Resolves where each real Silkroad Online pk2 archive lives, so a
## downloaded build works without setting any environment variables: a user
## copies their own retail install's *.pk2 files (BYO game assets, see
## docs/LEGAL.md) into a "pk2" folder placed next to the exported
## executable, and this class finds them there automatically.
##
## Resolution order per archive, checked in this order so this project's own
## existing dev/testing workflow (every debug/live-verification pass this
## session used SRREVAMP_*_PK2_PATH) keeps working unchanged:
##   1. The matching SRREVAMP_*_PK2_PATH environment variable, if set.
##   2. "<executable's real directory>/pk2/<real filename>.pk2", if present.
## Returns "" (never a guess) if neither resolves.

const DATA_FILENAME := "Data.pk2"
const MAP_FILENAME := "Map.pk2"
const MEDIA_FILENAME := "Media.pk2"
const PARTICLES_FILENAME := "Particles.pk2"
const MUSIC_FILENAME := "Music.pk2"

static func data_path() -> String:
	return _resolve("SRREVAMP_PK2_PATH", DATA_FILENAME)

static func map_path() -> String:
	return _resolve("SRREVAMP_MAP_PK2_PATH", MAP_FILENAME)

static func media_path() -> String:
	return _resolve("SRREVAMP_MEDIA_PK2_PATH", MEDIA_FILENAME)

static func particles_path() -> String:
	return _resolve("SRREVAMP_PARTICLES_PK2_PATH", PARTICLES_FILENAME)

static func music_path() -> String:
	return _resolve("SRREVAMP_MUSIC_PK2_PATH", MUSIC_FILENAME)

## The real local "pk2" folder a downloaded build looks in -- the directory
## the running executable itself lives in, not the current working
## directory (which can differ if launched from a shortcut/different cwd).
## In the Godot editor (no real exported executable to anchor to),
## OS.get_executable_path() points at the Godot editor binary itself, which
## has no real "pk2" sibling folder -- harmless, since editor runs almost
## always set the env var instead for a specific test file.
static func pk2_dir() -> String:
	return OS.get_executable_path().get_base_dir().path_join("pk2")

static func _resolve(env_var: String, filename: String) -> String:
	var env_value := OS.get_environment(env_var)
	if env_value != "":
		return env_value
	var local_path := pk2_dir().path_join(filename)
	if FileAccess.file_exists(local_path):
		return local_path
	return ""
