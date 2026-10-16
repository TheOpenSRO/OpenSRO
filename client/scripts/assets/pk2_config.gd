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
## session used OPENSRO_*_PK2_PATH) keeps working unchanged:
##   1. The matching OPENSRO_*_PK2_PATH environment variable, if set.
##   2. "<executable's real directory>/pk2/<real filename>.pk2", if present.
## Returns "" (never a guess) if neither resolves.
## Round 789: under the source mode (source_mode below) the same order finds
## a converted `<Name>.pk3` -- Pk2Reader.open reads either -- and the mode
## `pk2` resolves exactly as before.

const DATA_FILENAME := "Data.pk2"
const MAP_FILENAME := "Map.pk2"
const MEDIA_FILENAME := "Media.pk2"
const PARTICLES_FILENAME := "Particles.pk2"
const MUSIC_FILENAME := "Music.pk2"

static func data_path() -> String:
	return _resolve("OPENSRO_PK2_PATH", DATA_FILENAME)

static func map_path() -> String:
	return _resolve("OPENSRO_MAP_PK2_PATH", MAP_FILENAME)

static func media_path() -> String:
	return _resolve("OPENSRO_MEDIA_PK2_PATH", MEDIA_FILENAME)

static func particles_path() -> String:
	return _resolve("OPENSRO_PARTICLES_PK2_PATH", PARTICLES_FILENAME)

static func music_path() -> String:
	return _resolve("OPENSRO_MUSIC_PK2_PATH", MUSIC_FILENAME)

## The real local "pk2" folder a downloaded build looks in -- the directory
## the running executable itself lives in, not the current working
## directory (which can differ if launched from a shortcut/different cwd).
## In the Godot editor (no real exported executable to anchor to),
## OS.get_executable_path() points at the Godot editor binary itself, which
## has no real "pk2" sibling folder -- harmless, since editor runs almost
## always set the env var instead for a specific test file.
static func pk2_dir() -> String:
	return OS.get_executable_path().get_base_dir().path_join("pk2")

## Round 789 (OURS, asset packs; docs/protocol/asset_packs.md rule 5): which
## archive types are read, one setting -- `pk2` (only .pk2 archives, base and
## pack: the retail archives as before, plus any extra .pk2 pack), `pk3`
## (only .pk3/.zip: the base archives converted once, no .pk2 read) or
## `mixed` (the default: every type). custom/ is read in every mode. OPENSRO_ASSET_SOURCE
## (QA, a developer) wins over setting/config.yaml's `assets.source`
## (ClientConfig). Read once; reset_source_mode() makes the next call read
## again (AssetArchives.reload, tests).
const MODE_PK2 := "pk2"
const MODE_PK3 := "pk3"
const MODE_MIXED := "mixed"
const MODES := [MODE_PK2, MODE_PK3, MODE_MIXED]

static var _mode := ""
static var _mode_from := ""
## Why the mode is what it is ("default", "OPENSRO_ASSET_SOURCE",
## "<config.yaml path>"), for the log and the debug panel.
static func source_mode_origin() -> String:
	source_mode()
	return _mode_from

static func source_mode() -> String:
	if _mode != "":
		return _mode
	var m := MODE_MIXED
	var from := "default"
	var env := OS.get_environment("OPENSRO_ASSET_SOURCE")
	if env != "":
		if normalise_mode(env) != "":
			m = normalise_mode(env)
			from = "OPENSRO_ASSET_SOURCE"
		else:
			printerr("Pk2Config: OPENSRO_ASSET_SOURCE=%s is not pk2, pk3 or mixed -- ignored" % env)
	if from == "default":
		var cfg := ClientConfig.load_default()
		if cfg.asset_source != "":
			m = cfg.asset_source
			from = cfg.source
	_mode_from = from
	_mode = m
	return m

static func reset_source_mode() -> void:
	_mode = ""
	_mode_from = ""

