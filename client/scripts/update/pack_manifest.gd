extends RefCounted
class_name PackManifest

## The packs a server names (round 789, lane U; OURS -- retail has only its
## .pk2 archives): OpClientPacks' payload, the answer to OpClientPacksRequest
## that PackQuery asks before login. The layout and every rule are
## docs/protocol/asset_packs.md, "Server packs"; the Go side is
## server/internal/clientpacks (manifest.go), and both are held to the same
## hand-written bytes, client/scripts/net/testdata/client_packs_golden.json.
##
##   u8 version (1) | u8 flags | u16 http_port | u8 count |
##   count x ( u8 name_len | name | u64 size | sha256[32] | u16 url_len | url )
##
## all little-endian. Flags: bit 0 the server names its packs (the client
## layers exactly these over its base archives), bit 1 the client may keep
## its own packs and custom/ too. Decoding is strict: a name that could leave
## the pack folder, a base archive's name, a size over the cap or a malformed
## URL refuses the whole manifest.

const OP_REQUEST := 0x0009
const OP_MANIFEST := 0x000A
const VERSION := 1
const FLAG_REQUIRED := 1
const FLAG_LOCAL_EXTRAS := 2
const MAX_PACKS := 32
const MAX_NAME := 64
const MAX_URL := 512
const MAX_PACK_BYTES := 4294967296 # 4 GiB a pack
const MAX_TOTAL_BYTES := 17179869184 # 16 GiB together

class Pack:
	var name := ""
	var size := 0
	## Lower-case hex.
	var sha256 := ""
	## "" = only the server's own listener.
	var url := ""

var required := false
var local_extras := false
var http_port := 0
var packs: Array = [] # of Pack, in the server's cascade order, lowest first
## Why the payload did not decode ("" when it did).
var error := ""

static var _name_re: RegEx = null

## Why `name` cannot be a server pack's file name ("" when it can): ASCII
## letters, digits, `_`, `-`, `.` (not first), ending .pk3 or .zip, at most 64
## bytes, no "..", not one of the five base names. No separator, drive, colon
## or space can appear, so the name never leaves the folder it is written to.
static func name_problem(name: String) -> String:
	if _name_re == null:
		_name_re = RegEx.create_from_string("^[A-Za-z0-9_-][A-Za-z0-9_.-]{0,59}\\.(?i:pk3|zip)$")
	if name.length() == 0 or name.to_utf8_buffer().size() > MAX_NAME:
		return "a pack name is 1-%d bytes" % MAX_NAME
	if _name_re.search(name) == null:
		return "a pack name is letters, digits, _ - and . (not first), ending .pk3 or .zip"
	if name.contains(".."):
		return "a pack name may not hold \"..\""
	if AssetArchives.is_base_stem(name.substr(0, name.length() - 4)):
		return "\"%s\" is a base archive's name, not a pack's" % name
	return ""

## Why `url` cannot be a pack's URL ("" when it can): http:// or https://,
## printable ASCII without spaces, a host, no user name or password, no
## fragment. Which hosts plain http is taken from is url_allowed's rule.
static func url_problem(url: String, max_len: int = MAX_URL) -> String:
	var b := url.to_utf8_buffer()
	if b.size() > max_len:
		return "a URL is at most %d bytes" % max_len
	for c in b:
		if c <= 0x20 or c >= 0x7f:
			return "a URL is printable ASCII without spaces"
	var p := parse_url(url)
	if p.is_empty():
		return "a URL is http:// or https:// with a host"
	if url.contains("#"):
		return "a URL may not carry a fragment"
	return ""

