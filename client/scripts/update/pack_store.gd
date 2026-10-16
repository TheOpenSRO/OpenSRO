extends RefCounted
class_name PackStore

## Where a server's packs live on the player's disk, and what is already
## there (round 789, lane U; OURS, docs/protocol/asset_packs.md "Server
## packs").
##
## Each server gets a folder of its own, `<pack folder>/servers/<host>_<port>/`
## (server_key), so two servers in the list that ship different packs of the
## same name never overwrite each other's. The pack folder is the one the
## client reads its packs from (Pk2Config.pack_dir: the pk2/ folder beside the
## executable, or OPENSRO_PACK_DIR); the readers never look into subfolders,
## so a server's packs are read only while that server is the one connected
## (ServerPacks).
##
## The folder is the client's own: files the manifest no longer names are
## removed (sweep), and nothing else is ever written outside it. A pack is
## written as `<name>.<first 16 hex of its hash>.partial` and renamed to
## `<name>` only after its size and SHA-256 match the manifest's; the hash in
## the partial's name keeps a half-downloaded old version from being resumed
## into a new one.
##
## The hash cache (`packs.json` in the folder): name -> {size, mtime, sha256}
## of every pack this client verified. A pack whose size and modified time
## still match its entry is not hashed again at the next login (a multi-GB
## pack would cost seconds every time); anything else is.

const CACHE_FILE := "packs.json"
const CACHE_VERSION := 1
const SERVERS_DIR := "servers"
const PARTIAL_EXT := ".partial"

var dir := ""
## name -> {"size": int, "mtime": int, "sha256": String}
var cache := {}

## "<host>_<port>": the host lower-cased, every character outside [a-z0-9.-]
## an underscore (an IPv6 address's colons included), at most 80 of them.
static func server_key(host: String, port: int) -> String:
	var h := host.strip_edges().to_lower()
	var out := ""
	for i in range(mini(h.length(), 80)):
		var c := h[i]
		var ok := (c >= "a" and c <= "z") or (c >= "0" and c <= "9") or c == "." or c == "-"
		out += c if ok else "_"
	if out == "" or out.begins_with("."):
		out = "_" + out
	return "%s_%d" % [out, port]

## The folder every server's packs go under: <pack folder>/servers.
static func servers_root() -> String:
	return Pk2Config.pack_dir().path_join(SERVERS_DIR)

static func for_server(host: String, port: int) -> PackStore:
	return PackStore.new(servers_root().path_join(server_key(host, port)))

func _init(p_dir: String) -> void:
	dir = p_dir
	load_cache()

func path_of(name: String) -> String:
	return dir.path_join(name)

func partial_of(name: String, sha256: String) -> String:
	return dir.path_join("%s.%s%s" % [name, sha256.left(16), PARTIAL_EXT])

func ensure_dir() -> bool:
	if DirAccess.dir_exists_absolute(dir):
		return true
	return DirAccess.make_dir_recursive_absolute(dir) == OK

func load_cache() -> void:
	cache = {}
	var path := dir.path_join(CACHE_FILE)
	if not FileAccess.file_exists(path):
		return
	# JSON.parse, not parse_string: a damaged cache is simply not used (no
	# engine error line).
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK:
		return
	var parsed = json.data
	if not (parsed is Dictionary) or int(parsed.get("v", 0)) != CACHE_VERSION or not (parsed.get("files") is Dictionary):
		return
	for name in parsed["files"]:
		var e = parsed["files"][name]
		if e is Dictionary and PackManifest.name_problem(str(name)) == "":
			cache[str(name)] = {"size": int(e.get("size", -1)), "mtime": int(e.get("mtime", -1)), "sha256": str(e.get("sha256", ""))}

func save_cache() -> bool:
	if not ensure_dir():
		return false
	var tmp := dir.path_join(CACHE_FILE + ".tmp")
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify({"v": CACHE_VERSION, "files": cache}, " "))
	f.close()
	return _replace(tmp, dir.path_join(CACHE_FILE))

## Records a verified pack.
func remember(name: String, sha256: String) -> void:
	var p := path_of(name)
	cache[name] = {"size": _size(p), "mtime": int(FileAccess.get_modified_time(p)), "sha256": sha256}

