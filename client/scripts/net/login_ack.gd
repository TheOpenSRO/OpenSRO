extends RefCounted
class_name LoginAckNet

## Retail's login request and reply (round 788): 0x6102 and 0xA102, byte for
## byte as sro_client.exe and GatewayServer.exe have them (RESEARCH section 1,
## docs/protocol/opcodes/login.md). The Go twin is
## server/internal/session/loginack.go; testdata/login_golden.json holds the
## two to the same bytes (login_ack_test.gd here, TestLoginGolden there).
##
## They ride OpenSRO's own framing to OpenSRO's server (NetClient.login) and
## retail's framing to a legacy gateway (RetailGatewayClient).

## READ: the client builds 0x6102 in CClientNet::vslot_004 0x4c9290 and reads
## 0xA102 in CClientProcess::vslot_017 0x4cf500.
const OP_GATEWAY_LOGIN := 0x6102
const OP_GATEWAY_LOGIN_ACK := 0xA102

## The result byte (READ): 1 success, 2 an error code follows.
const RESULT_OK := 1
const RESULT_FAIL := 2

## The error codes after result 2 (READ: the client's switch, jump table
## 0x86caf8 behind CPSTitle::vslot_006 0x86bfc0). 0 and 13 and above show
## nothing.
const ERR_PASSWORD := 1           # u32 max, u32 used follow
const ERR_BLOCKED := 2            # a block kind follows (BLOCK_*)
const ERR_ALREADY_CONNECTED := 3
const ERR_NO_SHARD := 4
const ERR_FULL := 5
const ERR_FAILED := 6
const ERR_SHARD_MISMATCH := 7
const ERR_IP_LIMIT := 8
const ERR_BILLING := 9
const ERR_ADULT_ONLY := 10
const ERR_TEEN_OVER_ONLY := 11
const ERR_TEEN_SERVER := 12

## The block kinds after ERR_BLOCKED (READ: GatewayServer's failure builder
## 0x40dc40; the client's cases).
const BLOCK_PUNISHED := 1         # string reason + the 16-byte end time follow
const BLOCK_INSPECTION := 2
const BLOCK_NO_ACCOUNT_INFO := 3
const BLOCK_FREE_OVER := 4

## The punishment's end time on the wire: an ODBC TIMESTAMP_STRUCT, u16 year,
## month, day, hour, minute, second and a u32 fraction (READ: the gateway
## copies 16 bytes from certparam+0x242; the client reads the six u16 and
## ignores the fraction, 0x4cf350).
const TIMESTAMP_SIZE := 16
## READ: the gateway's reason buffer is 0x200 bytes (certparam+0x42).
const REASON_MAX_BYTES := 0x200

## A 0x6102 payload (READ 0x4c9290): u8 content id, the ID and the password
## as u16-length narrow strings, u16 shard id. The ID is sent as typed (the
## client lower-cases only its own copy, for 0x6103).
class Request:
	var content_id := 0
	var username := ""
	var password := ""
	var shard_id := 0
	var error := ""

## A 0xA102 payload. Success: token, agent host and port (OpenSRO's own
## server sends an empty host and port 0: "stay on this connection", OURS).
## Failure: code, and by code the attempts (1) or the block (2).
class Ack:
	var ok := false
	var token := 0
	var agent_host := ""
	var agent_port := 0
	var code := 0
	var max_attempts := 0
	var used_attempts := 0
	var block_kind := 0
	var block_reason := ""
	## {year, month, day, hour, minute, second}: wall-clock fields, no zone.
	var block_end := {}
	var error := ""

# --- Encoding ---------------------------------------------------------------

static func _u16(out: PackedByteArray, v: int) -> void:
	out.append(v & 0xff)
	out.append((v >> 8) & 0xff)

static func _u32(out: PackedByteArray, v: int) -> void:
	for i in range(4):
		out.append((v >> (8 * i)) & 0xff)

## A u16 length and the bytes (READ: FUN_004cc920, lstrlenA, no terminator).
## The text goes out as UTF-8, the same bytes as the narrow ASCII the ID,
## password and names are in practice (as LobbyNet does).
static func _str(out: PackedByteArray, s: String) -> void:
	var b := s.to_utf8_buffer()
	_u16(out, b.size())
	out.append_array(b)

static func encode_request(r: Request) -> PackedByteArray:
	var out := PackedByteArray([r.content_id & 0xff])
	_str(out, r.username)
	_str(out, r.password)
	_u16(out, r.shard_id)
	return out

static func encode_login(content_id: int, username: String, password: String, shard_id: int) -> PackedByteArray:
	var r := Request.new()
	r.content_id = content_id
	r.username = username
	r.password = password
	r.shard_id = shard_id
	return encode_request(r)