## {scheme, host, port, path} of an http(s) URL, or {} when it is not one
## (a user name, a missing host or a bad port included). path keeps the
## query; it is "/" when the URL has none.
static func parse_url(url: String) -> Dictionary:
	var lower := url.to_lower()
	var scheme := ""
	if lower.begins_with("https://"):
		scheme = "https"
	elif lower.begins_with("http://"):
		scheme = "http"
	else:
		return {}
	var rest := url.substr(scheme.length() + 3)
	var cut := rest.length()
	for sep in ["/", "?", "#"]:
		var at := rest.find(sep)
		if at >= 0 and at < cut:
			cut = at
	var authority := rest.substr(0, cut)
	var path := rest.substr(cut)
	if path.begins_with("#"):
		path = ""
	if path.begins_with("?"):
		path = "/" + path
	if path == "":
		path = "/"
	if authority.contains("@") or authority == "":
		return {}
	var host := authority
	var port := 443 if scheme == "https" else 80
	if authority.begins_with("["):
		var close := authority.find("]")
		if close < 0:
			return {}
		host = authority.substr(1, close - 1)
		var after := authority.substr(close + 1)
		if after != "":
			if not after.begins_with(":") or not after.substr(1).is_valid_int():
				return {}
			port = after.substr(1).to_int()
	else:
		var colon := authority.rfind(":")
		if colon >= 0:
			var ps := authority.substr(colon + 1)
			if not ps.is_valid_int():
				return {}
			port = ps.to_int()
			host = authority.substr(0, colon)
	if host == "" or port < 1 or port > 65535:
		return {}
	return {"scheme": scheme, "host": host, "port": port, "path": path}

## OURS (asset_packs.md, "Server packs"): https from any host; plain http
## only from the host the client reached the game server at (the server's
## own listener, or an operator URL on that host). The hash in the manifest
## -- which came over the game connection -- is what makes the bytes
## trustworthy either way; this keeps a player's downloads off unencrypted
## third parties.
static func url_allowed(url: String, gateway_host: String, max_len: int = MAX_URL) -> String:
	var why := url_problem(url, max_len)
	if why != "":
		return why
	var p := parse_url(url)
	if p["scheme"] == "https":
		return ""
	if str(p["host"]).to_lower() == gateway_host.to_lower():
		return ""
	return "plain http is taken only from the game server's own host (%s), not %s" % [gateway_host, p["host"]]

## Where `pack` can be fetched, in the order to try: its URL, then the
## server's own listener on the gateway's host.
func sources(pack: Pack, gateway_host: String) -> PackedStringArray:
	var out := PackedStringArray()
	if pack.url != "":
		out.append(pack.url)
	if http_port > 0:
		var h := gateway_host
		if h.contains(":"):
			h = "[%s]" % h
		out.append("http://%s:%d/packs/%s" % [h, http_port, pack.name])
	return out

func total_bytes() -> int:
	var t := 0
	for p in packs:
		t += (p as Pack).size
	return t

## Why the manifest cannot be used ("" when it can): Go's Manifest.Check.
func problem() -> String:
	if not required:
		if not packs.is_empty() or local_extras or http_port != 0:
			return "a manifest that names no packs carries no packs, extras or port"
		return ""
	if packs.size() > MAX_PACKS:
		return "%d packs, at most %d" % [packs.size(), MAX_PACKS]
	var seen := {}
	var total := 0
	for p in packs:
		var pk := p as Pack
		var why := name_problem(pk.name)
		if why != "":
			return "pack \"%s\": %s" % [pk.name, why]
		if seen.has(pk.name.to_lower()):
			return "pack \"%s\" named twice (case ignored)" % pk.name
		seen[pk.name.to_lower()] = true
		if pk.size < 1 or pk.size > MAX_PACK_BYTES:
			return "pack \"%s\": size %d, want 1-%d" % [pk.name, pk.size, MAX_PACK_BYTES]
		total += pk.size
		if pk.sha256.length() != 64 or not pk.sha256.is_valid_hex_number():
			return "pack \"%s\": the hash is not 32 bytes" % pk.name
		if pk.url != "":
			why = url_problem(pk.url)
			if why != "":
				return "pack \"%s\": URL: %s" % [pk.name, why]
		elif http_port == 0:
			return "pack \"%s\" has no URL and the server serves no files" % pk.name
	if total > MAX_TOTAL_BYTES:
		return "the packs total %d bytes, at most %d" % [total, MAX_TOTAL_BYTES]
	return ""

