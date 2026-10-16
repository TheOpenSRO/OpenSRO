extends RefCounted
class_name AssetArchives

## The client's one set of game archives (round 789; everything about packs
## is OURS -- retail has only .pk2). Before round 789 every scene opened its
## own handles (13 Pk2Reader.open sites in 9 files); now they all ask here,
## and the five base archives -- Data, Map, Media, Music, Particles -- are
## opened once, each the first time it is asked for, and shared by every
## scene and thread (Pk2Reader, Pk3Reader and LayeredArchive are thread-safe:
## World3D reads them from WorkerThreadPool tasks).
##
## The rules are docs/protocol/asset_packs.md's ("Rules"), which the Go tools
## (server/internal/assetfs, lane G) follow too; this is the client's reader.
##
## What a caller gets for `AssetArchives.data()` (a volume, rule 3: the
## archive a lookup names, as every find_file names its handle):
## - nothing overlays the volume (no pack, no custom/ file, one base file):
##   the base archive's own handle, exactly as before;
## - otherwise a LayeredArchive: the loose custom/ folder, then the packs
##   (later name first), then the volume's base layers (`Data.pk3` above
##   `Data.pk2` when both are read). Packs and custom/ overlay every volume.
## Either way it is a Pk2Reader, or null when the volume has no base archive
## (OURS: a pack never stands in for a missing base archive).
##
## The source mode (rule 5; Pk2Config.source_mode: setting/config.yaml's
## `assets.source`, OPENSRO_ASSET_SOURCE) picks the archive types read, base
## and pack: `pk2` only .pk2 (the retail archives as before, plus any extra
## .pk2 pack), `pk3` only .pk3/.zip, `mixed` (the default) every type.
##
## Packs (rules 1-2, discover_packs): every `*.pk3`, `*.zip` and `*.pk2` the
## mode reads in the pack folder (Pk2Config.pack_dir: OPENSRO_PACK_DIR, else
## the folder Data resolved to; no subfolders) whose name is not one of the
## five base names. They cascade by name, case ignored: a later name wins
## (`z_assets` over `assets`); of one name `.pk2` < `.zip` < `.pk3`; a tie
## after that by the exact file name. The base archives are always the
## bottom layer whatever the packs are called.
##
## custom/ (FrontEndTheme.custom_dir: OPENSRO_CUSTOM_DIR, else beside the
## executable, round 678's folder beside pk2/) is a path overlay above the
## packs, read in every mode: custom/prim/mtrl/x.ddj answers
## prim\mtrl\x.ddj. Its symbolic links are refused. Round 678's branding
## files live there too and are read by FrontEndTheme by their own paths.
##
## For the updater (round 789's lane U, OURS): reopen() reopens the set after
## new packs arrive -- see its comment.

const BASE_NAMES: Array[String] = ["Data", "Map", "Media", "Music", "Particles"]
## Of two packs with one name, the higher rank wins (OURS for .zip).
const EXT_RANK := {"pk2": 0, "zip": 1, "pk3": 2}
## Bounds on the custom/ scan (OURS): a development folder, not a game copy.
const MAX_CUSTOM_FILES := 20000
const MAX_CUSTOM_DEPTH := 16
## Overridden paths named in the load log per view; OPENSRO_PACK_LOG=all
## names every one.
const LOG_LISTED := 10
## Overlay paths a view's override census checks (OURS: a bound on the
## load-time cost of a huge pack).
const CENSUS_MAX := 200000

var mode := Pk2Config.MODE_MIXED
var generation := 0
## Volume name -> its base files, highest first (a String is one file).
var base_paths := {}
var pack_dir := ""
var custom_dir := ""
## The packs opened, lowest priority first (layer ids 1..n).
var pack_paths := PackedStringArray()
var overlay := LayeredArchive.Overlay.new()
## Every line this set has logged (the debug panel shows them).
var log_lines := PackedStringArray()
var _bases := {}
var _views := {}
var _lock := Mutex.new()

