extends SceneTree

## Round 789, lane U: PackDownload's state machine against a small HTTP
## server run in this same process (TestHttp below, polled in the same loop):
## a whole download, a resume after a partial left on disk, a source that
## ignores ranges, a connection cut mid-body and resumed, a source that sends
## more than the manifest's size, a wrong hash, a 404 with a second source, a
## redirect, plain http from a host that is not the game server's, and a
## stale partial of another version. Files are written in user:// only.

const ROOT := "user://pack_download_test"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

const Servers := preload("res://scripts/update/pack_test_servers.gd")

var srv := Servers.TestHttp.new()

func _abs(p: String) -> String:
	return ProjectSettings.globalize_path(p)

static func _sha(data: PackedByteArray) -> String:
	var c := HashingContext.new()
	c.start(HashingContext.HASH_SHA256)
	c.update(data)
	return c.finish().hex_encode()

func _body(n: int, seed: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(n)
	for i in range(n):
		b[i] = (i * 7 + seed) % 256
	return b

func _pack(name: String, body: PackedByteArray) -> PackManifest.Pack:
	var p := PackManifest.Pack.new()
	p.name = name
	p.size = body.size()
	p.sha256 = _sha(body)
	return p

func _url(path: String) -> String:
	return "http://127.0.0.1:%d%s" % [srv.port, path]

func _new_dl(pk: PackManifest.Pack, sources: PackedStringArray, dir: String) -> PackDownload:
	DirAccess.make_dir_recursive_absolute(dir)
	return PackDownload.new(pk, sources, "127.0.0.1", dir.path_join(pk.name), dir.path_join(pk.name + ".partial"))

func _run(dl: PackDownload, max_ms: int = 15000) -> void:
	dl.start()
	var t0 := Time.get_ticks_msec()
	while not dl.is_over() and Time.get_ticks_msec() - t0 < max_ms:
		srv.poll()
		dl.poll()
		OS.delay_msec(1)

func _file(path: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(path) if FileAccess.file_exists(path) else PackedByteArray()

func _write(path: String, data: PackedByteArray) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(data)
	f.close()

func _clean(dir: String) -> void:
	if DirAccess.dir_exists_absolute(dir):
		for f in DirAccess.get_files_at(dir):
			DirAccess.remove_absolute(dir.path_join(f))

func _test_whole() -> void:
	var dir := _abs(ROOT + "/whole")
	_clean(dir)
	var body := _body(300000, 1)
	srv.routes["/whole.pk3"] = {"body": body, "mode": "range"}
	var dl := _new_dl(_pack("whole.pk3", body), PackedStringArray([_url("/whole.pk3")]), dir)
	_run(dl)
	_check(dl.state == PackDownload.S_DONE, "a whole download is done (%s)" % dl.error)
	_check(_file(dir.path_join("whole.pk3")) == body, "the pack is on disk, byte for byte")
	_check(not FileAccess.file_exists(dir.path_join("whole.pk3.partial")), "no partial is left")
	var req: Array = srv.requests[-1]
	_check(not (req[1] as Dictionary).has("range"), "a fresh download asks no range")

func _test_resume() -> void:
	var dir := _abs(ROOT + "/resume")
	_clean(dir)
	var body := _body(200000, 2)
	srv.routes["/resume.pk3"] = {"body": body, "mode": "range"}
	_write(dir.path_join("resume.pk3.partial"), body.slice(0, 70000))
	var dl := _new_dl(_pack("resume.pk3", body), PackedStringArray([_url("/resume.pk3")]), dir)
	_run(dl)
	var req: Array = srv.requests[-1]
	_check(str((req[1] as Dictionary).get("range", "")) == "bytes=70000-", "a partial is resumed with a range (%s)" % (req[1] as Dictionary).get("range", ""))
	_check(dl.state == PackDownload.S_DONE and _file(dir.path_join("resume.pk3")) == body, "the resumed pack is whole and verified (%s)" % dl.error)

func _test_no_range() -> void:
	var dir := _abs(ROOT + "/norange")
	_clean(dir)
	var body := _body(150000, 3)
	srv.routes["/norange.pk3"] = {"body": body, "mode": "norange"}
	_write(dir.path_join("norange.pk3.partial"), body.slice(0, 50000))
	var dl := _new_dl(_pack("norange.pk3", body), PackedStringArray([_url("/norange.pk3")]), dir)
	_run(dl)
	_check(dl.state == PackDownload.S_DONE and _file(dir.path_join("norange.pk3")) == body,
		"a source that ignores the range: read from the start, still right (%s)" % dl.error)

func _test_cut() -> void:
	var dir := _abs(ROOT + "/cut")
	_clean(dir)
	var body := _body(400000, 4)
	srv.routes["/cut.pk3"] = {"body": body, "mode": "cut", "cut": 123456, "cuts": 2}
	var before := srv.requests.size()
	var dl := _new_dl(_pack("cut.pk3", body), PackedStringArray([_url("/cut.pk3")]), dir)
	_run(dl)
	_check(dl.state == PackDownload.S_DONE and _file(dir.path_join("cut.pk3")) == body, "two dropped connections, resumed: the pack is whole (%s)" % dl.error)
	_check(srv.requests.size() - before == 3, "three requests: one whole, two resumes (%d)" % (srv.requests.size() - before))
	var r2 := str((srv.requests[before + 1][1] as Dictionary).get("range", ""))
	_check(r2 == "bytes=123456-", "the first resume starts where the cut was (%s)" % r2)

func _test_lie() -> void:
	var dir := _abs(ROOT + "/lie")
	_clean(dir)
	var body := _body(50000, 5)
	srv.routes["/lie.pk3"] = {"body": body, "mode": "lie"}
	var dl := _new_dl(_pack("lie.pk3", body), PackedStringArray([_url("/lie.pk3")]), dir)
	_run(dl)
	_check(dl.state == PackDownload.S_FAILED, "a source whose file is larger than named fails (%s)" % dl.error)
	_check(not FileAccess.file_exists(dir.path_join("lie.pk3")), "and nothing is put in place")
	# No length declared: the bytes past the manifest's size stop it.
	srv.routes["/lie2.pk3"] = {"body": body, "mode": "lie_nolen"}
	dl = _new_dl(_pack("lie2.pk3", body), PackedStringArray([_url("/lie2.pk3")]), dir)
	_run(dl)
	_check(dl.state == PackDownload.S_FAILED and dl.error.contains("more than"), "a body past the named size is cut off (%s)" % dl.error)
	_check(not FileAccess.file_exists(dir.path_join("lie2.pk3")) and not FileAccess.file_exists(dir.path_join("lie2.pk3.partial")),
		"nothing is put in place, the partial is removed")

func _test_wrong_hash() -> void:
	var dir := _abs(ROOT + "/hash")
	_clean(dir)
	var body := _body(60000, 6)
	srv.routes["/hash.pk3"] = {"body": _body(60000, 7), "mode": "range"}
	var dl := _new_dl(_pack("hash.pk3", body), PackedStringArray([_url("/hash.pk3")]), dir)
	_run(dl)
	_check(dl.state == PackDownload.S_FAILED and dl.error.contains("hash"), "other bytes of the right size: the hash refuses them (%s)" % dl.error)
	_check(not FileAccess.file_exists(dir.path_join("hash.pk3")) and not FileAccess.file_exists(dir.path_join("hash.pk3.partial")),
		"nothing is put in place, the partial is removed")

func _test_fallback_and_redirect() -> void:
	var dir := _abs(ROOT + "/fallback")
	_clean(dir)
	var body := _body(80000, 8)
	srv.routes["/real/fb.pk3"] = {"body": body, "mode": "range"}
	srv.routes["/moved/fb.pk3"] = {"mode": "redirect", "location": "/real/fb.pk3"}
	var dl := _new_dl(_pack("fb.pk3", body), PackedStringArray([_url("/missing/fb.pk3"), _url("/moved/fb.pk3")]), dir)
	_run(dl)
	_check(dl.state == PackDownload.S_DONE and _file(dir.path_join("fb.pk3")) == body,
		"a 404 source, then a redirecting one: done (%s)" % dl.error)

func _test_refused_source() -> void:
	var dir := _abs(ROOT + "/refused")
	_clean(dir)
	var body := _body(1000, 9)
	var dl := PackDownload.new(_pack("r.pk3", body), PackedStringArray(["http://evil.example.com/r.pk3"]), "127.0.0.1",
		dir.path_join("r.pk3"), dir.path_join("r.pk3.partial"))
	_run(dl)
	_check(dl.state == PackDownload.S_FAILED and dl.error.contains("plain http"), "plain http from another host is never fetched (%s)" % dl.error)

func _test_stale_partial() -> void:
	var dir := _abs(ROOT + "/stale")
	_clean(dir)
	var body := _body(90000, 10)
	srv.routes["/stale.pk3"] = {"body": body, "mode": "range"}
	_write(dir.path_join("stale.pk3.partial"), _body(40000, 99)) # another version's first bytes
	var dl := _new_dl(_pack("stale.pk3", body), PackedStringArray([_url("/stale.pk3")]), dir)
	_run(dl)
	_check(dl.state == PackDownload.S_DONE and _file(dir.path_join("stale.pk3")) == body,
		"a stale partial: the hash fails once, the pack is fetched again whole (%s)" % dl.error)

func _test_helpers() -> void:
	_check(PackDownload.parse_content_range("bytes 100-199/200") == {"start": 100, "end": 199, "total": 200}, "Content-Range parses")
	_check(PackDownload.parse_content_range("bytes 0-9/*")["total"] == -1, "an unknown total")
	_check(PackDownload.parse_content_range("items 1-2/3").is_empty(), "not bytes: refused")
	_check(PackDownload.resolve_location("https://a.example/x/y.pk3?q=1", "/z.pk3") == "https://a.example:443/z.pk3", "a rooted Location")
	_check(PackDownload.resolve_location("https://a.example/x/y.pk3", "z.pk3") == "https://a.example:443/x/z.pk3", "a relative Location")
	_check(PackDownload.resolve_location("https://a.example/x", "https://b.example/q") == "https://b.example/q", "an absolute Location")

func _init() -> void:
	_test_helpers()
	if not srv.start():
		_check(false, "the test HTTP server listens")
	else:
		_test_whole()
		_test_resume()
		_test_no_range()
		_test_cut()
		_test_lie()
		_test_wrong_hash()
		_test_fallback_and_redirect()
		_test_refused_source()
		_test_stale_partial()
		srv.stop()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
