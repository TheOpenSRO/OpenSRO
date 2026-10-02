extends RefCounted
class_name RetailGatewayClient

## The client's side of the ORIGINAL gateway protocol as far as the shard
## list (round 681), with no socket: feed() takes what the server sent and
## returns what to send back. Login is out of scope -- nothing here sends
## anything like one. server/internal/retailgw's Conversation is the same
## machine in Go; the transcripts in frontend/testdata hold the two to
## identical bytes. The facts, with addresses: docs/protocol/opcodes/gateway.md.
##
## The exchange (READ, sro_client unless noted):
##   S 0x5000  flags 0x0E: Blowfish key, count seed, crc seed, key exchange
##             (handshake key, G, P, A)              ACTIVE_SESSION 0x4b1da0
##   C 0x5000  u32 B, 8-byte challenge (plain)       0x4b1f87..0x4b2073
##   S 0x5000  flags 0x10, 8-byte challenge          0x4b1e3f..0x4b1eb1
##   C 0x9000  (plain)
##   C 0x2001  "SR_Client", 0 (encrypted)            CClientProcess::vslot_010
##   S 0x2001  "GatewayServer", byte                 CClientProcess::vslot_014
##   C 0x6100  content id, "SR_Client", version (encrypted)
##   S 0xA100  1 = go on (GatewayServer sends it as a massive 0x600D pair)
##   C 0x6101  (encrypted, empty)                    CClientNet::vslot_002
##   S 0xA101  farms, shards                         CClientProcess::FUN_004cda30
## then the connection is closed (OURS).

const OP_HANDSHAKE := 0x5000
const OP_ACCEPT := 0x9000
const OP_IDENTITY := 0x2001
const OP_MASSIVE := 0x600D
const OP_PATCH_REQUEST := 0x6100
const OP_PATCH_REPLY := 0xA100
const OP_LIST_REQUEST := 0x6101
const OP_LIST_REPLY := 0xA101

## READ: sro_client 0xdd3050 and 0xe1b310.
const CLIENT_MODULE := "SR_Client"
const GATEWAY_MODULE := "GatewayServer"

## OURS bounds.
const MAX_SHARDS := 64
const MAX_FARMS := 64
const MAX_MASSIVE_PARTS := 16
const MAX_MASSIVE_SIZE := 0x8000
## OURS: frames passed over while waiting (keep-alives and the like).
const MAX_FRAMES := 64

enum St { HELLO, CHALLENGE, IDENTITY, PATCH, LIST, DONE }

var content_id := 0
var version := 0
## The key exchange's private value: READ, the client takes a fresh GUID's
## first dword & 0x7fffffff (CoCreateGuid at 0x4c7078); here
## Crypto.generate_random_bytes (OURS), or a test's fixed value.
var private_x := 0

var state := St.HELLO
var sec: RetailSecurity = null
var shards: Array = [] # of {id, name, current, capacity, state, farm}
var farms: Array = [] # of {id, name}
var farm_byte := false

var _hello := {}
var _b := 0
var _k := 0
var _key1: Blowfish = null
var _massive := {}
var _frames := 0

func _init(p_content_id: int, p_version: int, p_private_x: int = -1) -> void:
	content_id = p_content_id & 0xFF
	version = p_version & RetailSecurity.MASK32
	if p_private_x >= 0:
		private_x = p_private_x & 0x7FFFFFFF
	else:
		private_x = Crypto.new().generate_random_bytes(4).decode_u32(0) & 0x7FFFFFFF

func done() -> bool:
	return state == St.DONE

## The farm byte rule of the gateway (READ, GatewayServer 0x412d7b..0x412daa:
## its content id is one of 3, 5, 9, 10, 0x1a, 0x1c, 0x15, 0x16, 0x17, 0x22).
static func farm_byte_for(cid: int) -> bool:
	return cid in [3, 5, 9, 10, 0x15, 0x16, 0x17, 0x1a, 0x1c, 0x22]

## Takes everything received so far: {"consumed": bytes used from the front,
## "send": bytes to write, "error": why it stopped ("" while going on),
## "retry": true when a new connection may succeed}.
func feed(buf: PackedByteArray) -> Dictionary:
	var out := {"consumed": 0, "send": PackedByteArray(), "error": "", "retry": false}
	# Built here and stored once: a packed array taken out of a Dictionary is
	# a copy, and appending to it is lost (round 681).
	var send := PackedByteArray()
	var off := 0
	while state != St.DONE:
		var rest := buf.slice(off)
		var n := RetailSecurity.frame_len(rest)
		if n < 0:
			out["error"] = "a frame whose size word 0x%04x is over %d bytes" % [rest.decode_u16(0), RetailSecurity.MAX_FRAME]
			break
		if n == 0:
			break
		var r := _frame(rest.slice(0, n))
		off += n
		if r.has("error"):
			out["error"] = r["error"]
			out["retry"] = r.get("retry", false)
			break
		if r.has("send"):
			send.append_array(r["send"])
	out["consumed"] = off
	out["send"] = send
	return out