## A set from explicit options (the process's own set comes from current();
## tests build theirs): {mode, base_paths: {Data: path or [paths, highest
## first], ...}, pack_dir, custom_dir, generation}.
static func open_set(opts: Dictionary) -> AssetArchives:
	var s := AssetArchives.new()
	s.mode = str(opts.get("mode", Pk2Config.MODE_MIXED))
	s.base_paths = opts.get("base_paths", {})
	s.pack_dir = str(opts.get("pack_dir", ""))
	s.custom_dir = str(opts.get("custom_dir", ""))
	s.generation = int(opts.get("generation", 0))
	var t0 := Time.get_ticks_usec()
	s._open_packs()
	s._index_custom()
	var origin := str(opts.get("mode_origin", ""))
	s._say("AssetArchives: set %d, source mode %s%s; %d pack(s) from %s; %d custom/ file(s); %d overlay path(s); opened in %d ms" % [
		s.generation, s.mode, " (from %s)" % origin if origin != "" else "",
		s.pack_paths.size(), s.pack_dir if s.pack_dir != "" else "(no folder)", s.overlay.custom.size(),
		s.overlay.index.size(), (Time.get_ticks_usec() - t0) / 1000])
	return s

## The packs in `dir` under `mode`, lowest priority first (absolute paths).
static func discover_packs(dir: String, mode: String) -> PackedStringArray:
	var out := PackedStringArray()
	if dir == "":
		return out
	var da := DirAccess.open(dir)
	if da == null:
		return out
	var found: Array = []
	for f in da.get_files():
		var ext := f.get_extension().to_lower()
		if not EXT_RANK.has(ext):
			continue
		if (mode == Pk2Config.MODE_PK3 and ext == "pk2") or (mode == Pk2Config.MODE_PK2 and ext != "pk2"):
			continue
		var stem := f.get_basename().to_lower()
		if is_base_stem(stem):
			continue
		found.append([stem, int(EXT_RANK[ext]), f])
	found.sort_custom(func(a: Array, b: Array) -> bool:
		if a[0] != b[0]:
			return a[0] < b[0]
		if a[1] != b[1]:
			return a[1] < b[1]
		return a[2] < b[2])
	for item in found:
		out.append(dir.path_join(item[2]))
	return out

## True for the five base names, case ignored ("data", "MAP", ...).
static func is_base_stem(stem: String) -> bool:
	for n in BASE_NAMES:
		if n.to_lower() == stem.to_lower():
			return true
	return false

func _say(line: String) -> void:
	log_lines.append(line)
	print(line)

func _open_packs() -> void:
	for p in discover_packs(pack_dir, mode):
		var r := Pk2Reader.open(p)
		if r == null:
			_say("AssetArchives: pack %s did not open -- skipped" % p)
			continue
		var lid := overlay.layers.size()
		r.layer_id = lid
		overlay.layers.append(r)
		overlay.layer_names.append(p.get_file())
		pack_paths.append(p)
		var files := r.file_paths()
		var shadowed := {}
		var unsafe := 0
		for f in files:
			var sp := Pk3Reader.safe_path(f)
			if sp.size() == 1 or sp[1]:
				unsafe += 1
				continue
			var before := overlay.put(sp[0], lid)
			if before > 0:
				shadowed[before] = int(shadowed.get(before, 0)) + 1
		var kind := "pk2" if not (r is Pk3Reader) else ("zip64" if (r as Pk3Reader).zip64 else "zip")
		_say("AssetArchives: pack %d %s: %d file(s) (%s, %s)" % [lid, p.get_file(), files.size() - unsafe, kind, "native" if r.is_native() else "GDScript"])
		for below in shadowed:
			_say("AssetArchives:   %s overrides %d path(s) of %s" % [p.get_file(), shadowed[below], overlay.layer_names[below]])
		if r is Pk3Reader and (r as Pk3Reader).refused_count > 0:
			var pr := r as Pk3Reader
			_say("AssetArchives:   %s: %d entr%s REFUSED: %s" % [p.get_file(), pr.refused_count, "y" if pr.refused_count == 1 else "ies",
				"; ".join(pr.refused.slice(0, LOG_LISTED))])
		if unsafe > 0:
			_say("AssetArchives:   %s: %d unsafe name(s) left out" % [p.get_file(), unsafe])