## Encodes a reply as a server writes it (the tests' fake servers use it).
static func encode_ack(a: Ack) -> PackedByteArray:
	var out := PackedByteArray()
	if a.ok:
		out.append(RESULT_OK)
		_u32(out, a.token)
		_str(out, a.agent_host)
		_u16(out, a.agent_port)
		return out
	out.append(RESULT_FAIL)
	out.append(a.code & 0xff)
	match a.code:
		ERR_PASSWORD:
			_u32(out, a.max_attempts)
			_u32(out, a.used_attempts)
		ERR_BLOCKED:
			out.append(a.block_kind & 0xff)
			if a.block_kind == BLOCK_PUNISHED:
				_str(out, a.block_reason)
				for k in ["year", "month", "day", "hour", "minute", "second"]:
					_u16(out, int(a.block_end.get(k, 0)))
				_u32(out, 0)
	return out

# --- Decoding ---------------------------------------------------------------

## A strict little-endian reader.
class Reader:
	var data: PackedByteArray
	var pos := 0
	var error := ""

	func _init(d: PackedByteArray) -> void:
		data = d

	func _take(n: int, what: String) -> bool:
		if error != "":
			return false
		if pos + n > data.size():
			error = "%s: ends early" % what
			return false
		return true

	func u8(what: String) -> int:
		if not _take(1, what):
			return 0
		pos += 1
		return data[pos - 1]

	func u16(what: String) -> int:
		if not _take(2, what):
			return 0
		pos += 2
		return data.decode_u16(pos - 2)

	func u32(what: String) -> int:
		if not _take(4, what):
			return 0
		pos += 4
		return data.decode_u32(pos - 4)

	func raw(n: int, what: String) -> PackedByteArray:
		if not _take(n, what):
			return PackedByteArray()
		pos += n
		return data.slice(pos - n, pos)

	func text(what: String, max_bytes: int) -> String:
		var n := u16(what)
		var b := raw(n, what)
		if error != "":
			return ""
		return LoginAckNet.narrow_text(b, max_bytes)

	func rest() -> int:
		return data.size() - pos

## A narrow string's bytes as text: valid UTF-8 as such, anything else as
## Latin-1 (a retail server writes its own code page, which is not read
## here), at most max_bytes, control characters dropped except line breaks
## (OURS; RetailGatewayClient.decode_name's rule).
static func narrow_text(b: PackedByteArray, max_bytes: int) -> String:
	if b.size() > max_bytes:
		b = b.slice(0, max_bytes)
	# Line breaks are kept: a block reason may span lines.
	var lines: PackedStringArray = []
	var start := 0
	for i in range(b.size() + 1):
		if i == b.size() or b[i] == 0x0a:
			lines.append(RetailGatewayClient.decode_name(b.slice(start, i), max_bytes))
			start = i + 1
	return "\n".join(lines)

## Parses a 0x6102. Bytes after the shard id are an error (OURS: strict, as
## the Go twin).
static func decode_request(data: PackedByteArray) -> Request:
	var r := Request.new()
	var rd := Reader.new(data)
	r.content_id = rd.u8("0x6102 content id")
	r.username = rd.text("0x6102 ID", 0xffff)
	r.password = rd.text("0x6102 password", 0xffff)
	r.shard_id = rd.u16("0x6102 shard id")
	if rd.error == "" and rd.rest() != 0:
		rd.error = "0x6102: %d bytes after the shard id" % rd.rest()
	r.error = rd.error
	return r

## Parses a 0xA102. Trailing bytes are an error (OURS: strict); an unknown
## error code carries nothing after it, as the client reads nothing more.
static func decode_ack(data: PackedByteArray) -> Ack:
	var a := Ack.new()
	var rd := Reader.new(data)
	var res := rd.u8("0xA102 result")
	if rd.error != "":
		a.error = rd.error
		return a
	if res == RESULT_OK:
		a.ok = true
		a.token = rd.u32("0xA102 token")
		a.agent_host = rd.text("0xA102 agent host", 0xff)
		a.agent_port = rd.u16("0xA102 agent port")
	elif res == RESULT_FAIL:
		a.code = rd.u8("0xA102 error code")
		match a.code:
			ERR_PASSWORD:
				a.max_attempts = rd.u32("0xA102 code 1 max")
				a.used_attempts = rd.u32("0xA102 code 1 used")
			ERR_BLOCKED:
				a.block_kind = rd.u8("0xA102 block kind")
				if a.block_kind == BLOCK_PUNISHED:
					a.block_reason = rd.text("0xA102 block reason", REASON_MAX_BYTES)
					var t := rd.raw(TIMESTAMP_SIZE, "0xA102 block end")
					if rd.error == "":
						a.block_end = {"year": t.decode_u16(0), "month": t.decode_u16(2), "day": t.decode_u16(4),
							"hour": t.decode_u16(6), "minute": t.decode_u16(8), "second": t.decode_u16(10)}
	else:
		rd.error = "0xA102: result %d" % res
	if rd.error == "" and rd.rest() != 0:
		rd.error = "0xA102: %d trailing bytes" % rd.rest()
	a.error = rd.error
	return a