func _frame(raw: PackedByteArray) -> Dictionary:
	_frames += 1
	if _frames > MAX_FRAMES:
		return {"error": "more than %d frames without the list" % MAX_FRAMES}
	var f := (sec if sec != null else RetailSecurity.new()).decode(raw)
	if f.has("error"):
		return f
	if state != St.HELLO:
		var why := sec.check_from_server(f)
		if why != "":
			return {"error": why}
	var op: int = f["opcode"]
	var p: PackedByteArray = f["payload"]
	match state:
		St.HELLO, St.CHALLENGE:
			# READ (0x4b1dd2): before the handshake ends only 0x5000 is taken.
			if op != OP_HANDSHAKE:
				return {"error": "opcode 0x%04x before the handshake finished (only 0x5000 is accepted)" % op}
			var h := decode_hello(p)
			if h.has("error"):
				return h
			return _on_hello(h) if state == St.HELLO else _on_challenge(h)
		St.IDENTITY:
			if op != OP_IDENTITY:
				return {} # OURS: a keep-alive or the like is passed over
			var id := decode_identity(p)
			if id.has("error"):
				return id
			if id["name"] != GATEWAY_MODULE:
				return {"error": "the server is '%s', not %s (the client asks only a gateway for the list)" % [id["name"], GATEWAY_MODULE]}
			state = St.PATCH
			return {"send": sec.encode_client(OP_PATCH_REQUEST, encode_patch_request(content_id, version), true)}
		St.PATCH, St.LIST:
			if op == OP_MASSIVE:
				var m := _feed_massive(p)
				if m.has("error") or not m.has("opcode"):
					return m
				op = m["opcode"]
				p = m["data"]
			if state == St.PATCH and op == OP_PATCH_REPLY:
				if p.is_empty():
					return {"error": "0xA100 is empty"}
				if p[0] != 1:
					var code := int(p[1]) if p.size() > 1 else -1
					return {"error": "the gateway refused this client in 0xA100: result %d, code %d (%s)" % [p[0], code, patch_code_text(code)]}
				state = St.LIST
				return {"send": sec.encode_client(OP_LIST_REQUEST, PackedByteArray(), true)}
			if state == St.LIST and op == OP_LIST_REPLY:
				var l := decode_shard_list_for(p, content_id)
				if l.has("error"):
					return l
				shards = l["shards"]
				farms = l["farms"]
				farm_byte = l["farm_byte"]
				state = St.DONE
			return {}
	return {"error": "a frame after the list"}

## READ (CClientProcess::vslot_015 0x4cf0c0, GatewayServer 0x4053c8); the
## meanings INFERRED.
static func patch_code_text(code: int) -> String:
	match code:
		2:
			return "a newer client is needed (patch)"
		4:
			return "the server is not in service"
	return "see docs/protocol/opcodes/gateway.md"

func _on_hello(h: Dictionary) -> Dictionary:
	var flags: int = h["flags"]
	if flags & RetailSecurity.FLAG_CHALLENGE:
		return {"error": "0x5000 flags 0x%02x: a challenge before the key exchange" % flags}
	if flags & ~(RetailSecurity.FLAG_BLOWFISH | RetailSecurity.FLAG_SECURITY | RetailSecurity.FLAG_HANDSHAKE):
		return {"error": "0x5000 flags 0x%02x: a variant this client does not speak" % flags}
	_hello = h
	sec = RetailSecurity.new()
	sec.flags = flags
	if flags & RetailSecurity.FLAG_SECURITY:
		var idx := RetailSecurity.crc_index(h["crc_seed"])
		if not RetailSecurity.crc_index_known(idx):
			return {"error": "the session's checksum table %d is not a standard one; reconnecting" % idx, "retry": true}
		sec.count = RetailSecurity.count_seeds(h["count_seed"])
		sec.crc_table = RetailSecurity.crc_table_for(idx)
	if flags & RetailSecurity.FLAG_BLOWFISH:
		sec.cipher = Blowfish.new(h["blowfish_key"])
	if not (flags & RetailSecurity.FLAG_HANDSHAKE):
		# READ (0x4b1f92..0x4b20b1): no key exchange -- accept at once.
		return _established(sec.encode_client(OP_ACCEPT, PackedByteArray(), false))
	var g: int = h["g"]
	var p: int = h["p"]
	var a: int = h["a"]
	if p < 2:
		return {"error": "0x5000: modulus %d (the client would divide by zero)" % p}
	_b = RetailSecurity.modpow(g, private_x, p)
	_k = RetailSecurity.modpow(a, private_x, p)
	_key1 = Blowfish.new(RetailSecurity.key_transform(RetailSecurity.pair(a, _b), _k, _k & 3))
	var chal := _key1.encrypt_le(RetailSecurity.key_transform(RetailSecurity.pair(_b, a), _k, _b & 7))
	var payload := PackedByteArray()
	payload.resize(4)
	payload.encode_u32(0, _b)
	payload.append_array(chal)
	state = St.CHALLENGE
	return {"send": sec.encode_client(OP_HANDSHAKE, payload, false)}