func _index_custom() -> void:
	if custom_dir == "" or not DirAccess.dir_exists_absolute(custom_dir):
		return
	var files: Array = []
	var refused: Array = []
	_scan_custom(custom_dir, "", 0, files, refused)
	if not refused.is_empty():
		_say("AssetArchives: custom/ %s: %d entr%s REFUSED: %s" % [custom_dir, refused.size(), "y" if refused.size() == 1 else "ies",
			"; ".join(PackedStringArray(refused.slice(0, LOG_LISTED)))])
	for f in files:
		var rel: String = f[0]
		overlay.custom[rel.to_lower()] = [f[1], f[2], rel.get_file()]
		overlay.put(rel, LayeredArchive.LAYER_CUSTOM)
	if files.size() >= MAX_CUSTOM_FILES:
		_say("AssetArchives: custom/ holds more than %d files -- the rest are not overlaid" % MAX_CUSTOM_FILES)

## [relative `/` path, absolute path, size] of every file under dir. A
## symbolic link is refused (rule 6: nothing outside the folder is reachable
## through it), as is a file over the entry cap.
func _scan_custom(dir: String, rel: String, depth: int, out: Array, refused: Array) -> void:
	if depth > MAX_CUSTOM_DEPTH or out.size() >= MAX_CUSTOM_FILES:
		return
	var da := DirAccess.open(dir)
	if da == null:
		return
	for f in da.get_files():
		if out.size() >= MAX_CUSTOM_FILES:
			return
		if da.is_link(f):
			refused.append("%s: a symbolic link" % (rel + f))
			continue
		var sp := Pk3Reader.safe_path(rel + f)
		if sp.size() == 1:
			refused.append("%s: %s" % [rel + f, sp[0]])
			continue
		var abs_path := dir.path_join(f)
		var fa := FileAccess.open(abs_path, FileAccess.READ)
		if fa == null:
			continue
		if fa.get_length() > Pk3Reader.MAX_ENTRY_BYTES:
			refused.append("%s: larger than the 256 MiB entry cap" % (rel + f))
			continue
		out.append([rel + f, abs_path, fa.get_length()])
	for d in da.get_directories():
		if da.is_link(d):
			refused.append("%s/: a symbolic link" % (rel + d))
			continue
		_scan_custom(dir.path_join(d), rel + d + "/", depth + 1, out, refused)

## The base archive `name` (one of BASE_NAMES) on its own -- its highest
## base layer -- opened the first time it is asked for; null when missing.
func base(name: String) -> Pk2Reader:
	var vol := volume(name)
	return vol[0] if not vol.is_empty() else null

## A volume's base layers, highest first, opened the first time asked for
## (an archive that does not open is skipped and logged, rule 6).
func volume(name: String) -> Array:
	_lock.lock()
	var v := _volume_locked(name)
	_lock.unlock()
	return v

func _volume_locked(name: String) -> Array:
	if _bases.has(name):
		return _bases[name]
	var paths: Variant = base_paths.get(name, "")
	var list := PackedStringArray()
	if paths is String:
		if paths != "":
			list.append(paths)
	else:
		list = PackedStringArray(paths)
	var out: Array = []
	if list.is_empty():
		_say("AssetArchives: no %s archive (mode %s) -- not found beside the game or by its OPENSRO_*_PK2_PATH" % [name, mode])
	for path in list:
		var r := Pk2Reader.open(path)
		if r == null:
			_say("AssetArchives: %s at %s did not open -- skipped" % [name, path])
			continue
		out.append(r)
	# The lowest keeps layer 0; one above it is stamped before any entry is made.
	for i in range(out.size() - 1):
		(out[i] as Pk2Reader).layer_id = LayeredArchive.LAYER_UPPER_BASE - i
	for r in out:
		_say("AssetArchives: base %s = %s (%s)" % [name, (r as Pk2Reader).source_path, "native" if (r as Pk2Reader).is_native() else "GDScript"])
	_bases[name] = out
	return out

## What a caller reads `name` through: the base itself when nothing
## overlays it, else a LayeredArchive. Null when the volume has no base.
func view(name: String) -> Pk2Reader:
	_lock.lock()
	if _views.has(name):
		var hit: Pk2Reader = _views[name]
		_lock.unlock()
		return hit
	var vol := _volume_locked(name)
	var v: Pk2Reader = null
	if vol.size() == 1 and overlay.is_empty():
		v = vol[0]
	elif not vol.is_empty():
		v = LayeredArchive.make(name, vol, overlay, generation)
	_views[name] = v
	_lock.unlock()
	if v is LayeredArchive and not overlay.is_empty():
		_census(name, v as LayeredArchive)
	return v

