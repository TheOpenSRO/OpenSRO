extends SceneTree

## Round 789, lane U: PackManifest against the golden bytes the Go server is
## held to. Every vector of net/testdata/client_packs_golden.json -- written
## by hand, field by field, from docs/protocol/asset_packs.md "Server packs"
## -- is encoded from its fields and must equal its hex, and decoded from its
## hex and must equal its fields; a vector marked "error" must fail to decode.
## The Go side runs the same file (server/internal/clientpacks
## TestManifestGolden). Then the name and URL rules on their own.

const GOLDEN := "res://scripts/net/testdata/client_packs_golden.json"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

static func _bytes(hex: String) -> PackedByteArray:
	return hex.replace(" ", "").replace("|", "").hex_decode()

func _from_fields(f: Dictionary) -> PackManifest:
	var m := PackManifest.new()
	m.required = bool(f["required"])
	m.local_extras = bool(f["local_extras"])
	m.http_port = int(f["http_port"])
	for p in f["packs"]:
		var pk := PackManifest.Pack.new()
		pk.name = str(p["name"])
		pk.size = int(p["size"])
		pk.sha256 = str(p["sha256"])
		pk.url = str(p["url"])
		m.packs.append(pk)
	return m

static func _same(a: PackManifest, b: PackManifest) -> bool:
	if a.required != b.required or a.local_extras != b.local_extras or a.http_port != b.http_port or a.packs.size() != b.packs.size():
		return false
	for i in range(a.packs.size()):
		var x := a.packs[i] as PackManifest.Pack
		var y := b.packs[i] as PackManifest.Pack
		if x.name != y.name or x.size != y.size or x.sha256 != y.sha256 or x.url != y.url:
			return false
	return true

func _test_golden() -> void:
	var doc = JSON.parse_string(FileAccess.get_file_as_string(GOLDEN))
	_check(doc is Dictionary, "the golden file parses")
	if not (doc is Dictionary):
		return
	_check(int(doc["opcodes"]["client_packs_request"]) == PackManifest.OP_REQUEST and int(doc["opcodes"]["client_packs"]) == PackManifest.OP_MANIFEST,
		"the opcodes are 0x0009 / 0x000A")
	var good := 0
	var bad := 0
	for v in doc["manifests"]:
		var name: String = v["name"]
		var want := _bytes(v["hex"])
		var got := PackManifest.decode(want)
		if v.get("error", false):
			bad += 1
			_check(got.error != "", "%s: refused (%s)" % [name, got.error])
			continue
		good += 1
		var m := _from_fields(v["fields"])
		var enc := m.encode()
		_check(enc == want, "%s: encodes to the golden bytes (got %s, want %s)" % [name, enc.hex_encode(), want.hex_encode()])
		_check(got.error == "" and _same(got, m), "%s: decodes to its fields (%s)" % [name, got.error])
	_check(good >= 5 and bad >= 20, "the file's %d good and %d bad vectors were all played" % [good, bad])

func _test_names() -> void:
	for ok in ["z_akatsuki.pk3", "A.ZIP", "pack-1.0.pk3", "0.pk3", "_.zip"]:
		_check(PackManifest.name_problem(ok) == "", "name %s taken" % ok)
	for bad in ["", "a", ".pk3", "a.pk2", "a.pk3x", "a/b.pk3", "a\\b.pk3", "../a.pk3", "a..b.pk3", "c:a.pk3", "a b.pk3",
			"Data.pk3", "PARTICLES.zip", "-" + "x".repeat(61) + ".pk3", "ä.pk3"]:
		_check(PackManifest.name_problem(bad) != "", "name '%s' refused (%s)" % [bad, PackManifest.name_problem(bad)])

func _test_urls() -> void:
	var p := PackManifest.parse_url("https://cdn.example.com/p/a.pk3?sig=1")
	_check(p == {"scheme": "https", "host": "cdn.example.com", "port": 443, "path": "/p/a.pk3?sig=1"}, "an https URL parses (%s)" % p)
	p = PackManifest.parse_url("http://10.0.0.5:15780/packs/a.pk3")
	_check(p == {"scheme": "http", "host": "10.0.0.5", "port": 15780, "path": "/packs/a.pk3"}, "an http URL with a port parses")
	p = PackManifest.parse_url("http://[::1]:8080/x")
	_check(p.get("host", "") == "::1" and int(p.get("port", 0)) == 8080, "an IPv6 host parses")
	_check(PackManifest.parse_url("HTTPS://x").get("path", "") == "/", "no path is /")
	for bad in ["ftp://x/a", "https://", "https://u@x/a", "https://x:0/a", "https://x:99999/a", "https://x:p/a", "x/a.pk3", "//x/a"]:
		_check(PackManifest.parse_url(bad).is_empty(), "'%s' is not a URL we fetch" % bad)
	_check(PackManifest.url_problem("https://x/a b") != "", "a space is refused")
	_check(PackManifest.url_problem("https://x/a#f") != "", "a fragment is refused")
	_check(PackManifest.url_problem("https://x/" + "a".repeat(600)) != "", "a URL past 512 bytes is refused")
	# OURS: https anywhere; plain http only from the game server's own host.
	_check(PackManifest.url_allowed("https://cdn.example.com/a.pk3", "10.0.0.5") == "", "https from another host: taken")
	_check(PackManifest.url_allowed("http://10.0.0.5:15780/packs/a.pk3", "10.0.0.5") == "", "http from the server's host: taken")
	_check(PackManifest.url_allowed("http://Login.Example.com/a.pk3", "login.example.com") == "", "the host compared without case")
	_check(PackManifest.url_allowed("http://evil.example.com/a.pk3", "10.0.0.5") != "", "http from another host: refused")
	var m := PackManifest.new()
	m.required = true
	m.http_port = 15780
	var pk := PackManifest.Pack.new()
	pk.name = "z.pk3"
	pk.url = "https://cdn.example.com/z.pk3"
	_check(m.sources(pk, "10.0.0.5") == PackedStringArray(["https://cdn.example.com/z.pk3", "http://10.0.0.5:15780/packs/z.pk3"]),
		"sources: the URL, then the server's listener")
	_check(m.sources(pk, "::1")[1] == "http://[::1]:15780/packs/z.pk3", "an IPv6 server's listener is bracketed")

func _init() -> void:
	_test_golden()
	_test_names()
	_test_urls()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