## What to do for each pack of `m`: an Array of Dictionaries
## {pack, path, action, why}, action one of
## - "ready": on disk at its size, and the cache says its hash is the one named;
## - "hash":  on disk at its size, but not hashed since it last changed: hash it,
##            then it is ready or fetched;
## - "fetch": missing, another size, or a known other hash: download it.
func plan(m: PackManifest) -> Array:
	var out: Array = []
	for p in m.packs:
		var pk := p as PackManifest.Pack
		var path := path_of(pk.name)
		var step := {"pack": pk, "path": path, "action": "fetch", "why": ""}
		var size := _size(path)
		if size < 0:
			step["why"] = "not here"
		elif size != pk.size:
			step["why"] = "%d bytes here, %d named" % [size, pk.size]
		else:
			var e: Dictionary = cache.get(pk.name, {})
			var fresh: bool = not e.is_empty() and int(e["size"]) == size and int(e["mtime"]) == int(FileAccess.get_modified_time(path))
			if not fresh:
				step["action"] = "hash"
				step["why"] = "not verified since it last changed"
			elif str(e["sha256"]) == pk.sha256:
				step["action"] = "ready"
				step["why"] = "verified before"
			else:
				step["why"] = "another version here"
		out.append(step)
	return out

## Removes what the manifest does not name from the folder: older packs,
## their partials, partials of another version. Only file names this client
## writes are touched (a pack name, or one with the partial suffix).
func sweep(m: PackManifest) -> PackedStringArray:
	var keep := {}
	for p in m.packs:
		var pk := p as PackManifest.Pack
		keep[pk.name] = true
		keep[partial_of(pk.name, pk.sha256).get_file()] = true
	var removed := PackedStringArray()
	if not DirAccess.dir_exists_absolute(dir):
		return removed
	for f in DirAccess.get_files_at(dir):
		if keep.has(f) or f == CACHE_FILE:
			continue
		var base := f
		if f.ends_with(PARTIAL_EXT):
			base = f.substr(0, f.length() - PARTIAL_EXT.length())
			base = base.substr(0, base.rfind(".")) if base.rfind(".") > 0 else base
		if PackManifest.name_problem(base) != "":
			continue
		if DirAccess.remove_absolute(dir.path_join(f)) == OK:
			removed.append(f)
			cache.erase(f)
	for name in cache.keys():
		if not keep.has(name):
			cache.erase(name)
	return removed

## The packs of `m` as files, lowest first (what AssetArchives layers).
func paths(m: PackManifest) -> PackedStringArray:
	var out := PackedStringArray()
	for p in m.packs:
		out.append(path_of((p as PackManifest.Pack).name))
	return out

static func _size(path: String) -> int:
	if not FileAccess.file_exists(path):
		return -1
	var f := FileAccess.open(path, FileAccess.READ)
	return -1 if f == null else int(f.get_length())

## Renames `from` onto `to`, replacing it (DirAccess.rename replaces on
## every platform Godot 4.7 runs on; UpdateFs's note on Windows).
static func _replace(from: String, to: String) -> bool:
	return DirAccess.rename_absolute(from, to) == OK

## Bytes free where the folder is (or its nearest existing parent); -1 when
## the platform cannot say.
func space_left() -> int:
	var d := dir
	while d != "" and not DirAccess.dir_exists_absolute(d):
		var up := d.get_base_dir()
		if up == d:
			break
		d = up
	var da := DirAccess.open(d)
	return -1 if da == null else int(da.get_space_left())

# --- Hashing a file a slice at a time -------------------------------------------

## SHA-256 of a file, read in slices so a frame is never held for a large
## pack (poll() hashes at most `budget` bytes). OURS.
class FileHasher:
	var path := ""
	var size := 0
	var done := 0
	var hex := ""
	var error := ""
	## A prefix (a resumed download): the context is left open, not finished,
	## so what follows can be hashed into it (context()).
	var prefix := false
	var _f: FileAccess = null
	var _ctx := HashingContext.new()

	func _init(p_path: String, upto: int = -1, p_prefix: bool = false) -> void:
		path = p_path
		prefix = p_prefix
		_f = FileAccess.open(path, FileAccess.READ)
		if _f == null:
			error = "cannot open %s" % path
			return
		size = int(_f.get_length()) if upto < 0 else mini(upto, int(_f.get_length()))
		_ctx.start(HashingContext.HASH_SHA256)

	## Hashes up to `budget` more bytes; true once finished (hex or error set).
	func poll(budget: int = 32 << 20) -> bool:
		if error != "" or hex != "" or (prefix and done >= size and _f == null):
			return true
		var left := budget
		while left > 0 and done < size:
			var n := mini(mini(left, 1 << 20), size - done)
			var b := _f.get_buffer(n)
			if b.size() != n:
				error = "%s: read %d of %d bytes at %d" % [path, b.size(), n, done]
				_f = null
				return true
			_ctx.update(b)
			done += n
			left -= n
		if done >= size:
			if not prefix:
				hex = _ctx.finish().hex_encode()
			_f = null
			return true
		return false

	## The context so far (a resumed download keeps hashing what follows).
	func context() -> HashingContext:
		return _ctx