## Logs, once per view, every overlay path the base archive also holds: an
## override (docs/TODO.md's "log every override at load").
func _census(name: String, b: LayeredArchive) -> void:
	var t0 := Time.get_ticks_usec()
	var all := OS.get_environment("OPENSRO_PACK_LOG") == "all"
	var n := 0
	var checked := 0
	var named := PackedStringArray()
	for key in overlay.index:
		if checked >= CENSUS_MAX:
			break
		checked += 1
		if b.find_in_bases(key) != null:
			n += 1
			if all or named.size() < LOG_LISTED:
				named.append("%s <- %s" % [key, layer_label(int(overlay.index[key]))])
	var more := "" if all or n <= named.size() else ", ... (OPENSRO_PACK_LOG=all names all)"
	var partial := "" if checked >= overlay.index.size() else " (the first %d of %d overlay paths checked)" % [checked, overlay.index.size()]
	if n == 0:
		_say("AssetArchives: %s: no path of %s is overridden%s (%d ms)" % [name, b.source_path.get_file(), partial, (Time.get_ticks_usec() - t0) / 1000])
	else:
		_say("AssetArchives: %s: %d path(s) of %s overridden%s (%d ms): %s%s" % [name, n, b.source_path.get_file(), partial,
			(Time.get_ticks_usec() - t0) / 1000, "; ".join(named), more])

## "custom/" or a pack's file name for a layer id.
func layer_label(lid: int) -> String:
	if lid == LayeredArchive.LAYER_CUSTOM:
		return "custom/"
	if lid > 0 and lid < overlay.layer_names.size():
		return overlay.layer_names[lid]
	return "base"

## Which layer serves `path` (the QA question): {path, served_by, file,
## also_in: [labels below it that hold the path too]}. Labels are "custom/",
## a pack's file name, or "base <file>" ("base Data.pk2"). A path only base
## archives hold is served by the volume asked (rule 3), so every base file
## that holds it is listed, in the unscoped order (Data first).
func which(path: String) -> Dictionary:
	var key := LayeredArchive.key_of(path)
	var hits: Array = []
	if key == "":
		return {"path": path, "served_by": "", "file": "", "also_in": PackedStringArray()}
	if overlay.custom.has(key):
		hits.append(["custom/", str(overlay.custom[key][0])])
	for lid in range(overlay.layers.size() - 1, 0, -1):
		var r: Pk2Reader = overlay.layers[lid]
		var e := r.find_entry(key)
		if e != null and not e.is_dir:
			hits.append([overlay.layer_names[lid], r.source_path])
	for name in BASE_NAMES:
		for b in volume(name):
			var e := (b as Pk2Reader).find_entry(key)
			if e != null and not e.is_dir:
				hits.append(["base " + (b as Pk2Reader).source_path.get_file(), (b as Pk2Reader).source_path])
	var also := PackedStringArray()
	for i in range(1, hits.size()):
		also.append(hits[i][0])
	return {"path": path, "served_by": hits[0][0] if not hits.is_empty() else "", "file": hits[0][1] if not hits.is_empty() else "", "also_in": also}

static func describe_which(w: Dictionary) -> String:
	if str(w["served_by"]) == "":
		return "%s -> not in any layer" % w["path"]
	var also: PackedStringArray = w["also_in"]
	return "%s -> %s (%s)%s" % [w["path"], w["served_by"], w["file"], "" if also.is_empty() else "; also in " + ", ".join(also)]