## "pk2" / "pk3" / "mixed" (case and spaces ignored), or "" for anything else.
static func normalise_mode(s: String) -> String:
	var m := s.strip_edges().to_lower()
	return m if m in MODES else ""

## The folder the packs are looked for in: OPENSRO_PACK_DIR (QA, a
## developer), else the folder the Data archive resolved to (where a player's
## archives are), else pk2_dir().
static func pack_dir() -> String:
	var env := OS.get_environment("OPENSRO_PACK_DIR")
	if env != "":
		return env
	var data := data_path()
	if data != "":
		return data.get_base_dir()
	return pk2_dir()

static func _resolve(env_var: String, filename: String) -> String:
	var chain := base_chain(env_var, filename)
	return chain[0] if not chain.is_empty() else ""

## The env variable for a base archive's name ("Data" -> OPENSRO_PK2_PATH).
const ENV_FOR := {"Data": "OPENSRO_PK2_PATH", "Map": "OPENSRO_MAP_PK2_PATH", "Media": "OPENSRO_MEDIA_PK2_PATH",
	"Music": "OPENSRO_MUSIC_PK2_PATH", "Particles": "OPENSRO_PARTICLES_PK2_PATH"}

## A volume's base layers, highest first (round 789; docs/protocol/
## asset_packs.md, rules 2, 3 and 5): every one of <Name>.pk3, <Name>.zip and
## <Name>.pk2 the mode reads that is there -- `Data.pk3` above `Data.pk2` when
## both are. `name` is one of the five (AssetArchives.BASE_NAMES).
static func volume_chain(name: String) -> PackedStringArray:
	return base_chain(str(ENV_FOR.get(name, "")), name + ".pk2")

## The base archive extensions a mode reads, highest first.
static func base_exts(mode: String) -> PackedStringArray:
	if mode == MODE_PK2:
		return PackedStringArray(["pk2"])
	if mode == MODE_PK3:
		return PackedStringArray(["pk3", "zip"])
	return PackedStringArray(["pk3", "zip", "pk2"])

static func base_chain(env_var: String, filename: String) -> PackedStringArray:
	var mode := source_mode()
	var env_value := OS.get_environment(env_var) if env_var != "" else ""
	if env_value != "":
		return chain_from_env(env_value, mode)
	var stem := filename.get_basename()
	for dir in [pk2_dir(), ProjectSettings.globalize_path("res://pk2"), ProjectSettings.globalize_path("res://pk2/pk2")]:
		var found := chain_in(dir, stem, mode)
		if not found.is_empty():
			return found
	return PackedStringArray()

## An OPENSRO_*_PK2_PATH value under a mode (round 789). `pk2`: the value as
## set, unchecked (as before). Otherwise a value naming a .pk2/.pk3/.zip
## stands for its volume in that folder: every sibling of its stem the mode
## reads that is there, highest first; when none is, the value itself (or,
## in the mode `pk3`, its `.pk3` sibling), whose open then fails, logged. A
## value with another extension is used as set.
static func chain_from_env(value: String, mode: String) -> PackedStringArray:
	var ext := value.get_extension().to_lower()
	if mode == MODE_PK2 or not (ext in ["pk2", "pk3", "zip"]):
		return PackedStringArray([value])
	var stem := value.get_basename()
	var found := PackedStringArray()
	for e in base_exts(mode):
		var p := value if e == ext else stem + "." + e
		if FileAccess.file_exists(p):
			found.append(p)
	if found.is_empty():
		found.append(value if ext in base_exts(mode) else stem + ".pk3")
	return found

## <stem>.pk3 / .zip / .pk2 in dir that the mode reads, highest first.
static func chain_in(dir: String, stem: String, mode: String) -> PackedStringArray:
	var found := PackedStringArray()
	for e in base_exts(mode):
		var p := dir.path_join(stem + "." + e)
		if FileAccess.file_exists(p):
			found.append(p)
	return found
