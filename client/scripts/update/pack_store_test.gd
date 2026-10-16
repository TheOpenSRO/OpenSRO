extends SceneTree

## Round 789, lane U: PackStore -- the per-server folder, the plan against
## what is on disk, the hash cache that spares a re-hash at every login, the
## sweep -- and its FileHasher, on files written here in user:// (no game
## data).

const ROOT := "user://pack_store_test"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _abs(p: String) -> String:
	return ProjectSettings.globalize_path(p)

func _write(path: String, data: PackedByteArray) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(data)
	f.close()

static func _sha(data: PackedByteArray) -> String:
	var c := HashingContext.new()
	c.start(HashingContext.HASH_SHA256)
	c.update(data)
	return c.finish().hex_encode()

func _pack(name: String, data: PackedByteArray) -> PackManifest.Pack:
	var p := PackManifest.Pack.new()
	p.name = name
	p.size = data.size()
	p.sha256 = _sha(data)
	return p

func _manifest(packs: Array) -> PackManifest:
	var m := PackManifest.new()
	m.required = true
	m.http_port = 15780
	m.packs = packs
	return m

func _actions(plan: Array) -> Array:
	var out := []
	for st in plan:
		out.append(str(st["action"]))
	return out

func _clean(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_clean(dir.path_join(d))
	DirAccess.remove_absolute(dir)

func _test_keys() -> void:
	_check(PackStore.server_key("Login.Example.com", 15779) == "login.example.com_15779", "a host name, lower-cased")
	_check(PackStore.server_key("192.168.10.78", 15779) == "192.168.10.78_15779", "an IPv4 address")
	_check(PackStore.server_key("::1", 15779) == "__1_15779", "an IPv6 address: no colon in a folder name")
	_check(PackStore.server_key("../../etc", 1) == "_.._.._etc_1", "no separator survives, and no leading dot")
	_check(PackStore.server_key("a", 1) != PackStore.server_key("a", 2), "two ports of one host are two folders")

func _test_plan_and_cache() -> void:
	var dir := _abs(ROOT + "/servers/s_1")
	_clean(_abs(ROOT))
	var a := "pack a".to_utf8_buffer()
	var b := "pack b, a longer one".to_utf8_buffer()
	var c := "pack c".to_utf8_buffer()
	var d := "pack d".to_utf8_buffer()
	var m := _manifest([_pack("a.pk3", a), _pack("b.zip", b), _pack("c.pk3", c), _pack("d.pk3", d)])
	var s := PackStore.new(dir)
	_check(_actions(s.plan(m)) == ["fetch", "fetch", "fetch", "fetch"], "an empty folder: fetch everything")
	_write(dir.path_join("a.pk3"), a)
	_write(dir.path_join("b.zip"), "short".to_utf8_buffer())
	_write(dir.path_join("c.pk3"), "pack C".to_utf8_buffer()) # the right size, other bytes
	var plan := s.plan(m)
	_check(_actions(plan) == ["hash", "fetch", "hash", "fetch"], "on disk at its size: hash; another size: fetch (%s)" % [_actions(plan)])
	# Hash a and c as PackSync does, and remember the one that matches.
	for i in [0, 2]:
		var h := PackStore.FileHasher.new(str(plan[i]["path"]))
		while not h.poll(3):
			pass
		var pk := plan[i]["pack"] as PackManifest.Pack
		if h.hex == pk.sha256:
			s.remember(pk.name, pk.sha256)
		else:
			s.cache[pk.name] = {"size": pk.size, "mtime": int(FileAccess.get_modified_time(str(plan[i]["path"]))), "sha256": h.hex}
	_check(s.save_cache(), "the cache is written")
	var s2 := PackStore.new(dir)
	_check(s2.cache.has("a.pk3") and str(s2.cache["a.pk3"]["sha256"]) == _sha(a), "the cache reads back")
	plan = s2.plan(m)
	_check(_actions(plan) == ["ready", "fetch", "fetch", "fetch"], "a verified pack is ready without hashing; a known other version is fetched (%s)" % [_actions(plan)])
	_check(str(plan[2]["why"]) == "another version here", "the reason says so")
	# A pack that changed since it was verified (its modified time moved) is hashed again.
	s2.cache["a.pk3"]["mtime"] = int(s2.cache["a.pk3"]["mtime"]) - 10
	_check(_actions(s2.plan(m))[0] == "hash", "a changed modified time: hash again")
	# A corrupt cache file is ignored, not trusted.
	_write(dir.path_join(PackStore.CACHE_FILE), "{not json".to_utf8_buffer())
	_check(PackStore.new(dir).cache.is_empty(), "an unreadable cache is empty")
	_write(dir.path_join(PackStore.CACHE_FILE), JSON.stringify({"v": 1, "files": {"../x.pk3": {"size": 1, "mtime": 1, "sha256": "00"}}}).to_utf8_buffer())
	_check(PackStore.new(dir).cache.is_empty(), "a cached name that is not a pack name is dropped")
	_check(s2.paths(m) == PackedStringArray([dir.path_join("a.pk3"), dir.path_join("b.zip"), dir.path_join("c.pk3"), dir.path_join("d.pk3")]),
		"paths: the manifest's order, in the server's folder")

func _test_sweep() -> void:
	var dir := _abs(ROOT + "/servers/s_2")
	_clean(dir)
	var keep := "kept".to_utf8_buffer()
	var pk := _pack("z_keep.pk3", keep)
	var m := _manifest([pk])
	var s := PackStore.new(dir)
	_write(dir.path_join("z_keep.pk3"), keep)
	_write(s.partial_of("z_keep.pk3", pk.sha256), "half".to_utf8_buffer())
	_write(dir.path_join("old.pk3"), "x".to_utf8_buffer())
	_write(dir.path_join("z_keep.pk3.0123456789abcdef.partial"), "x".to_utf8_buffer())
	_write(dir.path_join("notes.txt"), "the player's".to_utf8_buffer())
	s.cache["old.pk3"] = {"size": 1, "mtime": 1, "sha256": "00"}
	var removed := s.sweep(m)
	removed.sort()
	_check(removed == PackedStringArray(["old.pk3", "z_keep.pk3.0123456789abcdef.partial"]), "sweep: an unnamed pack and another version's partial go (%s)" % [removed])
	_check(FileAccess.file_exists(dir.path_join("z_keep.pk3")) and FileAccess.file_exists(s.partial_of("z_keep.pk3", pk.sha256)),
		"sweep: the named pack and its own partial stay")
	_check(FileAccess.file_exists(dir.path_join("notes.txt")), "sweep: a file the client did not write stays")
	_check(not s.cache.has("old.pk3"), "sweep: the cache forgets what went")

func _test_hasher() -> void:
	var path := _abs(ROOT + "/hash.bin")
	var data := PackedByteArray()
	for i in range(100000):
		data.append(i % 251)
	_write(path, data)
	var h := PackStore.FileHasher.new(path)
	var polls := 0
	while not h.poll(4096):
		polls += 1
	_check(h.error == "" and h.hex == _sha(data), "FileHasher: the file's SHA-256, in slices")
	_check(polls >= 20, "FileHasher: a budget is a slice (%d polls)" % polls)
	# A prefix stays open: the rest hashed into it gives the whole file's hash.
	var p := PackStore.FileHasher.new(path, 30000, true)
	while not p.poll(7000):
		pass
	_check(p.hex == "" and p.done == 30000, "a prefix hashes its bytes and does not finish")
	var ctx := p.context()
	ctx.update(data.slice(30000))
	_check(ctx.finish().hex_encode() == _sha(data), "a prefix's context continues to the whole file's hash")
	var missing := PackStore.FileHasher.new(_abs(ROOT + "/none.bin"))
	_check(missing.poll() and missing.error != "", "a missing file is an error, not a hash")

func _init() -> void:
	_test_keys()
	_test_plan_and_cache()
	_test_sweep()
	_test_hasher()
	_clean(_abs(ROOT))
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