## The set in a few lines (the debug panel).
func describe() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("source mode %s (%s), set %d" % [mode, Pk2Config.source_mode_origin(), generation])
	for name in BASE_NAMES:
		var paths: Variant = base_paths.get(name, "")
		var shown := str(paths) if paths is String else ", ".join(PackedStringArray(paths))
		_lock.lock()
		var opened: bool = _bases.has(name)
		_lock.unlock()
		out.append("%s %s%s" % [name, shown if shown != "" else "(none)", " (open)" if opened else ""])
	out.append("packs in %s: %d (highest first)" % [pack_dir if pack_dir != "" else "(no folder)", pack_paths.size()])
	for lid in range(overlay.layers.size() - 1, 0, -1):
		out.append("  %d %s" % [lid, overlay.layer_names[lid]])
	out.append("custom/ %s: %d file(s); %d overlay path(s)" % [custom_dir, overlay.custom.size(), overlay.index.size()])
	return out

# --- The process's set -------------------------------------------------------

static var _cur: AssetArchives = null
static var _sig := ""
static var _gen := 0
static var _slock := Mutex.new()

static func data() -> Pk2Reader:
	return current().view("Data")

static func map() -> Pk2Reader:
	return current().view("Map")

static func media() -> Pk2Reader:
	return current().view("Media")

static func music() -> Pk2Reader:
	return current().view("Music")

static func particles() -> Pk2Reader:
	return current().view("Particles")

## The set every scene reads from, built on first use. Rebuilt when an
## environment variable it depends on changes (a test, a tool); otherwise
## only reopen() rebuilds it. (Not "reload": that name is every GDScript
## class's own Script.reload, which AssetArchives.reload() would call.)
static func current() -> AssetArchives:
	_slock.lock()
	var sig := _signature()
	var fresh := false
	if _cur == null or sig != _sig:
		if _cur != null:
			Pk2Config.reset_source_mode()
		_gen += 1
		_cur = open_set(_config_opts(_gen))
		_sig = sig
		fresh = true
	var c := _cur
	_slock.unlock()
	if fresh:
		_qa_which(c)
	return c

## For lane U (the updater) and anything that changes the archive folder at
## run time: reads the source mode and the folders again, opens the packs
## anew, and returns the new set. Handles taken before keep reading the set
## they came from (its readers stay open while referenced); every
## AssetArchives.data()/media()/... after it gets the new one, and the
## parsed-table caches keyed by Pk2Reader.cache_key() parse again. Call it
## where no scene holds archive handles it must see change -- before the
## login screen opens its Media, or between scenes -- and then reopen.
static func reopen() -> AssetArchives:
	_slock.lock()
	Pk2Config.reset_source_mode()
	_cur = null
	_slock.unlock()
	return current()

## The current set's generation (1 for the first; 0 before any): a cache of
## anything read from the archives can compare it to know it is stale.
static func current_generation() -> int:
	return _gen

static func _signature() -> String:
	var parts := PackedStringArray()
	for v in ["OPENSRO_ASSET_SOURCE", "OPENSRO_PK2_PATH", "OPENSRO_MAP_PK2_PATH", "OPENSRO_MEDIA_PK2_PATH",
			"OPENSRO_MUSIC_PK2_PATH", "OPENSRO_PARTICLES_PK2_PATH", "OPENSRO_PACK_DIR", "OPENSRO_CUSTOM_DIR"]:
		parts.append(OS.get_environment(v))
	return "|".join(parts)

static func _config_opts(gen: int) -> Dictionary:
	return {
		"mode": Pk2Config.source_mode(),
		"mode_origin": Pk2Config.source_mode_origin(),
		"base_paths": {
			"Data": Pk2Config.volume_chain("Data"), "Map": Pk2Config.volume_chain("Map"), "Media": Pk2Config.volume_chain("Media"),
			"Music": Pk2Config.volume_chain("Music"), "Particles": Pk2Config.volume_chain("Particles"),
		},
		"pack_dir": Pk2Config.pack_dir(),
		"custom_dir": FrontEndTheme.custom_dir(),
		"generation": gen,
	}

## OPENSRO_QA_WHICH="path;path;..." (QA, OURS): once per set, logs which
## layer serves each path -- `QA WHICH <path> -> <layer> (<file>); also in
## ...`. client/tools/which_layer.gd asks the same without a game run.
static func _qa_which(c: AssetArchives) -> void:
	var spec := OS.get_environment("OPENSRO_QA_WHICH")
	if spec == "":
		return
	for p in spec.split(";", false):
		print("QA WHICH " + describe_which(c.which(p.strip_edges())))