## The payload; empty when problem() is not "".
func encode() -> PackedByteArray:
	if problem() != "":
		return PackedByteArray()
	var out := PackedByteArray()
	out.append(VERSION)
	out.append((FLAG_REQUIRED if required else 0) | (FLAG_LOCAL_EXTRAS if local_extras else 0))
	out.append(http_port & 0xff)
	out.append(http_port >> 8)
	out.append(packs.size())
	for p in packs:
		var pk := p as Pack
		var n := pk.name.to_utf8_buffer()
		out.append(n.size())
		out.append_array(n)
		var sz := PackedByteArray()
		sz.resize(8)
		sz.encode_u64(0, pk.size)
		out.append_array(sz)
		out.append_array(pk.sha256.hex_decode())
		var u := pk.url.to_utf8_buffer()
		out.append(u.size() & 0xff)
		out.append(u.size() >> 8)
		out.append_array(u)
	return out

static func decode(data: PackedByteArray) -> PackManifest:
	var m := PackManifest.new()
	m.error = m._decode(data)
	if m.error == "":
		m.error = m.problem()
	if m.error != "":
		m.packs = []
	return m

func _decode(d: PackedByteArray) -> String:
	if d.size() < 5:
		return "truncated header"
	if d[0] != VERSION:
		return "version %d, want %d" % [d[0], VERSION]
	var flags := int(d[1])
	if flags & ~(FLAG_REQUIRED | FLAG_LOCAL_EXTRAS) != 0:
		return "unknown flag bits 0x%02x" % (flags & ~(FLAG_REQUIRED | FLAG_LOCAL_EXTRAS))
	required = flags & FLAG_REQUIRED != 0
	local_extras = flags & FLAG_LOCAL_EXTRAS != 0
	http_port = d.decode_u16(2)
	var count := int(d[4])
	if count > MAX_PACKS:
		return "%d packs, at most %d" % [count, MAX_PACKS]
	var at := 5
	for i in range(count):
		var pk := Pack.new()
		if at + 1 > d.size():
			return "pack %d: truncated name length" % i
		var nl := int(d[at])
		at += 1
		if at + nl > d.size():
			return "pack %d: truncated name" % i
		var nb := d.slice(at, at + nl)
		for c in nb:
			if c < 0x20 or c >= 0x7f:
				return "pack %d: the name is not printable ASCII" % i
		pk.name = nb.get_string_from_ascii()
		at += nl
		if at + 8 > d.size():
			return "pack %d: truncated size" % i
		# decode_u64 is a signed 64-bit int in GDScript: anything with the
		# top bit set reads negative, and is refused as past the cap anyway.
		pk.size = d.decode_u64(at)
		at += 8
		if pk.size < 0 or pk.size > MAX_PACK_BYTES:
			return "pack %d: size past the cap" % i
		if at + 32 > d.size():
			return "pack %d: truncated hash" % i
		pk.sha256 = d.slice(at, at + 32).hex_encode()
		at += 32
		if at + 2 > d.size():
			return "pack %d: truncated URL length" % i
		var ul := d.decode_u16(at)
		at += 2
		if ul > MAX_URL:
			return "pack %d: URL of %d bytes, at most %d" % [i, ul, MAX_URL]
		if at + ul > d.size():
			return "pack %d: truncated URL" % i
		var ub := d.slice(at, at + ul)
		for c in ub:
			if c <= 0x20 or c >= 0x7f:
				return "pack %d: the URL is not printable ASCII" % i
		pk.url = ub.get_string_from_ascii()
		at += ul
		packs.append(pk)
	if at != d.size():
		return "%d trailing byte(s)" % (d.size() - at)
	return ""

## One line for the log.
func describe() -> String:
	if not required:
		return "no packs"
	var names := PackedStringArray()
	for p in packs:
		names.append("%s (%d bytes, sha256 %s...)" % [(p as Pack).name, (p as Pack).size, (p as Pack).sha256.left(12)])
	return "%d pack(s)%s%s: %s" % [packs.size(), ", listener port %d" % http_port if http_port > 0 else "",
		", local extras allowed" if local_extras else "", ", ".join(names) if not names.is_empty() else "(none: the base archives only)"]