func _on_challenge(h: Dictionary) -> Dictionary:
	if h["flags"] != RetailSecurity.FLAG_CHALLENGE:
		return {"error": "0x5000 flags 0x%02x where the challenge (0x10) was due" % h["flags"]}
	var a: int = _hello["a"]
	var want := _key1.encrypt_le(RetailSecurity.key_transform(RetailSecurity.pair(a, _b), _k, a & 7))
	if want != h["challenge"]:
		return {"error": "the server's challenge does not match (the client's \"Handshake ServerSignature Error\")"}
	sec.cipher = Blowfish.new(RetailSecurity.key_transform(_hello["handshake_key"], _k, 3))
	return _established(sec.encode_client(OP_ACCEPT, PackedByteArray(), false))

## READ: the client's identity follows (0x2001 "SR_Client", 0, encrypted;
## sent on the session's connected notification, INFERRED to follow the
## accept).
func _established(accept: PackedByteArray) -> Dictionary:
	var out := accept.duplicate()
	out.append_array(sec.encode_client(OP_IDENTITY, encode_identity(CLIENT_MODULE, 0), true))
	state = St.IDENTITY
	return {"send": out}

func _feed_massive(p: PackedByteArray) -> Dictionary:
	if p.is_empty():
		return {"error": "0x600D: empty"}
	match p[0]:
		1:
			if not _massive.is_empty():
				return {"error": "0x600D: a second header before the first message ended"}
			if p.size() != 5:
				return {"error": "0x600D header: not u8 1, u16 count, u16 opcode"}
			var n := p.decode_u16(1)
			if n == 0 or n > MAX_MASSIVE_PARTS:
				return {"error": "0x600D header: %d parts (1-%d)" % [n, MAX_MASSIVE_PARTS]}
			_massive = {"opcode": p.decode_u16(3), "left": n, "data": PackedByteArray()}
			return {}
		0:
			if _massive.is_empty():
				return {"error": "0x600D: a part before its header"}
			var data: PackedByteArray = _massive["data"]
			if data.size() + p.size() - 1 > MAX_MASSIVE_SIZE:
				return {"error": "0x600D: over %d bytes" % MAX_MASSIVE_SIZE}
			data.append_array(p.slice(1))
			_massive["data"] = data
			_massive["left"] = int(_massive["left"]) - 1
			if int(_massive["left"]) == 0:
				var whole := {"opcode": _massive["opcode"], "data": data}
				_massive = {}
				return whole
			return {}
	return {"error": "0x600D: kind %d, not 0 or 1" % p[0]}

# --- Payloads -------------------------------------------------------------------

## A strict reader over one payload.
class Reader:
	var p: PackedByteArray
	var off := 0
	var bad := false

	func _init(payload: PackedByteArray) -> void:
		p = payload

	func u8() -> int:
		if off + 1 > p.size():
			bad = true
			return 0
		off += 1
		return p[off - 1]

	func u16() -> int:
		if off + 2 > p.size():
			bad = true
			return 0
		off += 2
		return p.decode_u16(off - 2)

	func u32() -> int:
		if off + 4 > p.size():
			bad = true
			return 0
		off += 4
		return p.decode_u32(off - 4)

	func bytes(n: int) -> PackedByteArray:
		if off + n > p.size():
			bad = true
			return PackedByteArray()
		off += n
		return p.slice(off - n, off)

	## READ (CClientProcess::FUN_004d36a0): a u16 length, then the bytes.
	func text() -> String:
		var n := u16()
		var b := bytes(n)
		return "" if bad else RetailGatewayClient.decode_name(b)

	func done() -> bool:
		return not bad and off == p.size()

## A name's bytes as text (OURS: ASCII as is; else UTF-8 when valid, else
## Latin-1 -- the client's own code page is the archive's and is not read
## here; control characters dropped).
static func decode_name(b: PackedByteArray) -> String:
	var ascii := true
	for c in b:
		if c >= 0x80:
			ascii = false
			break
	var s := ""
	if ascii:
		s = b.get_string_from_ascii()
	else:
		s = b.get_string_from_utf8()
		# Valid UTF-8 only if it encodes back to the same bytes.
		if s.to_utf8_buffer() != b:
			s = ""
			for c in b:
				s += String.chr(c)
	var clean := ""
	for ch in s:
		if ch.unicode_at(0) >= 0x20 and ch.unicode_at(0) != 0x7f:
			clean += ch
	return clean

