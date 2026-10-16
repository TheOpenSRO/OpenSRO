extends SceneTree

## Round 789, lane U: PackSync end to end in one process -- a fake gateway
## answering the pack question on this project's framing, a test HTTP
## listener serving the pack, an empty pack folder (all in user://, no game
## data) -- driven by hand, frame by frame:
## 1. the first sync downloads the pack, verifies it and layers it: the
##    shared archive set reads the pack's file;
## 2. a second sync downloads nothing and does not reopen the set;
## 3. a pack changed on disk is hashed, found different, fetched again;
## 4. a server that names no packs puts the player's own set back;
## 5. a server that never answers (older than round 789): the player's own
##    set after the timeout, and the address is not asked again this run;
## 6. a list with an unsafe name is refused, nothing changed.

const Z := preload("res://scripts/pk2/pk3_test_archives.gd")
const Servers := preload("res://scripts/update/pack_test_servers.gd")
const ROOT := "user://pack_sync_test"

var _failures := 0
var gw := Servers.FakeGateway.new()
var http := Servers.TestHttp.new()

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _abs(p: String) -> String:
	return ProjectSettings.globalize_path(p)

static func _sha(data: PackedByteArray) -> String:
	var c := HashingContext.new()
	c.start(HashingContext.HASH_SHA256)
	c.update(data)
	return c.finish().hex_encode()

func _read(a: Pk2Reader, path: String) -> String:
	var e := ObjectLoader.find_file(a, path) if a != null else null
	return "<none>" if e == null else a.read_file(e).get_string_from_utf8()

func _manifest(packs: Array) -> PackedByteArray:
	var m := PackManifest.new()
	m.required = true
	m.http_port = http.port
	for p in packs:
		var pk := PackManifest.Pack.new()
		pk.name = p[0]
		pk.size = (p[1] as PackedByteArray).size()
		pk.sha256 = _sha(p[1])
		m.packs.append(pk)
	return m.encode()

var _made: Array = []

func _sync(timeout_ms: int = 2500) -> PackSync:
	var s := PackSync.new()
	_made.append(s)
	s.query_timeout_ms = timeout_ms
	s.start("127.0.0.1", gw.port)
	var t0 := Time.get_ticks_msec()
	while not s.done and Time.get_ticks_msec() - t0 < 15000:
		gw.poll()
		http.poll()
		var q := s.get_node_or_null("PackQuery") as PackQuery
		if q != null and not q.is_done():
			q._process(0.0)
		if s.is_processing():
			s._process(0.0)
		OS.delay_msec(1)
	return s

func _clean(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_clean(dir.path_join(d))
	DirAccess.remove_absolute(dir)

func _run() -> void:
	_clean(_abs(ROOT))
	Z.write_pk2(ROOT + "/pk2/Data.pk2", {"server_dep/silkroad/textdata/test.txt": Z.text("base")})
	Z.write_zip(ROOT + "/pk2/a_mine.pk3", [Z.item("server_dep/silkroad/textdata/test.txt", Z.text("mine"))])
	OS.set_environment("OPENSRO_PK2_PATH", _abs(ROOT + "/pk2/Data.pk2"))
	OS.set_environment("OPENSRO_PACK_DIR", _abs(ROOT + "/pk2"))
	OS.set_environment("OPENSRO_CUSTOM_DIR", _abs(ROOT + "/no_custom"))
	ServerPacks.set_selection(null)
	AssetArchives.reopen()
	_check(_read(AssetArchives.data(), "server_dep\\silkroad\\textdata\\test.txt") == "mine", "before: the player's own pack serves")

	var pack := Z.zip_bytes([Z.item("server_dep/silkroad/textdata/test.txt", Z.text("server")), Z.item("prim/new.txt", Z.text("new"))])
	http.routes["/packs/z_server.pk3"] = {"body": pack, "mode": "range"}
	gw.payload = _manifest([["z_server.pk3", pack]])

	# 1. The first login: downloaded, verified, layered.
	var g0 := AssetArchives.current_generation()
	var s := _sync()
	var folder := _abs(ROOT + "/pk2/servers/127.0.0.1_%d" % gw.port)
	_check(s.ok and s.fetched == 1, "first sync: ok, one pack downloaded (%s)" % s.why)
	_check(FileAccess.get_file_as_bytes(folder.path_join("z_server.pk3")) == pack, "the pack is in the server's own folder")
	_check(AssetArchives.current_generation() == g0 + 1, "the archive set was reopened")
	_check(_read(AssetArchives.data(), "server_dep\\silkroad\\textdata\\test.txt") == "server", "the server's pack serves, not the player's")
	_check(str(AssetArchives.current().which("prim/new.txt")["served_by"]) == "z_server.pk3", "which(): the server's pack")
	var fetches := http.requests.size()

	# 2. The second login: nothing downloaded, nothing reopened.
	s = _sync()
	_check(s.ok and s.fetched == 0 and s.hashed == 0 and s.reused == 1, "second sync: verified before, nothing fetched or hashed (%s)" % s.why)
	_check(http.requests.size() == fetches, "no HTTP request the second time")
	_check(AssetArchives.current_generation() == g0 + 1, "and the set is not reopened")

	# 3. Changed on disk (same size, other bytes): hashed, fetched again.
	var bad := pack.duplicate()
	bad[bad.size() - 30] = bad[bad.size() - 30] ^ 0xff
	var f := FileAccess.open(folder.path_join("z_server.pk3"), FileAccess.WRITE)
	f.store_buffer(bad)
	f.close()
	var cache := PackStore.new(folder)
	cache.cache["z_server.pk3"]["mtime"] = 1 # as if the file moved since it was verified
	cache.save_cache()
	s = _sync()
	_check(s.ok and s.hashed == 1 and s.fetched == 1, "a changed pack: hashed, found different, fetched again (%s)" % s.why)
	_check(FileAccess.get_file_as_bytes(folder.path_join("z_server.pk3")) == pack, "the server's version is back")

	# 4. A server that names no packs: the player's own set again.
	gw.payload = PackedByteArray([1, 0, 0, 0, 0])
	s = _sync()
	_check(s.ok and ServerPacks.active() == null, "no packs named: no selection (%s)" % s.why)
	_check(_read(AssetArchives.data(), "server_dep\\silkroad\\textdata\\test.txt") == "mine", "the player's own pack serves again")

	# 6. A list with an unsafe name: refused, nothing changes.
	gw.payload = _manifest([["z_server.pk3", pack]])
	var raw: PackedByteArray = gw.payload
	raw[6] = "/".unicode_at(0) # the name's first byte: "/_server.pk3"
	gw.payload = raw
	s = _sync()
	_check(not s.ok and s.why.contains("cannot be read"), "an unsafe name: the list is refused (%s)" % s.why)
	_check(ServerPacks.active() == null, "and nothing is layered")

	# 5. An older server: never answers.
	gw.payload = null
	var t0 := Time.get_ticks_msec()
	s = _sync(600)
	_check(s.ok and Time.get_ticks_msec() - t0 >= 550, "no answer: the player's own packs after the timeout (%s)" % s.why)
	_check(PackSync._no_list.has("127.0.0.1:%d" % gw.port), "the address is remembered as an older server for this run")

func _init() -> void:
	if not gw.start() or not http.start():
		_check(false, "the test servers listen")
	else:
		_run()
		gw.stop()
		http.stop()
	for s in _made:
		(s as Node).free()
	ServerPacks.set_selection(null)
	AssetArchives._cur = null
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
