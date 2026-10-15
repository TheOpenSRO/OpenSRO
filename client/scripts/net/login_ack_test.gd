extends SceneTree

## Round 788: LoginAckNet against the golden bytes the Go server is held to.
## Every vector of testdata/login_golden.json -- written by hand from the
## READ layouts (docs/protocol/opcodes/login.md) -- is encoded from its fields
## and must equal its hex, and decoded from its hex and must equal its fields;
## a vector marked "error" must fail to decode. The Go side runs the same file
## (server/internal/session TestLoginGolden).
##
## NEGATIVE: before round 788 LoginAckNet does not exist and this suite does
## not parse.

const GOLDEN := "res://scripts/net/testdata/login_golden.json"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

static func _bytes(hex: String) -> PackedByteArray:
	var clean := hex.replace(" ", "").replace("|", "")
	var out := PackedByteArray()
	for i in range(0, clean.length(), 2):
		out.append(clean.substr(i, 2).hex_to_int())
	return out

## "YYYY-MM-DD hh:mm:ss" -> the decoder's fields.
static func _time_fields(s: String) -> Dictionary:
	var d := s.split(" ")[0].split("-")
	var t := s.split(" ")[1].split(":")
	return {"year": int(d[0]), "month": int(d[1]), "day": int(d[2]), "hour": int(t[0]), "minute": int(t[1]), "second": int(t[2])}

func _ack_from(f: Dictionary) -> LoginAckNet.Ack:
	var a := LoginAckNet.Ack.new()
	a.ok = bool(f.get("ok", false))
	a.token = int(f.get("token", 0))
	a.agent_host = str(f.get("agent_host", ""))
	a.agent_port = int(f.get("agent_port", 0))
	a.code = int(f.get("code", 0))
	a.max_attempts = int(f.get("max_attempts", 0))
	a.used_attempts = int(f.get("used_attempts", 0))
	a.block_kind = int(f.get("block_kind", 0))
	a.block_reason = str(f.get("block_reason", ""))
	if f.has("block_end"):
		a.block_end = _time_fields(str(f["block_end"]))
	return a

static func _same_ack(a: LoginAckNet.Ack, b: LoginAckNet.Ack) -> bool:
	return a.ok == b.ok and a.token == b.token and a.agent_host == b.agent_host and a.agent_port == b.agent_port \
		and a.code == b.code and a.max_attempts == b.max_attempts and a.used_attempts == b.used_attempts \
		and a.block_kind == b.block_kind and a.block_reason == b.block_reason and str(a.block_end) == str(b.block_end)

func _test_golden() -> void:
	var text := FileAccess.get_file_as_string(GOLDEN)
	_check(text != "", "the golden file is readable at " + GOLDEN)
	var doc = JSON.parse_string(text)
	_check(doc is Dictionary, "the golden file parses")
	if not (doc is Dictionary):
		return
	var ops: Dictionary = doc["opcodes"]
	_check(int(ops["gateway_login"]) == LoginAckNet.OP_GATEWAY_LOGIN and int(ops["gateway_login_ack"]) == LoginAckNet.OP_GATEWAY_LOGIN_ACK,
		"the opcodes are 0x6102 / 0xA102")
	var n_req := 0
	for v in doc["requests"]:
		n_req += 1
		var name: String = v["name"]
		var want := _bytes(v["hex"])
		var got := LoginAckNet.decode_request(want)
		if v.get("error", false):
			_check(got.error != "", "request %s: refused to decode (%s)" % [name, got.error])
			continue
		var f: Dictionary = v["fields"]
		var enc := LoginAckNet.encode_login(int(f["content_id"]), str(f["username"]), str(f["password"]), int(f["shard_id"]))
		_check(enc == want, "request %s: encodes to the golden bytes (got %s, want %s)" % [name, enc.hex_encode(), want.hex_encode()])
		_check(got.error == "" and got.content_id == int(f["content_id"]) and got.username == str(f["username"])
			and got.password == str(f["password"]) and got.shard_id == int(f["shard_id"]), "request %s: decodes to its fields" % name)
	var n_ack := 0
	for v in doc["acks"]:
		n_ack += 1
		var name: String = v["name"]
		var want := _bytes(v["hex"])
		var got := LoginAckNet.decode_ack(want)
		if v.get("error", false):
			_check(got.error != "", "ack %s: refused to decode (%s)" % [name, got.error])
			continue
		var a := _ack_from(v["fields"])
		var enc := LoginAckNet.encode_ack(a)
		_check(enc == want, "ack %s: encodes to the golden bytes (got %s, want %s)" % [name, enc.hex_encode(), want.hex_encode()])
		_check(got.error == "" and _same_ack(got, a), "ack %s: decodes to its fields (%s)" % [name, got.error])
	_check(n_req >= 4 and n_ack >= 13, "the file's %d requests and %d acks were all played" % [n_req, n_ack])

## The reason's text: UTF-8 as such, a non-UTF-8 byte as Latin-1, line
## breaks kept, other controls dropped.
func _test_reason_text() -> void:
	_check(LoginAckNet.narrow_text("a\nb".to_utf8_buffer(), 0x200) == "a\nb", "a line break survives in a reason")
	_check(LoginAckNet.narrow_text(PackedByteArray([0x42, 0xe9, 0x09]), 0x200) == "Bé", "Latin-1 and a dropped tab")
	var long := PackedByteArray()
	long.resize(0x300)
	long.fill(0x41)
	_check(LoginAckNet.narrow_text(long, LoginAckNet.REASON_MAX_BYTES).length() == 0x200, "a reason is cut at the gateway's 0x200 bytes")

func _init() -> void:
	_test_golden()
	_test_reason_text()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