## A 0x5000: {flags, blowfish_key, count_seed, crc_seed, handshake_key, g, p,
## a, challenge} or {"error"} (strict: the fields its flags name and nothing
## after them).
static func decode_hello(p: PackedByteArray) -> Dictionary:
	var r := Reader.new(p)
	var flags := r.u8()
	var h := {"flags": flags}
	if flags & RetailSecurity.FLAG_BLOWFISH:
		h["blowfish_key"] = r.bytes(8)
	if flags & RetailSecurity.FLAG_SECURITY:
		h["count_seed"] = r.u32()
		h["crc_seed"] = r.u32()
	if flags & RetailSecurity.FLAG_CHALLENGE:
		h["challenge"] = r.bytes(8)
	elif flags & RetailSecurity.FLAG_HANDSHAKE:
		h["handshake_key"] = r.bytes(8)
		h["g"] = r.u32()
		h["p"] = r.u32()
		h["a"] = r.u32()
	if r.bad:
		return {"error": "0x5000 (flags 0x%02x) ends early" % flags}
	if not r.done():
		return {"error": "0x5000 (flags 0x%02x): %d bytes after its fields" % [flags, p.size() - r.off]}
	return h

static func encode_text(w: PackedByteArray, s: String) -> void:
	var b := s.to_ascii_buffer()
	var at := w.size()
	w.resize(at + 2)
	w.encode_u16(at, b.size())
	w.append_array(b)

static func encode_identity(name: String, b: int) -> PackedByteArray:
	var w := PackedByteArray()
	encode_text(w, name)
	w.append(b)
	return w

static func decode_identity(p: PackedByteArray) -> Dictionary:
	var r := Reader.new(p)
	var name := r.text()
	var b := r.u8()
	if not r.done():
		return {"error": "0x2001 is not a name and a byte"}
	return {"name": name, "byte": b}

## READ (0x4cea72..0x4ceaba): u8 content id, "SR_Client", u32 version.
static func encode_patch_request(cid: int, ver: int) -> PackedByteArray:
	var w := PackedByteArray([cid & 0xFF])
	encode_text(w, CLIENT_MODULE)
	var at := w.size()
	w.resize(at + 4)
	w.encode_u32(at, ver & RetailSecurity.MASK32)
	return w

## A 0xA101 (READ, FUN_004cda30; GatewayServer 0x405800/0x412c80): per farm
## u8 1, u8 id, name; u8 0; per shard u8 1, u16 id, name, u16 current, u16
## capacity, u8 state[, u8 farm]; u8 0. Strict (OURS): a terminator must be
## 0 and the payload must end right after the last one.
static func decode_shard_list(p: PackedByteArray, with_farm: bool) -> Dictionary:
	var r := Reader.new(p)
	var fl: Array = []
	var sl: Array = []
	while true:
		var flag := r.u8()
		if r.bad:
			return {"error": "0xA101 farm flag: ends early"}
		if flag == 0:
			break
		if flag != 1:
			return {"error": "0xA101 farm flag: is %d, not 0 or 1" % flag}
		if fl.size() >= MAX_FARMS:
			return {"error": "0xA101 farms: more than %d" % MAX_FARMS}
		var f := {}
		f["id"] = r.u8()
		f["name"] = r.text()
		if r.bad:
			return {"error": "0xA101 farm: ends early"}
		fl.append(f)
	while true:
		var flag := r.u8()
		if r.bad:
			return {"error": "0xA101 shard flag: ends early"}
		if flag == 0:
			break
		if flag != 1:
			return {"error": "0xA101 shard flag: is %d, not 0 or 1" % flag}
		if sl.size() >= MAX_SHARDS:
			return {"error": "0xA101 shards: more than %d" % MAX_SHARDS}
		# One field at a time: the wire order is the read order.
		var s := {}
		s["id"] = r.u16()
		s["name"] = r.text()
		s["current"] = r.u16()
		s["capacity"] = r.u16()
		s["state"] = r.u8()
		s["farm"] = 0
		if with_farm:
			s["farm"] = r.u8()
		if r.bad:
			return {"error": "0xA101 shard: ends early"}
		sl.append(s)
	if not r.done():
		return {"error": "0xA101 end: %d bytes after the last terminator" % (p.size() - r.off)}
	return {"farms": fl, "shards": sl, "farm_byte": with_farm}

## The gateway's layout for this content id first, then the other (OURS:
## which one the client reads hangs on a word whose writer is OPEN).
static func decode_shard_list_for(p: PackedByteArray, cid: int) -> Dictionary:
	var first := farm_byte_for(cid)
	var l := decode_shard_list(p, first)
	if not l.has("error"):
		return l
	var l2 := decode_shard_list(p, not first)
	return l if l2.has("error") else l2
